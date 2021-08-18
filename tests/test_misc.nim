import
  std/[os, parseopt],
  unittest2, stew/byteutils,
  eth/common/eth_types,
  eth/p2p,
  ../nimbus/vm_internals,
  ../nimbus/config,
  ../nimbus/utils/header

func toAddress(n: int): EthAddress =
  result[19] = n.byte

func toAddress(a, b: int): EthAddress =
  result[18] = a.byte
  result[19] = b.byte

func toAddress(a, b, c: int): EthAddress =
  result[17] = a.byte
  result[18] = b.byte
  result[19] = c.byte

proc miscMain*() =
  suite "Misc test suite":
    test "EthAddress to int":
      check toAddress(0xff).toInt == 0xFF
      check toAddress(0x10, 0x0).toInt == 0x1000
      check toAddress(0x10, 0x0, 0x0).toInt == 0x100000

    const genesisFile = "tests" / "customgenesis" / "calaveras.json"
    test "networkid cli":
      var msg: string
      var opt = initOptParser("--customnetwork:" & genesisFile & " --networkid:345")
      let res = processArguments(msg, opt)
      if res != Success:
        echo msg
        quit(QuitFailure)

      let conf = getConfiguration()
      check conf.net.networkId == 345.NetworkId

    test "networkid first, customnetwork next":
      var msg: string
      var opt = initOptParser("--networkid:678 --customnetwork:" & genesisFile)
      let res = processArguments(msg, opt)
      if res != Success:
        echo msg
        quit(QuitFailure)

      let conf = getConfiguration()
      check conf.net.networkId == 678.NetworkId

    test "networkid not set, copy from chainId of customnetwork":
      let conf = getConfiguration()
      conf.net.flags.excl NetworkIdSet
      var msg: string
      var opt = initOptParser("--customnetwork:" & genesisFile)
      let res = processArguments(msg, opt)
      if res != Success:
        echo msg
        quit(QuitFailure)

      check conf.net.networkId == 123.NetworkId

    test "calcGasLimitEIP1559":
      type
        GLT = object
          limit: GasInt
          max  : GasInt
          min  : GasInt

      const testData = [
        GLT(limit: 20000000, max: 20019530, min: 19980470),
        GLT(limit: 40000000, max: 40039061, min: 39960939)
      ]

      for x in testData:
        # Increase
        var have = calcGasLimit1559(x.limit, 2*x.limit)
        var want = x.max
        check have == want

        # Decrease
        have = calcGasLimit1559(x.limit, 0)
        want = x.min
        check have == want

        # Small decrease
        have = calcGasLimit1559(x.limit, x.limit-1)
        want = x.limit-1
        check have == want

        # Small increase
        have = calcGasLimit1559(x.limit, x.limit+1)
        want = x.limit+1
        check have == want

        # No change
        have = calcGasLimit1559(x.limit, x.limit)
        want = x.limit
        check have == want

when isMainModule:
  miscMain()
