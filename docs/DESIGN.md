# bouncer — diseño v0.1

Validación de datos para Nim al estilo [Zod](https://zod.dev): defines un esquema
como un valor, lo compones, y con él parseas datos no confiables (JSON, formularios,
config) obteniendo un resultado válido o una lista de errores con su ubicación exacta.

## Por qué (el hueco)

En Nim no existe un buen validador estilo Zod. Lo que hay —`nim-validation`,
`lost22git/validate`, `openpeeps/bag`— es estilo "pragmas sobre un tipo" (Pydantic-like)
y queda corto para lo que las apps reales necesitan a diario: validar datos de los que
*no* tienes un tipo, componer y derivar esquemas, transformar mientras validas, y juntar
todos los errores con su ruta. Zod domina en TS justo por eso; sus clones aparecen en
Go (`gozod`), Rust (`vld`) y Elixir (`xod`). `bouncer` trae ese modelo a Nim.

## Qué copiamos de las referencias y qué mejoramos

Estudiado: [`gozod`](https://github.com/0xfurai/gozod) (Go, el más cercano por ser
tipado estático) y la API de Zod.

**Bien en gozod — lo copiamos:**
- Interfaz `Schema` unificada (`Validate(value, path) -> errors`) para que un objeto pueda
  tener campos de tipos distintos. En Nim lo hacemos con un **objeto variante** (`case kind`):
  un solo tipo `Schema`, sin herencia ni dispatch dinámico. Más simple y más Nim.
- **Códigos de error estables** (`invalid_type`, `too_small`, `too_big`, `invalid_string`,
  `required`, `unrecognized_keys`, `invalid_enum`, `custom`) + error estructurado con
  `path`, `code`, `message`. Permite formatear para APIs, no solo imprimir.
- **Ruta como lista de partes** (claves e índices) para localizar el error en datos anidados.
- **API fluida** encadenable: `str().min(3).max(50)`.
- `refine` para reglas propias.
- `safeParse` (no lanza, devuelve resultado) vs `parse` (lanza) — de Zod.

**Flojo en gozod / Go — lo mejoramos:**
- Go usa `value any` por todos lados → aserciones de tipo en runtime y se pierde tipado.
  Nosotros usamos `JsonNode` como valor universal (el caso real #1 es JSON), más limpio.
- `map[string]Schema` **pierde el orden** de los campos → en Nim usamos `OrderedTable`, así
  los errores y la salida respetan el orden en que declaraste los campos (mejor DX).
- El display de errores (`join("; ")`) es pobre → damos `$` por issue con ruta puntuada:
  `user.email: must be a valid email`.
- Go no tiene nada en compile-time. Nim sí: dejamos la puerta abierta a una capa futura
  "esquema ⇄ tipo de Nim" con macros (la comodidad de Pydantic, encima de esta base).
- Cero dependencias externas: email validado a mano (sin motor regex); `pattern` usa
  `std/re` (stdlib).

## Arquitectura

```
src/bouncer.nim            # fachada: import + export de la API pública
src/bouncer/core.nim       # tipos (Schema variante, Issue, ParseResult) + validate + $
src/bouncer/builders.nim   # constructores (str/integer/number/boolean/obj/arr),
                           # encadenado (min/max/email/pattern/oneOf/optional/refine),
                           # parse / safeParse
```

`Schema` es un `ref object` variante por `kind`. Un único `validate(s, node, path)` recorre
el `case`. Los constructores devuelven un `Schema`; los métodos de encadenado mutan y
devuelven el mismo `Schema` (ref), como Zod/gozod.

### Tipos núcleo

```nim
PathPart   = objeto variante: clave (string) o índice (int)
IssueCode  = enum (los códigos de arriba)
Issue      = object: path: seq[PathPart]; code: IssueCode; message: string
ParseResult = object variante { ok: bool }:
               ok   -> value: JsonNode   (dato validado)
               err  -> issues: seq[Issue]
BouncerError = object of CatchableError: issues: seq[Issue]
```

## Alcance v0.1

- Escalares: `str` (min/max/email/pattern/oneOf), `integer` y `number` (min/max), `boolean`.
- Compuestos: `obj({...})` (con modo `strict` para rechazar claves extra) y `arr(elem)`.
- `optional` para campos ausentes o `null`.
- `refine(fn, msg)` para reglas propias.
- `safeParse` / `parse`, errores con ruta y código, `$` legible.
- Tests desde el día 1.

## Después de v0.1 (no ahora)

- `transform` (coerción: string→int, trim) y `coerce`.
- Composición: `partial`, `pick`, `omit`, `extend`, `merge`.
- Capa macro: derivar un `Schema` desde un `object` de Nim y parsear directo a ese tipo.
- Uniones (`oneOfSchema`), `record`, fechas.
