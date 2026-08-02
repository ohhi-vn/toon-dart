/// BTOON encoder.
///
/// The encoder performs two passes over the input:
///
///   1. a *collect* pass that walks the value in the exact order the body
///      will be written, counting string occurrences to build the
///      per-message string table;
///   2. an *emit* pass that writes the body, replacing table/session strings
///      with `StringRef` entries.
///
/// Both passes share the same traversal, so the wire output is fully
/// deterministic.
library btoon_encoder;

import 'dart:convert';
import 'dart:typed_data';

import '../utilities/int64_bounds.dart';
import 'constants.dart';
import 'errors.dart';
import 'io.dart';
import 'numeric.dart';
import 'options.dart';
import 'types.dart';

/// Encode state shared between the collect and emit passes.
class _EncodeState {
  final BtoonSession? session;
  final int minTableFreq;

  final Map<String, int> _freq = {};
  final List<String> _order = [];
  final Set<String> _orderSeen = {};

  final List<String> table = [];
  final Map<String, int> tableIndex = {};

  final List<String> inlineStrings = [];
  final Set<String> _inlineSeen = {};

  _EncodeState({required this.session, required this.minTableFreq});

  /// Collect pass: record a string occurrence (session strings are skipped).
  void recordString(String value) {
    final session = this.session;
    if (session != null && session.indexOf(value) != null) return;
    _freq[value] = (_freq[value] ?? 0) + 1;
    if (_orderSeen.add(value)) {
      _order.add(value);
    }
  }

  /// Emit pass: record an inline string for later session growth.
  void recordInlineString(String value) {
    if (_inlineSeen.add(value)) {
      inlineStrings.add(value);
    }
  }

  void buildTable() {
    for (final value in _order) {
      if ((_freq[value] ?? 0) >= minTableFreq) {
        tableIndex[value] = table.length;
        table.add(value);
      }
    }
  }

  void growSession(BtoonSession target) {
    for (final value in table) {
      target.add(value);
    }
    for (final value in inlineStrings) {
      target.add(value);
    }
  }
}

/// Encodes [value] into a BTOON binary.
Uint8List btoonEncodeBytes(Object? value, BtoonEncodeOptions options) {
  final state = _EncodeState(
    session: options.session,
    minTableFreq: options.minStringTableFrequency,
  );

  final schema = _resolveSchema(value, options);

  // Pass 1: collect string frequencies.
  if (schema != null) {
    _encodeSchemaBody(value, schema, state, null);
  } else {
    _encodeValue(value, state, null);
  }
  state.buildTable();

  // Pass 2: emit the body.
  final bodyWriter = BtoonWriter();
  if (schema != null) {
    _encodeSchemaBody(value, schema, state, bodyWriter);
  } else {
    _encodeValue(value, state, bodyWriter);
  }
  final body = bodyWriter.takeBytes();

  // Assemble the envelope + optional sections + aligned body.
  final writer = BtoonWriter();
  writer.writeBytes(btoonMagic);
  writer.writeByte(btoonVersion);
  var flags = 0;
  if (state.table.isNotEmpty) flags |= flagStringTable;
  if (schema != null) flags |= flagHasSchema;
  if (options.session != null && options.session!.length > 0) {
    flags |= flagSession;
  }
  writer.writeByte(flags);
  writer.writeByte(0);
  writer.writeByte(0);

  if (state.table.isNotEmpty) {
    writer.writeUint32(state.table.length);
    for (final entry in state.table) {
      final bytes = utf8.encode(entry);
      writer.writeUint32(bytes.length);
      writer.writeBytes(bytes);
    }
  }

  if (schema != null) {
    _writeSchema(writer, schema);
  }

  writer.align(8);
  writer.writeBytes(body);

  if (options.session != null && options.growSession) {
    state.growSession(options.session!);
  }

  return writer.takeBytes();
}

/// Resolves the schema to embed / use for schema mode.
BtoonSchema? _resolveSchema(Object? value, BtoonEncodeOptions options) {
  final schema = options.schema;
  if (schema != null) return schema;
  if (options.schemaMode) {
    final derived = _deriveSchema(value);
    if (derived == null) {
      throw BtoonEncodeError(
        'schema mode requires a map or a list of maps at the root',
        value,
      );
    }
    return derived;
  }
  return null;
}

// #region String emission

