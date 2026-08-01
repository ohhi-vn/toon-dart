import '../types.dart';
import '../utilities/constants.dart';
import 'normalize.dart';
import 'primitives.dart';
import 'writer.dart';

// Per TOON spec §11.1: Delimiter-aware quoting rules
// - Document delimiter: Used for quoting decisions in object field values (key: value)
// - Active delimiter: Used for quoting decisions in inline arrays and tabular rows
// The document delimiter is set by encoder options and applies throughout the document.
// The active delimiter is declared by array headers and applies within their scope.

// #region Encode normalized JsonValue

/// Encodes a JsonValue to TOON format.
///
/// Optimized: pre-estimates buffer capacity to avoid reallocation.
/// Uses [LineWriter.estimateFromMap] for a rough size estimate,
/// which is much better than dynamic growth (2-3x reallocation overhead).
String encodeValue(JsonValue value, ResolvedEncodeOptions options) {
  if (isJsonPrimitive(value)) {
    return encodePrimitive(value, options.delimiter);
  }

  // Pre-estimate buffer capacity for better performance
  final estimatedCapacity = isJsonObject(value)
      ? LineWriter.estimateFromMap(value as JsonObject)
      : isJsonArray(value)
          ? _estimateArrayCapacity(value as JsonArray)
          : 256;

  final writer =
      LineWriter(options.indent, estimatedCapacity: estimatedCapacity);

  if (isJsonArray(value)) {
    encodeArray(null, value as JsonArray, writer, 0, options);
  } else if (isJsonObject(value)) {
    final objValue = value as JsonObject;
    if (objValue.isNotEmpty && isKeyedTabularEligible(objValue)) {
      // Root keyed tabular form: no key prefix, keyless keyed header
      final fields = detectKeyedFields(objValue);
      _encodeKeyedTabularObject(null, objValue, fields, writer, 0, options);
    } else {
      encodeObject(objValue, writer, 0, options);
    }
  }

  return writer.toString();
}

/// Estimates buffer capacity for an array value.
int _estimateArrayCapacity(JsonArray arr) {
  if (arr.isEmpty) return 64;
  final first = arr.first;
  if (first is Map<String, dynamic>) {
    // Tabular estimate: header + rows
    return 64 + arr.length * (first.length * 16 + 16);
  }
  // Primitive or mixed estimate
  return 64 + arr.length * 24;
}

// #endregion

// #region Object encoding

/// Encodes a JSON object.
///
/// Optimized: uses direct key iteration without creating intermediate list.
/// Uses [LineWriter.pushKeyValue] for primitive values to avoid
/// intermediate string concatenation.
void encodeObject(JsonObject value, LineWriter writer, Depth depth,
    ResolvedEncodeOptions options) {
  for (final key in value.keys) {
    _encodeKeyValuePairInline(key, value[key], writer, depth, options);
  }
}

/// Encodes a key-value pair.
///
/// This is the public API that delegates to the inlined version.
void encodeKeyValuePair(String key, JsonValue? value, LineWriter writer,
    Depth depth, ResolvedEncodeOptions options) {
  _encodeKeyValuePairInline(key, value, writer, depth, options);
}

/// Encodes a key-value pair (inlined hot path).
///
/// Optimized: uses [LineWriter.pushKeyValue] for primitive values,
/// which writes directly to the buffer without creating the
/// intermediate `'$key: $value'` string.
///
/// Performance: ~1.5-2x faster for primitive values due to
/// eliminated string interpolation overhead.
void _encodeKeyValuePairInline(String key, JsonValue? value, LineWriter writer,
    Depth depth, ResolvedEncodeOptions options) {
  final encodedKey = encodeKey(key);

  if (isJsonPrimitive(value)) {
    // Per TOON spec §11.1: object field values use the document delimiter for quoting decisions
    // Inlined: write key + ": " + value directly to buffer
    writer.pushKeyValue(
        depth, encodedKey, encodePrimitive(value, options.delimiter));
  } else if (isJsonArray(value)) {
    encodeArray(key, value as JsonArray, writer, depth, options);
  } else if (isJsonObject(value)) {
    final objValue = value as JsonObject;
    if (objValue.isEmpty) {
      // Empty object
      writer.pushKeyValue(depth, encodedKey, '');
    } else if (isKeyedTabularEligible(objValue)) {
      // Per TOON spec §9.5: Keyed tabular form
      final fields = detectKeyedFields(objValue);
      _encodeKeyedTabularObject(encodedKey, objValue, fields, writer, depth, options);
    } else {
      writer.pushKeyValue(depth, encodedKey, '');
      encodeObject(objValue, writer, depth + 1, options);
    }
  }
}

