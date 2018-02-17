import strutils, sequtils, macros

const indexVariableName = "__index__"
const emptyCheckName = "__empty__"
const iteratorVariableName = "it"
const internalIteratorName = "__" & iteratorVariableName & "__"

type 
  ExtNimNode = ref object
    node: NimNode
    index: int
    isLastItem: bool
    needsEmpty: bool

proc newExtNode(node: NimNode, 
                   index: int, 
                   isLastItem = false, 
                   needsEmpty = false): ExtNimNode =
  result = ExtNimNode(node: node, 
                      index: index, 
                      isLastItem: isLastItem, 
                      needsEmpty: needsEmpty)

proc clone(x: ExtNimNode): ExtNimNode {.compileTime.} =
    result = x.node.newExtNode(index = x.index, isLastItem = x.isLastItem, needsEmpty = x.needsEmpty)

proc iterFunction: NimNode {.compileTime.} =
  let empty = newEmptyNode()
  result = nnkLambda.newTree(
    empty,
    empty,
    empty,
    nnkFormalParams.newTree(newIdentNode("auto")),
    empty,
    empty,
    nnkStmtList.newTree())

proc itNode(index: int) : NimNode {.compileTime.} = 
  newIdentNode(internalIteratorName & ("$1" % $index))

proc adapt(ext: ExtNimNode, index=1): NimNode {.compileTime.} =
  let fun = ext.node[index]
  case fun.kind:
  of nnkIdent:
    if $fun == iteratorVariableName:
      return itNode(ext.index-1)
    else:
      return fun
  of nnkFloatLit..nnkFloat128Lit, nnkCharLit..nnkUInt64Lit, nnkStrLit..nnkTripleStrLit, nnkSym:
    return fun
  else:
    for z in 0..<fun.len:
      let son = ext.clone()
      son.node = fun
      fun.add(son.adapt(index=z))
    fun.del(0, fun.len div 2)
    return fun

proc res(ext: ExtNimNode): NimNode {.compileTime.} = 
  newIdentNode("result")

