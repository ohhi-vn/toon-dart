/// Value types and schemas for BTOON encoding and decoding.
///
/// BTOON encodes plain JSON-like values (`null`, `bool`, `int`, `double`,
/// `String`, `List`, `Map` with string keys) plus a few explicit wrappers:
///
///   * [BtoonBinary] / `Uint8List` — raw byte blobs;
///   * [BtoonTypedArray] — a numeric list encoded as a fixed-width
///     `TypedArray`;
///   * [BtoonObjectTable] — a list of maps encoded as a columnar
///     `ObjectTable`.
///
/// A [BtoonSession] is an optional string dictionary shared across several
/// messages; strings already present in the dictionary are emitted as
/// `StringRef` instead of being repeated.
library btoon_types;

import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';

/// A raw binary blob carried through BTOON as a byte sequence.
class BtoonBinary {
  /// The raw bytes.
  final Uint8List bytes;

  BtoonBinary(this.bytes);

  @override
  bool operator ==(Object other) =>
      other is BtoonBinary &&
      other.bytes.length == bytes.length &&
      _listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'BtoonBinary(${bytes.length} bytes)';
}

/// Fixed-width numeric element types for [BtoonTypedArray] columns.
enum BtoonElementType {
  int8,
  int16,
  int32,
  int64,
  uint8,
  uint16,
  uint32,
  uint64,
  float32,
  float64;

  /// Number of bytes each element occupies on the wire.
  int get size {
    switch (this) {
      case int8:
      case uint8:
        return 1;
      case int16:
      case uint16:
        return 2;
      case int32:
      case uint32:
      case float32:
        return 4;
      case int64:
      case uint64:
      case float64:
        return 8;
    }
  }
}

/// A numeric list encoded as a fixed-width `TypedArray`.
///
/// When [elementType] is null the encoder picks the smallest lossless
/// element type automatically.
class BtoonTypedArray {
  /// Numeric values to encode.
  final List<num> values;

  /// Forced element type, or null for automatic selection.
  final BtoonElementType? elementType;

  BtoonTypedArray(this.values, {this.elementType});
}

/// A list of maps encoded as a columnar `ObjectTable`.
///
/// Field order on the wire is the sorted union of all keys; rows missing a
/// key are filled with `null`.
class BtoonObjectTable {
  /// Rows to encode.
  final List<Map<String, dynamic>> rows;

  BtoonObjectTable(this.rows);

  /// Validates that all rows have string keys and returns a normalized copy.
  List<Map<String, dynamic>> normalized() {
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final normalized = <String, dynamic>{};
      normalized.addAll(row);
      result.add(normalized);
    }
    return result;
  }
}

/// An optional string dictionary shared across encode/decode calls.
///
/// When provided to an encoder, strings already in the dictionary are
/// emitted as `StringRef` entries instead of being written out again. After
/// each message the encoder (and a paired decoder using the same session)
/// appends the new strings it saw, so repeated messages progressively shrink.
class BtoonSession {
  final List<String> _strings = [];
  final Map<String, int> _index = {};

  /// All entries in first-added order.
  List<String> get entries => List.unmodifiable(_strings);

  /// Number of entries.
  int get length => _strings.length;

  /// Returns the session index of [value], or null if absent.
  int? indexOf(String value) => _index[value];

  /// Returns the entry at [index].
  String at(int index) => _strings[index];

  /// Adds [value] if not already present; returns its session index.
  int add(String value) {
    final existing = _index[value];
    if (existing != null) return existing;
    _index[value] = _strings.length;
    _strings.add(value);
    return _strings.length - 1;
  }

  /// Removes all entries.
  void clear() {
    _strings.clear();
    _index.clear();
  }
}

/// Schema field types used in BTOON schema mode.
///
/// The wire element-type selectors (§12) are shared with `TypedArray` and
/// `ObjectTable` columns; numeric schema fields map onto `integer` (int64)
/// and `number` (float64). The exact selector a field was read with is
/// preserved on [BtoonSchemaField.elementCode], so narrower numeric fields
/// (int8, float32, ...) decode and re-encode with their original width.
enum BtoonSchemaType {
  /// No element type; not representable on the wire. Using it in schema mode
  /// raises [BtoonEncodeError].
  any,

