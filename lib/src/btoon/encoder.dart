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
  final bool countFrequencies;
  final bool useStringTable;
  final bool typedArrays;
  final bool objectTables;
  final bool schemaIdUint16;

  final Map<String, int> _freq = {};
  final List<String> _order = [];
  final Set<String> _orderSeen = {};

  /// True when the default string-table mode is in effect (every
  /// first-encounter string is tabled), letting the collect pass assign
  /// table indices directly instead of counting occurrences.
  final bool directTable;

  /// Strings that MUST appear in the per-message table regardless of their
  /// frequency (ObjectTable column names when a session dictionary is
  /// active, §14).
  final Set<String> _forced = {};

  final List<String> table = [];
  final Map<String, int> tableIndex = {};

  final List<String> inlineStrings = [];
  final Set<String> _inlineSeen = {};

  /// Per-encode memo of list scans (typed-array element type, ObjectTable
  /// plan) keyed by list identity, so the collect and emit passes scan each
  /// list once.
  final Map<List<dynamic>, Object> scanCache = {};

  _EncodeState(
      {required this.session,
      required this.minTableFreq,
      required this.countFrequencies,
      required this.useStringTable,
      required this.typedArrays,
      required this.objectTables,
      required this.schemaIdUint16})
      : directTable = useStringTable && minTableFreq <= 1;

  /// Collect pass: record a string occurrence (session strings are skipped).
  void recordString(String value) {
    final session = this.session;
    if (session != null && session.indexOf(value) != null) return;
    if (directTable) {
      // First-encounter order == table order: assign the index directly.
      final existing = tableIndex[value];
      if (existing == null) {
        tableIndex[value] = table.length;
        table.add(value);
      }
      return;
    }
    if (countFrequencies) {
      _freq[value] = (_freq[value] ?? 0) + 1;
    }
    if (_orderSeen.add(value)) {
      _order.add(value);
    }
  }

  /// Collect pass: force [value] into the per-message table (§14) even when
  /// it occurs once or the table is disabled.
  void forceTableString(String value) {
    final session = this.session;
    if (session != null && session.indexOf(value) != null) return;
    if (!_forced.add(value)) return;
    if (directTable) {
      final existing = tableIndex[value];
      if (existing == null) {
        tableIndex[value] = table.length;
        table.add(value);
      }
      return;
    }
    if (countFrequencies) {
      _freq[value] = (_freq[value] ?? 0) + 1;
    }
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
    if (directTable) return; // table already built during collect
    if (!useStringTable && _forced.isEmpty) return;
    for (final value in _order) {
      if (_forced.contains(value) ||
          !countFrequencies ||
          (_freq[value] ?? 0) >= minTableFreq) {
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
    countFrequencies: options.minStringTableFrequency > 1,
    useStringTable: options.stringTable == BtoonStringTableMode.auto &&
        !options.noStringTable,
    typedArrays: options.typedArrays,
    objectTables: options.objectTables,
    schemaIdUint16: options.schemaIdUint16,
  );

  final schema = _resolveSchema(value, options);

  // Pass 1: collect string frequencies.
  if (schema != null) {
    _encodeSchemaBody(value, schema, state, null);
  } else {
    _encodeValue(value, state, null,
        typedArrays: state.typedArrays, objectTables: state.objectTables);
  }
  state.buildTable();

  // Pass 2: emit the body. With no string table and no schema the body
  // starts right after the 8-byte header, so it can be written directly
  // into the envelope writer — no intermediate body buffer or copy.
  final writer = BtoonWriter();
  writer.writeBytes(btoonMagic);
  writer.writeByte(btoonVersion);
  var flags = 0;
  if (state.table.isNotEmpty) flags |= flagStringTable;
  if (schema != null) flags |= flagHasSchema;
  if (options.session != null && options.session!.length > 0) {
    flags |= flagSession;
  }
  if (options.session != null &&
      options.session!.length > 0 &&
      state.table.isEmpty) {
    flags |= flagNoStringTable;
  }
  if (schema != null && options.schemaIdUint16) {
    flags |= flagSchemaIdUint16;
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
    writer.align(8);
  }

  if (schema != null) {
    _writeSchema(writer, schema, (flags & flagSchemaIdUint16) != 0);
  }

  if (schema != null || state.table.isNotEmpty) {
    writer.align(8);
    final bodyWriter = BtoonWriter();
    if (schema != null) {
      _encodeSchemaBody(value, schema, state, bodyWriter);
    } else {
      _encodeValue(value, state, bodyWriter,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    }
    writer.writeWriter(bodyWriter);
  } else {
    _encodeValue(value, state, writer,
        typedArrays: state.typedArrays, objectTables: state.objectTables);
  }

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

void _encodeValue(Object? value, _EncodeState state, BtoonWriter? writer,
    {bool typedArrays = true, bool objectTables = true}) {
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
    // Rows are already typed maps — encode directly, no defensive copy.
    final plan = _objectTablePlan(value.rows, state);
    if (plan != null) {
      _encodeObjectTable(plan.rows, state, writer,
          fields: plan.fields, columnTypes: plan.columnTypes);
    } else {
      // Not a valid table — the direct encoding reports the offending
      // column.
      _encodeObjectTable(value.rows, state, writer);
    }
    return;
  }
  if (value is BtoonExtension) {
    if (!isCollect) {
      writer.writeByte(value.tag);
      writer.writeUint32(value.payload.length);
      writer.writeBytes(value.payload);
    }
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
    if (typedArrays) {
      final scan = _typedArrayScan(value, state);
      if (scan.type != null) {
        if (!isCollect) {
          _emitScannedTypedArray(writer, value, scan);
        }
        return;
      }
    }
    if (objectTables) {
      final plan = _objectTablePlan(value, state);
      if (plan != null) {
        _encodeObjectTable(plan.rows, state, writer,
            fields: plan.fields, columnTypes: plan.columnTypes);
        return;
      }
    }
    if (!isCollect) {
      writer.writeByte(tagArray);
      writer.writeUint32(value.length);
    }
    for (final item in value) {
      _encodeValue(item, state, writer,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    }
    return;
  }
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw BtoonEncodeError('map keys must be strings', key);
      }
      keys.add(key);
    }
    // Keys are sorted by their UTF-8 byte sequence (§17).
    sortUtf8(keys);
    if (!isCollect) {
      writer.writeByte(tagObject);
      writer.writeUint32(keys.length);
    }
    for (final key in keys) {
      _emitString(key, state, writer);
      _encodeValue(value[key], state, writer,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    }
    return;
  }
  throw BtoonEncodeError('unsupported value type: ${value.runtimeType}', value);
}

// #endregion

// #region TypedArray

/// Result of scanning a list for a TypedArray encoding (memoized across the
/// collect and emit passes).
class _ListScan {
  /// Element type, or null when the list is not a homogeneous numeric
  /// array (falls through to ObjectTable / general array).
  final BtoonElementType? type;

  /// Prebuilt float32/float64 buffer when [type] is a float type; null for
  /// integer types (written per element).
  final TypedData? buffer;

  const _ListScan(this.type, this.buffer);
}

/// Single-pass scan of [list]: classifies it as an int or double typed
/// array, choosing the narrowest lossless element type and, for doubles,
/// building the conversion buffer in the same pass. Statically-typed lists
/// get a specialized loop without per-element dynamic dispatch.
_ListScan _scanTypedArray(List<dynamic> list) {
  if (list is List<int>) return _scanIntList(list);
  if (list is List<double>) return _scanDoubleList(list);
  return _scanMixedList(list);
}

_ListScan _scanIntList(List<int> list) {
  var min = 0;
  var max = 0;
  for (var i = 0; i < list.length; i++) {
    final e = list[i];
    if (e < int64Min || e > int64Max) return const _ListScan(null, null);
    if (i == 0) {
      min = max = e;
    } else if (e < min) {
      min = e;
    } else if (e > max) {
      max = e;
    }
  }
  var type = bestIntElementTypeForRange(min, max);
  if (type == null) return const _ListScan(null, null);
  // uint64 is not a valid TypedArray selector (§12); the values fit int64.
  if (type == BtoonElementType.uint64) type = BtoonElementType.int64;
  return _ListScan(type, null);
}

_ListScan _scanDoubleList(List<double> list) {
  final length = list.length;
  final f32 = Float32List(length);
  var lossless32 = true;
  for (var i = 0; i < length; i++) {
    final e = list[i];
    f32[i] = e;
    if (lossless32 && f32[i] != e) lossless32 = false;
  }
  if (lossless32) return _ListScan(BtoonElementType.float32, f32);
  // Rare path: rebuild as float64 (NaN payloads and out-of-float32 values).
  final f64 = Float64List(length);
  for (var i = 0; i < length; i++) {
    f64[i] = list[i];
  }
  return _ListScan(BtoonElementType.float64, f64);
}

_ListScan _scanMixedList(List<dynamic> list) {
  var allInt = true;
  var allDouble = true;
  var min = 0;
  var max = 0;
  Float32List? f32;
  Float64List? f64;
  var lossless32 = true;
  final length = list.length;
  for (var i = 0; i < length; i++) {
    final e = list[i];
    if (e is int) {
      allDouble = false;
      if (e < int64Min || e > int64Max) return const _ListScan(null, null);
      if (i == 0) {
        min = max = e;
      } else if (e < min) {
        min = e;
      } else if (e > max) {
        max = e;
      }
    } else if (e is double) {
      allInt = false;
      f64 ??= Float64List(length);
      f64[i] = e;
      f32 ??= Float32List(length);
      f32[i] = e;
      if (lossless32 && f32[i] != e) lossless32 = false;
    } else {
      return const _ListScan(null, null);
    }
  }
  if (allInt) {
    var type = bestIntElementTypeForRange(min, max);
    if (type == null) return const _ListScan(null, null);
    // uint64 is not a valid TypedArray selector (§12); the values fit int64.
    if (type == BtoonElementType.uint64) type = BtoonElementType.int64;
    return _ListScan(type, null);
  }
  if (allDouble) {
    if (lossless32) return _ListScan(BtoonElementType.float32, f32);
    return _ListScan(BtoonElementType.float64, f64);
  }
  return const _ListScan(null, null);
}

/// Memoized [_ListScan] for [list] within one encode.
_ListScan _typedArrayScan(List<dynamic> list, _EncodeState state) {
  final cached = state.scanCache[list];
  if (cached is _ListScan) return cached;
  final scan = _scanTypedArray(list);
  state.scanCache[list] = scan;
  return scan;
}

/// Emits a TypedArray for a scan that already classified [list] (and, for
/// float types, prebuilt its buffer).
void _emitScannedTypedArray(
  BtoonWriter writer,
  List<dynamic> list,
  _ListScan scan,
) {
  final type = scan.type!;
  writer.writeByte(tagTypedArray);
  writer.writeByte(elementTagOf(type));
  writer.writeUint32(list.length);
  // PadLen counts the zero bytes that follow it (§16), so account for the
  // PadLen byte itself when computing how many remain to align the buffer.
  final padLen = (type.size - ((writer.length + 1) % type.size)) % type.size;
  writer.writeByte(padLen);
  writer.writePadding(padLen);
  final buffer = scan.buffer;
  if (buffer != null) {
    writer.writeBytes(Uint8List.sublistView(buffer));
  } else {
    writeRawNumericData(writer, asNumList(list), type);
  }
}

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
  _emitTypedArray(writer, values, type);
}

