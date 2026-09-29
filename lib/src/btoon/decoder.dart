/// BTOON decoder.
library btoon_decoder;

import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';
import 'io.dart';
import 'numeric.dart';
import 'options.dart';
import 'types.dart';

class _DecodeState {
  final BtoonReader reader;
  final List<String> messageTable;
  final BtoonSession? session;
  final bool growSession;
  final bool preserveBinary;
  final bool preserveTypedArrays;
  final int maxDepth;
  final int maxStringSize;
  final int maxBinarySize;
  final int maxContainerCount;
  final bool schemaIdUint16;
  final bool sessionActive;

  final List<String> inlineStrings = [];
  final Set<String> _inlineSeen = {};

  _DecodeState({
    required this.reader,
    required this.messageTable,
    required this.session,
    required this.growSession,
    required this.preserveBinary,
    required this.preserveTypedArrays,
    required this.maxDepth,
    required this.maxStringSize,
    required this.maxBinarySize,
    required this.maxContainerCount,
    required this.schemaIdUint16,
    required this.sessionActive,
  });

  void recordInlineString(String value) {
    // Inline strings are only tracked to grow a session dictionary after the
    // message; skip the bookkeeping entirely when that cannot happen.
    if (session == null || !growSession) return;
    if (_inlineSeen.add(value)) {
      inlineStrings.add(value);
    }
  }

  void growSessionIfNeeded() {
    final target = session;
    if (target == null || !growSession) return;
    for (final entry in messageTable) {
      target.add(entry);
    }
    for (final entry in inlineStrings) {
      target.add(entry);
    }
  }

  /// Validates an element/entry count against both the configured limit and
  /// the bytes actually available (each item needs at least [minBytesPerItem]
  /// bytes on the wire) before anything is allocated (§24).
  void checkCount(int count, int minBytesPerItem) {
    if (count > maxContainerCount) {
      throw BtoonDecodeError(
        'container count $count exceeds the limit of $maxContainerCount',
        reader.position,
      );
    }
    if (count > reader.remaining ~/ minBytesPerItem) {
      throw BtoonDecodeError(
        'container count $count exceeds the ${reader.remaining} byte(s) '
        'remaining',
        reader.position,
      );
    }
  }
}

/// Decodes a BTOON binary into a Dart value.
Object? btoonDecodeBytes(Uint8List bytes, BtoonDecodeOptions options) {
  if (bytes.length < btoonEnvelopeSize) {
    throw const BtoonDecodeError(
      'input is shorter than the BTOON envelope',
      0,
    );
  }
  final reader = BtoonReader(bytes);

  for (var i = 0; i < 4; i++) {
    if (bytes[i] != btoonMagic[i]) {
      throw BtoonDecodeError('bad magic bytes', i);
    }
  }
  reader.skip(4);
  final version = reader.readByte();
  if (version != btoonVersion) {
    throw BtoonDecodeError('unsupported BTOON version $version', 4);
  }
  final flags = reader.readByte();
  if ((flags & flagStringTable) != 0 && (flags & flagNoStringTable) != 0) {
    throw const BtoonDecodeError(
      'string-table and no-string-table flags are mutually exclusive',
      5,
    );
  }
  if (reader.readByte() != 0 || reader.readByte() != 0) {
    throw const BtoonDecodeError('non-zero reserved envelope bytes', 6);
  }
  // Unrecognized/reserved flag bits are ignored (§19).

  final messageTable = <String>[];
  if ((flags & flagStringTable) != 0) {
    final count = reader.readUint32();
    // Each entry is at least a UInt32 length field.
    if (count > options.maxContainerCount || count > reader.remaining ~/ 4) {
      throw BtoonDecodeError(
        'string table count $count exceeds the available input',
        reader.position,
      );
    }
    for (var i = 0; i < count; i++) {
      final length = reader.readUint32();
      if (length > options.maxStringSize) {
        throw BtoonDecodeError(
          'string table entry length $length exceeds the limit of '
          '${options.maxStringSize}',
          reader.position,
        );
      }
      messageTable.add(_readUtf8(reader, length));
    }
    _skipAlignedPadding(reader);
  }

  // The schema flag (0x02) is what signals a schema-mode body (§7.7); the
  // embedded schema is authoritative in v1. A schema supplied out of band
  // only validates the embedded one.
  BtoonSchema? schema;
  final isSchemaMode = (flags & flagHasSchema) != 0;
  if (isSchemaMode) {
    schema = _readSchema(
      reader,
      (flags & flagSchemaIdUint16) != 0,
      maxStringSize: options.maxStringSize,
      maxContainerCount: options.maxContainerCount,
    );
    final supplied = options.schema;
    if (supplied != null) {
      _validateSchemaMatches(supplied, schema, reader);
    }
  }

  reader.skipPaddingTo(8);

  final state = _DecodeState(
    reader: reader,
    messageTable: messageTable,
    session: options.session,
    growSession: options.growSession,
    preserveBinary: options.preserveBinary,
    preserveTypedArrays: options.preserveTypedArrays,
    maxDepth: options.maxDepth,
    maxStringSize: options.maxStringSize,
    maxBinarySize: options.maxBinarySize,
    maxContainerCount: options.maxContainerCount,
    schemaIdUint16: (flags & flagSchemaIdUint16) != 0,
    sessionActive: (flags & flagSession) != 0,
  );

  final result =
      isSchemaMode ? _decodeSchemaBody(state, schema!) : _decodeValue(state);

  if (!isSchemaMode && reader.remaining != 0) {
    throw BtoonDecodeError(
      'trailing bytes after the body: ${reader.remaining} unconsumed',
      reader.position,
    );
  }

  state.growSessionIfNeeded();
  return result;
}