  /// Only `null` is allowed; encoded with zero bytes (selector `0x09`).
  null_,

  /// Encoded as a single byte (`0x00` / `0x01`), no tag (selector `0x0A`).
  boolean,

  /// Encoded as a fixed-width little-endian `int64`, no tag
  /// (selector `0x06`).
  integer,

  /// Encoded as a fixed-width little-endian `float64`, no tag
  /// (selector `0x08`).
  number,

  /// Encoded as a tagged String or StringRef (selector `0x0B`).
  string,

  /// Encoded as a tagged Binary value (selector `0x0C`).
  binary,

  /// Encoded as a full tagged value (selector `0x0D`).
  array,

  /// Encoded as a full tagged value (selector `0x0E`).
  object;

  /// Wire element-type selector code.
  int get code {
    switch (this) {
      case any:
        throw const BtoonEncodeError(
          'BtoonSchemaType.any has no wire element-type code; '
          'give the field a concrete type',
        );
      case null_:
        return elementNull;
      case boolean:
        return elementBool;
      case integer:
        return elementInt64;
      case number:
        return elementFloat64;
      case string:
        return elementString;
      case binary:
        return elementBinary;
      case array:
        return elementArray;
      case object:
        return elementObject;
    }
  }

  /// Resolves a wire element-type selector to a [BtoonSchemaType].
  ///
  /// Numeric selectors map onto [integer] / [number]; callers that need to
  /// re-encode with the original width should also keep the raw selector in
  /// [BtoonSchemaField.elementCode].
  static BtoonSchemaType fromCode(int code) {
    switch (code) {
      case elementInt64:
      case elementUint64:
        return integer;
      case elementFloat32:
      case elementFloat64:
        return number;
      case elementNull:
        return null_;
      case elementBool:
        return boolean;
      case elementString:
        return string;
      case elementBinary:
        return binary;
      case elementArray:
        return array;
      case elementObject:
        return object;
      default:
        if (code >= elementInt8 && code <= elementUint32) return integer;
        throw BtoonDecodeError('invalid schema element-type code $code');
    }
  }
}

/// A single field of a [BtoonSchema].
class BtoonSchemaField {
  /// Field name (used as the map key).
  final String name;

  /// Field type controlling the (tagless) encoding in schema mode.
  final BtoonSchemaType type;

  /// The exact wire element-type selector, when it differs from the one
  /// implied by [type] (used when decoding schemas that declare narrower
  /// numeric fields such as int8 or float32).
  final int? elementCode;

  const BtoonSchemaField(
    this.name, {
    this.type = BtoonSchemaType.any,
    this.elementCode,
  });

  /// The wire element-type selector for this field.
  int get code => elementCode ?? type.code;
}

/// A schema for BTOON schema mode.
///
/// Schema mode drops keys and tags: values are encoded positionally after a
/// `SchemaID::UInt32`, using the fixed-width encoding of each field's
/// element type ([§15][spec]). A schema has an id, a name, and an ordered
/// list of typed fields; the embedded schema (§7.6) carries the same layout.
///
/// [spec]: https://github.com/johannschopplich/toon/blob/main/BTOON.md
class BtoonSchema {
  /// Schema id, echoed at the head of every schema-mode body.
  final int id;

  /// Schema name (informational; carried in the embedded schema).
  final String name;

  /// Fields in order; order determines the positional encoding.
  final List<BtoonSchemaField> fields;

  BtoonSchema(this.fields, {this.id = 0, this.name = ''});

  /// Creates a schema from field names (all typed as `any`; give fields a
  /// concrete type before using the schema in schema mode).
  BtoonSchema.fromNames(List<String> names, {this.id = 0, this.name = ''})
      : fields = List<BtoonSchemaField>.unmodifiable(
          names.map((n) => BtoonSchemaField(n)),
        );

  /// Field names in order.
  List<String> get fieldNames =>
      List<String>.unmodifiable(fields.map((f) => f.name));
}

bool _listEquals(List<int> a, List<int> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