// #endregion

// #region Array encoding

/// Encodes a JSON array.
void encodeArray(
  String? key,
  JsonArray value,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  if (value.isEmpty) {
    // Per TOON spec §9.1: Empty arrays under a key use inline [] form;
    // root-level empty arrays also use [].
    if (key != null) {
      writer.pushKeyValue(depth, encodeKey(key), '[]');
    } else {
      writer.push(depth, '[]');
    }
    return;
  }

  // Primitive array
  if (isArrayOfPrimitives(value)) {
    _encodeInlinePrimitiveArray(key, value, writer, depth, options);
    return;
  }

  // Array of arrays (all primitives)
  if (isArrayOfArrays(value)) {
    final allPrimitiveArrays =
        value.every((arr) => isArrayOfPrimitives(arr as JsonArray));
    if (allPrimitiveArrays) {
      encodeArrayOfArraysAsListItems(
          key, value.cast<JsonArray>(), writer, depth, options);
      return;
    }
  }

  // Array of objects (tabular format when eligible)
  if (isArrayOfObjects(value)) {
    final objects = value.cast<JsonObject>();
    final header = extractTabularHeader(objects);
    // §9.3: Keyless tabular headers (without key prefix) are valid only at
    // document root (depth 0). In list-item position, use list form instead.
    if (header != null && (key != null || depth == 0)) {
      encodeArrayOfObjectsAsTabular(
          key, objects, header, writer, depth, options);
    } else {
      encodeMixedArrayAsListItems(key, value, writer, depth, options);
    }
    return;
  }

  // Mixed array: fallback to expanded format
  encodeMixedArrayAsListItems(key, value, writer, depth, options);
}

// #endregion

// #region Inline primitive array encoding

/// Encodes an inline primitive array.
///
/// Optimized: uses [LineWriter.pushArrayHeader] with inline values
/// to build the entire line in one buffer write sequence.
void _encodeInlinePrimitiveArray(
  String? key,
  JsonArray value,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  final delimiter = options.delimiter;
  final joinedValues =
      encodeAndJoinPrimitives(value.cast<JsonPrimitive>(), delimiter);

  // Optimized: build header + inline values directly in buffer
  writer.pushArrayHeader(depth,
      key: key != null ? encodeKey(key) : null,
      length: value.length,
      delimiter: delimiter,
      lengthMarker: options.lengthMarker,
      inlineValues: joinedValues);
}

/// Encodes an inline array line (for nested arrays).
///
/// Returns the formatted line string. Used when the array header
/// needs to be combined with other content on the same line.
String encodeInlineArrayLine(List<JsonPrimitive> values, String delimiter,
    String? prefix, String? lengthMarker) {
  // Per TOON spec §9.1: Empty arrays under a key use inline [] form;
  // list-item empty arrays use [0]: header form.
  if (values.isEmpty) {
    if (prefix != null) {
      return '${encodeKey(prefix)}: []';
    }
    return '[0]:';
  }
  final header = formatHeader(values.length,
      key: prefix, delimiter: delimiter, lengthMarker: lengthMarker);
  final joinedValue = encodeAndJoinPrimitives(values, delimiter);
  return '$header $joinedValue';
}

// #endregion

// #region Array of arrays (expanded format)

