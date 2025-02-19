import macros, sequtils, strformat, options, sets, tables, algorithm, strutils
import formulaNameMacro

import column, value, df_types

type
  AssignKind* = enum
    byIndex, byTensor
  ## replace occurence of nnkAccQuote, nnkCallStrLit, nnkBracketExpr(df) by:
  ReplaceByKind = enum
    rbIndex ## by call to tensor index, `tT[idx]`, in a `for` loop
    rbElement ## by single element, `tIdx` in a `forEach` call
    rbColumn ## by full tensor (df column), `colT` in `<<` formula
  ## `impure` in the context of `FormulaNode` refers to evaluation requiring
  ## a data frame. Pure formulas represent raw expressions that evaluate to
  ## a simple `Value`
  FormulaKind* = enum
    fkNone = "none" ## default value for uninitialized formula / no formula kind at CT yet
    fkVariable = "" ## Nim variable as `Value`, pure
    fkAssign = "<-" ## assignment op, pure
    fkVector = "~" ## map operation, impure
    fkScalar = "<<" ## reduce operation, impure
  ## either: `t in df["foo", int]`
  ## or: `t = df["foo", int]`
  Assign* = object
    asgnKind*: AssignKind
    node*: NimNode ## the exact node that will be replaced by this `Assign` instance
    ## TODO: rename / change `ReplaceByKind` as it's currently a bit unclear, in particular after
    ## `get` and `delete` was added!
    rbKind*: ReplaceByKind ## stores how this should be inserted
    element*: NimNode # e.g. `t`
    tensor*: NimNode # either `t` or `t_T` if `elmenent` used
    col*: NimNode # name of the column
    colType*: NimNode # e.g. `float`
    resType*: NimNode # the resulting type of the computation `Assign` is ``involved`` in!
  Preface* = object
    args*: seq[Assign]
  FormulaCT* = object
    funcKind*: FormulaKind
    preface*: Preface
    typeHint*: TypeHint # the actual type hint given in the formula
    resType*: NimNode # e.g. `ident"float"`
    name*: NimNode # name of the formula -> refers to new column / assignment name
    rawName*: string # name of the formula body as lisp
    loop*: NimNode # loop needs to be patched to remove accented quotes etc
  ## `Lift` stores a node which needs to be lifted out of a for loop, because it performs a
  ## reducing operation on a full DF column. It will be replaced by `liftedNode` in the loop
  ## body.
  Lift* = object
    toLift*: NimNode
    liftedNode*: NimNode

  ## The `TypeHint` and `HeuristicType` are only used for the shortform of the
  ## `Formula` syntax using `f{}`.
  ##
  ## In the general shortform `Formula` syntax `f{}` a `TypeHint` is of the form
  ## `f{float -> int: <operation>}`, where the first value is the type we use to read the
  ## DF tensors and the second the output datatype of the operation.
  ##
  ## If a `TypeHint` is found in a formula, we do attempt to heuristically determine
  ## sensible data types.
  TypeHint* = object
    inputType*: Option[NimNode]
    resType*: Option[NimNode]

  ## `HeuristicType` stores the input and output types of a formula constructed using the
  ## `f{}` syntax based on simple heuristic rules about the presence of certain operators
  ## and typed symbols (e.g. proc calls, literals). They are only used if no `TypeHint`
  ## is supplied.
  HeuristicType* = TypeHint

  ## `FormulaTypes` finally is the type used for input and output of the formula
  ## construction. Here the types *must* be set, otherwise it's a CT error (which happens
  ## if we cannot deduce a type and no hints are given)
  FormulaTypes* = object
    inputType*: NimNode
    resType*: NimNode

## Idents used for the generated code
const
  InIdent = "in"
  ResIdent = "res"
  ResultIdent = "result"
  RIdent = "r"
  DFIdent = "df"
  IdxIdent = "idx"
  ColIdent = "Column"
  ValueIdent = "Value"

const Dtypes* = ["float", "int", "string", "bool", "Value"]
const DtypesAll* = ["float", "float64", "int", "int64", "string", "bool", "Value"]