void _emitString(String value, _EncodeState state, BtoonWriter? writer) {
  final isCollect = writer == null;
  final session = state.session;
  final sessionIndex = session?.indexOf(value);

  if (isCollect) {
    if (sessionIndex == null) state.recordString(value);
    return;
  }

  final tableEntry = state.tableIndex[value];
  if (sessionIndex != null) {
    // Session entries own ids 0..n-1 (§11.3).
    writer.writeByte(tagStringRef);
    _writeIntValue(writer, sessionIndex);
  } else if (tableEntry != null) {
    // Table entries start at the current session size.
    writer.writeByte(tagStringRef);
    _writeIntValue(writer, (session?.length ?? 0) + tableEntry);
  } else {
    state.recordInlineString(value);
    final bytes = utf8.encode(value);
    writer.writeByte(tagString);
    writer.writeUint32(bytes.length);
    writer.writeBytes(bytes);
  }
}

/// Writes [value] as a canonical integer value (SmallInt / Int32 / Int64),
/// used for StringRef ids (§9.6).
void _writeIntValue(BtoonWriter writer, int value) {
  if (value >= smallIntMin && value <= smallIntMax) {
    writer.writeByte(smallIntBias + value);
  } else if (value >= -2147483648 && value <= 2147483647) {
    writer.writeByte(tagInt32);
    writer.writeInt32(value);
  } else {
    writer.writeByte(tagInt64);
    writer.writeInt64(value);
  }
}

// #endregion

// #region Tagged value encoding

void _encodeValue(Object? value, _EncodeState state, BtoonWriter? writer) {
  final isCollect = writer == null;

  if (value == null) {
    if (!isCollect) writer.writeByte(tagNull);
    return;
  }
  if (value is bool) {
    if (!isCollect) writer.writeByte(value ? tagTrue : tagFalse);
    return;
  }
  if (value is int) {
    if (isCollect) return;
    if (value >= smallIntMin && value <= smallIntMax) {
      writer.writeByte(smallIntBias + value);
    } else if (value >= -2147483648 && value <= 2147483647) {
      writer.writeByte(tagInt32);
      writer.writeInt32(value);
    } else if (isInInt64Range(value)) {
      writer.writeByte(tagInt64);
      writer.writeInt64(value);
    } else {
      throw BtoonEncodeError('integer out of int64 range', value);
    }
    return;
  }
  if (value is double) {
    if (isCollect) return;
    if (value == 0.0) {
      // Normalize -0.0 to 0 (matches TOON canonical number behavior).
      writer.writeByte(smallIntBias);
    } else if (isLosslessFloat32(value)) {
      writer.writeByte(tagFloat32);
      writer.writeFloat32(value);
    } else {
      writer.writeByte(tagFloat64);
      writer.writeFloat64(value);
    }
    return;
  }
  if (value is String) {
    _emitString(value, state, writer);
    return;
  }
  if (value is Uint8List) {
    if (!isCollect) {
      writer.writeByte(tagBinary);
      writer.writeUint32(value.length);
      writer.writeBytes(value);
    }
    return;
  }
  if (value is BtoonBinary) {
    if (!isCollect) {
      writer.writeByte(tagBinary);
      writer.writeUint32(value.bytes.length);
      writer.writeBytes(value.bytes);
    }
    return;
  }
  if (value is BtoonTypedArray) {
    if (!isCollect) _writeTypedArray(writer, value.values, value.elementType);
    return;
  }
  if (value is BtoonObjectTable) {
    _encodeObjectTable(value.normalized(), state, writer);
    return;
  }
  if (value is List) {
    if (value.isEmpty) {
      if (!isCollect) {
        writer.writeByte(tagArray);
        writer.writeUint32(0);
      }
      return;
    }
    final intType = _allInts(value) ? bestIntElementType(value) : null;
    if (intType != null) {
      if (!isCollect) {
        _writeTypedArray(
          writer,
          value.cast<num>(),
          intType == BtoonElementType.uint64
              ? BtoonElementType.int64
              : intType,
        );
      }
      return;
    }
    if (_allDoubles(value)) {
      final doubleType =
          value.every((e) => isLosslessFloat32(e as double))
              ? BtoonElementType.float32
              : BtoonElementType.float64;
      if (!isCollect) _writeTypedArray(writer, value.cast<num>(), doubleType);
      return;
    }
    if (isObjectTable(value)) {
      _encodeObjectTable(objectTableRows(value), state, writer);
      return;
    }
    if (!isCollect) {
      writer.writeByte(tagArray);
      writer.writeUint32(value.length);
    }
    for (final item in value) {
      _encodeValue(item, state, writer);
    }
    return;
  }
  if (value is Map) {
    final keys = value.keys.toList();
    for (final key in keys) {
      if (key is! String) {
        throw BtoonEncodeError('map keys must be strings', key);
      }
    }
    keys.sort();
    if (!isCollect) {
      writer.writeByte(tagObject);
      writer.writeUint32(keys.length);
    }
    for (final key in keys) {
      _emitString(key, state, writer);
      _encodeValue(value[key], state, writer);
    }
    return;
  }
  throw BtoonEncodeError('unsupported value type: ${value.runtimeType}', value);
}

