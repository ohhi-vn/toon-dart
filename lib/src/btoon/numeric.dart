/// Numeric helpers for `TypedArray` / columnar `ObjectTable` payloads.
library btoon_numeric;

import 'dart:typed_data';

import '../utilities/int64_bounds.dart';
import 'constants.dart';
import 'errors.dart';
import 'io.dart';
import 'types.dart';

/// Returns [list] as a `List<num>` without copying when its runtime type is
/// already compatible (`List<int>` / `List<double>` are subtypes); falls
/// back to a lazy cast for heterogeneous `List<dynamic>` input.
List<num> asNumList(List<dynamic> list) =>
    list is List<num> ? list : list.cast<num>();

/// Maps a [BtoonElementType] to its wire element selector (§12).
int elementTagOf(BtoonElementType type) {
  switch (type) {
    case BtoonElementType.int8:
      return elementInt8;
    case BtoonElementType.int16:
      return elementInt16;
    case BtoonElementType.int32:
      return elementInt32;
    case BtoonElementType.int64:
      return elementInt64;
    case BtoonElementType.uint8:
      return elementUint8;
    case BtoonElementType.uint16:
      return elementUint16;
    case BtoonElementType.uint32:
      return elementUint32;
    case BtoonElementType.uint64:
      return elementUint64;
    case BtoonElementType.float32:
      return elementFloat32;
    case BtoonElementType.float64:
      return elementFloat64;
  }
}

/// Resolves a wire element selector to a [BtoonElementType].
BtoonElementType elementTypeOf(int tag) {
  switch (tag) {
    case elementInt8:
      return BtoonElementType.int8;
    case elementInt16:
      return BtoonElementType.int16;
    case elementInt32:
      return BtoonElementType.int32;
    case elementInt64:
      return BtoonElementType.int64;
    case elementUint8:
      return BtoonElementType.uint8;
    case elementUint16:
      return BtoonElementType.uint16;
    case elementUint32:
      return BtoonElementType.uint32;
    case elementUint64:
      return BtoonElementType.uint64;
    case elementFloat32:
      return BtoonElementType.float32;
    case elementFloat64:
      return BtoonElementType.float64;
    default:
      throw BtoonDecodeError(
        'invalid numeric element tag 0x${tag.toRadixString(16)}',
      );
  }
}

/// Returns the smallest lossless element type for a list of integers,
/// or null if any value is not numeric or is out of the `int64` range.
///
/// When a signed and an unsigned type of the same width both fit, the
/// signed type is used (§17, matching the §26.4 vector).
BtoonElementType? bestIntElementType(List<dynamic> values) {
  var minValue = 0x7FFFFFFFFFFFFFFF;
  var maxValue = -0x8000000000000000;
  for (final v in values) {
    if (v is! num) return null;
    if (!isInInt64Range(v)) return null;
    final i = v.toInt();
    if (i < minValue) minValue = i;
    if (i > maxValue) maxValue = i;
  }
  return bestIntElementTypeForRange(minValue, maxValue);
}

/// Returns the smallest lossless element type covering the inclusive
/// integer range [min], [max], or null when out of the `int64` range.
///
/// Types are probed narrowest-first, signed before unsigned of the same
/// width (§17).
BtoonElementType? bestIntElementTypeForRange(int min, int max) {
  if (!isInInt64Range(min) || !isInInt64Range(max)) return null;
  if (min >= -128 && max <= 127) return BtoonElementType.int8;
  if (min >= 0 && max <= 0xFF) return BtoonElementType.uint8;
  if (min >= -32768 && max <= 32767) return BtoonElementType.int16;
  if (min >= 0 && max <= 0xFFFF) return BtoonElementType.uint16;
  if (min >= -2147483648 && max <= 2147483647) {
    return BtoonElementType.int32;
  }
  if (min >= 0 && max <= 0xFFFFFFFF) return BtoonElementType.uint32;
  return BtoonElementType.int64;
}

