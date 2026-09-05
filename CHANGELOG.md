## Unreleased

### BTOON: v1.0-draft spec compliance

Implements the new BTOON v1.0-draft specification (§ references below):

- **String table by default (§26.3, §26.5)**: every string is added to the
  per-message table in first-encounter order (`minStringTableFrequency`
  now defaults to 1), matching the spec test vectors. New
  `noStringTable` encode option maps to the no-table envelope flag 0x10
  (§7.5.1).
- **ObjectTable column names (§14)**: with a session dictionary active,
  column names outside the dictionary are added to the per-message table
  (instead of failing), so they can be referenced as `StringRef`s; the
  no-table flag is then not set.
- **Signed-first element types (§17, §26.4)**: homogeneous integer lists
  now prefer the signed type when a signed and unsigned type of the same
  width both fit (`[1, 2, 3]` encodes as int8, not uint8).
- **UTF-8 byte-sequence key order (§17)**: object keys, ObjectTable columns
  and derived schema fields sort by UTF-8 bytes (code-point order), not
  UTF-16 code units.
- **Extension types (§23)**: tags `0xF0`–`0xFF` decode as
  `BtoonExtension` (raw payload surfaced) instead of failing, and encode
  back losslessly; unknown extensions are skippable per spec.
- **Decoder strictness (§19)**: trailing bytes after the body are
  rejected; the schema flag (0x02) alone selects the schema body mode, and
  an out-of-band schema now validates the embedded schema instead of
  driving decoding; alignment padding is verified to be zero (§16).
- **Decoder limits (§24)**: new `maxStringSize`, `maxBinarySize` and
  `maxContainerCount` decode options; hostile counts are validated against
  the bytes actually available before any allocation.
- Byte-exact test vectors from §26.1–§26.6 in
  `test/btoon/spec_vectors_test.dart`.

### BTOON: performance

Encode/decode hot paths reworked (see `benchmark/btoon_benchmark.dart`):

- `BtoonWriter` rewritten around a growable buffer with `ByteData` stores:
  every multi-byte value is one native store instead of per-byte calls;
  growth jumps exactly for large writes; a no-table fast path writes the
  body straight into the envelope buffer (no intermediate body copy).
- TypedArray encode: single-pass memoized list scan (element type +
  float32/float64 conversion buffer built in the same pass), specialized
  loops for `List<int>` / `List<double>`, and bulk int writes through
  typed-list conversion (10k ints: ~1.6 ms → ~47 µs).
- TypedArray decode: bulk conversion through typed-data views over an
  exact-size copy (10k ints: ~136 µs → ~1.9 µs; 100k float64:
  ~2.3 ms → ~160 µs).
- ObjectTable encode: the plan is computed once and memoized across the
  encode passes, rows are no longer copied, columns are detected in a
  single pass and written by direct row indexing.
- String table: default mode assigns table indices during the collect
  pass (no occurrence counting); schema derivation no longer copies row
  maps. Overall: small maps ~1.8x, nested maps ~1.6x, object tables ~2x,
  string lists ~2.3x, schema mode ~1.7x faster to encode.

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