/// True if every element is a [double] (used for numeric list detection).
bool _allDoubles(List<dynamic> list) {
  for (final element in list) {
    if (element is! double) return false;
  }
  return true;
}

/// True if every element is an [int] (used for numeric list detection).
bool _allInts(List<dynamic> list) {
  for (final element in list) {
    if (element is! int) return false;
  }
  return true;
}

// #endregion

// #region TypedArray

void _writeTypedArray(
  BtoonWriter writer,
  List<num> values,
  BtoonElementType? forced,
) {
  final type = forced ?? bestNumericElementType(values);
  if (type == BtoonElementType.uint64) {
    throw BtoonEncodeError(
      'uint64 is not a valid TypedArray element type (only 0x00..0x08)',
      values,
    );
  }
  if (forced != null) validateNumericRange(values, type);
  writer.writeByte(tagTypedArray);
  writer.writeByte(elementTagOf(type));
  writer.writeUint32(values.length);
  // PadLen counts the zero bytes that follow it (§16), so account for the
  // PadLen byte itself when computing how many remain to align the buffer.
  final padLen = (type.size - ((writer.length + 1) % type.size)) % type.size;
  writer.writeByte(padLen);
  writer.writePadding(padLen);
  writeRawNumericData(writer, values, type);
}

// #endregion

// #region ObjectTable

void _encodeObjectTable(
  List<Map<String, dynamic>> rows,
  _EncodeState state,
  BtoonWriter? writer,
) {
  final isCollect = writer == null;
  final fields = objectTableFields(rows);

  if (!isCollect) {
    writer.writeByte(tagObjectTable);
    writer.writeUint32(rows.length);
    writer.writeUint32(fields.length);
  }
  for (final field in fields) {
    final columnType = columnElementType(rows, field);
    if (columnType == null) {
      throw BtoonEncodeError(
        'ObjectTable column "$field" must be a homogeneous numeric column',
        rows,
      );
    }
    _emitString(field, state, writer);
    if (!isCollect) {
      writer.writeByte(elementTagOf(columnType));
      final padLen = (columnType.size -
              ((writer.length + 1) % columnType.size)) %
          columnType.size;
      writer.writeByte(padLen);
      writer.writePadding(padLen);
      writeRawNumericData(writer, _columnValues(rows, field), columnType);
    }
  }
}

List<num> _columnValues(List<Map<String, dynamic>> rows, String field) {
  return rows.map((row) => row[field] as num).toList();
}

// #endregion

// #region Schema

void _writeSchema(BtoonWriter writer, BtoonSchema schema) {
  writer.writeUint32(schema.id);
  final name = utf8.encode(schema.name);
  writer.writeUint32(name.length);
  writer.writeBytes(name);
  writer.writeUint32(schema.fields.length);
  for (final field in schema.fields) {
    final bytes = utf8.encode(field.name);
    writer.writeUint32(bytes.length);
    writer.writeBytes(bytes);
    writer.writeByte(field.code);
  }
}

void _encodeSchemaBody(
  Object? value,
  BtoonSchema schema,
  _EncodeState state,
  BtoonWriter? writer,
) {
  final isCollect = writer == null;
  if (!isCollect) writer.writeUint32(schema.id);

  if (value is Map) {
    _encodeSchemaFields(_stringKeyMap(value), schema, state, writer);
    return;
  }
  if (value is List) {
    for (final element in value) {
      if (element is! Map) {
        throw BtoonEncodeError(
          'schema mode rows must be maps',
          element,
        );
      }
      _encodeSchemaFields(_stringKeyMap(element), schema, state, writer);
    }
    return;
  }
  throw BtoonEncodeError(
    'schema mode requires a map or a list of maps at the root',
    value,
  );
}