const DtypeOrderMap* = {
  "Value" : 1,
  "Tensor[Value]" : 2,
  "Tensor[T]" : 3,
  "T" : 4,
  "Tensor[string]" : 5,
  "string" : 6,
  "Tensor[int]" : 7,
  "int" : 8,
  "Tensor[int64]" : 9,
  "int64" : 10,
  "Tensor[float]" : 11,
  "float" : 12,
  "Tensor[float64]" : 13,
  "float64" : 14,
  "Tensor[bool]" : 15,
  "bool" : 16 # if something  can be done with `bool`, take that
}.toTable()
const DtypeOrderMapKeys = toSeq(DtypeOrderMap.keys())

proc toStrType*(n: NimNode): NimNode =
  case n.kind
  of nnkIntLit .. nnkUInt64Lit: result = ident "int"
  of nnkFloatLit .. nnkFloat128Lit: result = ident "float"
  of nnkStrLit: result = ident "string"
  of nnkIdent, nnkSym:
    if n.strVal in ["true", "false"]: result = ident "bool"
    else: result = ident(n.repr)
  else: result = ident(n.repr)

proc isValidType*(n: NimNode): bool =  n.strVal in DtypeOrderMapKeys

proc sortTypes*(s: seq[string]): seq[string] =
  ## sorts the types according to our own "priority list"
  var ids = newSeq[int](s.len)
  for i, el in s:
    if el in DtypeOrderMap:
      ids[i] = DtypeOrderMap[el]
  result = zip(s, ids).sortedByIt(it[1]).mapIt(it[0])

proc sortTypes*(s: seq[NimNode]): seq[string] =
  result = s.filterIt(it.isValidType).mapIt(it.strVal).sortTypes()

proc isColumnType*(n: NimNode): bool =
  case n.kind
  of nnkBracketExpr:
    if n[0].kind in {nnkSym, nnkIdent} and n[0].strVal == "Tensor":
      result = true
  of nnkSym, nnkIdent:
    if n.strVal.startsWith("Tensor"):
      result = true
  else: discard

proc checkIdent(n: NimNode, s: string): bool =
  result = n.len > 0 and n[0].kind == nnkIdent and n[0].strVal == s

proc extractCall(stmts: NimNode, id: string): NimNode =
  expectKind(stmts, nnkStmtList)
  for ch in stmts:
    case ch.kind
    of nnkCall:
      if checkIdent(ch, id):
        return ch
    else: continue

proc parsePreface(n: NimNode): Preface =
  proc addInfixAssign(ch: NimNode): Assign =
    doAssert checkIdent(ch, "in")
    doAssert ch[1].kind == nnkIdent, "First element before `in` needs to be an ident!"
    doAssert ch[2].kind == nnkBracketExpr, "`in` must refer to a `df[<col>, <type>]`!"
    doAssert ch[2][0].strVal == "df", "`in` must refer to a `df[<col>, <type>]`!"
    let elId = ch[1].strVal
    let dtype = ch[2][2].strVal
    doAssert dtype in Dtypes, "Column dtype " & $dtype & " not in " & $Dtypes & "!"
    result = Assign(asgnKind: byIndex,
                    node: ch,
                    element: ident(elId),
                    tensor: ident(elId & "T"),
                    col: ch[2][1],
                    colType: ident(dtype))
  proc addAsgnAssign(ch: NimNode): Assign =
    doAssert ch[0].kind == nnkIdent, "First element before `=` needs to be an ident!"
    doAssert ch[1].kind == nnkBracketExpr, "`=` must assign from a `df[<col>, <type>]`!"
    doAssert ch[1][0].strVal == "df", "`=` must assign from a `df[<col>, <type>]`!"
    let tId = ch[0].strVal
    let dtype = ch[1][2].strVal
    doAssert dtype in Dtypes, "Column dtype " & $dtype & " not in " & $Dtypes & "!"
    result = Assign(asgnKind: byTensor,
                    node: ch,
                    element: ident(tId & "Idx"),
                    tensor: ident(tId),
                    col: ch[1][1],
                    colType: ident(dtype))

  expectKind(n, nnkCall)
  expectKind(n[1], nnkStmtList)
  for ch in n[1]:
    case ch.kind
    of nnkInfix: result.args.add addInfixAssign(ch)
    of nnkAsgn: result.args.add addAsgnAssign(ch)
    else: error("Invalid node kind " & $ch.kind & " in `preface`: " & (ch.repr))

