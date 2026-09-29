# Spec Delta

## Purpose

BTOON is the deterministic, little-endian binary transport encoding of the TOON data model. This capability defines the Dart codec's v1.0 wire behavior, optimized value forms, and defensive decoding contract.

## ADDED Requirements

### Requirement: BTOON v1 envelope and dynamic values

Every message MUST begin with the 8-byte header `BTON`, version `0x01`, flags, and two zero reserved bytes. All multi-byte values, lengths, and counts MUST be fixed-width little-endian; lengths and counts MUST be UInt32. Flag `0x02` indicates an embedded schema and schema-mode body, `0x04` a per-message string table, `0x08` an active non-empty session dictionary, `0x10` no per-message table, and `0x20` UInt16 schema IDs. Flags `0x04` and `0x10` MUST NOT both be set. The encoder MUST set flags to match emitted sections and body mode. String-table and embedded-schema sections MUST end in zero padding to an 8-byte boundary, and the body MUST start at an offset divisible by 8. The decoder MUST reject invalid magic, unsupported versions, non-zero reserved bytes, malformed sections, unknown non-extension tags, mode mismatches, and trailing bytes; it MUST ignore reserved or unrecognized flag bits.

Dynamic values MUST use the v1 tag assignments: Null `0x00`, False `0x01`, True `0x02`, Int32 `0x03`, Int64 `0x04`, Float32 `0x05`, Float64 `0x06`, String `0x07`, Binary `0x08`, Array `0x09`, Object `0x0A`, StringRef `0x0B`, TypedArray `0x0C`, ObjectTable `0x0D`, and RecordBatch `0x0E`. SmallInt uses the bare lead byte `0x20..0x9F` with value `byte - 64`. Arrays contain a UInt32 count and tagged values; objects contain a UInt32 count and string or StringRef key/value pairs. Reserved tags `0x0F..0x1F` and `0xA0..0xEF` MUST be rejected.

The encoder MUST use SmallInt for integers in `-32..95`, otherwise the narrowest of Int32 and Int64, and MUST reject integers outside Int64. It MUST encode a value as Float32 only when conversion to and from binary32 is lossless, including preserving positive and negative floating zero as floats. Object keys MUST be emitted in UTF-8 byte order. Binary values MUST remain distinct from UTF-8 strings.

#### Scenario: Encode canonical primitive values
- **WHEN** the encoder receives `42`, `96`, `1.5`, `1.1`, and `-0.0`
- **THEN** it encodes `42` as SmallInt, `96` as Int32, `1.5` as Float32, `1.1` as Float64, and `-0.0` as a floating-point value with its sign preserved

#### Scenario: Emit object fields deterministically
- **WHEN** the encoder receives equivalent maps whose keys were inserted in different orders
- **THEN** it emits their key/value pairs in the same UTF-8 byte order and produces identical bytes

#### Scenario: Reject invalid envelope and body data
- **WHEN** the decoder receives an unsupported version, invalid magic, non-zero reserved bytes, an unknown reserved tag, a schema flag with a dynamic body, or bytes after the body
- **THEN** it returns a decode error instead of accepting or misparsing the message

### Requirement: Deterministic string-table and session-dictionary selection

The encoder MUST consider only strings that occur at least twice in the message and are not already in the session dictionary as ordinary per-message string-table candidates. A set per-message table MUST contain a UInt32 entry count followed by UInt32 byte lengths and UTF-8 bytes, then zero padding to an 8-byte boundary. It MUST emit a candidate table only when the complete message, including envelope, entries, references, flags, and padding, is smaller than its inline-string representation; ties MUST use inline strings. Selected entries MUST retain first-encounter order. StringRef IDs MUST use the canonical SmallInt/Int32/Int64 integer encoding and address session entries first and per-message entries second. When `0x10` is set the per-message table MUST be absent, and strings MUST be inline or referenced from the session dictionary. The encoder MUST set the string-table, session, and no-per-message-table flags consistently, and MUST NOT set the mutually exclusive table and no-table flags together.

When a session dictionary is active, ObjectTable column names MUST use StringRef. A column name absent from both dictionaries MUST be placed in the per-message table, so the no-per-message-table flag cannot be set for that message.

#### Scenario: Keep one-off strings inline
- **WHEN** a message contains a non-session string only once
- **THEN** the encoder does not add that string to the per-message table