/// Returns the best element type for a list of values.
///
/// * all `int` → smallest signed/unsigned integer type that fits;
/// * all `double` → `float32` if every value survives a float32 round-trip,
///   otherwise `float64`;
/// * mixed `num` → `float64`.
BtoonElementType bestNumericElementType(List<num> values) {
  var allInt = true;
  var allDouble = true;
  for (final v in values) {
    if (v is int) {
      allDouble = false;
    } else if (v is double) {
      allInt = false;
    } else {
      throw BtoonEncodeError('TypedArray values must be numeric', v);
    }
  }
  if (allInt) {
    final type = bestIntElementType(values);
    if (type == null) {
      throw BtoonEncodeError('integer out of int64 range', values);
    }
    // uint64 is a valid ObjectTable column selector but not a valid
    // TypedArray selector (§12); the values fit int64 anyway.
    return type == BtoonElementType.uint64 ? BtoonElementType.int64 : type;
  }
  if (allDouble) {
    for (final v in values) {
      if (!isLosslessFloat32(v as double)) return BtoonElementType.float64;
    }
    return BtoonElementType.float32;
  }
  return BtoonElementType.float64;
}

/// Returns true if [list] is a list of maps whose keys are all strings,
/// whose key sets are identical and non-empty, and whose columns are all
/// homogeneous numeric columns (a valid ObjectTable, §14).
bool isObjectTable(List<dynamic> list) {
  if (list.isEmpty) return false;
  for (final element in list) {
    if (element is! Map) return false;
    if (element.keys.any((k) => k is! String)) return false;
  }
  final first = list.first as Map;
  final keySet = first.keys.toSet();
  if (keySet.isEmpty) return false;
  for (final element in list.skip(1)) {
    final map = element as Map;
    if (map.length != keySet.length) return false;
    for (final k in map.keys) {
      if (k is! String || !keySet.contains(k)) return false;
    }
  }
  final rows = objectTableRows(list);
  for (final field in objectTableFields(rows)) {
    if (columnElementType(rows, field) == null) return false;
  }
  return true;
}

/// Copies a list of maps into `Map<String, dynamic>` rows (the runtime type
/// of a Dart literal `{}` is `Map<dynamic, dynamic>`, which would otherwise
/// break a `List.cast<Map<String, dynamic>>()`).
List<Map<String, dynamic>> objectTableRows(List<dynamic> list) {
  return list
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList(growable: false);
}

/// Sorted union of all keys across [rows], ordered by UTF-8 byte
/// sequence (§17).
List<String> objectTableFields(List<Map<dynamic, dynamic>> rows) {
  final set = <String>{};
  for (final row in rows) {
    for (final key in row.keys) {
      if (key is String) set.add(key);
    }
  }
  final result = set.toList();
  sortUtf8(result);
  return result;
}

/// The column kind for field [field] across [rows]:
/// returns an element type when the column is a homogeneous numeric column,
/// or null for a general (tagged) column.
///
/// Values are inspected in place in a single pass — no intermediate column
/// list is built. For integer columns the min/max range is tracked on the
/// way; for double columns a float32 conversion buffer is built once and
/// verified in a second tight loop.
BtoonElementType? columnElementType(
  List<Map<dynamic, dynamic>> rows,
  String field,
) {
  if (rows.isEmpty) return null;
  var sawInt = false;
  var sawDouble = false;
  var intRangeInit = false;
  var min = 0;
  var max = 0;
  Float32List? f32;
  for (var i = 0; i < rows.length; i++) {
    final value = rows[i][field];
    if (value is int) {
      sawInt = true;
      if (!sawDouble) {
        if (!intRangeInit) {
          min = max = value;
          intRangeInit = true;
        } else if (value < min) {
          min = value;
        } else if (value > max) {
          max = value;
        }
      }
    } else if (value is double) {
      sawDouble = true;
      final f = f32 ??= Float32List(rows.length);
      f[i] = value;
    } else {
      return null;
    }
  }
  if (sawInt && !sawDouble) {
    return bestIntElementTypeForRange(min, max);
  }
  if (sawDouble && !sawInt) {
    for (var i = 0; i < rows.length; i++) {
      if (f32![i] != rows[i][field]) return BtoonElementType.float64;
    }
    return BtoonElementType.float32;
  }
  return null;
}

/// Pre-computed ObjectTable layout.
///
/// The field order plus per-column element types are resolved once, so
/// encoding never has to re-validate or re-scan user data. Rows reference
/// the caller's maps directly (the encoder only reads them).
class ObjectTablePlan {
  /// Rows as raw maps with string keys (already validated).
  final List<Map<dynamic, dynamic>> rows;

