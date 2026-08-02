/// Wire-format constants for BTOON (Binary TOON).
///
/// BTOON is the binary transport encoding of the TOON data model. Unlike
/// TOON's text form it is optimized for CPU cost first and wire size
/// second:
///
///   * a fixed 8-byte envelope (`"BTON"` magic, version, flags) with an
///     optional per-message string table, optional embedded schema and an
///     8-byte-aligned body;
///   * inline `SmallInt` values and fixed-width little-endian integers and
///     floats (never varints);
///   * strings deduplicated against a session dictionary and per-message
///     string table via `StringRef`;
///   * homogeneous numeric lists as `TypedArray` and homogeneous numeric
///     object lists as columnar `ObjectTable`, both padded so decoders can
///     expose zero-copy views;
///   * optional schema mode that drops keys and tags entirely.
///
/// Every input maps to exactly one byte sequence (deterministic encoding).
///
/// The constants mirror `btoon_spec/spec.md` (§7 Envelope, §8 Value
/// Encoding, §12 Element Types).
library btoon_constants;

/// Magic bytes at the start of every BTOON message: ASCII `"BTON"`.
const List<int> btoonMagic = [0x42, 0x54, 0x4F, 0x4E];

/// Current BTOON format version.
const int btoonVersion = 0x01;

/// Total size of the BTOON envelope in bytes.
const int btoonEnvelopeSize = 8;

/// Envelope flag: reserved (must stay zero in the wire, ignored on decode).
const int flagReserved = 0x01;

/// Envelope flag: an embedded schema section is present (§7.6). When set,
/// the body is a schema body (§15.2).
const int flagHasSchema = 0x02;

/// Envelope flag: a per-message string table section is present (§7.5).
const int flagStringTable = 0x04;

/// Envelope flag: a non-empty session dictionary is in use (§11.1).
const int flagSession = 0x08;

// Value tags (§8.1).
const int tagNull = 0x00;
const int tagFalse = 0x01;
const int tagTrue = 0x02;
const int tagInt32 = 0x03;
const int tagInt64 = 0x04;
const int tagFloat32 = 0x05;
const int tagFloat64 = 0x06;
const int tagString = 0x07;
const int tagBinary = 0x08;
const int tagArray = 0x09;
const int tagObject = 0x0A;
const int tagStringRef = 0x0B;
const int tagTypedArray = 0x0C;
const int tagObjectTable = 0x0D;

/// Inline `SmallInt` values occupy the bare bytes `0x20`..`0x9F`; the value
/// is `byte - smallIntBias`, covering `[-32, 95]` with no payload bytes
/// (§8.2).
const int smallIntBias = 0x40;
const int smallIntTagMin = 0x20;
const int smallIntTagMax = 0x9F;
const int smallIntMin = -32;
const int smallIntMax = 95;

// Element-type selectors shared by TypedArray buffers, ObjectTable columns
// and Schema fields (§12). TypedArray allows `0x00`-`0x08`; ObjectTable
// columns additionally allow `0x0F` (uint64); schema fields may use any.
const int elementInt8 = 0x00;
const int elementUint8 = 0x01;
const int elementInt16 = 0x02;
const int elementUint16 = 0x03;
const int elementInt32 = 0x04;
const int elementUint32 = 0x05;
const int elementInt64 = 0x06;
const int elementFloat32 = 0x07;
const int elementFloat64 = 0x08;
const int elementNull = 0x09;
const int elementBool = 0x0A;
const int elementString = 0x0B;
const int elementBinary = 0x0C;
const int elementArray = 0x0D;
const int elementObject = 0x0E;
const int elementUint64 = 0x0F;