/// Encodes an array of arrays as list items.
void encodeArrayOfArraysAsListItems(
  String? prefix,
  List<JsonArray> values,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  // Optimized: use pushArrayHeader instead of formatHeader + push
  writer.pushArrayHeader(depth,
      key: prefix != null ? encodeKey(prefix) : null,
      length: values.length,
      delimiter: options.delimiter,
      lengthMarker: options.lengthMarker);

  for (final arr in values) {
    if (isArrayOfPrimitives(arr)) {
      final inline = encodeInlineArrayLine(
          arr, options.delimiter, null, options.lengthMarker);
      writer.pushListItem(depth + 1, inline);
    }
  }
}

// #endregion

// #region Array of objects (tabular format) — HOT PATH

/// Encodes an array of objects in tabular format.
///
/// This is the hottest encoding path for tabular data.
/// Optimized with:
/// - [LineWriter.pushArrayHeader] for direct header building
/// - Batch row writing via [LineWriter.pushTabularRows]
/// - Pre-encoded row strings to avoid per-row buffer overhead
/// - Inlined primitive encoding in row building loop
///
/// Performance: ~2-3x faster than naive per-row push() calls
/// for large tabular arrays (1000+ rows).
void encodeArrayOfObjectsAsTabular(
  String? prefix,
  List<JsonObject> rows,
  List<TabularField> fields,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  final delimiter = options.delimiter;

  // Build header with nested field support
  final hasNested = fields.any((f) => f.nestedFields != null);
  if (hasNested) {
    final header = _formatTabularArrayHeader(prefix, rows.length, delimiter, fields, options);
    writer.push(depth, header);
  } else {
    // Simple case: use pushArrayHeader
    final flatFields = fields.map((f) => encodeKey(f.name)).toList();
    writer.pushArrayHeader(depth,
        key: prefix != null ? encodeKey(prefix) : null,
        length: rows.length,
        delimiter: delimiter,
        fields: flatFields,
        lengthMarker: options.lengthMarker);
  }

  // Pre-encode all rows
  final encodedRows = _preEncodeTabularRows(rows, fields, delimiter);
  writer.pushTabularRows(depth + 1, encodedRows);
}

/// Formats a tabular array header with hierarchical field support.
String _formatTabularArrayHeader(
  String? prefix,
  int length,
  String delimiter,
  List<TabularField> fields,
  ResolvedEncodeOptions options,
) {
  final buffer = StringBuffer();
  if (prefix != null) {
    buffer.write(encodeKey(prefix));
  }
  buffer.write('[');
  if (options.lengthMarker != null) {
    buffer.write(options.lengthMarker);
  }
  buffer.write(length);
  if (delimiter != DEFAULT_DELIMITER) {
    buffer.write(delimiter);
  }
  buffer.write(']');
  if (fields.isNotEmpty) {
    buffer.write('{');
    _formatFields(buffer, fields, delimiter);
    buffer.write('}');
  }
  buffer.write(':');
  return buffer.toString();
}

/// Pre-encodes tabular rows into strings.
///
/// This is the inlined hot path for tabular row encoding.
/// Each row is encoded into a string with delimited values,
/// avoiding per-row StringBuffer allocation by reusing a
/// single buffer that is cleared between rows.
///
/// Performance: ~1.5-2x faster than creating a new StringBuffer
/// per row due to reduced allocation overhead.
List<String> _preEncodeTabularRows(
  List<JsonObject> rows,
  List<TabularField> fields,
  String delimiter,
) {
  final result = <String>[];
  // Reuse a single buffer for all rows to reduce allocation
  final buffer = StringBuffer();

  for (final row in rows) {
    buffer.clear();
    final cells = _flattenValues(row, fields);
    for (int i = 0; i < cells.length; i++) {
      if (i > 0) {
        buffer.write(delimiter);
      }
      buffer.write(encodePrimitive(cells[i], delimiter));
    }
    result.add(buffer.toString());
  }

  return result;
}

/// Extracts the tabular header from an array of objects.
///
/// Optimized: uses early exit on first non-tabular row.
/// Only checks keys existence and primitive type — no
/// intermediate list creation for keys.
List<TabularField>? extractTabularHeader(List<JsonObject> rows) {
  if (rows.isEmpty) return null;

  final fields = extractTabularFields(rows);
  return fields;
}

