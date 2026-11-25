# include fragment of bouncer/core — the constructors and the fluent modifiers.
# Shares core.nim's imports and scope.

func str*(): Schema = Schema(kind: skString)
func integer*(): Schema = Schema(kind: skInt)
func number*(): Schema = Schema(kind: skFloat)
func boolean*(): Schema = Schema(kind: skBool)
func arr*(elem: Schema): Schema = Schema(kind: skArray, elem: elem)

func obj*(shape: openArray[(string, Schema)], strict = false): Schema =
  result = Schema(kind: skObject, strict: strict)
  result.shape = initOrderedTable[string, Schema]()
  for (k, v) in shape: result.shape[k] = v

proc optional*(s: Schema): Schema =
  s.optional = true; s

proc default*(s: Schema, value: JsonNode): Schema =
  ## Fill in this value when the field is missing or null.
  s.defaultVal = some value; s

proc default*(s: Schema, value: int): Schema = s.default(%value)
proc default*(s: Schema, value: float): Schema = s.default(%value)
proc default*(s: Schema, value: string): Schema = s.default(%value)
proc default*(s: Schema, value: bool): Schema = s.default(%value)

proc coerce*(s: Schema): Schema =
  ## Accept a string and convert it: "42" -> integer, "3.14" -> number, "true" -> boolean.
  s.coerceInput = true; s

proc refine*(s: Schema, check: proc (node: JsonNode): bool {.closure.},
             message = "failed a custom check"): Schema =
  s.refinements.add Refinement(check: check, message: message); s

proc transform*(s: Schema, fn: proc (node: JsonNode): JsonNode {.closure.}): Schema =
  ## Reshape the value after it validates. Runs on the cleaned-up node.
  s.transforms.add fn; s

proc min*(s: Schema, n: int): Schema =
  case s.kind
  of skString: s.minLen = some n
  of skArray:  s.amin = some n
  of skInt:    s.imin = some n
  of skFloat:  s.fmin = some n.float
  else: raise newException(ValueError, "min() is not supported on " & typeLabel(s.kind))
  s

proc max*(s: Schema, n: int): Schema =
  case s.kind
  of skString: s.maxLen = some n
  of skArray:  s.amax = some n
  of skInt:    s.imax = some n
  of skFloat:  s.fmax = some n.float
  else: raise newException(ValueError, "max() is not supported on " & typeLabel(s.kind))
  s

proc min*(s: Schema, n: float): Schema =
  doAssert s.kind == skFloat, "min(float) only applies to number()"
  s.fmin = some n; s

proc max*(s: Schema, n: float): Schema =
  doAssert s.kind == skFloat, "max(float) only applies to number()"
  s.fmax = some n; s

proc nonEmpty*(s: Schema): Schema =
  case s.kind
  of skString: s.minLen = some 1
  of skArray:  s.amin = some 1
  else: raise newException(ValueError, "nonEmpty() only applies to str() and arr()")
  s

proc positive*(s: Schema): Schema =
  case s.kind
  of skInt:   s.intPositive = true
  of skFloat: s.numPositive = true
  else: raise newException(ValueError, "positive() only applies to integer() and number()")
  s

proc nonNegative*(s: Schema): Schema =
  case s.kind
  of skInt:   s.intNonNeg = true
  of skFloat: s.numNonNeg = true
  else: raise newException(ValueError, "nonNegative() only applies to integer() and number()")
  s

proc email*(s: Schema): Schema =
  doAssert s.kind == skString, "email() only applies to str()"
  s.isEmail = true; s

proc url*(s: Schema): Schema =
  doAssert s.kind == skString, "url() only applies to str()"
  s.isUrl = true; s

proc uuid*(s: Schema): Schema =
  doAssert s.kind == skString, "uuid() only applies to str()"
  s.isUuid = true; s

proc trim*(s: Schema): Schema =
  doAssert s.kind == skString, "trim() only applies to str()"
  s.doTrim = true; s

proc pattern*(s: Schema, regex: string): Schema =
  doAssert s.kind == skString, "pattern() only applies to str()"
  s.pattern = some re(regex); s

proc oneOf*(s: Schema, values: openArray[string]): Schema =
  doAssert s.kind == skString, "oneOf() only applies to str()"
  s.enumVals = @values; s