proc parseSingle(n: NimNode): NimNode =
  expectKind(n[1], nnkStmtList)
  result = n[1][0]

proc parseLoop(n: NimNode): NimNode =
  expectKind(n[1], nnkStmtList)
  result = n[1]

func removeCallAcc(n: NimNode): NimNode =
  result = if n.kind == nnkAccQuoted: newLit(n[0].strVal)
           elif n.kind == nnkCallStrLit: n[1]
           else: n

proc convertPreface(p: Preface): NimNode =
  ## TODO:
  ## anything that contains a type of `Tensor[T]` needs to be handled differently.
  ## Instead of generating a `let colT = df["col", dType]` we need to just call
  ## the function that
  proc toLet(a: Assign): NimNode =
    result = nnkIdentDefs.newTree(
      a.tensor,
      newEmptyNode(),
      nnkBracketExpr.newTree(ident(DfIdent), a.col.removeCallAcc(),
                             ident(a.colType.strVal)) #convert nnkSym to nnkIdent
    )
  result = nnkLetSection.newTree()
  var seenTensors = initHashSet[string]()
  for arg in p.args:
    if arg.tensor.strVal notin seenTensors:
      result.add toLet(arg)
    seenTensors.incl arg.tensor.strVal

proc convertDtype(d: NimNode): NimNode =
  result = nnkVarSection.newTree(
    nnkIdentDefs.newTree(
      ident(ResIdent),
      newEmptyNode(),
      nnkCall.newTree(
        nnkBracketExpr.newTree(ident"newTensorUninit",
                               d),
        nnkDotExpr.newTree(ident(DfIdent),
                           ident"len"))
    )
  )

proc `$`*(p: Preface): string =
  result = "Preface("
  for i, ch in p.args:
    result.add &"Assign(element: {ch.element.strVal}, "
    result.add &"asgnKind: {ch.asgnKind}, "
    result.add &"node: {ch.node.repr}, "
    result.add &"tensor: {ch.tensor.strVal}, "
    result.add &"col: {buildName(ch.col)}, "
    result.add &"rbKind: {ch.rbKind}, "
    result.add &"colType: {buildName(ch.colType)}, "
    result.add &"resType: {buildName(ch.resType)})"
    if i < p.args.high:
      result.add ", "
  result.add ")"

proc contains(p: Preface, n: NimNode): bool =
  for arg in p.args:
    if arg.node == n:
      return true

proc `[]`(p: Preface, n: NimNode): Assign =
  for arg in p.args:
    if arg.node == n:
      return arg
  error("Could not find " & n.repr & " in preface containing " & $p)

proc delete(p: var Preface, n: NimNode) =
  var idx = 0
  while idx < p.args.len:
    if p.args[idx].node == n:
      p.args.delete(idx)
      # deleted so return
      ## TODO: we don't depend on removing all "duplicates" (same column ref), right?
      return
    inc idx

proc nodeIsDf*(n: NimNode): bool =
  if n.kind == nnkBracketExpr:
    result = n[0].kind == nnkIdent and n[0].strVal == "df"
  elif n.kind == nnkCall:
    result = n[0].kind == nnkIdent and n[0].strVal == "col"
  elif n.kind in {nnkCallStrLit, nnkAccQuoted}:
    result = true

proc nodeIsDfIdx*(n: NimNode): bool =
  if n.kind == nnkBracketExpr:
    result = n[0].kind == nnkBracketExpr and n[0][0].kind == nnkIdent and
    n[0][0].strVal == "df" and n[1].kind == nnkIdent and n[1].strVal == "idx"
  elif n.kind == nnkCall:
    result = n[0].kind == nnkIdent and n[0].strVal == "idx"
  elif n.kind in {nnkCallStrLit, nnkAccQuoted}:
    result = true

