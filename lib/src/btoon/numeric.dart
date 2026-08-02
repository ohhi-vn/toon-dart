/// Numeric helpers for `TypedArray` / columnar `ObjectTable` payloads.
library btoon_numeric;

import 'dart:typed_data';

import '../utilities/int64_bounds.dart';
import 'constants.dart';
import 'errors.dart';
import 'io.dart';
import 'types.dart';

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
  if (minValue >= 0) {
    if (maxValue <= 0xFF) return BtoonElementType.uint8;
    if (maxValue <= 0xFFFF) return BtoonElementType.uint16;
    if (maxValue <= 0xFFFFFFFF) return BtoonElementType.uint32;
    return BtoonElementType.uint64;
  }
  if (minValue >= -128 && maxValue <= 127) return BtoonElementType.int8;
  if (minValue >= -32768 && maxValue <= 32767) return BtoonElementType.int16;
  if (minValue >= -2147483648 && maxValue <= 2147483647) {
    return BtoonElementType.int32;
  }
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
    return type == BtoonElementType.uint64
        ? BtoonElementType.int64
        : type;
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

/// Sorted union of all keys across [rows].
List<String> objectTableFields(List<Map<String, dynamic>> rows) {
  final set = <String>{};
  for (final row in rows) {
    set.addAll(row.keys);
  }
  final result = set.toList()..sort();
  return result;
}

/// The column kind for field [field] across [rows]:
/// returns an element type when the column is a homogeneous numeric column,
/// or null for a general (tagged) column.
BtoonElementType? columnElementType(
  List<Map<String, dynamic>> rows,
  String field,
) {
  if (rows.isEmpty) return null;
  var sawNull = false;
  var sawInt = false;
  var sawDouble = false;
  for (final row in rows) {
    final value = row[field];
    if (value == null) {
      sawNull = true;
      continue;
    }
    if (value is int) {
      sawInt = true;
    } else if (value is double) {
      sawDouble = true;
    } else {
      return null;
    }
  }
  if (sawNull) return null;
  if (sawInt && !sawDouble) {
    return bestIntElementType(rows.map((r) => r[field] as int).toList());
  }
  if (sawDouble && !sawInt) {
    for (final row in rows) {
      if (!isLosslessFloat32(row[field] as double)) {
        return BtoonElementType.float64;
      }
    }
    return BtoonElementType.float32;
  }
  return null;
}

/// Writes [values] as raw fixed-width data using [type].
///
/// Callers must have already validated that every value fits [type]; a
/// mismatch raises [BtoonEncodeError].
void writeRawNumericData(
  BtoonWriter writer,
  List<num> values,
  BtoonElementType type,
) {
  switch (type) {
    case BtoonElementType.int8:
      for (final value in values) {
        writer.writeByte(value.toInt());
      }
    case BtoonElementType.int16:
      for (final value in values) {
        writer.writeInt16(value.toInt());
      }
    case BtoonElementType.int32:
      for (final value in values) {
        writer.writeInt32(value.toInt());
      }
    case BtoonElementType.int64:
      for (final value in values) {
        writer.writeInt64(value.toInt());
      }
    case BtoonElementType.uint8:
      for (final value in values) {
        writer.writeByte(value.toInt());
      }
    case BtoonElementType.uint16:
      for (final value in values) {
        writer.writeUint16(value.toInt());
      }
    case BtoonElementType.uint32:
      for (final value in values) {
        writer.writeUint32(value.toInt());
      }
    case BtoonElementType.uint64:
      for (final value in values) {
        writer.writeUint64(value.toInt());
      }
    case BtoonElementType.float32:
      final buffer = Float32List(values.length);
      for (var i = 0; i < values.length; i++) {
        buffer[i] = values[i].toDouble();
      }
      writer.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.float64:
      final buffer = Float64List(values.length);
      for (var i = 0; i < values.length; i++) {
        buffer[i] = values[i].toDouble();
      }
      writer.writeBytes(Uint8List.sublistView(buffer));
  }
}

/// Reads [count] raw fixed-width values of [type].
List<num> readRawNumericData(
  BtoonReader reader,
  BtoonElementType type,
  int count,
) {
  final result = List<num>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    switch (type) {
      case BtoonElementType.int8:
        result[i] = reader.readByte().toSigned(8);
      case BtoonElementType.int16:
        result[i] = reader.readInt16();
      case BtoonElementType.int32:
        result[i] = reader.readInt32();
      case BtoonElementType.int64:
        result[i] = reader.readInt64();
      case BtoonElementType.uint8:
        result[i] = reader.readByte();
      case BtoonElementType.uint16:
        result[i] = reader.readUint16();
      case BtoonElementType.uint32:
        result[i] = reader.readUint32();
      case BtoonElementType.uint64:
        result[i] = reader.readUint64();
      case BtoonElementType.float32:
        result[i] = reader.readFloat32();
      case BtoonElementType.float64:
        result[i] = reader.readFloat64();
    }
  }
  return result;
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