// #region Tagged value decoding

Object? _decodeValue(_DecodeState state, {int depth = 0}) {
  _checkDepth(state, depth);
  final reader = state.reader;
  final tag = reader.readByte();
  // Dispatch hot path first: inline SmallInt (§8.2).
  if (tag >= smallIntTagMin && tag <= smallIntTagMax) {
    return tag - smallIntBias;
  }
  switch (tag) {
    case tagNull:
      return null;
    case tagFalse:
      return false;
    case tagTrue:
      return true;
    case tagInt32:
      return reader.readInt32();
    case tagInt64:
      return reader.readInt64();
    case tagFloat32:
      return reader.readFloat32();
    case tagFloat64:
      return reader.readFloat64();
    case tagString:
      return _readInlineString(state);
    case tagBinary:
      final length = reader.readUint32();
      if (length > state.maxBinarySize) {
        throw BtoonDecodeError(
          'binary length $length exceeds the limit of ${state.maxBinarySize}',
          reader.position,
        );
      }
      final bytes = reader.readBytes(length);
      return state.preserveBinary ? BtoonBinary(bytes) : bytes;
    case tagArray:
      final count = reader.readUint32();
      state.checkCount(count, 1); // each item carries at least a tag byte
      final list = <Object?>[];
      list.length = count;
      for (var i = 0; i < count; i++) {
        list[i] = _decodeValue(state, depth: depth + 1);
      }
      return list;
    case tagObject:
      final count = reader.readUint32();
      state.checkCount(count, 3); // key tag+ref, value tag minimum
      final map = <String, dynamic>{};
      for (var i = 0; i < count; i++) {
        final key = _readStringValue(state);
        map[key] = _decodeValue(state, depth: depth + 1);
      }
      return map;
    case tagTypedArray:
      return _readTypedArray(state);
    case tagObjectTable:
      return _readObjectTable(state);
    case tagRecordBatch:
      return _readRecordBatch(state);
    case tagStringRef:
      return _resolveStringRef(state, _readIntValue(reader));
    default:
      if (tag >= 0xF0) {
        // Extension type (§23): length-prefixed payload, so an unimplemented
        // extension can be skipped. Surface the raw payload for round-trip.
        final length = reader.readUint32();
        if (length > state.maxBinarySize) {
          throw BtoonDecodeError(
            'extension payload length $length exceeds the limit of '
            '${state.maxBinarySize}',
            reader.position,
          );
        }
        final payload = reader.readBytes(length);
        return BtoonExtension(tag, payload);
      }
      throw BtoonDecodeError(
        'unknown value tag 0x${tag.toRadixString(16)}',
        reader.position - 1,
      );
  }
}