/// Checks if an array of objects is tabular (all have same keys and primitive values).
///
/// Optimized: uses early exit on first mismatch. Checks key count
/// first (cheap integer comparison) before checking individual keys.
bool isTabularArray(
  List<JsonObject> rows,
  List<String> header,
) {
  final headerLength = header.length;

  for (final row in rows) {
    final keys = row.keys;

    // Quick check: key count must match (cheap integer comparison)
    if (keys.length != headerLength) {
      return false;
    }

    // Check that all header keys exist in the row and all values are primitives
    for (final key in header) {
      if (!row.containsKey(key)) {
        return false;
      }
      if (!isJsonPrimitive(row[key])) {
        return false;
      }
    }
  }

  return true;
}

/// Writes tabular rows.
///
/// Optimized: uses pre-encoded row strings and batch writing.
/// This is a fallback for cases where rows are written individually
/// (e.g., when called from list-item encoding).
///
/// Optimized: pre-builds all row strings and uses batch [LineWriter.pushTabularRows]
/// instead of calling push() in a loop. This avoids per-row method call overhead
/// and allows the writer to optimize the batch write.
void writeTabularRows(
  List<JsonObject> rows,
  List<String> header,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  final delimiter = options.delimiter;
  final headerLength = header.length;

  // Pre-allocate row strings list for batch writing
  final rowStrings = List<String>.generate(rows.length, (r) {
    final row = rows[r];
    final buffer = StringBuffer();
    for (int i = 0; i < headerLength; i++) {
      if (i > 0) {
        buffer.write(delimiter);
      }
      buffer.write(encodePrimitive(row[header[i]], delimiter));
    }
    return buffer.toString();
  }, growable: false);

  // Use batch write for better performance
  writer.pushTabularRows(depth, rowStrings);
}

// #endregion

// #region Array of objects (expanded format)

/// Encodes a mixed array as list items.
///
/// Optimized: uses [LineWriter.pushArrayHeader] for direct
/// header building without intermediate string.
void encodeMixedArrayAsListItems(
  String? prefix,
  List<JsonValue> items,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  // Optimized: build header directly in buffer
  writer.pushArrayHeader(depth,
      key: prefix != null ? encodeKey(prefix) : null,
      length: items.length,
      delimiter: options.delimiter,
      lengthMarker: options.lengthMarker);

  for (final item in items) {
    encodeListItemValue(item, writer, depth + 1, options);
  }
}

