import '../types.dart';

// #region Normalization (unknown → JsonValue)

/// Normalizes a value to a JsonValue.
JsonValue normalizeValue(Object? value) {
  // null
  if (value == null) {
    return null;
  }

  // Primitives
  if (value is String || value is bool) {
    return value;
  }

  // Numbers: canonicalize -0 to 0, handle NaN and Infinity
  if (value is num) {
    if (value == 0 && value.isNegative) {
      return 0;
    }
    if (!value.isFinite) {
      return null;
    }
    return value;
  }

  // BigInt → number (if safe) or quoted string for lossless preservation
  if (value is BigInt) {
    // Try to convert to number if within safe integer range
    final minSafe = BigInt.from(-9007199254740991);
    final maxSafe = BigInt.from(9007199254740991);
    if (value >= minSafe && value <= maxSafe) {
      return value.toInt();
    }
    // Otherwise convert to string to preserve exact value.
    return value.toString();
  }

  // DateTime → ISO string
  if (value is DateTime) {
    return value.toIso8601String();
  }

  // Array
  if (value is List) {
    return value.map((item) => normalizeValue(item)).toList();
  }

  // Set → array
  if (value is Set) {
    return value.map((item) => normalizeValue(item)).toList();
  }

  // Map → object
  if (value is Map) {
    final result = <String, JsonValue>{};
    for (final entry in value.entries) {
      result[entry.key.toString()] = normalizeValue(entry.value);
    }
    return result;
  }

  // Fallback: function, symbol, undefined, or other → null
  return null;
}

// #endregion

// #region Type guards

/// Checks if a value is a JSON primitive.
bool isJsonPrimitive(Object? value) {
  return value == null || value is String || value is num || value is bool;
}

/// Checks if a value is a JSON array.
bool isJsonArray(Object? value) {
  return value is List;
}

/// Checks if a value is a JSON object.
bool isJsonObject(Object? value) {
  return value != null && value is Map<String, Object?>;
}

/// Checks if a value is a plain object.
bool isPlainObject(Object? value) {
  if (value == null || value is! Map) {
    return false;
  }
  return value is Map<String, Object?>;
}

// #endregion

// #region Array type detection

/// Checks if an array contains only primitives.
bool isArrayOfPrimitives(JsonArray value) {
  return value.every((item) => isJsonPrimitive(item));
}

/// Checks if an array contains only arrays.
bool isArrayOfArrays(JsonArray value) {
  return value.every((item) => isJsonArray(item));
}

/// Checks if an array contains only objects.
bool isArrayOfObjects(JsonArray value) {
  return value.every((item) => isJsonObject(item));
}

// #endregion

// #region Keyed tabular detection (§9.5)

/// Checks if a non-primitive value at a given key is nested-uniform
/// across all rows: every value is a non-empty object with the same
/// set of keys, and every sub-column is uniform-primitive or nested-uniform.
bool _isNestedUniform(List<JsonValue> values) {
  if (values.isEmpty) return true;
  final first = values[0];
  if (!isJsonObject(first)) return false;
  final firstObj = first as JsonObject;
  if (firstObj.isEmpty) return false;
  final firstKeys = firstObj.keys.toList();

  // All rows must be non-empty objects sharing the first row's key set.
  for (final val in values) {
    if (!isJsonObject(val)) return false;
    final obj = val as JsonObject;
    if (obj.isEmpty || obj.length != firstKeys.length) return false;
    for (final key in firstKeys) {
      if (!obj.containsKey(key)) return false;
    }
  }

  // Each sub-column is checked exactly once — O(rows x keys x depth).
  for (final key in firstKeys) {
    final subValues = <JsonValue>[
      for (final v in values) (v as JsonObject)[key],
    ];
    if (!_isUniformColumn(subValues)) return false;
  }

  return true;
}

/// Checks if a column (list of values at one key) is uniform-primitive
/// or nested-uniform.
bool _isUniformColumn(List<JsonValue> values) {
  if (values.isEmpty) return true;

  final first = values[0];

  // Null is a primitive — uniform-primitive column
  if (first == null) {
    return values.every((v) => v == null || v is num || v is String || v is bool);
  }

  // Primitive column (all primitives, including null)
  if (isJsonPrimitive(first)) {
    return values.every((v) => v == null || isJsonPrimitive(v));
  }

  // Object column — check nested-uniform
  if (isJsonObject(first)) {
    return _isNestedUniform(values);
  }

  // Array or other value → not uniform
  return false;
}

/// Detects the hierarchical field structure for a nested-uniform value.
List<TabularField> _detectFields(JsonObject obj) {
  return obj.keys.map((key) {
    final value = obj[key];
    if (value is JsonObject && value.isNotEmpty) {
      return TabularField(key, _detectFields(value));
    }
    return TabularField(key);
  }).toList();
}

/// Extracts tabular fields from a list of objects, detecting nested uniformity.
/// Returns null if the rows are not all objects or not tabular.
///
/// Accepts untyped lists so callers can probe tabularity with a single
/// pass instead of pre-scanning with an `every(isJsonObject)` check.
List<TabularField>? extractTabularFields(List<Object?> rows) {
  if (rows.isEmpty) return null;

  final firstRow = rows[0];
  if (firstRow is! JsonObject) return null;
  final firstKeys = firstRow.keys.toList();
  if (firstKeys.isEmpty) return null;

  // Check that all rows are objects with the same key set.
  for (final row in rows) {
    if (row is! JsonObject) return null;
    if (row.length != firstKeys.length) return null;
    for (final key in firstKeys) {
      if (!row.containsKey(key)) return null;
    }
  }

  // Safe to cast lazily now that every row is validated.
  final objects = rows.cast<JsonObject>();

  // Check each column is uniform
  for (final key in firstKeys) {
    final column = <JsonValue>[for (final r in objects) r[key]];
    if (!_isUniformColumn(column)) return null;
  }

  return _detectFields(firstRow);
}

/// Checks if an object is eligible for keyed tabular encoding (§9.5).
bool isKeyedTabularEligible(JsonObject obj) {
  if (obj.length < 2) return false;

  final entries = obj.entries.toList();
  final firstEntry = entries[0].value;
  if (firstEntry is! JsonObject || firstEntry.isEmpty) return false;

  final firstEntryKeys = firstEntry.keys.toList();

  for (final entry in entries) {
    final val = entry.value;
    if (!isJsonObject(val)) return false;
    final entryObj = val as JsonObject;
    if (entryObj.isEmpty) return false;

    // Must have same set of keys
    if (entryObj.length != firstEntryKeys.length) return false;
    for (final key in firstEntryKeys) {
      if (!entryObj.containsKey(key)) return false;
    }
  }

  // Every column must be uniform across all entries
  for (final key in firstEntryKeys) {
    final column = entries.map((e) => (e.value as JsonObject)[key]!).toList();
    if (!_isUniformColumn(column)) return false;
  }

  return true;
}

/// Detects the field list for a keyed tabular object based on its first entry.
List<TabularField> detectKeyedFields(JsonObject obj) {
  final firstEntry = obj.entries.first;
  return _detectFields(firstEntry.value as JsonObject);
}

// #endregion