proc hasExplicitTypeHint*(n: NimNode): bool =
  result = (n.nodeIsDf or n.nodeIsDfIdx) and
    n.kind == nnkCall and
    n.len == 3 and
    n[2].kind in {nnkIdent, nnkSym} and
    n[2].strVal in DtypesAll

proc get(p: var Preface, node: NimNode, useIdx: bool): NimNode =
  let n = p[node]
  p.delete(node)
  result = if n.asgnKind == byIndex:
             if useIdx:
               nnkBracketExpr.newTree(
                 n.tensor,
                 ident(IdxIdent)
               )
             else:
               n.element
           else:
             n.tensor

proc replaceByIdx(n: NimNode, preface: var Preface): NimNode =
  ## recurses the node `n` and replaces all occurences by `t[idx]` for each
  ## tensor in the loop
  # first check if an ident that is in preface we have to replace or if
  # an `nnkBracketExpr` which contains an ident from `preface`. In those cases
  # return early
  case n.kind
  of nnkIdent, nnkSym:
    if n in preface: return preface.get(n, useIdx = true)
    else: return n
  of nnkAccQuoted:
    return preface.get(n, useIdx = true)
  of nnkCallStrLit:
    return preface.get(n, useIdx = true)
  of nnkBracketExpr:
    if n[0].kind == nnkIdent and n in preface:
      return n
    # if `df["someCol"]` replace by full tensor (e.g. in a call taking tensor)
    if nodeIsDf(n) and n in preface:
      return preface.get(n, useIdx = true)
    if nodeIsDfIdx(n) and n in preface:
      return preface.get(n, useIdx = true)
  of nnkCall:
    if (nodeIsDf(n) or nodeIsDfIdx(n)) and n in preface:
      return preface.get(n, useIdx = true)
  else: result = n
  if n.len > 0:
    result = newTree(n.kind)
    for ch in n:
      result.add replaceByIdx(ch, preface)

proc replaceByElement(n: NimNode, preface: var Preface): NimNode =
  ## recurses the node `n` and replaces all occurences by `t` for each
  ## tensor in the loop
  # first check if an ident that is in preface we have to replace or if
  # an `nnkBracketExpr` which contains an ident from `preface`. In those cases
  # return early
  case n.kind
  of nnkIdent, nnkSym:
    if n in preface: return preface.get(n, useIdx = false)
    else: return n
  of nnkAccQuoted:
    return preface.get(n, useIdx = false)
  of nnkCallStrLit:
    return preface.get(n, useIdx = false)
  of nnkBracketExpr:
    if n[0].kind == nnkIdent and n in preface:
      return preface.get(n, useIdx = false)
    # for `df["someCol"]` replace by full tensor, e.g. for call taking tensor
    if nodeIsDf(n) and n in preface:
      return preface.get(n, useIdx = false)
    if nodeIsDfIdx(n) and n in preface:
      return preface.get(n, useIdx = false)
  of nnkCall:
    if (nodeIsDf(n) or nodeIsDfIdx(n)) and n in preface:
      return preface.get(n, useIdx = false)
  else: result = n
  if n.len > 0:
    result = newTree(n.kind)
    for ch in n:
      result.add replaceByElement(ch, preface)

proc replaceByColumn(n: NimNode, preface: var Preface): NimNode =
  ## recurses the node `n` and replaces all occurences by full `col` (i.e. field `tensor`) for each
  ## tensor in the loop
  case n.kind
  of nnkIdent, nnkSym:
    if n in preface: return preface[n].tensor
    else: return n
  of nnkAccQuoted:
    return preface[n].tensor
  of nnkCallStrLit:
    return preface[n].tensor
  of nnkBracketExpr:
    if n[0].kind == nnkIdent and n in preface:
      return preface[n].tensor
    # for `df["someCol"]` replace by full tensor, e.g. for call taking tensor
    if nodeIsDf(n) and n in preface:
      return preface[n].tensor
    if nodeIsDfIdx(n) and n in preface:
      error("Invalid usage of `idx` in a reducing formula! Access: " & $(n.repr))
  of nnkCall:
    if (nodeIsDf(n) or nodeIsDfIdx(n)) and n in preface:
      return preface[n].tensor
  else: result = n
  if n.len > 0:
    result = newTree(n.kind)
    for ch in n:
      result.add replaceByColumn(ch, preface)

