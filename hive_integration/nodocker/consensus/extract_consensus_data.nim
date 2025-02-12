# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[json, strutils, options],
  stew/byteutils

type
  ChainData* = object
    genesis*: string
    lastBlockHash*: string
    blocksRlp*: seq[byte]

const genFields = [
  "nonce",
  "timestamp",
  "extraData",
  "gasLimit",
  "difficulty",
  "mixHash",
  "coinbase"
]

proc processNetwork(network: string): JsonNode =
  var
    homesteadBlock      = 2000
    daoForkSupport      = false
    daoForkBlock        = homesteadBlock
    eip150Block         = 2000
    eip158Block         = 2000
    byzantiumBlock      = 2000
    constantinopleBlock = 2000
    petersburgBlock     = 2000
    istanbulBlock       = 2000
    muirGlacierBlock    = 2000
    berlinBlock         = 2000
    londonBlock         = 2000
    arrowGlacierBlock   = 2000
    mergeForkBlock      = none(int)
    ttd                 = none(int)

  case network

  # All the network forks, which includes all the EVM, DAO and Glacier forks.
  of "Frontier":
    discard
  of "Homestead":
    homesteadBlock = 0
  of "EIP150":
    homesteadBlock = 0
    eip150Block    = 0
  of "EIP158":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
  of "Byzantium":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
  of "Constantinople":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
  of "ConstantinopleFix":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock =     0
  of "Istanbul":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock   = 0
  of "Berlin":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock   = 0
  of "London":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock   = 0
    londonBlock = 0
  of "ArrowGlacier":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock   = 0
    londonBlock = 0
    arrowGlacierBlock = 0
  of "Merge":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock   = 0
    londonBlock = 0
    arrowGlacierBlock = 0
    mergeForkBlock = some(0)
    ttd = some(0)

  # Just the subset of "At5" networks mentioned in the test suite.
  of "FrontierToHomesteadAt5":
    homesteadBlock = 5
  of "HomesteadToDaoAt5":
    homesteadBlock = 0
    daoForkSupport = true
    daoForkBlock   = 5
  of "HomesteadToEIP150At5":
    homesteadBlock = 0
    eip150Block = 5
  of "EIP158ToByzantiumAt5":
    homesteadBlock = 0
    eip150Block = 0
    eip158Block = 0
    byzantiumBlock = 5
  of "ByzantiumToConstantinopleFixAt5":
    homesteadBlock = 0
    eip150Block = 0
    eip158Block = 0
    byzantiumBlock = 0
    constantinopleBlock = 5
    petersburgBlock = 5
  of "BerlinToLondonAt5":
    homesteadBlock = 0
    eip150Block = 0
    eip158Block = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock = 0
    londonBlock = 5
  of "ArrowGlacierToMergeAtDiffC0000":
    homesteadBlock = 0
    eip150Block    = 0
    eip158Block    = 0
    byzantiumBlock = 0
    constantinopleBlock = 0
    petersburgBlock = 0
    istanbulBlock = 0
    muirGlacierBlock = 0
    berlinBlock   = 0
    londonBlock = 0
    arrowGlacierBlock = 0
    ttd = some(0xC0000)

  else:
    doAssert(false, "unsupported network: " & network)

  var n = newJObject()
  n["homesteadBlock"]      = newJInt(homesteadBlock)
  if daoForkSupport:
    n["daoForkSupport"]    = newJBool(daoForkSupport)
    n["daoForkBlock"]      = newJInt(daoForkBlock)
  n["eip150Block"]         = newJInt(eip150Block)
  n["eip158Block"]         = newJInt(eip158Block)
  n["byzantiumBlock"]      = newJInt(byzantiumBlock)
  n["constantinopleBlock"] = newJInt(constantinopleBlock)
  n["petersburgBlock"]     = newJInt(petersburgBlock)
  n["istanbulBlock"]       = newJInt(istanbulBlock)
  n["muirGlacierBlock"]    = newJInt(muirGlacierBlock)
  n["berlinBlock"]         = newJInt(berlinBlock)
  n["londonBlock"]         = newJInt(londonBlock)
  n["arrowGlacierBlock"]   = newJInt(arrowGlacierBlock)
  if mergeForkBlock.isSome:
    n["mergeForkBlock"]    = newJInt(mergeForkBlock.get())
  n["chainId"]             = newJInt(1)
  if ttd.isSome:
    n["terminalTotalDifficulty"] = newJString("0x" & ttd.get().toHex(8))
  result = n

proc optionalField(n: string, genesis, gen: JsonNode) =
  if n in gen:
    genesis[n] = gen[n]

proc extractChainData*(n: JsonNode): ChainData =
  let gen = n["genesisBlockHeader"]
  var genesis = newJObject()
  for x in genFields:
    genesis[x] = gen[x]

  optionalField("baseFeePerGas", genesis, gen)
  genesis["alloc"] = n["pre"]

  var ngen = newJObject()
  ngen["genesis"] = genesis
  ngen["config"] = processNetwork(n["network"].getStr)
  result.lastblockhash = n["lastblockhash"].getStr
  result.genesis = $ngen

  let blks = n["blocks"]
  for x in blks:
    let hex = x["rlp"].getStr
    let bytes = hexToSeqByte(hex)
    result.blocksRlp.add bytes