/// Reads a canonical integer value (SmallInt / Int32 / Int64), used for
/// StringRef ids (§9.6).
int _readIntValue(BtoonReader reader) {
  final tag = reader.readByte();
  if (tag >= smallIntTagMin && tag <= smallIntTagMax) {
    return tag - smallIntBias;
  }
  switch (tag) {
    case tagInt32:
      return reader.readInt32();
    case tagInt64:
      return reader.readInt64();
    default:
      throw BtoonDecodeError(
        'expected an integer, got tag 0x${tag.toRadixString(16)}',
        reader.position - 1,
      );
  }
}

/// Reads a string that is either inline or a `StringRef`.
String _readStringValue(_DecodeState state) {
  final reader = state.reader;
  final tag = reader.readByte();
  if (tag == tagString) return _readInlineString(state);
  if (tag == tagStringRef) {
    return _resolveStringRef(state, _readIntValue(reader));
  }
  throw BtoonDecodeError(
    'expected a string tag, got 0x${tag.toRadixString(16)}',
    reader.position - 1,
  );
}

String _readInlineString(_DecodeState state) {
  final length = state.reader.readUint32();
  if (length > state.maxStringSize) {
    throw BtoonDecodeError(
      'string length $length exceeds the limit of ${state.maxStringSize}',
      state.reader.position,
    );
  }
  final value = _readUtf8(state.reader, length);
  state.recordInlineString(value);
  return value;
}

/// Resolves a combined-dictionary ref id (§11.3): session entries first
/// (ids `0..n-1`), then per-message table entries.
String _resolveStringRef(_DecodeState state, int id) {
  final session = state.session;
  if (session != null && id < session.length) return session.at(id);
  final tableIndex = id - (session?.length ?? 0);
  if (tableIndex >= 0 && tableIndex < state.messageTable.length) {
    return state.messageTable[tableIndex];
  }
  throw BtoonDecodeError(
    'string reference $id out of range',
    state.reader.position - 1,
  );
}

// #endregion

// #region TypedArray

Object? _readTypedArray(_DecodeState state) {
  final reader = state.reader;
  final type = elementTypeOf(reader.readByte());
  if (type == BtoonElementType.uint64) {
    throw BtoonDecodeError(
      'uint64 is not a valid TypedArray element type',
      reader.position - 1,
    );
  }
  final count = reader.readUint32();
  state.checkCount(count, type.size);
  reader.readPadLen(type.size);
  final values = readRawNumericData(reader, type, count);
  if (state.preserveTypedArrays) {
    return BtoonTypedArray(values, elementType: type);
  }
  return values;
}

// #endregion

// #region ObjectTable

Object? _readObjectTable(_DecodeState state) {
  final reader = state.reader;
  final rowCount = reader.readUint32();
  final fieldCount = reader.readUint32();
  state.checkCount(fieldCount, 5); // name tag+ref, selector, padLen, 1 cell
  if (rowCount > state.maxContainerCount) {
    throw BtoonDecodeError(
      'container count $rowCount exceeds the limit of '
      '${state.maxContainerCount}',
      reader.position,
    );
  }

  final fields = <String>[];
  final columns = <List<num>>[];
  for (var f = 0; f < fieldCount; f++) {
    final nameTag = state.reader.readByte();
    if (state.sessionActive && nameTag != tagStringRef) {
      throw BtoonDecodeError(
        'ObjectTable column names must use StringRef with a session dictionary',
        state.reader.position - 1,
      );
    }
    if (nameTag == tagStringRef) {
      fields.add(_resolveStringRef(state, _readIntValue(state.reader)));
    } else if (nameTag == tagString) {
      fields.add(_readInlineString(state));
    } else {
      throw BtoonDecodeError(
          'expected a string column name', state.reader.position - 1);
    }
    final type = elementTypeOf(reader.readByte());
    reader.readPadLen(type.size);
    columns.add(readRawNumericData(reader, type, rowCount));
  }

  final rows = <Map<String, dynamic>>[];
  for (var i = 0; i < rowCount; i++) {
    final map = <String, dynamic>{};
    for (var f = 0; f < fieldCount; f++) {
      map[fields[f]] = columns[f][i];
    }
    rows.add(map);
  }
  return rows;
}

