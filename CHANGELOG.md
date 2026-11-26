# Changelog

## 1.0.0
- First stable release. The API is settled.
- Object validation does one field lookup instead of two (`hasKey` + `[]` → a single
  `{}`), a few percent off the hot path.

## 0.8.0
- A failed `union` now reports the errors of the variant that came closest, instead
  of a generic "didn't match" — so a discriminated union points right at the bad field.

## 0.7.0
- `catch(value)`: fall back to a value when validation fails (unlike `default`, which
  only fills a missing or null field).

## 0.6.0
- `nullable()` and `nullish()` alongside `optional()`, matching Zod's three-way split
  between a missing key and a null value. A nullable null is kept in the output.

## 0.5.0
- `tup([...])`: fixed-length tuples with one schema per position, plus an optional
  `rest` for a variadic tail.

## 0.4.0
- `record(valueSchema)`: an object with arbitrary keys whose values share one schema.
- CI now runs on Linux, macOS and Windows.

## 0.3.1
- Faster validation: the error path is built from one shared buffer instead of a new
  seq per field, and a string node is only rebuilt when `trim` changed it. ~18% on
  nested input, with the error output unchanged.

## 0.3.0
- `union`, `literal`, and `date()` / `datetime()` string checks.

## 0.2.0
- Compose object schemas: `partial`, `pick`, `omit`, `extend`, `merge`.
- Derive a schema from a Nim type with `schemaFor`, and validate into a typed value
  with `fromJson`.
- GitHub Actions CI.

## 0.1.0
- First release: `str`/`integer`/`number`/`boolean`/`obj`/`arr`, the validators
  (`min`/`max`/`email`/`url`/`uuid`/`pattern`/`oneOf`/…), `coerce`/`trim`/`default`/
  `refine`/`transform`, and `safeParse` / `parse` with collected, path-tagged errors.
