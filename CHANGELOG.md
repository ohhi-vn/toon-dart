## 0.2.0

### BTOON: binary codec

New binary sibling format, aligned to `btoon_spec/spec.md`:

- `btoonEncode` / `btoonDecode` with a fixed 8-byte envelope (`BTON` magic,
  version, flags) and an 8-byte-aligned body.
- Compact value encoding: inline `SmallInt` (`-32..95`), `Int32` / `Int64`,
  `Float32` / `Float64`, strings, binary blobs, arrays, and objects with
  deterministically sorted keys.
- Per-message **string table** with configurable minimum frequency
  (`minStringTableFrequency`), plus a cross-message **session dictionary**
  (`BtoonSession`) for progressive deduplication across messages.
- Homogeneous numeric lists encode as aligned **TypedArray** buffers
  (`BtoonTypedArray`, `BtoonElementType`) for zero-copy decodable columns.
- Homogeneous numeric object lists encode as columnar **ObjectTable**
  (`BtoonObjectTable`) with aligned fixed-width columns.
- **Schema mode** (`BtoonSchema`, `BtoonSchemaField`, `BtoonSchemaType`)
  drops keys and tags: values are written positionally after a schema id,
  with an optional embedded schema and out-of-band schema support.
- Deterministic encoding: identical inputs always produce identical bytes.
- Robust decoding: truncation, invalid alignment, out-of-range string
  references, non-numeric ObjectTable columns, and unknown flags are all
  rejected with `BtoonDecodeError` / `BtoonEncodeError`.
- New types exported from `package:toon_format/toon_format.dart`:
  `BtoonBinary`, `BtoonElementType`, `BtoonTypedArray`, `BtoonObjectTable`,
  `BtoonSession`, `BtoonSchema`, `BtoonSchemaField`, `BtoonSchemaType`,
  `BtoonEncodeOptions`, `BtoonDecodeOptions`.

### TOON improvements

- Faster text encoder/decoder paths (code-unit scanners, pre-estimated
  buffer capacity, cached indentation, inlined hot paths).
- Schema-based tabular encode/decode (`ConcreteSchema`, `FlattenedSchema`,
  `IntKeyedSchema`) for direct, indexed field access.
- Stream decoding (`ToonStreamDecoder`, `streamTabularRows`,
  `streamTabularRowsWithSchema`, `streamListItems`) for O(1) memory per item.
- Int64 range guard and web (JS) compatibility for large integers.

## 0.1.0

- Initial release
- Reserved package namespace on pub.dev
- Implementation pending
