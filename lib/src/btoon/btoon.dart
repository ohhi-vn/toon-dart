/// BTOON — a compact binary codec for the TOON data model.
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
///   * homogeneous numeric lists as `TypedArray` and homogeneous object
///     lists as columnar `ObjectTable`, both padded so decoders can expose
///     zero-copy views;
///   * optional schema mode that drops keys and tags entirely.
///
/// Every input maps to exactly one byte sequence (deterministic encoding).
library btoon;

import 'dart:typed_data';

import 'decoder.dart';
import 'encoder.dart';
import 'errors.dart';
import 'options.dart';

export 'errors.dart';
export 'options.dart';
export 'types.dart';

/// Encodes [value] to a BTOON binary.
///
/// Returns the encoded bytes, or throws [BtoonEncodeError] if [value]
/// contains a type that cannot be encoded (non-string map keys, unsupported
/// host types, integers outside the `int64` range, ...).
///
/// ```dart
/// final bytes = btoonEncode({'name': 'Alice', 'age': 30});
/// ```
Uint8List btoonEncode(Object? value, {BtoonEncodeOptions? options}) {
  return btoonEncodeBytes(value, options ?? const BtoonEncodeOptions());
}

/// Decodes a BTOON binary back into a Dart value.
///
/// Returns the decoded value, or throws [BtoonDecodeError] if [bytes] is
/// malformed.
///
/// ```dart
/// final data = btoonDecode(bytes);
/// ```
Object? btoonDecode(Uint8List bytes, {BtoonDecodeOptions? options}) {
  return btoonDecodeBytes(bytes, options ?? const BtoonDecodeOptions());
}
