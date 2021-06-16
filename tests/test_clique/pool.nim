# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[random, sequtils, strformat, strutils, tables, times],
  ../../nimbus/[config, chain_config, constants, genesis, utils],
  ../../nimbus/db/db_chain,
  ../../nimbus/p2p/clique,
  ../../nimbus/p2p/clique/[clique_defs, clique_utils],
  ./voter_samples as vs,
  eth/[common, keys, rlp, trie/db],
  ethash,
  secp256k1_abi,
  stew/objects

export
  vs

const
  prngSeed = 42
  # genesisTemplate = "../customgenesis/berlin2000.json"

type
  XSealKey = array[EXTRA_SEAL,byte]
  XSealValue = object
    blockNumber: uint64
    account:     string

  TesterPool* = ref object ## Pool to maintain currently active tester accounts,
                           ## mapped from textual names used in the tests below
                           ## to actual Ethereum private keys capable of signing
                           ## transactions.
    prng: Rand
    accounts: Table[string,PrivateKey] ## accounts table
    boot: CustomGenesis                ## imported Genesis configuration
    batch: seq[seq[BlockHeader]]       ## collect header chains
    engine: Clique

    names: Table[EthAddress,string]    ## reverse lookup for debugging
    xSeals: Table[XSealKey,XSealValue] ## collect signatures for debugging
    debug: bool                        ## debuggin mode for sub-systems

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

proc bespokeGenesis(file: string): CustomGenesis =
  ## Find genesis block
  if file == "":
    let networkId = getConfiguration().net.networkId
    result.genesis = defaultGenesisBlockForNetwork(networkId)
  else:
    doAssert file.loadCustomGenesis(result)
  result.config.poaEngine = true

proc chain(ap: TesterPool): BaseChainDB =
  ## Getter
  ap.engine.cfgInternal.dbChain

proc isZero(a: openArray[byte]): bool =
  result = true
  for w in a:
    if w != 0:
      return false

proc rand(ap: TesterPool): byte =
  ap.prng.rand(255).byte

proc newPrivateKey(ap: TesterPool): PrivateKey =
  ## Roughly modelled after `random(PrivateKey,getRng()[])` with
  ## non-secure but reproducible PRNG
  var data{.noinit.}: array[SkRawSecretKeySize,byte]
  for n in 0 ..< data.len:
    data[n] = ap.rand
  # verify generated key, see keys.random(PrivateKey) from eth/keys.nim
  var dataPtr0 = cast[ptr cuchar](unsafeAddr data[0])
  doAssert secp256k1_ec_seckey_verify(
    secp256k1_context_no_precomp, dataPtr0) == 1
  # Convert to PrivateKey
  PrivateKey.fromRaw(data).value

proc privateKey(ap: TesterPool; account: string): PrivateKey =
  ## Return private key for given tester `account`
  if account != "":
    if account in ap.accounts:
      result = ap.accounts[account]
    else:
      result = ap.newPrivateKey
      ap.accounts[account] = result
      let address = result.toPublicKey.toCanonicalAddress
      ap.names[address] = account

proc resetChainDb(ap: TesterPool; extraData: Blob) =
  ## Setup new block chain with bespoke genesis
  ap.engine.cfgInternal.dbChain = BaseChainDB(
      db: newMemoryDb(),
      config: ap.boot.config)
  # new genesis block
  var g = ap.boot.genesis
  if 0 < extraData.len:
    g.extraData = extraData
  g.commit(ap.engine.cfgInternal.dbChain)

# ------------------------------------------------------------------------------
# Private pretty printer call backs
# ------------------------------------------------------------------------------

proc findName(ap: TesterPool; address: EthAddress): string =
  ## Find name for a particular address
  if address in ap.names:
    return ap.names[address]

proc findSignature(ap: TesterPool; sig: openArray[byte]): XSealValue =
  ## Find a previusly registered signature
  if sig.len == XSealKey.len:
    let key = toArray(XSealKey.len,sig)
    if key in ap.xSeals:
      result = ap.xSeals[key]

proc ppNonce(ap: TesterPool; v: BlockNonce): string =
  ## Pretty print nonce
  if v == NONCE_AUTH:
    "AUTH"
  elif v == NONCE_DROP:
    "DROP"
  else:
    &"0x{v.toHex}"

proc ppAddress(ap: TesterPool; v: EthAddress): string =
  ## Pretty print address
  if v.isZero:
    result = "@0"
  else:
    let a = ap.findName(v)
    if a == "":
      result = &"@{v}"
    else:
      result = &"@{a}"