#### Scenario: Select a table for a complete-message size win
- **WHEN** repeated non-session strings make the complete message smaller with a per-message table
- **THEN** the encoder writes the entries in first-encounter order and references them using IDs after the session dictionary

#### Scenario: Keep strings inline when the table does not reduce size
- **WHEN** the table representation ties or is larger than inline strings
- **THEN** the encoder emits no per-message table and uses inline strings

#### Scenario: Resolve references across both dictionaries
- **WHEN** a StringRef addresses a valid session entry or per-message entry
- **THEN** the decoder resolves it using the combined ID space, with session IDs first

#### Scenario: Reject an out-of-range reference
- **WHEN** a StringRef is outside the combined dictionary
- **THEN** the decoder returns a decode error

#### Scenario: Reference ObjectTable names with an active session
- **WHEN** an ObjectTable column name is absent from an active session dictionary
- **THEN** the encoder adds it to the per-message table, emits it as a StringRef, and does not set the no-per-message-table flag

### Requirement: Numeric TypedArrays and ObjectTables

When enabled, the encoder MUST encode homogeneous numeric arrays as TypedArrays and homogeneous object arrays with identical keys and numeric columns as ObjectTables. A TypedArray MUST contain tag `0x0C`, element selector, UInt32 element count, PadLen, zero padding, and a raw buffer of exactly count × element-size bytes. An ObjectTable MUST contain tag `0x0D`, UInt32 row and column counts, and for each column a String or StringRef name, numeric selector, PadLen, zero padding, and exactly one fixed-width element per row. It MUST choose the narrowest lossless numeric selector deterministically, preferring a signed type when signed and unsigned types of the same width both fit. ObjectTable columns MUST be sorted by UTF-8 key order. Non-numeric or structurally ineligible object arrays MUST use the general Array representation. Applications MAY disable either optimized representation.

TypedArray selectors MUST be numeric selectors `0x00..0x08`; ObjectTable column selectors MUST be numeric selectors `0x00..0x08` or `0x0F` (UInt64). TypedArray and ObjectTable column payloads MUST have the declared element width, little-endian values, and zero padding that places each payload at an offset aligned to its element size. The decoder MUST reject invalid selectors, inconsistent payload sizes, invalid padding lengths, non-zero padding, or misaligned payloads.

#### Scenario: Encode homogeneous numeric arrays and rows
- **WHEN** numeric values form a homogeneous list or a same-key object array with numeric columns
- **THEN** the encoder uses a TypedArray or ObjectTable with deterministic element types and aligned raw buffers

#### Scenario: Fall back for ineligible object arrays
- **WHEN** object rows have different keys or a column contains strings, nulls, or mixed numeric types
- **THEN** the encoder uses a general Array of Objects unless the caller explicitly supplies an invalid ObjectTable wrapper, which produces an encode error

#### Scenario: Reject malformed numeric payload alignment
- **WHEN** a TypedArray or ObjectTable column declares an invalid element type, out-of-range padding length, non-zero padding, misaligned data, or truncated data
- **THEN** the decoder returns a decode error without reading beyond the message

### Requirement: Embedded schema mode

When schema mode is used, the encoder MUST embed the authoritative schema in the envelope and set the schema flag. The embedded schema and body SchemaID MUST use UInt16 exactly when the schema-ID-width flag is set, and UInt32 otherwise. The body MUST contain values in schema field order without keys or per-field tags: numeric values use their declared fixed-width little-endian representation, null uses no bytes, booleans use exactly `0` or `1`, strings use String or StringRef, binary uses a tagged Binary value, and array/object values use full tagged values. Values MUST satisfy the declared field types and widths. The decoder MUST reject invalid selectors, mismatched supplied schemas, invalid boolean values, schema violations, and truncated fields.

#### Scenario: Encode and decode a schema record
- **WHEN** a value matches an embedded schema
- **THEN** the encoder writes the schema and schema ID at the selected width and the decoder reconstructs the original map or record list

#### Scenario: Reject a schema value outside its declared type
- **WHEN** a schema field value has the wrong type, does not fit its declared numeric width, or contains a boolean byte other than `0` or `1`
- **THEN** encoding or decoding returns the corresponding error

### Requirement: Capability-gated RecordBatch encoding

