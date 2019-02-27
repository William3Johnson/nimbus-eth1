import options,
  eth/[common, bloom], ranges, chronicles, nimcrypto,
  ../db/[db_chain, state_db],
  ../utils, ../constants, ../transaction,
  ../vm_state, ../vm_types, ../vm_state_transactions,
  ../vm/[computation, interpreter_dispatch, message],
  ../vm/interpreter/vm_forks

proc contractCall*(tx: Transaction, vmState: BaseVMState, sender: EthAddress, forkOverride=none(Fork)): GasInt =
  var db = vmState.accountDb
  var computation = setupComputation(vmState, tx, sender, forkOverride)
  if execComputation(computation):
    let
      gasRemaining = computation.gasMeter.gasRemaining
      gasRefunded = computation.getGasRefund()
      gasUsed = tx.gasLimit - gasRemaining
      gasRefund = min(gasRefunded, gasUsed div 2)
      gasRefundAmount = (gasRefund + gasRemaining).u256 * tx.gasPrice.u256

    db.addBalance(sender, gasRefundAmount)
    return (tx.gasLimit - gasRemaining - gasRefund)
  else:
    if computation.tracingEnabled: computation.traceError()
    return tx.gasLimit

proc processTransaction*(tx: Transaction, sender: EthAddress, vmState: BaseVMState): GasInt =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = tx.rlpHash

  var db = vmState.accountDb
  var transactionFailed = false

  # TODO: combine/refactor re validate
  let upfrontGasCost = tx.gasLimit.u256 * tx.gasPrice.u256
  let upfrontCost = upfrontGasCost + tx.value
  var balance = db.getBalance(sender)
  if balance < upfrontCost:
    if balance <= upfrontGasCost:
      result = (balance div tx.gasPrice.u256).truncate(GasInt)
      balance = 0.u256
    else:
      result = tx.gasLimit
      balance -= upfrontGasCost
    transactionFailed = true
  else:
    balance -= upfrontGasCost

  db.incNonce(sender)
  db.setBalance(sender, balance)
  if transactionFailed: return

  # TODO: Run the vm with proper fork
  if tx.isContractCreation:
    result = applyCreateTransaction(tx, vmState, sender)
  else:
    result = contractCall(tx, vmState, sender)

type
  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  Bloom = common.BloomFilter
  LogsBloom = bloom.BloomFilter

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for receipt in receipts:
    bloom.value = bloom.value or logsBloom(receipt.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt(vmState: BaseVMState, cumulativeGasUsed: GasInt, fork = FkFrontier): Receipt =
  if fork < FkByzantium:
    result.stateRootOrStatus = hashOrStatus(vmState.accountDb.rootHash)
  else:
    # TODO: post byzantium fork use status instead of rootHash
    let vmStatus = true # success or failure
    result.stateRootOrStatus = hashOrStatus(vmStatus)

  result.cumulativeGasUsed = cumulativeGasUsed
  result.logs = vmState.getAndClearLogEntries()
  result.bloom = logsBloom(result.logs).value.toByteArrayBE

proc processBlock*(chainDB: BaseChainDB, head, header: BlockHeader, body: BlockBody, vmState: BaseVMState): ValidationResult =
  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot", blockNumber=header.blockNumber
    return ValidationResult.Error

  var stateDb = vmState.accountDb
  if header.txRoot != BLANK_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body", blockNumber=header.blockNumber
      return ValidationResult.Error
    else:
      trace "Has transactions", blockNumber = header.blockNumber, blockHash = header.blockHash

      vmState.receipts = newSeq[Receipt](body.transactions.len)
      var cumulativeGasUsed = GasInt(0)
      for txIndex, tx in body.transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          let gasUsed = processTransaction(tx, sender, vmState)
          cumulativeGasUsed += gasUsed

          # miner fee
          let txFee = gasUsed.u256 * tx.gasPrice.u256
          stateDb.addBalance(header.coinbase, txFee)
        else:
          debug "Could not get sender", txIndex, tx
          return ValidationResult.Error
        vmState.receipts[txIndex] = makeReceipt(vmState, cumulativeGasUsed)

  var mainReward = blockReward
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error
    for uncle in body.uncles:
      var uncleReward = uncle.blockNumber + 8.u256
      uncleReward -= header.blockNumber
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      stateDb.addBalance(uncle.coinbase, uncleReward)
      mainReward += blockReward div 32.u256

  # Reward beneficiary
  stateDb.addBalance(header.coinbase, mainReward)

  if header.stateRoot != stateDb.rootHash:
    error "Wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash, arrivedFrom=chainDB.getCanonicalHead().stateRoot
    # this one is a show stopper until we are confident in our VM's
    # compatibility with the main chain
    return ValidationResult.Error

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    debug "wrong bloom in block", blockNumber=header.blockNumber
    return ValidationResult.Error

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block", blockNumber=header.blockNumber, actual=receiptRoot, expected=header.receiptRoot
    return ValidationResult.Error