proc ppExtraData(ap: TesterPool; v: Blob): string =
  ## Visualise `extraData` field

  if v.len < EXTRA_VANITY + EXTRA_SEAL or
     ((v.len - (EXTRA_VANITY + EXTRA_SEAL)) mod EthAddress.len) != 0:
    result = &"0x{v.toHex}[{v.len}]"
  else:
    var data = v
    #
    # extra vanity prefix
    let vanity = data[0 ..< EXTRA_VANITY]
    data = data[EXTRA_VANITY ..< data.len]
    result = if vanity.isZero: "0u256+" else: &"{vanity.toHex}+"
    #
    # list of addresses
    if EthAddress.len + EXTRA_SEAL <= data.len:
      var glue = "["
      while EthAddress.len + EXTRA_SEAL <= data.len:
        let address = toArray(EthAddress.len,data[0 ..< EthAddress.len])
        data = data[EthAddress.len ..< data.len]
        result &= &"{glue}{ap.ppAddress(address)}"
        glue = ","
      result &= "]+"
    #
    # signature
    let val = ap.findSignature(data)
    if val.account != "":
      result &= &"<#{val.blockNumber},{val.account}>"
    elif data.isZero:
      result &= &"<0>"
    else:
      let sig = SkSignature.fromRaw(data)
      if sig.isOk:
        result &= &"<{sig.value.toHex}>"
      else:
        result &= &"0x{data.toHex}[{data.len}]"

proc ppBlockHeader(ap: TesterPool; v: BlockHeader; delim: string): string =
  ## Pretty print block header
  let sep = if 0 < delim.len: delim else: ";"
  &"(blockNumber=#{v.blockNumber.truncate(uint64)}" &
    &"{sep}coinbase={ap.ppAddress(v.coinbase)}" &
    &"{sep}nonce={ap.ppNonce(v.nonce)}" &
    &"{sep}extraData={ap.ppExtraData(v.extraData)})"

proc initPrettyPrinters(pp: var PrettyPrinters; ap: TesterPool) =
  pp.nonce =       proc(v:BlockNonce):            string = ap.ppNonce(v)
  pp.address =     proc(v:EthAddress):            string = ap.ppAddress(v)
  pp.extraData =   proc(v:Blob):                  string = ap.ppExtraData(v)
  pp.blockHeader = proc(v:BlockHeader; d:string): string = ap.ppBlockHeader(v,d)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(t: TesterPool): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  t.engine.cfgInternal.prettyPrint

proc say*(t: TesterPool; v: varargs[string,`$`]) =
  if t.debug:
    stderr.write v.join & "\n"


proc newTesterPool*(epoch = 0.u256; genesisTemplate = ""): TesterPool =
  new result
  result.boot = genesisTemplate.bespokeGenesis
  result.prng = initRand(prngSeed)
  result.batch = @[newSeq[BlockHeader]()]
  result.accounts = initTable[string,PrivateKey]()
  result.xSeals = initTable[XSealKey,XSealValue]()
  result.names = initTable[EthAddress,string]()
  result.engine = newCliqueCfg(
         dbChain = BaseChainDB(),
         period = initDuration(seconds = 1),
         epoch = epoch)
       .initClique
  result.engine.setDebug(false)
  result.engine.cfgInternal.prettyPrint.initPrettyPrinters(result)
  result.resetChainDb(@[])


proc setDebug*(ap: TesterPool; debug = true) =
  ## Set debugging mode on/off
  ap.debug = debug
  ap.engine.setDebug(debug)


# clique/snapshot_test.go(62): func (ap *testerAccountPool) address(account [..]
proc address*(ap: TesterPool; account: string): EthAddress =
  ## retrieves the Ethereum address of a tester account by label, creating
  ## a new account if no previous one exists yet.
  if account != "":
    result = ap.privateKey(account).toPublicKey.toCanonicalAddress


# clique/snapshot_test.go(49): func (ap *testerAccountPool) [..]
proc checkpoint*(ap: TesterPool;
                header: var BlockHeader; signers: openArray[string]) =
  ## creates a Clique checkpoint signer section from the provided list
  ## of authorized signers and embeds it into the provided header.
  header.extraData.setLen(EXTRA_VANITY)
  header.extraData.add signers
    .mapIt(ap.address(it))
    .sorted(EthAscending)
    .mapIt(toSeq(it))
    .concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)


# clique/snapshot_test.go(77): func (ap *testerAccountPool) sign(header n[..]
proc sign*(ap: TesterPool; header: var BlockHeader; signer: string) =
  ## sign calculates a Clique digital signature for the given block and embeds
  ## it back into the header.
  #
  # Sign the header and embed the signature in extra data
  let
    hashData = header.hashSealHeader.data
    signature = ap.privateKey(signer).sign(SkMessage(hashData)).toRaw
    extraLen = header.extraData.len
  header.extraData.setLen(extraLen -  EXTRA_SEAL)
  header.extraData.add signature
  #
  # Register for debugging
  ap.xSeals[signature] = XSealValue(
    blockNumber: header.blockNumber.truncate(uint64),
    account:     signer)