// #endregion

// #region RecordBatch

/// A RecordBatch field descriptor read from the wire (§10.3).
class _RecordBatchField {
  final String name;

  /// The element selector; one of the numeric selectors, `0x0B` (string) or
  /// `0x09` (null).
  final int selector;

  final bool nullable;

  _RecordBatchField(this.name, this.selector, this.nullable);
}

/// Reads a RecordBatch value and returns an ordinary list of objects
/// (§10.3).
///
/// Every count, descriptor, bitmap and value is validated against the
/// configured limits and the remaining input before anything is allocated,
/// so a hostile row or field count cannot trigger a large allocation or an
/// out-of-bounds read (§24).
Object? _readRecordBatch(_DecodeState state) {
  final reader = state.reader;

  final fieldCount = reader.readUint32();
  // Each descriptor is at least a UInt32 name length, a selector and a
  // nullable byte, plus the inline name bytes.
  state.checkCount(fieldCount, 6);
  if (fieldCount == 0) {
    throw BtoonDecodeError('RecordBatch must declare at least one field', reader.position);
  }

  final fields = <_RecordBatchField>[];
  for (var f = 0; f < fieldCount; f++) {
    final nameLength = reader.readUint32();
    if (nameLength > state.maxStringSize) {
      throw BtoonDecodeError(
        'RecordBatch field name length $nameLength exceeds the limit of '
        '${state.maxStringSize}',
        reader.position,
      );
    }
    final name = _readUtf8(reader, nameLength);
    final selector = reader.readByte();
    if (!_isValidRecordBatchSelector(selector)) {
      throw BtoonDecodeError(
        'invalid RecordBatch element-type code 0x${selector.toRadixString(16)}',
        reader.position - 1,
      );
    }
    final nullableByte = reader.readByte();
    if (nullableByte > 1) {
      throw BtoonDecodeError(
        'invalid RecordBatch nullable byte $nullableByte (expected 0 or 1)',
        reader.position - 1,
      );
    }
    // A string field must be nullable whenever any row is null; the
    // descriptor itself must be self-consistent, which is checked when the
    // bitmaps are read below.
    fields.add(_RecordBatchField(name, selector, nullableByte == 1));
  }

  final rowCount = reader.readUint32();
  if (rowCount > state.maxContainerCount) {
    throw BtoonDecodeError(
      'RecordBatch row count $rowCount exceeds the limit of '
      '${state.maxContainerCount}',
      reader.position,
    );
  }
  // Each row needs at least one byte across all fields, plus a bit per row.
  if (rowCount > 0 && rowCount > reader.remaining * 8) {
    throw BtoonDecodeError(
      'RecordBatch row count $rowCount exceeds the available input',
      reader.position,
    );
  }

  // Validity bitmaps, in field order, before the row values. An all-null
  // field carries no bitmap.
  final bitmaps = <Uint8List>[];
  for (final field in fields) {
    if (!field.nullable) {
      bitmaps.add(Uint8List(0));
      continue;
    }
    final byteCount = (rowCount + 7) ~/ 8;
    if (byteCount > reader.remaining) {
      throw BtoonDecodeError(
        'RecordBatch validity bitmap exceeds the available input',
        reader.position,
      );
    }
    final bitmap = reader.readBytes(byteCount);
    _validateUnusedBits(bitmap, rowCount);
    bitmaps.add(bitmap);
  }

  // Row-major values, field by field, in schema order.
  final rows = <Map<String, dynamic>>[];
  for (var r = 0; r < rowCount; r++) {
    final row = <String, dynamic>{};
    for (var f = 0; f < fields.length; f++) {
      final field = fields[f];
      // An all-null field uses the null selector with no bitmap, so its value
      // is always null and never occupies bytes.
      final present = field.selector != elementNull &&
          (!field.nullable || _isPresent(bitmaps[f], r));
      row[field.name] = present ? _readRecordBatchValue(state, field) : null;
    }
    rows.add(row);
  }
  return rows;
}

/// Whether the value for row [row] is present according to [bitmap].
bool _isPresent(Uint8List bitmap, int row) {
  return (bitmap[row >> 3] & (1 << (row & 7))) != 0;
}