void _encodeSchemaFields(
  Map<String, dynamic> map,
  BtoonSchema schema,
  _EncodeState state,
  BtoonWriter? writer,
) {
  for (final field in schema.fields) {
    _encodeSchemaFieldValue(field, map[field.name], state, writer);
  }
}

void _encodeSchemaFieldValue(
  BtoonSchemaField field,
  Object? value,
  _EncodeState state,
  BtoonWriter? writer,
) {
  final isCollect = writer == null;
  switch (field.code) {
    case elementNull:
      if (value != null) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects null',
          value,
        );
      }
    case elementBool:
      if (value is! bool) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a bool',
          value,
        );
      }
      if (!isCollect) writer.writeByte(value ? 1 : 0);
    case elementString:
      if (value is! String) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a string',
          value,
        );
      }
      _emitString(value, state, writer);
    case elementBinary:
      final bytes = _binaryBytes(value);
      if (bytes == null) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects binary',
          value,
        );
      }
      if (!isCollect) {
        writer.writeByte(tagBinary);
        writer.writeUint32(bytes.length);
        writer.writeBytes(bytes);
      }
    case elementArray:
    case elementObject:
      _encodeValue(value, state, writer);
    case elementFloat32:
    case elementFloat64:
      if (value is! num) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a number',
          value,
        );
      }
      if (!isCollect) _writeSchemaNumeric(writer, field.code, value);
    default:
      if (value is! int) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects an integer',
          value,
        );
      }
      if (!isCollect) _writeSchemaNumeric(writer, field.code, value);
  }
}

/// Writes a single fixed-width numeric schema field value of [code].
void _writeSchemaNumeric(BtoonWriter writer, int code, num value) {
  switch (code) {
    case elementInt8:
    case elementUint8:
      writer.writeByte(value.toInt());
    case elementInt16:
    case elementUint16:
      writer.writeUint16(value.toInt());
    case elementInt32:
    case elementUint32:
      writer.writeUint32(value.toInt());
    case elementInt64:
    case elementUint64:
      writer.writeUint64(value.toInt());
    case elementFloat32:
      writer.writeFloat32(value.toDouble());
    case elementFloat64:
      writer.writeFloat64(value.toDouble());
    default:
      throw BtoonEncodeError('invalid schema element-type code $code');
  }
}

// #endregion

// #region Schema derivation

/// Derives a [BtoonSchema] from [value] by inspecting map keys and value
/// types, or returns null when [value] is neither a `Map` nor a `List` of
/// maps.
///
/// Fields are the sorted union of all keys; each field's type is inferred
/// from the first non-null value seen across the rows.
BtoonSchema? deriveBtoonSchema(Object? value) => _deriveSchema(value);

Map<String, dynamic> _stringKeyMap(Map<dynamic, dynamic> map) {
  final result = <String, dynamic>{};
  map.forEach((key, value) {
    if (key is! String) {
      throw BtoonEncodeError('map keys must be strings', key);
    }
    result[key] = value;
  });
  return result;
}

BtoonSchema? _deriveSchema(Object? value) {
  List<Map<String, dynamic>> rows;
  if (value is Map) {
    rows = [_stringKeyMap(value)];
  } else if (value is List) {
    rows = [];
    for (final element in value) {
      if (element is! Map) return null;
      rows.add(_stringKeyMap(element));
    }
  } else {
    return null;
  }

  final keySet = <String>{};
  for (final row in rows) {
    keySet.addAll(row.keys);
  }
  final keys = keySet.toList()..sort();
  final fields = <BtoonSchemaField>[];
  for (final key in keys) {
    var type = BtoonSchemaType.null_;
    for (final row in rows) {
      final rowValue = row[key];
      if (rowValue != null) {
        type = _inferType(rowValue);
        break;
      }
    }
    fields.add(BtoonSchemaField(key, type: type));
  }
  return BtoonSchema(fields);
}

BtoonSchemaType _inferType(Object? value) {
  if (value is bool) return BtoonSchemaType.boolean;
  if (value is int) return BtoonSchemaType.integer;
  if (value is double) return BtoonSchemaType.number;
  if (value is String) return BtoonSchemaType.string;
  if (value is Uint8List || value is BtoonBinary) return BtoonSchemaType.binary;
  if (value is List) return BtoonSchemaType.array;
  if (value is Map) return BtoonSchemaType.object;
  return BtoonSchemaType.any;
}

Uint8List? _binaryBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is BtoonBinary) return value.bytes;
  return null;
}

// #endregion