proc snapshot*(ap: TesterPool; number: BlockNumber; hash: Hash256;
               parent: openArray[BlockHeader]): auto =
  ## Call p2p/clique.snapshotInternal()
  if ap.debug:
    var header = ap.chain.getBlockHeader(number)
    ap.say "*** snapshot argument: ", ap.pp(header,24)
    while true:
      doAssert ap.chain.getBlockHeader(header.parentHash,header)
      ap.say "        parent header: ", ap.pp(header,24)
      if header.blockNumber.isZero:
        break
    when false: # all addresses are typically pp-mappable
      ap.say "          address map: ", toSeq(ap.names.pairs)
                                          .mapIt(&"@{it[1]}:{it[0]}")
                                          .sorted
                                          .join("\n" & ' '.repeat(23))

  ap.engine.snapshotInternal(number, hash, parent)

# ------------------------------------------------------------------------------
# Public: set up & manage voter database
# ------------------------------------------------------------------------------

proc resetVoterChain*(ap: TesterPool;
                      signers: openArray[string]; epoch: uint64) =
  ## Reset the batch list for voter headers and update genesis block
  ap.batch = @[newSeq[BlockHeader]()]

  # clique/snapshot_test.go(384): signers := make([]common.Address, [..]
  let signers = signers.mapIt(ap.address(it)).sorted(EthAscending)

  var extraData = 0.byte.repeat(EXTRA_VANITY)

  # clique/snapshot_test.go(399): for j, signer := range signers {
  for signer in signers:
    extraData.add signer.toSeq

  # clique/snapshot_test.go(397):
  extraData.add 0.byte.repeat(EXTRA_SEAL)

  # store modified genesis block and epoch
  ap.resetChainDb(extraData)
  ap.engine.cfgInternal.epoch = epoch


# clique/snapshot_test.go(415): blocks, _ := core.GenerateChain(&config, [..]
proc appendVoter*(ap: TesterPool; voter: TesterVote) =
  ## Append a voter header to the block chain batch list
  doAssert 0 < ap.batch.len # see initTesterPool() and resetVoterChain()
  let parent = if ap.batch[^1].len == 0:
                 ap.chain.getBlockHeader(0.u256)
               else:
                 ap.batch[^1][^1]

  var header = BlockHeader(
    parentHash:  parent.hash,
    ommersHash:  EMPTY_UNCLE_HASH,
    stateRoot:   parent.stateRoot,
    timestamp:   parent.timestamp + initDuration(seconds = 10),
    txRoot:      BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH,
    blockNumber: parent.blockNumber + 1,
    gasLimit:    parent.gasLimit,
    #
    # clique/snapshot_test.go(417): gen.SetCoinbase(accounts.address( [..]
    coinbase:    ap.address(voter.voted),
    #
    # clique/snapshot_test.go(418): if tt.votes[j].auth {
    nonce:       if voter.auth: NONCE_AUTH else: NONCE_DROP,
    #
    # clique/snapshot_test.go(436): header.Difficulty = diffInTurn [..]
    difficulty:  DIFF_INTURN,  # Ignored, we just need a valid number
    #
    extraData:   0.byte.repeat(EXTRA_VANITY + EXTRA_SEAL))

  # clique/snapshot_test.go(432): if auths := tt.votes[j].checkpoint; [..]
  if 0 < voter.checkpoint.len:
    doAssert (header.blockNumber mod ap.engine.cfgInternal.epoch) == 0
    ap.checkpoint(header,voter.checkpoint)

  # Generate the signature, embed it into the header and the block
  ap.sign(header, voter.signer)

  if voter.newbatch:
    ap.batch.add @[]
  ap.batch[^1].add header


proc commitVoterChain*(ap: TesterPool) =
  ## Write the headers from the voter header batch list to the block chain DB
  # Create a pristine blockchain with the genesis injected
  for headers in ap.batch:
    if 0 < headers.len:
      doAssert ap.chain.getCanonicalHead.blockNumber < headers[0].blockNumber

      # see p2p/chain.persistBlocks()
      ap.chain.highestBlock = headers[^1].blockNumber
      let transaction = ap.chain.db.beginTransaction()
      for i in 0 ..< headers.len:
        let header = headers[i]

        discard ap.chain.persistHeaderToDb(header)
        doAssert ap.chain.getCanonicalHead().blockHash == header.blockHash

        discard ap.chain.persistTransactions(header.blockNumber, @[])
        discard ap.chain.persistReceipts(@[])
        ap.chain.currentBlock = header.blockNumber
      transaction.commit()


proc topVoterHeader*(ap: TesterPool): BlockHeader =
  ## Get top header from voter batch list
  doAssert 0 < ap.batch.len # see initTesterPool() and resetVoterChain()
  if 0 < ap.batch[^1].len:
    result = ap.batch[^1][^1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------