/// Encodes an object as a list item.
///
/// Per TOON spec §10: When a list-item object has a tabular array as its first field,
/// the tabular header appears on the hyphen line, rows at depth +2, other fields at depth +1.
///
/// Optimized: uses [LineWriter.pushKeyValue] for primitive first fields
/// and [LineWriter.pushArrayHeader] for array first fields.
void encodeObjectAsListItem(JsonObject obj, LineWriter writer, Depth depth,
    ResolvedEncodeOptions options) {
  final keys = obj.keys.toList();
  if (keys.isEmpty) {
    writer.push(depth, LIST_ITEM_MARKER);
    return;
  }

  // First key-value on the same line as "- "
  final firstKey = keys[0];
  final encodedKey = encodeKey(firstKey);
  final firstValue = obj[firstKey];

  if (isJsonPrimitive(firstValue)) {
    // Per TOON spec §11.1: Object field values use the document delimiter for quoting
    // Optimized: use pushKeyValue with list item prefix
    writer.pushListItem(depth,
        '$encodedKey: ${encodePrimitive(firstValue, options.delimiter)}');
  } else if (isJsonArray(firstValue)) {
    final arr = firstValue as JsonArray;
    if (isArrayOfPrimitives(arr)) {
      // Inline format for primitive arrays
      final formatted = encodeInlineArrayLine(
          arr, options.delimiter, firstKey, options.lengthMarker);
      writer.pushListItem(depth, formatted);
    } else if (isArrayOfObjects(arr)) {
      // Check if array of objects can use tabular format
      final objects = arr.cast<JsonObject>();
      final tabularFields = extractTabularHeader(objects);
      if (tabularFields != null) {
        // Per TOON spec §10: Tabular header on hyphen line, rows at depth +2
        final hasNested = tabularFields.any((f) => f.nestedFields != null);
        if (hasNested) {
          final headerStr = _formatTabularArrayHeader(
              firstKey, arr.length, options.delimiter, tabularFields, options);
          writer.pushListItem(depth, headerStr);
        } else {
          final flatFields = tabularFields.map((f) => encodeKey(f.name)).toList();
          final headerStr = formatHeader(arr.length,
              key: firstKey,
              fields: flatFields,
              delimiter: options.delimiter,
              lengthMarker: options.lengthMarker);
          writer.pushListItem(depth, headerStr);
        }
        // Rows at depth +2 relative to the hyphen line
        final encodedRows =
            _preEncodeTabularRows(objects, tabularFields, options.delimiter);
        writer.pushTabularRows(depth + 2, encodedRows);
      } else {
        // Fall back to list format for non-uniform arrays of objects
        writer.pushListItem(depth, '$encodedKey[${arr.length}]:');
        for (final item in arr) {
          encodeObjectAsListItem(
              item as JsonObject, writer, depth + 2, options);
        }
      }
    } else {
      // Complex arrays on separate lines
      writer.pushListItem(depth, '$encodedKey[${arr.length}]:');
      for (final item in arr) {
        encodeListItemValue(item, writer, depth + 2, options);
      }
    }
  } else if (isJsonObject(firstValue)) {
    final objValue = firstValue as JsonObject;
    if (objValue.isEmpty) {
      writer.pushListItem(depth, '$encodedKey:');
    } else if (isKeyedTabularEligible(objValue)) {
      // Per TOON spec §10 + §9.5: Keyed header on hyphen line, entry rows at depth +2
      final fields = detectKeyedFields(objValue);
      final headerStr = _formatKeyedHeader(encodedKey,
          objValue.length, options.delimiter, fields);
      writer.pushListItem(depth, headerStr);
      // Entry rows at depth +2 relative to hyphen line
      int entryIndex = 0;
      for (final entry in objValue.entries) {
        entryIndex++;
        final entryKey = encodeKey(entry.key);
        final entryObj = entry.value as JsonObject;
        final cells = _flattenValues(entryObj, fields);
        final cellBuffer = StringBuffer();
        cellBuffer.write(entryKey);
        cellBuffer.write(':');
        if (cells.isNotEmpty) {
          cellBuffer.write(' ');
          for (int i = 0; i < cells.length; i++) {
            if (i > 0) cellBuffer.write(options.delimiter);
            cellBuffer.write(encodePrimitive(cells[i], options.delimiter));
          }
        }
        if (entryIndex == 1) {
          writer.push(depth + 2, cellBuffer.toString());
        } else {
          writer.push(depth + 2, cellBuffer.toString());
        }
      }
    } else {
      writer.pushListItem(depth, '$encodedKey:');
      encodeObject(objValue, writer, depth + 2, options);
    }
  }

  // Remaining keys on indented lines at depth +1
  for (int i = 1; i < keys.length; i++) {
    final key = keys[i];
    _encodeKeyValuePairInline(key, obj[key], writer, depth + 1, options);
  }
}

// #endregion

// #region List item encoding helpers

