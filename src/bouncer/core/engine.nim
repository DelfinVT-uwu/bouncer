# include fragment of bouncer/core — input coercion, the validation walk, and the
# safeParse / parse entry points. Shares core.nim's imports and scope.

proc coerced(s: Schema, node: JsonNode): JsonNode =
  # Best-effort input coercion from a JSON string, for data that arrives as text
  # (query params, form fields). On failure the original node is returned so the
  # normal type check reports it.
  if not s.coerceInput or node.isNil or node.kind != JString: return node
  let raw = node.getStr.strip
  case s.kind
  of skInt:
    try: newJInt(parseInt(raw)) except ValueError: node
  of skFloat:
    try: newJFloat(parseFloat(raw)) except ValueError: node
  of skBool:
    case raw.toLowerAscii
    of "true": newJBool(true)
    of "false": newJBool(false)
    else: node
  else: node

proc run(s: Schema, input: JsonNode, path: seq[PathPart]): (seq[Issue], JsonNode) =
  var issues: seq[Issue]
  var node = s.coerced(input)

  # Missing or null is fine when optional, a type error otherwise. Objects handle
  # their own missing fields (default / omit) before they ever call this.
  if node.isNil or node.kind == JNull:
    if not s.optional:
      issues.add issue(path, icInvalidType, "expected " & typeLabel(s.kind) & ", got null")
    return (issues, node)

  case s.kind
  of skString:
    if node.kind != JString:
      return (@[issue(path, icInvalidType, "expected string, got " & jsonLabel(node))], node)
    var v = node.getStr
    if s.doTrim: v = v.strip
    if s.minLen.isSome and v.len < s.minLen.get:
      issues.add issue(path, icTooSmall, "must be at least " & $s.minLen.get & " characters")
    if s.maxLen.isSome and v.len > s.maxLen.get:
      issues.add issue(path, icTooBig, "must be at most " & $s.maxLen.get & " characters")
    if s.isEmail and not looksLikeEmail(v):
      issues.add issue(path, icInvalidString, "must be a valid email")
    if s.isUrl and not looksLikeUrl(v):
      issues.add issue(path, icInvalidString, "must be a valid URL")
    if s.isUuid and not looksLikeUuid(v):
      issues.add issue(path, icInvalidString, "must be a valid UUID")
    if s.pattern.isSome and not v.contains(s.pattern.get):
      issues.add issue(path, icInvalidString, "does not match the required pattern")
    if s.enumVals.len > 0 and v notin s.enumVals:
      issues.add issue(path, icInvalidEnum, "must be one of: " & s.enumVals.join(", "))
    node = newJString(v)

  of skInt:
    var v: int
    case node.kind
    of JInt:
      v = node.getInt
    of JFloat:
      # JSON doesn't separate 18 from 18.0; accept a whole-number float as an integer.
      let f = node.getFloat
      if f < int.low.float or f > int.high.float or f != f.int.float:
        return (@[issue(path, icInvalidType, "expected integer, got number")], node)
      v = f.int
      node = newJInt(v)
    else:
      return (@[issue(path, icInvalidType, "expected integer, got " & jsonLabel(node))], node)
    if s.imin.isSome and v < s.imin.get:
      issues.add issue(path, icTooSmall, "must be >= " & $s.imin.get)
    if s.imax.isSome and v > s.imax.get:
      issues.add issue(path, icTooBig, "must be <= " & $s.imax.get)
    if s.intPositive and v <= 0:
      issues.add issue(path, icTooSmall, "must be positive")
    if s.intNonNeg and v < 0:
      issues.add issue(path, icTooSmall, "must be zero or greater")

  of skFloat:
    if node.kind notin {JInt, JFloat}:
      return (@[issue(path, icInvalidType, "expected number, got " & jsonLabel(node))], node)
    let v = node.getFloat
    if s.fmin.isSome and v < s.fmin.get:
      issues.add issue(path, icTooSmall, "must be >= " & $s.fmin.get)
    if s.fmax.isSome and v > s.fmax.get:
      issues.add issue(path, icTooBig, "must be <= " & $s.fmax.get)
    if s.numPositive and v <= 0:
      issues.add issue(path, icTooSmall, "must be positive")
    if s.numNonNeg and v < 0:
      issues.add issue(path, icTooSmall, "must be zero or greater")

  of skBool:
    if node.kind != JBool:
      return (@[issue(path, icInvalidType, "expected boolean, got " & jsonLabel(node))], node)

  of skObject:
    if node.kind != JObject:
      return (@[issue(path, icInvalidType, "expected object, got " & jsonLabel(node))], node)
    var cleaned = newJObject()
    for name, sub in s.shape:
      if node.hasKey(name) and node[name].kind != JNull:
        let (childIssues, childValue) = run(sub, node[name], path & key(name))
        issues.add childIssues
        cleaned[name] = childValue
      elif sub.defaultVal.isSome:
        cleaned[name] = sub.defaultVal.get
      elif not sub.optional:
        issues.add issue(path & key(name), icRequired, "required")
    if s.strict:
      for name, _ in node:
        if name notin s.shape:
          issues.add issue(path & key(name), icUnrecognized, "unexpected key")
    node = cleaned  # unknown keys are dropped from the output

  of skArray:
    if node.kind != JArray:
      return (@[issue(path, icInvalidType, "expected array, got " & jsonLabel(node))], node)
    if s.amin.isSome and node.len < s.amin.get:
      issues.add issue(path, icTooSmall, "must have at least " & $s.amin.get & " items")
    if s.amax.isSome and node.len > s.amax.get:
      issues.add issue(path, icTooBig, "must have at most " & $s.amax.get & " items")
    var cleaned = newJArray()
    for i, el in node.getElems:
      let (childIssues, childValue) = run(s.elem, el, path & idx(i))
      issues.add childIssues
      cleaned.add childValue
    node = cleaned

  # Custom rules and transforms run only once the value is otherwise valid, so a
  # refinement never has to re-check the type it was handed.
  if issues.len == 0:
    for r in s.refinements:
      if not r.check(node):
        issues.add issue(path, icCustom, r.message)
    if issues.len == 0:
      for t in s.transforms:
        node = t(node)

  (issues, node)

proc safeParse*(s: Schema, node: JsonNode): ParseResult =
  ## Validate `node`. Never raises; check `.ok`, then read `.value` (cleaned up:
  ## trimmed, coerced, unknown keys dropped) or `.issues`.
  let (issues, value) = s.run(node, @[])
  if issues.len == 0: ParseResult(ok: true, value: value)
  else: ParseResult(ok: false, issues: issues)

proc safeParse*(s: Schema, jsonText: string): ParseResult =
  ## Parse the JSON text first; a malformed body becomes an issue, not an exception.
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except JsonParsingError as e:
    return ParseResult(ok: false, issues: @[issue(@[], icInvalidType, "invalid JSON: " & e.msg)])
  s.safeParse(node)

proc raiseInvalid(issues: seq[Issue]) {.noreturn.} =
  var msg = "validation failed:"
  for it in issues: msg.add "\n  " & $it
  var e = newException(BouncerError, msg)
  e.issues = issues
  raise e

proc parse*(s: Schema, node: JsonNode): JsonNode =
  ## Validate and return the cleaned-up data, or raise `BouncerError` with `.issues`.
  let r = s.safeParse(node)
  if r.ok: r.value else: raiseInvalid(r.issues)

proc parse*(s: Schema, jsonText: string): JsonNode =
  let r = s.safeParse(jsonText)
  if r.ok: r.value else: raiseInvalid(r.issues)
