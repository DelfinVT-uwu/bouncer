# include fragment of bouncer/core — deriving one object schema from another.
# Shares core.nim's imports and scope.

proc clone(s: Schema): Schema =
  # Deep copy, so deriving one schema from another never mutates the original.
  case s.kind
  of skString:
    result = Schema(kind: skString, minLen: s.minLen, maxLen: s.maxLen,
                    isEmail: s.isEmail, isUrl: s.isUrl, isUuid: s.isUuid,
                    isDate: s.isDate, isDatetime: s.isDatetime,
                    doTrim: s.doTrim, pattern: s.pattern, enumVals: s.enumVals)
  of skInt:
    result = Schema(kind: skInt, imin: s.imin, imax: s.imax,
                    intPositive: s.intPositive, intNonNeg: s.intNonNeg)
  of skFloat:
    result = Schema(kind: skFloat, fmin: s.fmin, fmax: s.fmax,
                    numPositive: s.numPositive, numNonNeg: s.numNonNeg)
  of skBool:
    result = Schema(kind: skBool)
  of skObject:
    result = Schema(kind: skObject, strict: s.strict)
    result.shape = initOrderedTable[string, Schema]()
    for k, v in s.shape: result.shape[k] = v.clone()
  of skArray:
    result = Schema(kind: skArray, elem: s.elem.clone(), amin: s.amin, amax: s.amax)
  of skLiteral:
    result = Schema(kind: skLiteral, litVal: s.litVal)
  of skUnion:
    result = Schema(kind: skUnion)
    for v in s.variants: result.variants.add v.clone()
  of skRecord:
    result = Schema(kind: skRecord, valueSchema: s.valueSchema.clone())
  of skTuple:
    result = Schema(kind: skTuple, rest: (if s.rest.isNil: nil else: s.rest.clone()))
    for it in s.items: result.items.add it.clone()
  result.optional = s.optional
  result.allowNull = s.allowNull
  result.coerceInput = s.coerceInput
  result.defaultVal = s.defaultVal
  result.catchVal = s.catchVal
  result.refinements = s.refinements
  result.transforms = s.transforms

proc mustBeObject(s: Schema, who: string) =
  if s.kind != skObject:
    raise newException(ValueError, who & " only applies to obj()")

proc partial*(s: Schema): Schema =
  ## Copy the object schema with every field made optional. Good for an "update"
  ## variant of a "create" schema.
  s.mustBeObject("partial()")
  result = s.clone()
  for k, v in result.shape: v.optional = true

proc pick*(s: Schema, keys: openArray[string]): Schema =
  ## Copy the object schema keeping only the named fields.
  s.mustBeObject("pick()")
  result = s.clone()
  var kept = initOrderedTable[string, Schema]()
  for k in keys:
    if result.shape.hasKey(k): kept[k] = result.shape[k]
  result.shape = kept

proc omit*(s: Schema, keys: openArray[string]): Schema =
  ## Copy the object schema without the named fields.
  s.mustBeObject("omit()")
  result = s.clone()
  for k in keys: result.shape.del(k)

proc extend*(s: Schema, shape: openArray[(string, Schema)]): Schema =
  ## Copy the object schema with fields added or overridden.
  s.mustBeObject("extend()")
  result = s.clone()
  for (k, v) in shape: result.shape[k] = v

proc merge*(a, b: Schema): Schema =
  ## Combine two object schemas; on a key clash, b wins.
  a.mustBeObject("merge()")
  b.mustBeObject("merge()")
  result = a.clone()
  for k, v in b.shape: result.shape[k] = v.clone()