/// Rejects non-zero bits that no row can use in the final bitmap byte
/// (§10.3: unused high bits MUST be zero).
void _validateUnusedBits(Uint8List bitmap, int rowCount) {
  if (rowCount == 0 || bitmap.isEmpty) return;
  final usedBits = rowCount & 7;
  if (usedBits == 0) return;
  final mask = (1 << usedBits) - 1;
  final lastByte = bitmap[bitmap.length - 1] & ~mask & 0xFF;
  if (lastByte != 0) {
    throw BtoonDecodeError(
      'RecordBatch validity bitmap has non-zero unused bits',
      lastByte,
    );
  }
}

bool _isValidRecordBatchSelector(int selector) {
  if (selector >= elementInt8 && selector <= elementFloat64) return true;
  return selector == elementString || selector == elementNull;
}

/// Reads one present RecordBatch value for [field].
Object? _readRecordBatchValue(_DecodeState state, _RecordBatchField field) {
  final reader = state.reader;
  if (field.selector == elementString) {
    // A string value is Length::UInt32 plus UTF-8 bytes, with no tag. A
    // zero-length string is present and distinct from null.
    final length = reader.readUint32();
    if (length > state.maxStringSize) {
      throw BtoonDecodeError(
        'RecordBatch string length $length exceeds the limit of '
        '${state.maxStringSize}',
        reader.position,
      );
    }
    return _readUtf8(reader, length);
  }
  return _readSchemaNumeric(reader, field.selector);
}

// #endregion

// #region Schema mode

Object? _decodeSchemaBody(_DecodeState state, BtoonSchema? schema) {
  if (schema == null) {
    throw BtoonDecodeError(
      'message is in schema mode but no schema is available',
      state.reader.position,
    );
  }
  final reader = state.reader;
  final schemaId =
      state.schemaIdUint16 ? reader.readUint16() : reader.readUint32();
  if (schemaId != schema.id) {
    throw BtoonDecodeError(
      'schema id $schemaId does not match "${schema.name}" (id ${schema.id})',
      reader.position - 4,
    );
  }
  final rows = <Map<String, dynamic>>[];
  while (reader.remaining > 0) {
    // Records are siblings: each starts at the same nesting depth.
    rows.add(_decodeSchemaFields(state, schema, 0));
  }
  // A single record is returned as a map; repeated records as a list. (A
  // one-element list and a single record are byte-identical, per §15.)
  return rows.length == 1 ? rows.first : rows;
}

Map<String, dynamic> _decodeSchemaFields(
    _DecodeState state, BtoonSchema schema, int depth) {
  _checkDepth(state, depth);
  final map = <String, dynamic>{};
  for (final field in schema.fields) {
    map[field.name] = _decodeSchemaFieldValue(state, field, depth);
  }
  return map;
}

Object? _decodeSchemaFieldValue(
    _DecodeState state, BtoonSchemaField field, int depth) {
  final reader = state.reader;
  switch (field.code) {
    case elementNull:
      return null;
    case elementBool:
      // §15.2: a schema bool is exactly 0 or 1. Any other byte is a schema
      // violation rather than a truthy value.
      final b = reader.readByte();
      if (b > 1) {
        throw BtoonDecodeError(
          'invalid schema bool byte $b (expected 0 or 1)',
          reader.position - 1,
        );
      }
      return b == 1;
    case elementString:
      return _readStringValue(state);
    case elementBinary:
      final tag = reader.readByte();
      if (tag != tagBinary) {
        throw BtoonDecodeError(
          'expected a binary tag, got 0x${tag.toRadixString(16)}',
          reader.position - 1,
        );
      }
      final length = reader.readUint32();
      if (length > state.maxBinarySize) {
        throw BtoonDecodeError(
          'binary length $length exceeds the limit of ${state.maxBinarySize}',
          reader.position,
        );
      }
      final bytes = reader.readBytes(length);
      return state.preserveBinary ? BtoonBinary(bytes) : bytes;
    case elementArray:
    case elementObject:
      return _decodeValue(state, depth: depth + 1);
    default:
      return _readSchemaNumeric(reader, field.code);
  }
}