  /// Sorted union of all keys across [rows].
  final List<String> fields;

  /// Element type per field in [fields].
  final Map<String, BtoonElementType> columnTypes;

  const ObjectTablePlan({
    required this.rows,
    required this.fields,
    required this.columnTypes,
  });
}

/// Builds an [ObjectTablePlan] from a list of maps, or null when [list]
/// does not qualify as an ObjectTable (non-map rows, inconsistent key sets,
/// non-string keys, or non-homogeneous-numeric columns).
ObjectTablePlan? buildObjectTablePlan(List<dynamic> list) {
  if (list.isEmpty) return null;
  final first = list.first;
  if (first is! Map) return null;
  final keySet = first.keys.toSet();
  if (keySet.isEmpty) return null;

  final rows = <Map<dynamic, dynamic>>[first];
  for (var i = 1; i < list.length; i++) {
    final element = list[i];
    if (element is! Map) return null;
    if (element.length != keySet.length) return null;
    for (final k in element.keys) {
      if (k is! String || !keySet.contains(k)) return null;
    }
    rows.add(element);
  }

  final fields = objectTableFields(rows);

  final columnTypes = <String, BtoonElementType>{};
  for (final field in fields) {
    final type = columnElementType(rows, field);
    if (type == null) return null;
    columnTypes[field] = type;
  }
  return ObjectTablePlan(rows: rows, fields: fields, columnTypes: columnTypes);
}

/// Writes [values] as raw fixed-width data using [type].
///
/// Callers must have already validated that every value fits [type]; a
/// mismatch raises [BtoonEncodeError].
void writeRawNumericData(
  BtoonSink sink,
  List<num> values,
  BtoonElementType type,
) {
  // Fast path: already a typed buffer of the exact width — write it raw.
  if (type == BtoonElementType.float64 && values is Float64List) {
    sink.writeBytes(Uint8List.sublistView(values));
    return;
  }
  if (type == BtoonElementType.float32 && values is Float32List) {
    sink.writeBytes(Uint8List.sublistView(values));
    return;
  }
  // Fast path: bulk-convert a plain int list through a typed list (native
  // conversion loop) instead of writing element by element. Callers have
  // already validated that every value fits [type], so wrapping on
  // conversion cannot occur.
  if (values is List<int>) {
    switch (type) {
      case BtoonElementType.int8:
      case BtoonElementType.uint8:
        sink.writeBytes(Uint8List.sublistView(Int8List.fromList(values)));
        return;
      case BtoonElementType.int16:
      case BtoonElementType.uint16:
        sink.writeBytes(Uint8List.sublistView(Int16List.fromList(values)));
        return;
      case BtoonElementType.int32:
      case BtoonElementType.uint32:
        sink.writeBytes(Uint8List.sublistView(Int32List.fromList(values)));
        return;
      case BtoonElementType.int64:
      case BtoonElementType.uint64:
        sink.writeBytes(Uint8List.sublistView(Int64List.fromList(values)));
        return;
      case BtoonElementType.float32:
      case BtoonElementType.float64:
        break;
    }
  }
  switch (type) {
    case BtoonElementType.int8:
      for (final value in values) {
        sink.writeByte(value.toInt());
      }
    case BtoonElementType.int16:
      for (final value in values) {
        sink.writeInt16(value.toInt());
      }
    case BtoonElementType.int32:
      for (final value in values) {
        sink.writeInt32(value.toInt());
      }
    case BtoonElementType.int64:
      for (final value in values) {
        sink.writeInt64(value.toInt());
      }
    case BtoonElementType.uint8:
      for (final value in values) {
        sink.writeByte(value.toInt());
      }
    case BtoonElementType.uint16:
      for (final value in values) {
        sink.writeUint16(value.toInt());
      }
    case BtoonElementType.uint32:
      for (final value in values) {
        sink.writeUint32(value.toInt());
      }
    case BtoonElementType.uint64:
      for (final value in values) {
        sink.writeUint64(value.toInt());
      }
    case BtoonElementType.float32:
      final buffer = Float32List(values.length);
      for (var i = 0; i < values.length; i++) {
        buffer[i] = values[i].toDouble();
      }
      sink.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.float64:
      final buffer = Float64List(values.length);
      for (var i = 0; i < values.length; i++) {
        buffer[i] = values[i].toDouble();
      }
      sink.writeBytes(Uint8List.sublistView(buffer));
  }
}

