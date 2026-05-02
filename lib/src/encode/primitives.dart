import 'dart:math';

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

/// Encodes a number in canonical decimal form per TOON spec §2.
///
/// Canonical form rules:
/// - No exponent notation (e.g., 1e6 → 1000000)
/// - No leading zeros except single "0"
/// - No trailing zeros in fractional part (e.g., 1.5000 → 1.5)
/// - If fractional part is zero, emit as integer (e.g., 1.0 → 1)
/// - -0 → 0
String _encodeNumber(num value) {
  // Handle integers directly
  if (value is int) {
    return value.toString();
  }

  // Handle doubles
  if (value is double) {
    // Normalize -0 to 0
    if (value == 0.0) {
      return '0';
    }

    // Handle non-finite values (should be normalized to null before encoding)
    if (!value.isFinite) {
      return NULL_LITERAL;
    }

    // Check if it's actually an integer value
    if (value == value.truncateToDouble()) {
      // It's a whole number - format without decimal point
      // Use toStringAsFixed(0) to avoid scientific notation for large numbers
      return value.toStringAsFixed(0);
    }

    // It's a decimal number - need canonical form
    // Strategy: Use toString() first, which gives good precision
    // If it contains exponent notation, convert to fixed notation
    String str = value.toString();

    if (str.contains('e') || str.contains('E')) {
      // Need to convert from scientific notation to decimal
      // Calculate appropriate decimal places based on the number
      final absValue = value.abs();
      int decimalPlaces;

      if (absValue >= 1) {
        // For numbers >= 1, use enough precision for ~15 significant digits
        final intPart = value.truncateToDouble().abs();
        final intDigits = intPart == 0 ? 1 : (log(intPart) / ln10).floor() + 1;
        decimalPlaces = (15 - intDigits).clamp(0, 17).toInt();
      } else {
        // For small numbers < 1, find the first significant digit
        final log10 = (log(value.abs()) / ln10).floor();
        decimalPlaces = -log10 + 14;
      }

      str = value.toStringAsFixed(decimalPlaces);
    }

    // Remove trailing zeros after decimal point (code unit approach, no regex)
    if (str.contains('.')) {
      // Find the last non-zero digit after decimal point
      int end = str.length - 1;
      while (end >= 0 && str.codeUnitAt(end) == 0x30) {
        // '0'
        end--;
      }
      // Remove trailing zeros
      if (end >= 0 && str.codeUnitAt(end) == 0x2E) {
        // '.' - no fractional part
        str = str.substring(0, end); // Remove decimal point
      } else if (end < str.length - 1) {
        str = str.substring(0, end + 1);
      }
    }

    return str;
  }

  // Fallback (should not reach here)
  return value.toString();
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