/// Reads a single fixed-width numeric schema field value of [code].
Object? _readSchemaNumeric(BtoonReader reader, int code) {
  switch (code) {
    case elementInt8:
      return reader.readByte().toSigned(8);
    case elementUint8:
      return reader.readByte();
    case elementInt16:
      return reader.readInt16();
    case elementUint16:
      return reader.readUint16();
    case elementInt32:
      return reader.readInt32();
    case elementUint32:
      return reader.readUint32();
    case elementInt64:
      return reader.readInt64();
    case elementUint64:
      return reader.readUint64();
    case elementFloat32:
      return reader.readFloat32();
    case elementFloat64:
      return reader.readFloat64();
    default:
      throw BtoonDecodeError('invalid schema element-type code $code');
  }
}

// #endregion

// #region Schema parsing

BtoonSchema _readSchema(BtoonReader reader, bool idUint16,
    {int maxStringSize = 1 << 24, int maxContainerCount = 1 << 26}) {
  final id = idUint16 ? reader.readUint16() : reader.readUint32();
  final nameLength = reader.readUint32();
  if (nameLength > maxStringSize) {
    throw BtoonDecodeError(
      'schema name length $nameLength exceeds the limit of $maxStringSize',
      reader.position,
    );
  }
  final name = _readUtf8(reader, nameLength);
  final count = reader.readUint32();
  if (count > maxContainerCount || count > reader.remaining ~/ 5) {
    // Each field is at least a UInt32 name length plus a 1-byte selector.
    throw BtoonDecodeError(
      'schema field count $count exceeds the available input',
      reader.position,
    );
  }
  final fields = <BtoonSchemaField>[];
  for (var i = 0; i < count; i++) {
    final length = reader.readUint32();
    if (length > maxStringSize) {
      throw BtoonDecodeError(
        'schema field name length $length exceeds the limit of '
        '$maxStringSize',
        reader.position,
      );
    }
    final fieldName = _readUtf8(reader, length);
    final code = reader.readByte();
    if (code > elementUint64) {
      // Schema fields may use any element selector 0x00..0x0F (§12).
      throw BtoonDecodeError(
        'invalid schema element-type code 0x${code.toRadixString(16)}',
        reader.position - 1,
      );
    }
    fields.add(BtoonSchemaField(
      fieldName,
      type: BtoonSchemaType.fromCode(code),
      elementCode: code,
    ));
  }
  return BtoonSchema(fields, id: id, name: name);
}

/// Validates an out-of-band schema against the embedded one (§15.1).
void _validateSchemaMatches(
  BtoonSchema supplied,
  BtoonSchema embedded,
  BtoonReader reader,
) {
  if (supplied.id != embedded.id) {
    throw BtoonDecodeError(
      'supplied schema "${supplied.name}" (id ${supplied.id}) does not match '
      'the embedded schema "${embedded.name}" (id ${embedded.id})',
      reader.position,
    );
  }
  if (supplied.name != embedded.name ||
      supplied.fields.length != embedded.fields.length) {
    throw BtoonDecodeError(
      'supplied schema "${supplied.name}" does not match the embedded '
      'schema "${embedded.name}"',
      reader.position,
    );
  }
  for (var i = 0; i < supplied.fields.length; i++) {
    final a = supplied.fields[i];
    final b = embedded.fields[i];
    if (a.name != b.name || a.code != b.code) {
      throw BtoonDecodeError(
        'supplied schema field ${i + 1} ("${a.name}") does not match the '
        'embedded schema field ("${b.name}")',
        reader.position,
      );
    }
  }
}

// #endregion

void _checkDepth(_DecodeState state, int depth) {
  if (depth > state.maxDepth) {
    throw BtoonDecodeError(
        'maximum nesting depth exceeded', state.reader.position);
  }
}

void _skipAlignedPadding(BtoonReader reader) {
  final count = (8 - (reader.position % 8)) % 8;
  reader.skipZeroPadding(count);
}

String _readUtf8(BtoonReader reader, int length) {
  final bytes = reader.readBytes(length);
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    throw BtoonDecodeError(
        'invalid UTF-8 string: ${e.message}', reader.position);
  }
}