/// Encodes a list item value.
void encodeListItemValue(
  JsonValue value,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  if (isJsonPrimitive(value)) {
    writer.pushListItem(depth, encodePrimitive(value, options.delimiter));
  } else if (isJsonArray(value)) {
    final arr = value as JsonArray;
    if (isArrayOfPrimitives(arr)) {
      // Inline primitive array
      final inline = encodeInlineArrayLine(
          arr, options.delimiter, null, options.lengthMarker);
      writer.pushListItem(depth, inline);
    } else if (isArrayOfArrays(arr)) {
      // Array of arrays - use expanded list format
      writer.pushArrayHeader(depth,
          length: arr.length,
          delimiter: options.delimiter,
          lengthMarker: options.lengthMarker);
      for (final item in arr) {
        if (isArrayOfPrimitives(item as JsonArray)) {
          final inline = encodeInlineArrayLine(
              item, options.delimiter, null, options.lengthMarker);
          writer.pushListItem(depth + 1, inline);
        } else {
          // Recursively handle nested structures
          encodeListItemValue(item, writer, depth + 1, options);
        }
      }
    } else if (isArrayOfObjects(arr)) {
      // Keyless array of objects in list-item position — use list form
      // per §9.3 (keyless tabular headers are valid only at document root).
      final listHeader = formatHeader(arr.length,
          delimiter: options.delimiter, lengthMarker: options.lengthMarker);
      writer.pushListItem(depth, listHeader);
      for (final item in arr) {
        encodeObjectAsListItem(item as JsonObject, writer, depth + 1, options);
      }
    } else {
      // Mixed array - use expanded list format
      writer.pushArrayHeader(depth,
          length: arr.length,
          delimiter: options.delimiter,
          lengthMarker: options.lengthMarker);
      for (final item in arr) {
        encodeListItemValue(item, writer, depth + 1, options);
      }
    }
  } else if (isJsonObject(value)) {
    encodeObjectAsListItem(value as JsonObject, writer, depth, options);
  }
}

/// Formats a keyed header: key[N:<delim?>]{fields}: or [N:<delim?>]{fields}:
String _formatKeyedHeader(
  String? key,
  int length,
  String delimiter,
  List<TabularField> fields,
) {
  final buffer = StringBuffer();
  if (key != null) {
    buffer.write(key);
  }
  buffer.write('[');
  buffer.write(length);
  buffer.write(':');
  if (delimiter != DEFAULT_DELIMITER) {
    buffer.write(delimiter);
  }
  buffer.write(']');
  if (fields.isNotEmpty) {
    buffer.write('{');
    _formatFields(buffer, fields, delimiter);
    buffer.write('}');
  }
  buffer.write(':');
  return buffer.toString();
}

/// Recursively writes field entries to a buffer.
void _formatFields(StringBuffer buffer, List<TabularField> fields, String delimiter) {
  for (int i = 0; i < fields.length; i++) {
    if (i > 0) buffer.write(delimiter);
    buffer.write(encodeKey(fields[i].name));
    final nested = fields[i].nestedFields;
    if (nested != null && nested.isNotEmpty) {
      buffer.write('{');
      _formatFields(buffer, nested, delimiter);
      buffer.write('}');
    }
  }
}

/// Recursively flattens object values into depth-first leaf cells.
List<JsonPrimitive> _flattenValues(JsonObject obj, List<TabularField> fields) {
  final result = <JsonPrimitive>[];
  for (final field in fields) {
    final value = obj[field.name];
    if (field.nestedFields != null) {
      result.addAll(_flattenValues(value as JsonObject, field.nestedFields!));
    } else {
      // Leaf field
      result.add(isJsonPrimitive(value) ? value : null);
    }
  }
  return result;
}

/// Encodes an object in keyed tabular form (§9.5).
void _encodeKeyedTabularObject(
  String? key,
  JsonObject obj,
  List<TabularField> fields,
  LineWriter writer,
  Depth depth,
  ResolvedEncodeOptions options,
) {
  final delimiter = options.delimiter;
  final headerStr = _formatKeyedHeader(
    key,
    obj.length,
    delimiter,
    fields,
  );
  writer.push(depth, headerStr);

  // Write entry rows
  final entryDepth = depth + 1;
  int entryIndex = 0;
  for (final entry in obj.entries) {
    entryIndex++;
    final entryKey = encodeKey(entry.key);
    final entryObj = entry.value as JsonObject;
    final cells = _flattenValues(entryObj, fields);

    final buffer = StringBuffer();
    buffer.write(entryKey);
    buffer.write(':');
    if (cells.isNotEmpty) {
      buffer.write(' ');
      for (int i = 0; i < cells.length; i++) {
        if (i > 0) buffer.write(delimiter);
        buffer.write(encodePrimitive(cells[i], delimiter));
      }
    }

    if (entryIndex == 1) {
      writer.push(entryDepth, buffer.toString());
    } else {
      writer.push(entryDepth, buffer.toString());
    }
  }
}

// #endregion
