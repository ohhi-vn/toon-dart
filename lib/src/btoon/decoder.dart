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

  final List<String> inlineStrings = [];
  final Set<String> _inlineSeen = {};

  _DecodeState({
    required this.reader,
    required this.messageTable,
    required this.session,
    required this.growSession,
    required this.preserveBinary,
    required this.preserveTypedArrays,
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
  if (reader.readByte() != 0 || reader.readByte() != 0) {
    throw const BtoonDecodeError('non-zero reserved envelope bytes', 6);
  }
  // Unrecognized/reserved flag bits are ignored (§19).

  final messageTable = <String>[];
  if ((flags & flagStringTable) != 0) {
    final count = reader.readUint32();
    for (var i = 0; i < count; i++) {
      final length = reader.readUint32();
      messageTable.add(_readUtf8(reader, length));
    }
  }

  BtoonSchema? schema;
  final hasEmbeddedSchema = (flags & flagHasSchema) != 0;
  if (hasEmbeddedSchema) {
    schema = _readSchema(reader);
  }

  reader.skipPaddingTo(8);

  final state = _DecodeState(
    reader: reader,
    messageTable: messageTable,
    session: options.session,
    growSession: options.growSession,
    preserveBinary: options.preserveBinary,
    preserveTypedArrays: options.preserveTypedArrays,
  );

  final isSchemaMode = hasEmbeddedSchema || options.schema != null;
  final result = isSchemaMode
      ? _decodeSchemaBody(state, schema ?? options.schema)
      : _decodeValue(state);

  state.growSessionIfNeeded();
  return result;
}

// #region Tagged value decoding

Object? _decodeValue(_DecodeState state) {
  final reader = state.reader;
  final tag = reader.readByte();
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
      final bytes = reader.readBytes(length);
      return state.preserveBinary ? BtoonBinary(bytes) : bytes;
    case tagArray:
      final count = reader.readUint32();
      final list = <Object?>[];
      list.length = count;
      for (var i = 0; i < count; i++) {
        list[i] = _decodeValue(state);
      }
      return list;
    case tagObject:
      final count = reader.readUint32();
      final map = <String, dynamic>{};
      for (var i = 0; i < count; i++) {
        final key = _readStringValue(state);
        map[key] = _decodeValue(state);
      }
      return map;
    case tagTypedArray:
      return _readTypedArray(state);
    case tagObjectTable:
      return _readObjectTable(state);
    case tagStringRef:
      return _resolveStringRef(state, _readIntValue(reader));
    default:
      if (tag >= smallIntTagMin && tag <= smallIntTagMax) {
        return tag - smallIntBias;
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
    throw BtoonDecodeError('invalid padding length $padLen', reader.position - 1);
  }
  return padLen;
}

// #endregion

// #region ObjectTable

Object? _readObjectTable(_DecodeState state) {
  final reader = state.reader;
  final rowCount = reader.readUint32();
  final fieldCount = reader.readUint32();

  final fields = <String>[];
  final columns = <List<num>>[];
  for (var f = 0; f < fieldCount; f++) {
    fields.add(_readStringValue(state));
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
  final schemaId = reader.readUint32();
  if (schemaId != schema.id) {
    throw BtoonDecodeError(
      'schema id $schemaId does not match "${schema.name}" (id ${schema.id})',
      reader.position - 4,
    );
  }
  final rows = <Map<String, dynamic>>[];
  while (reader.remaining > 0) {
    rows.add(_decodeSchemaFields(state, schema));
  }
  // A single record is returned as a map; repeated records as a list. (A
  // one-element list and a single record are byte-identical, per §15.)
  return rows.length == 1 ? rows.first : rows;
}

Map<String, dynamic> _decodeSchemaFields(_DecodeState state, BtoonSchema schema) {
  final map = <String, dynamic>{};
  for (final field in schema.fields) {
    map[field.name] = _decodeSchemaFieldValue(state, field);
  }
  return map;
}

Object? _decodeSchemaFieldValue(_DecodeState state, BtoonSchemaField field) {
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
      final bytes = reader.readBytes(length);
      return state.preserveBinary ? BtoonBinary(bytes) : bytes;
    case elementArray:
    case elementObject:
      return _decodeValue(state);
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

BtoonSchema _readSchema(BtoonReader reader) {
  final id = reader.readUint32();
  final nameLength = reader.readUint32();
  final name = _readUtf8(reader, nameLength);
  final count = reader.readUint32();
  final fields = <BtoonSchemaField>[];
  for (var i = 0; i < count; i++) {
    final length = reader.readUint32();
    final fieldName = _readUtf8(reader, length);
    final code = reader.readByte();
    fields.add(BtoonSchemaField(
      fieldName,
      type: BtoonSchemaType.fromCode(code),
      elementCode: code,
    ));
  }
  return BtoonSchema(fields, id: id, name: name);
}

// #endregion

String _readUtf8(BtoonReader reader, int length) {
  final bytes = reader.readBytes(length);
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    throw BtoonDecodeError('invalid UTF-8 string: ${e.message}', reader.position);
  }
}