proc fixupTensorIndices(loopStmts: NimNode, preface: var Preface,
                        rbKind: ReplaceByKind): NimNode =
  ## If `toElements` is true, we rewrite everything by `t` (where `t` is an
  ## element of `tT` (Tensor). This includes
  expectKind(loopStmts, nnkStmtList)
  case rbKind
  of rbIndex:
    let loop = loopStmts[0].replaceByIdx(preface)
    case loop.kind
    of nnkAsgn:
      doAssert loop[0].kind == nnkBracketExpr and
        loop[0][0].kind == nnkIdent and loop[0][0].strVal == "r" and
        loop[0][1].kind == nnkIdent and loop[0][1].strVal == "idx"
      ## TODO: make this prettier / fix this
    else:
      # turn this into an nnkAsgn node with `res` as LHS and `nnkAsgn` on RHS
      result = nnkAsgn.newTree(
        nnkBracketExpr.newTree(ident(ResIdent), ident(IdxIdent)),
        loop)
  of rbElement:
    let loop = loopStmts[0].replaceByElement(preface)
    case loop.kind
    of nnkAsgn: doAssert loop[0].kind == nnkIdent and loop[0].strVal == RIdent
    else:
      # turn this into an nnkAsgn node with `res` as LHS and `nnkAsgn` on RHS
      result = nnkAsgn.newTree(ident(RIdent), loop)
  of rbColumn:
    let loop = loopStmts[0].replaceByColumn(preface)
    case loop.kind
    of nnkAsgn: doAssert loop[0].kind == nnkIdent and loop[0].strVal == ResIdent
    else:
      # turn this into an `nnkVarSection` node with `res` as LHS and `loop` as RHS
      result = nnkVarSection.newTree(
        nnkIdentDefs.newTree(
          ident(ResIdent),
          newEmptyNode(),
          loop)
      )

proc convertLoop(p: Preface, dtype, loop: NimNode,
                 fnKind: FormulaKind): NimNode =
  let memCopyable = ["float", "int", "bool"]
  let isMemCopyable = dtype.strVal in memCopyable and
    p.args.allIt(it.colType.strVal in memCopyable)
  proc genForLoop(p: Preface, loop: NimNode): NimNode =
    var mpreface = p
    let loopIndexed = fixupTensorIndices(loop, mpreface, rbKind = rbIndex)
    let idx = ident(IdxIdent)
    let df = ident(DfIdent)
    var loop = quote do:
      for `idx` in 0 ..< `df`.len:
        `loopIndexed`
    result = newStmtList(loop)

  proc genForEach(p: Preface, loop: NimNode): NimNode =
    var mpreface = p
    let loopElements = fixupTensorIndices(loop, mpreface, rbKind = rbElement)
    var forEach = nnkCommand.newTree(ident"forEach")
    forEach.add nnkInfix.newTree(ident(InIdent), ident(RIdent), ident(ResIdent))
    for arg in p.args:
      forEach.add nnkInfix.newTree(ident(InIdent), arg.element, arg.tensor)
    forEach.add nnkStmtList.newTree(loopElements)
    result = newStmtList(forEach)

  proc addResultVector(): NimNode =
    let resId = ident(ResIdent)
    let resultId = ident(ResultIdent)
    result = quote do:
      `resultId` = toColumn `resId`

  case fnKind
  of fkVector:
    if not isMemCopyable:
      result = genForLoop(p, loop)
      result.add addResultVector()
    else:
      result = genForEach(p, loop)
      result.add addResultVector()
  of fkScalar:
    let resultId = ident(ResultIdent)
    var mpreface = p
    let loopElements = fixupTensorIndices(loop, mpreface, rbKind = rbColumn)
    let resId = ident(ResIdent)
    result = quote do:
      `loopElements`
      `resultId` = %~ `resId`
  else:
    error("Invalid FormulaKind `" & $(fnKind.repr) & "` in `convertLoop`. Already handled " &
      "in `compileFormula`!")