proc inlineZip(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let itIdent = itNode(ext.index)
  let idxIdent = newIdentNode(indexVariableName)
  let m = nnkCall.newTree(newIdentNode("min"), nnkBracket.newTree())
  let p = nnkPar.newTree()
  var z = 0
  for arg in ext.node:
    if z > 0:
      m[^1].add(nnkCall.newTree(newIdentNode("high"), arg))
      p.add(nnkBracketExpr.newTree(arg, idxIdent))
    z += 1
  let q = quote:
    let minHigh = `m`
    for `idxIdent` in 0..minHigh:
      let `itIdent` = `p`
  result = (q, q[1][^1], ext.index+1)

proc inlineMap(ext: ExtNimNode, indexed = false): (NimNode, NimNode, int) {.compileTime.} =
  let itIdent = itNode(ext.index)
  let adaptedF = ext.adapt()
  var next: NimNode
  if indexed:
    let idxIdent = newIdentNode(indexVariableName)
    next = quote:
      (`idxIdent`, `adaptedF`)
  else:
    next = adaptedF
  var q: NimNode
  if ext.isLastItem:
    let emptyIdent = newIdentNode(emptyCheckName)
    let resultIdent = ext.res
    q = quote:
      if `emptyIdent`:
        `emptyIdent` = false
        `resultIdent` = @[`next`]
      else:
        `resultIdent`.add(`next`)
  else:
    q = quote:
      let `itIdent` = `next`
  result = (q, nil, ext.index+1)

proc inlineFilter(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let itPreviousIdent = itNode(ext.index-1)
  let adaptedTest = ext.adapt()
  
  if ext.isLastItem:
    let emptyIdent = newIdentNode(emptyCheckName)
    let resultIdent = ext.res
    let q = quote:
      if `adaptedTest`:
        if `emptyIdent`:
          `emptyIdent` = false
          `resultIdent` = @[`itPreviousIdent`]
        else:
          `resultIdent`.add(`itPreviousIdent`)
    result = (q, q[0][^1], ext.index)
  else:
    let q = quote :
        if `adaptedTest`:
          nil
    q[0][0][1].del(0, 1) # remove nil statement
    #[
        check with echo(treeRepr(q))

        StmtList (q)
            IfStmt (q[0])
                ElifBranch (q[0][0])
                    <<Conditition>>
                    StmtList (q[0][0][1])
                        <<LetSection>>..
    ]#
    result = (q, q[0][0][1], ext.index)
 

proc inlineExists(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let adaptedTest = ext.adapt()
  let resultIdent = ext.res
  let q = quote:
    `resultIdent` = false
    if `adaptedTest`:
      return true
  result = (q, nil, ext.index)

proc inlineAll(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let adaptedTest = ext.adapt()
  let resultIdent = ext.res()
  let q = quote:
    `resultIdent` = true
    if not `adaptedTest`:
      return false
  result = (q, nil, ext.index)

proc inlineForeach(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let adaptedExpression = ext.adapt()
  let q = quote:
    `adaptedExpression`
  result = (q, nil, ext.index)
      
proc inlineIndex(ext: ExtNimNode): (NimNode, NimNode, int){.compileTime.} =
  let adaptedTest = ext.adapt()
  var idxIdent = newIdentNode(indexVariableName)
  var resultIdent = ext.res
  let q = quote:
    `resultIdent` = -1 # index not found
    if `adaptedTest`:
      return `idxIdent` # return index
  result = (q, nil, ext.index)  

proc inlineFold(ext: ExtNimNode, initials: NimNode): (NimNode, NimNode, int){.compileTime.} =
  let initialValue = ext.node[1]
  let resultIdent = ext.res()
  let foldOperation = ext.adapt(index=2)
  let i = quote:
    `resultIdent` = `initialValue`
  initials.add(i)
  let q = quote:
    `resultIdent` = `foldOperation`
  result = (q, nil, ext.index)

proc inlineEmpty(): NimNode {.compileTime.} =
  let emptyIdent = newIdentNode(emptyCheckName)
  result = quote:
    var `emptyIdent` = true
 
proc inlineSeq(ext: ExtNimNode): (NimNode, NimNode, int) {.compileTime.} =
  let itIdent = itNode(0)
  let node = ext.node
  let idxIdent = newIdentNode(indexVariableName)
  var q = quote:
    for `idxIdent`, `itIdent` in `node`:
      nil
  q[0][^1].del(0, 1) # remove nil statement from above quote
  if ext.needsEmpty:
    q = inlineEmpty().add(q) # insert 'var empty = true' to statement list in q
    result = (q, q[1][0][^1], ext.index+1)
  else:
    result = (q, q[0][^1], ext.index+1)

proc ensureLast(label: string, last: bool, node: NimNode) {.compileTime.} =
  if not last:
    error("$1 can be only last in a chain" % label, node)

proc ensureNotLast(label: string, last: bool, node: NimNode) {.compileTime.} =
  if last:
    error("$1 can be only last in a chain" % label, node)
        
proc inlineElement(node: NimNode, index: int, last: bool, needsEmpty: bool, initials: NimNode): (NimNode, NimNode, int) {.compileTime.} =
  let ext = node.newExtNode(index, last, needsEmpty)
  if node.kind == nnkCall:
    let label = $node[0]
    case label:
    of "zip":
        ensureNotLast(label, last, node)
        return ext.inlineZip()
    of "map":
      return ext.inlineMap()
    of "filter":
      return ext.inlineFilter()
    of "exists":
      ensureLast(label, last, node)
      return ext.inlineExists()
    of "all":
      ensureLast(label, last, node)
      return ext.inlineAll()
    of "index":
      ensureLast(label, last, node)
      return ext.inlineIndex()
    of "indexedMap":
      return ext.inlineMap(indexed=true)
    of "fold":
      ensureLast(label, last, node)
      return ext.inlineFold(initials)
    of "foreach":
      return ext.inlineForeach()
    else:
      error("$1 is unknown" % label, node)    
  else:
    if index != 0:
      error("seq supposed to be first", node)
    return ext.inlineSeq()

proc iterHandler(args: NimNode): NimNode {.compileTime.} =
  result = iterFunction()
  var code = result[^1]
  let initials = nnkStmtList.newTree()
  result[^1].add(initials)
  var needsEmpty = false
  if args.len > 0 and args[^1].len > 0:
    let lastCall = $args[^1][0]
    needsEmpty = (lastCall == "map") or (lastCall == "indexedMap") or (lastCall == "filter")
    if needsEmpty and args[0].kind == nnkCall:
        code.add(inlineEmpty())
  var index = 0

  for arg in args:
    let last = arg == args[^1]
    let (res, newCode, newIndex) = inlineElement(arg, index, last, needsEmpty, initials)
    code.add(res)
    if newCode != nil:
      code = newCode
    index = newIndex
  result = nnkCall.newTree(result)

macro inline_iter*(args: varargs[untyped]): untyped =
  result = iterHandler(args)

proc delegateMacro(a: NimNode, b:NimNode): NimNode =
  assert b.kind == nnkCall
  let methods = b
  var m: seq[NimNode] = @[]
  var node = methods
  while node.kind == nnkCall:
    if node[0].kind == nnkDotExpr:
      m.add(nnkCall.newTree(node[0][^1]))
      var z = 0
      for b in node:
        if z > 0:
          m[^1].add(b)
        z += 1
      node = node[0][0]
    elif node[0].kind == nnkIdent:
      m.add(node)
      break
    else:
      break
  var m2: seq[NimNode] = @[a]
  for z in countdown(high(m), low(m)):
    m2.add(m[z])
  let mad = nnkArgList.newTree(m2)
  result = iterHandler(mad)


macro `-->`*(a: untyped, b: untyped): untyped =
  result = delegateMacro(a,b)

macro `=>`*(a: untyped, b: untyped): untyped =
  result = delegateMacro(a,b)