/// Writes a TypedArray whose [values] are already known to fit [type]
/// (auto-detected element types guarantee this; user-supplied types go
/// through [_writeTypedArray], which validates).
void _emitTypedArray(
  BtoonWriter writer,
  List<num> values,
  BtoonElementType type,
) {
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

/// Memoized [ObjectTablePlan] for [list] within one encode, so the collect
/// and emit passes classify each table once.
ObjectTablePlan? _objectTablePlan(List<dynamic> list, _EncodeState state) {
  final cached = state.scanCache[list];
  if (cached is ObjectTablePlan) return cached;
  if (cached is _NullPlan) return null;
  final plan = buildObjectTablePlan(list);
  state.scanCache[list] = plan ?? const _NullPlan();
  return plan;
}

/// Cache sentinel for lists that do not qualify as ObjectTables (null is
/// ambiguous with an absent cache entry).
class _NullPlan {
  const _NullPlan();
}

void _encodeObjectTable(
  List<Map<dynamic, dynamic>> rows,
  _EncodeState state,
  BtoonWriter? writer, {
  List<String>? fields,
  Map<String, BtoonElementType>? columnTypes,
}) {
  final isCollect = writer == null;
  final resolvedFields = fields ?? objectTableFields(rows);

  if (!isCollect) {
    writer.writeByte(tagObjectTable);
    writer.writeUint32(rows.length);
    writer.writeUint32(resolvedFields.length);
  }
  for (final field in resolvedFields) {
    final columnType = columnTypes?[field] ?? columnElementType(rows, field);
    if (columnType == null) {
      throw BtoonEncodeError(
        'ObjectTable column "$field" must be a homogeneous numeric column',
        rows,
      );
    }
    final session = state.session;
    if (session != null &&
        session.length > 0 &&
        session.indexOf(field) == null) {
      // With the session flag (0x08) set, column names MUST be StringRefs
      // (§14); force the name into the per-message table so it can be
      // referenced (and so the no-table flag 0x10 is not set).
      state.forceTableString(field);
    } else {
      state.recordString(field);
    }
    if (!isCollect) {
      _emitString(field, state, writer);
      writer.writeByte(elementTagOf(columnType));
      final padLen =
          (columnType.size - ((writer.length + 1) % columnType.size)) %
              columnType.size;
      writer.writeByte(padLen);
      writer.writePadding(padLen);
      _writeColumnValues(writer, rows, field, columnType);
    }
  }
}

/// Writes a single ObjectTable column by reading each row's value for
/// [field] directly — no intermediate column list.
void _writeColumnValues(
  BtoonWriter writer,
  List<Map<dynamic, dynamic>> rows,
  String field,
  BtoonElementType type,
) {
  final n = rows.length;
  switch (type) {
    case BtoonElementType.float64:
      final buffer = Float64List(n);
      for (var i = 0; i < n; i++) {
        buffer[i] = rows[i][field] as double;
      }
      writer.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.float32:
      final buffer = Float32List(n);
      for (var i = 0; i < n; i++) {
        buffer[i] = rows[i][field] as double;
      }
      writer.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.int8:
    case BtoonElementType.uint8:
      for (var i = 0; i < n; i++) {
        writer.writeByte(rows[i][field] as int);
      }
    case BtoonElementType.int16:
    case BtoonElementType.uint16:
      for (var i = 0; i < n; i++) {
        writer.writeInt16(rows[i][field] as int);
      }
    case BtoonElementType.int32:
    case BtoonElementType.uint32:
      for (var i = 0; i < n; i++) {
        writer.writeInt32(rows[i][field] as int);
      }
    case BtoonElementType.int64:
    case BtoonElementType.uint64:
      for (var i = 0; i < n; i++) {
        writer.writeInt64(rows[i][field] as int);
      }
  }
}

// #endregion

// #region Schema

void _writeSchema(BtoonWriter writer, BtoonSchema schema, bool idUint16) {
  if (idUint16) {
    if (schema.id < 0 || schema.id > 0xFFFF) {
      throw BtoonEncodeError('schema id does not fit UInt16', schema.id);
    }
    writer.writeUint16(schema.id);
  } else {
    if (schema.id < 0 || schema.id > 0xFFFFFFFF) {
      throw BtoonEncodeError('schema id does not fit UInt32', schema.id);
    }
    writer.writeUint32(schema.id);
  }
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
  if (!isCollect) {
    if (state.schemaIdUint16) {
      if (schema.id < 0 || schema.id > 0xFFFF) {
        throw BtoonEncodeError('schema id does not fit UInt16', schema.id);
      }
      writer.writeUint16(schema.id);
    } else {
      if (schema.id < 0 || schema.id > 0xFFFFFFFF) {
        throw BtoonEncodeError('schema id does not fit UInt32', schema.id);
      }
      writer.writeUint32(schema.id);
    }
  }

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
      _encodeValue(value, state, writer,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
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
  List<Map<dynamic, dynamic>> rows;
  if (value is Map) {
    _validateStringKeys(value);
    rows = [value];
  } else if (value is List) {
    rows = <Map<dynamic, dynamic>>[];
    for (final element in value) {
      if (element is! Map) return null;
      _validateStringKeys(element);
      rows.add(element);
    }
  } else {
    return null;
  }

  final keySet = <String>{};
  for (final row in rows) {
    for (final key in row.keys) {
      if (key is String) keySet.add(key);
    }
  }
  final keys = keySet.toList();
  sortUtf8(keys);
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

/// Validates that every key of [map] is a string.
void _validateStringKeys(Map<dynamic, dynamic> map) {
  for (final key in map.keys) {
    if (key is! String) {
      throw BtoonEncodeError('map keys must be strings', key);
    }
  }
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