/// Reads [count] raw fixed-width values of [type].
///
/// The count is validated against the bytes actually available before any
/// allocation, so a hostile count cannot trigger a huge allocation (§24).
/// Numeric payloads are decoded in bulk through typed-data views over an
/// exact-size copy of the raw buffer; `uint64` stays per-element because
/// Dart has no native unsigned 64-bit read.
List<num> readRawNumericData(
  BtoonReader reader,
  BtoonElementType type,
  int count,
) {
  if (count > reader.remaining ~/ type.size) {
    throw BtoonDecodeError(
      'element count $count exceeds the ${reader.remaining} byte(s) '
      'remaining for ${type.name} elements',
      reader.position,
    );
  }
  if (count == 0) return const <num>[];
  // An exact-size fresh buffer starts at byte offset 0, so typed-data views
  // over it are always element-aligned regardless of how the message
  // arrived.
  final raw = reader.readBytes(count * type.size);
  switch (type) {
    case BtoonElementType.int8:
      return Int8List.view(raw.buffer);
    case BtoonElementType.uint8:
      return raw;
    case BtoonElementType.int16:
      return Int16List.view(raw.buffer);
    case BtoonElementType.uint16:
      return Uint16List.view(raw.buffer);
    case BtoonElementType.int32:
      return Int32List.view(raw.buffer);
    case BtoonElementType.uint32:
      return Uint32List.view(raw.buffer);
    case BtoonElementType.int64:
      return Int64List.view(raw.buffer);
    case BtoonElementType.float32:
      return Float32List.view(raw.buffer);
    case BtoonElementType.float64:
      return Float64List.view(raw.buffer);
    case BtoonElementType.uint64:
      final result = List<num>.filled(count, 0);
      for (var i = 0; i < count; i++) {
        result[i] = reader.readUint64();
      }
      return result;
  }
}

/// Validates that every value in [values] fits [type] (forced types only).
void validateNumericRange(List<num> values, BtoonElementType type) {
  for (final value in values) {
    if (value is int) {
      switch (type) {
        case BtoonElementType.int8:
          if (value < -128 || value > 127) {
            throw BtoonEncodeError('value $value does not fit int8', value);
          }
        case BtoonElementType.int16:
          if (value < -32768 || value > 32767) {
            throw BtoonEncodeError('value $value does not fit int16', value);
          }
        case BtoonElementType.int32:
          if (value < -2147483648 || value > 2147483647) {
            throw BtoonEncodeError('value $value does not fit int32', value);
          }
        case BtoonElementType.int64:
          if (!isInInt64Range(value)) {
            throw BtoonEncodeError('value $value does not fit int64', value);
          }
        case BtoonElementType.uint8:
          if (value < 0 || value > 0xFF) {
            throw BtoonEncodeError('value $value does not fit uint8', value);
          }
        case BtoonElementType.uint16:
          if (value < 0 || value > 0xFFFF) {
            throw BtoonEncodeError('value $value does not fit uint16', value);
          }
        case BtoonElementType.uint32:
          if (value < 0 || value > 0xFFFFFFFF) {
            throw BtoonEncodeError('value $value does not fit uint32', value);
          }
        case BtoonElementType.uint64:
          if (value < 0 || !isInInt64Range(value)) {
            throw BtoonEncodeError(
                'value $value does not fit uint64 (int64 range required)',
                value);
          }
        case BtoonElementType.float32:
        case BtoonElementType.float64:
          break;
      }
    } else if (value is double) {
      switch (type) {
        case BtoonElementType.int8:
        case BtoonElementType.int16:
        case BtoonElementType.int32:
        case BtoonElementType.int64:
        case BtoonElementType.uint8:
        case BtoonElementType.uint16:
        case BtoonElementType.uint32:
        case BtoonElementType.uint64:
          if (value != value.truncateToDouble() ||
              !isInInt64Range(value.truncate())) {
            throw BtoonEncodeError('value $value is not an integer', value);
          }
        case BtoonElementType.float32:
        case BtoonElementType.float64:
          break;
      }
    } else {
      throw BtoonEncodeError('TypedArray values must be numeric', value);
    }
  }
}