The encoder MUST treat only a top-level array with at least two objects, identical string-key sets, and stable per-field non-null types as a RecordBatch candidate. Eligible fields MUST include at least one numeric field and one string field; nulls are allowed, but a field with multiple non-null types makes the array ineligible. Numeric-only arrays MUST continue to use ObjectTable rules. A RecordBatch MUST contain tag `0x0E`, UInt32 field count, field descriptors (`UInt32` name length, inline UTF-8 name, selector, nullable byte), UInt32 row count, validity bitmaps, then row-major values. Integer and float field selectors MUST be the narrowest lossless numeric selectors, with the signed selector preferred when signed and unsigned selectors of equal width both fit. All-null fields MUST use the null selector with `Nullable = 0` and no validity bitmap. Other fields MUST set `Nullable = 1` and carry a validity bitmap exactly when at least one row is null; otherwise `Nullable` MUST be `0` and no bitmap is present.

RecordBatch descriptors MUST be ordered by UTF-8 field-name bytes. Its validity maps MUST use one low-order-first bit per row, have zero unused high bits, and precede row-major field values. Values MUST use the selected fixed-width little-endian numeric format or a UInt32 byte length followed by UTF-8 string bytes, without per-value tags or padding. Decoding MUST return an ordinary array of objects.

The encoder MUST emit tag `0x0E` only when `peerSupportsRecordBatch` is true and the complete RecordBatch message is smaller than dynamic encoding; ties MUST use dynamic encoding. Peer support MUST default to false. The decoder MUST reject invalid selectors, nullable bytes, truncated descriptors, bitmaps or values, and non-zero unused bitmap bits.

#### Scenario: Encode a supported, size-efficient mixed batch
- **WHEN** the top-level rows satisfy RecordBatch eligibility, the peer-support option is enabled, and the complete RecordBatch message is smaller than the dynamic message
- **THEN** the encoder emits tag `0x0E` with sorted descriptors, correct null bitmaps, and row-major values, and decoding returns the original array of objects

#### Scenario: Fall back when peer support or size benefit is absent
- **WHEN** peer support is false, eligibility fails, or the complete RecordBatch message ties or exceeds dynamic encoding
- **THEN** the encoder emits the dynamic representation, and numeric-only object arrays continue to follow ObjectTable rules

#### Scenario: Reject malformed RecordBatch data
- **WHEN** a RecordBatch contains an invalid descriptor or nullable byte, a truncated bitmap or row, or non-zero unused validity bits
- **THEN** the decoder returns a decode error

### Requirement: Length-prefixed extension values

Extension values MUST use tags `0xF0..0xFF`, a UInt32 little-endian payload length, and exactly that many payload bytes. A decoder without an implementation for an extension MUST safely skip or surface its raw payload and continue decoding without treating the tag as a reserved-tag error.

#### Scenario: Preserve an unimplemented extension payload
- **WHEN** the decoder receives a well-formed extension with an unimplemented tag
- **THEN** it consumes exactly the length-prefixed payload and exposes or skips it without misaligning the following value

#### Scenario: Reject a truncated extension
- **WHEN** an extension length exceeds the remaining message or configured binary limit
- **THEN** the decoder returns a decode error

### Requirement: Defensive decoding and Dart API behavior

The decoder MUST validate all lengths, counts, reference IDs, offsets, and arithmetic before allocating or reading. It MUST enforce configurable maximum nesting depth, string size, binary size, and container count, reject invalid UTF-8 and truncated input, and MUST NOT materialize binary payloads as numeric lists as an intermediate step. The public Dart API MUST retain `btoonEncode` and `btoonDecode`, return decoded ordinary values for RecordBatch, and report malformed input and unsupported values through the existing BTOON decode and encode errors. The encoder options MUST expose an explicit RecordBatch peer-support setting that defaults to disabled.

#### Scenario: Reject hostile sizes and excessive nesting
- **WHEN** input lengths, counts, nesting, or arithmetic exceed configured limits or available bytes
- **THEN** decoding fails with a BTOON decode error before unsafe allocation or out-of-bounds access

#### Scenario: Use the public codec API with capability options
- **WHEN** an application encodes or decodes through the public BTOON API
- **THEN** existing entry points and wrapper types remain available, and RecordBatch is sent only when the caller opts in to peer support
