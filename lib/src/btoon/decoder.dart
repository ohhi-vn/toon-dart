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
  reader.skip(_readPadLen(reader));
  final values = readRawNumericData(reader, type, count);
  if (state.preserveTypedArrays) {
    return BtoonTypedArray(values, elementType: type);
  }
  return values;
}

int _readPadLen(BtoonReader reader) {
  final padLen = reader.readByte();
  if (padLen > 7) {
    throw BtoonDecodeError(
        'invalid padding length $padLen', reader.position - 1);
  }
  return padLen;
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
    reader.skip(_readPadLen(reader));
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
      return reader.readByte() != 0;
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
