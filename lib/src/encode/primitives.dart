import '../types.dart';
import '../utilities/constants.dart';
import '../utilities/string-utils.dart';

// #region Primitive encoding

/// Encodes a primitive value to a string.
@pragma('vm:prefer-inline')
String encodePrimitive(JsonPrimitive value, [String? delimiter]) {
  if (value == null) {
    return NULL_LITERAL;
  }

  if (value is bool) {
    return value.toString();
  }

  if (value is num) {
    return _encodeNumber(value);
  }

  return encodeStringLiteral(value as String, delimiter ?? COMMA);
}

/// Encodes a number in canonical form per TOON spec §2.
///
/// Canonical decimal form (no exponent) is REQUIRED when:
/// - n = 0
/// - 1e-6 ≤ |n| < 1e21
///
/// Outside this range, exponent notation MAY be used.
String _encodeNumber(num value) {
  // Handle integers directly
  if (value is int) {
    return value.toString();
  }

  // Handle doubles (num is sealed to int|double, so this cast is safe)
  final double d = value as double;
  {
    // Normalize -0 to 0
    if (d == 0.0) {
      return '0';
    }

    // Handle non-finite values (should be normalized to null before encoding)
    if (!d.isFinite) {
      return NULL_LITERAL;
    }

    // Check if within canonical decimal range
    // Must use decimal when |n| >= 1e-6 and |n| < 1e21, or n == 0
    final absValue = d.abs();
    final inCanonicalRange = absValue >= 1e-6 && absValue < 1e21;

    if (!inCanonicalRange) {
      // Outside canonical range — MAY use exponent notation
      return d.toString();
    }

    // Check if it's actually an integer value
    if (d == d.truncateToDouble()) {
      // It's a whole number - format without decimal point
      // Use toStringAsFixed(0) to avoid scientific notation for large numbers
      return d.toStringAsFixed(0);
    }

    // It's a decimal number in canonical range — toString() already produces
    // canonical decimal form for non-integer doubles in [1e-6, 1e21).
    return d.toString();
  }
}

/// Encodes a string literal, adding quotes if necessary.
@pragma('vm:prefer-inline')
String encodeStringLiteral(String value, [String delimiter = COMMA]) {
  if (isSafeUnquoted(value, delimiter)) {
    return value;
  }

  return '$DOUBLE_QUOTE${escapeString(value)}$DOUBLE_QUOTE';
}

// #endregion

// #region Key encoding

/// Encodes a key, adding quotes if necessary.
@pragma('vm:prefer-inline')
String encodeKey(String key) {
  if (isValidUnquotedKey(key)) {
    return key;
  }

  return '$DOUBLE_QUOTE${escapeString(key)}$DOUBLE_QUOTE';
}

// #endregion

// #region Value joining

/// Encodes and joins primitive values with a delimiter.
/// Optimized to use StringBuffer and avoid intermediate list creation.
String encodeAndJoinPrimitives(List<JsonPrimitive> values,
    [String delimiter = COMMA]) {
  if (values.isEmpty) return '';
  if (values.length == 1) return encodePrimitive(values[0], delimiter);

  final buffer = StringBuffer();
  buffer.write(encodePrimitive(values[0], delimiter));
  for (int i = 1; i < values.length; i++) {
    buffer.write(delimiter);
    buffer.write(encodePrimitive(values[i], delimiter));
  }
  return buffer.toString();
}

// #endregion

// #region Header formatters

/// Formats an array header.
///
/// Optimized: uses StringBuffer to avoid intermediate string concatenations.
String formatHeader(
  int length, {
  String? key,
  List<String>? fields,
  String? delimiter,
  String? lengthMarker,
}) {
  final delimiterValue = delimiter ?? COMMA;
  final lengthMarkerValue = lengthMarker ?? '';

  final buffer = StringBuffer();

  if (key != null) {
    buffer.write(encodeKey(key));
  }

  // Only include delimiter if it's not the default (comma)
  final delimiterSuffix =
      delimiterValue != DEFAULT_DELIMITER ? delimiterValue : '';
  buffer.write('[');
  buffer.write(lengthMarkerValue);
  buffer.write(length);
  buffer.write(delimiterSuffix);
  buffer.write(']');

  if (fields != null) {
    buffer.write('{');
    for (int i = 0; i < fields.length; i++) {
      if (i > 0) buffer.write(delimiterValue);
      buffer.write(encodeKey(fields[i]));
    }
    buffer.write('}');
  }

  buffer.write(':');

  return buffer.toString();
}

// #endregion
