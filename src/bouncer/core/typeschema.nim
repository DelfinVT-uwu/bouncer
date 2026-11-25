# include fragment of bouncer/core — deriving a schema from a Nim type and the
# typed fromJson. Shares core.nim's imports and scope.

proc schemaForType[T](t: typedesc[T]): Schema =
  # One generic, no typedesc overloads: older Nim (2.0) mis-resolves those. seq and
  # Option are detected here, and their inner type pulled out with `typeof` (which
  # only inspects the type, never runs the indexing/`get`). Option before object,
  # since Option is itself an object.
  when T is string:
    result = str()
  elif T is bool:
    result = boolean()
  elif T is SomeFloat:
    result = number()
  elif T is SomeInteger:
    result = integer()
  elif T is seq:
    var probe: T
    let inner: Schema = schemaForType(typeof(probe[0]))
    result = arr(inner)
  elif T is Option:
    var probe: T
    let inner: Schema = schemaForType(typeof(probe.get))
    result = optional(inner)
  elif T is object:
    result = Schema(kind: skObject)
    result.shape = initOrderedTable[string, Schema]()
    var probe: T
    for name, field in probe.fieldPairs:
      result.shape[name] = schemaForType(typeof(field))
  else:
    {.error: "bouncer.schemaFor: unsupported field type (use string, number, bool, seq, Option, or a nested object)".}

proc schemaFor*[T](t: typedesc[T]): Schema =
  ## Build a schema from a Nim object type's shape: a `string` field becomes `str()`,
  ## `int` becomes `integer()`, `Option[x]` becomes optional, `seq[x]` an array, a
  ## nested object its own object schema. Layer rules on with `.extend()` / `.refine()`.
  schemaForType(t)

proc fromJson*[T](t: typedesc[T], node: JsonNode): T =
  ## Validate `node` against `T`'s shape, then deserialize into a typed `T`.
  ## Raises `BouncerError` (with `.issues`) if the shape doesn't match.
  discard schemaFor(T).parse(node)
  # bouncer has already checked the shape; let the deserializer tolerate a missing
  # optional field or an extra key it doesn't map.
  node.jsonTo(T, Joptions(allowExtraKeys: true, allowMissingKeys: true))

proc fromJson*[T](t: typedesc[T], jsonText: string): T =
  fromJson(T, parseJson(jsonText))