proc parseFormulaCT(stmts: NimNode): FormulaCT =
  let preface = parsePreface(extractCall(stmts, "preface"))
  ## TODO: if `dtype` not given: auto determine
  let dtype = parseSingle(extractCall(stmts, "dtype"))
  let name = parseSingle(extractCall(stmts, "name"))
  let loop = parseLoop(extractCall(stmts, "loop"))
  result = FormulaCT(preface: preface,
                     resType: dtype,
                     name: name,
                     loop: loop)

proc generateClosure*(fct: FormulaCT): NimNode =
  var procBody = newStmtList()
  procBody.add getAst(convenienceValueComparisons()) # add convenience comparison ops Value ⇔ T
  procBody.add convertPreface(fct.preface)
  if fct.funcKind == fkVector:
    procBody.add convertDtype(fct.resType)
  procBody.add convertLoop(fct.preface, fct.resType, fct.loop, fct.funcKind)
  result = procBody
  var params: array[2, NimNode]
  case fct.funcKind
  of fkVector:
    params = [ident(ColIdent),
              nnkIdentDefs.newTree(ident(DfIdent),
                                   ident"DataFrame",
                                   newEmptyNode())]
  of fkScalar:
    when (NimMajor, NimMinor, NimPatch) < (1, 5, 0):
      let valueId = ident(ValueIdent)
    else:
      let valueId = nnkDotExpr.newTree(ident"value", ident(ValueIdent))
    # to avoid clashes with other `Value` objects, fully clarify we mean ours
    params = [valueId,
              nnkIdentDefs.newTree(ident(DfIdent),
                                   ident"DataFrame",
                                   newEmptyNode())]
  else:
    error("Invalid FormulaKind `" & $(fct.funcKind.repr) & "` in `convertLoop`. Already handled " &
      "in `compileFormula`!")
  result = newProc(newEmptyNode(),
                   params = params,
                   body = procBody,
                   procType = nnkLambda)

proc compileFormula(stmts: NimNode): NimNode =
  let fct = parseFormulaCT(stmts)
  result = generateClosure(fct)

macro formula(y: untyped): untyped =
  ## TODO: add some ability to explicitly create formulas of
  ## different kinds more easily! Essentially force the type without
  ## a check to avoid having to rely on heuristics.
  ## Use
  ## - `<-` for assignment
  ## - `<<` for reduce operations, i.e. scalar proc?
  ## - `~` for vector like proc
  ## - formula without any of the above will be considered:
  ##   - `fkVariable` if no column involved
  ##   - `fkVector` else
  ## - `<type>: <actualFormula>`: simple type hint for tensors in closure
  ## - `<type> -> <resDtype>: <actualFormula>`: full type for closure.
  ##   `<type>` is the dtype used for tensors, `<resDtype>` the resulting type
  ## - `df[<someIdent/Sym>]`: to access columns using identifiers / symbols
  ##   defined in the scope
  ## - `idx`: can be used to access the loop iteration index
  result = compileFormula(y)

when false: # isMainModule:
  import math
  import arraymancer / laser / strided_iteration / foreach
  let f1 = formula:
    preface:
      t in df["foo", int] # t refers to each element of `foo` in the loop
      u in df["bar", float]
      v = df["baz", int] # v refers to the ``Tensor`` `baz`
    dtype: float
    name: "fooBar"
    loop:
      t.float * u + v[idx].float

  let f2 = f{ parseInt(`t`) > 5 }


#let f2 = fn:
#  preface:
#    t in df["foo", int] # t refers to each element of `foo` in the loop
#    u in df["bar", float]
#    v = df["baz", int] # v refers to the ``Tensor`` `baz`
#    #r in result
#  dtype: bool
#  name: "filterme"
#  loop:
#    t.float > u and v[idx].float < 2.2
#
#let f3 = fn:
#  preface:
#    t in df["foo", float] # t refers to each element of `foo` in the loop
#  dtype: bool
#  name: "noNan"
#  loop:
#    not (classify(t) == fcNan)
