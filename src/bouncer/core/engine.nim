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

proc run(s: Schema, input: JsonNode, path: var seq[PathPart]): (seq[Issue], JsonNode)

proc runInner(s: Schema, input: JsonNode, path: var seq[PathPart]): (seq[Issue], JsonNode) =
  # `path` is one buffer shared down the whole walk: each level pushes its key or
  # index, recurses, then pops. We only ever copy it when an issue is actually made
  # (issue() snapshots it), so a valid parse builds no paths at all.
  var issues: seq[Issue]
  var node = s.coerced(input)

  # Missing or null is fine when optional, a type error otherwise. Objects handle
  # their own missing fields (default / omit) before they ever call this. Union and
  # literal decide for themselves what null means, so they skip this.
  if s.kind notin {skUnion, skLiteral} and (node.isNil or node.kind == JNull):
    if not (s.optional or s.allowNull):
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
    if s.isDate and not looksLikeDate(v):
      issues.add issue(path, icInvalidString, "must be a valid date (YYYY-MM-DD)")
    if s.isDatetime and not looksLikeDatetime(v):
      issues.add issue(path, icInvalidString, "must be a valid ISO 8601 date-time")
    if s.pattern.isSome and not v.contains(s.pattern.get):
      issues.add issue(path, icInvalidString, "does not match the required pattern")
    if s.enumVals.len > 0 and v notin s.enumVals:
      issues.add issue(path, icInvalidEnum, "must be one of: " & s.enumVals.join(", "))
    if s.doTrim: node = newJString(v)   # only rebuild when trim actually changed it

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
      if node.hasKey(name):
        let val = node[name]
        if val.kind != JNull:
          path.add key(name)
          let (childIssues, childValue) = run(sub, val, path)
          path.setLen(path.len - 1)
          issues.add childIssues
          cleaned[name] = childValue
        elif sub.allowNull:
          cleaned[name] = newJNull()          # null is a valid value: keep it
        elif sub.defaultVal.isSome:
          cleaned[name] = sub.defaultVal.get
        elif sub.catchVal.isSome:
          cleaned[name] = sub.catchVal.get
        elif not sub.optional:
          path.add key(name)
          issues.add issue(path, icRequired, "required")
          path.setLen(path.len - 1)
      elif sub.defaultVal.isSome:              # key absent
        cleaned[name] = sub.defaultVal.get
      elif sub.catchVal.isSome:
        cleaned[name] = sub.catchVal.get
      elif not sub.optional:
        path.add key(name)
        issues.add issue(path, icRequired, "required")
        path.setLen(path.len - 1)
    if s.strict:
      for name, _ in node:
        if name notin s.shape:
          path.add key(name)
          issues.add issue(path, icUnrecognized, "unexpected key")
          path.setLen(path.len - 1)
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
      path.add idx(i)
      let (childIssues, childValue) = run(s.elem, el, path)
      path.setLen(path.len - 1)
      issues.add childIssues
      cleaned.add childValue
    node = cleaned

  of skTuple:
    if node.kind != JArray:
      return (@[issue(path, icInvalidType, "expected array, got " & jsonLabel(node))], node)
    let got = node.len
    if s.rest.isNil:
      if got != s.items.len:
        issues.add issue(path, (if got < s.items.len: icTooSmall else: icTooBig),
          "must have exactly " & $s.items.len & " items")
    elif got < s.items.len:
      issues.add issue(path, icTooSmall, "must have at least " & $s.items.len & " items")
    var cleaned = newJArray()
    for i, el in node.getElems:
      let sub = if i < s.items.len: s.items[i] else: s.rest
      if sub.isNil:                    # extra sin rest: ya se reportó por longitud
        cleaned.add el
        continue
      path.add idx(i)
      let (childIssues, childValue) = run(sub, el, path)
      path.setLen(path.len - 1)
      issues.add childIssues
      cleaned.add childValue
    node = cleaned

  of skRecord:
    if node.kind != JObject:
      return (@[issue(path, icInvalidType, "expected object, got " & jsonLabel(node))], node)
    var cleaned = newJObject()
    for name, val in node:
      path.add key(name)
      let (childIssues, childValue) = run(s.valueSchema, val, path)
      path.setLen(path.len - 1)
      issues.add childIssues
      cleaned[name] = childValue
    node = cleaned

  of skLiteral:
    if node != s.litVal:
      return (@[issue(path, icInvalidType, "must be " & $s.litVal)], node)

  of skUnion:
    if (s.optional or s.allowNull) and (node.isNil or node.kind == JNull):
      discard                                   # an optional/nullable union lets null through
    else:
      var matched = false
      var closest: seq[Issue]
      for v in s.variants:
        let (vIssues, vValue) = run(v, input, path)
        if vIssues.len == 0:
          node = vValue                         # keep the winning branch's clean value
          matched = true
          break
        if closest.len == 0 or vIssues.len < closest.len:
          closest = vIssues                     # the variant that came nearest to matching
      if not matched:
        # Surface that closest variant's own errors — for a discriminated union
        # (a literal tag per variant) this points right at the real problem.
        return (closest, node)

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

proc run(s: Schema, input: JsonNode, path: var seq[PathPart]): (seq[Issue], JsonNode) =
  ## Validate the schema, then let catch() swallow any failure for a fallback value.
  result = runInner(s, input, path)
  if result[0].len > 0 and s.catchVal.isSome:
    result = (newSeq[Issue](), s.catchVal.get)

proc safeParse*(s: Schema, node: JsonNode): ParseResult =
  ## Validate `node`. Never raises; check `.ok`, then read `.value` (cleaned up:
  ## trimmed, coerced, unknown keys dropped) or `.issues`.
  var path: seq[PathPart] = @[]
  let (issues, value) = s.run(node, path)
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
