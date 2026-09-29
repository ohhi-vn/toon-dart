/// Shared numeric utilities for TOON parsing.
///
/// Consolidates duplicate numeric detection/parsing logic from:
/// - parser.dart
/// - stream_decoder.dart
/// - toon_schema.dart
library numeric_utils;

/// Fast numeric-like check without regex.
/// Includes check for forbidden leading zeros per TOON spec §4.
@pragma('vm:prefer-inline')
bool isNumericLikeFast(String value) {
  if (value.isEmpty) return false;
  int start = 0;
  final first = value.codeUnitAt(0);
  if (first == 0x2D || first == 0x2B) start = 1; // '-' or '+'
  if (start >= value.length) return false;

  // Check for forbidden leading zeros (e.g., "05", "007")
  if (start < value.length && value.codeUnitAt(start) == 0x30) {
    if (start + 1 < value.length) {
      final next = value.codeUnitAt(start + 1);
      if (next != 0x2E && next != 0x65 && next != 0x45) {
        // '.', 'e', 'E'
        return false; // Forbidden leading zero like "05"
      }
    }
  }

  bool hasDigit = false;
  bool hasDot = false;
  bool hasE = false;
  for (int i = start; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) {
      hasDigit = true;
    } else if (c == 0x2E && !hasDot) {
      hasDot = true;
    } else if ((c == 0x65 || c == 0x45) && !hasE && hasDigit) {
      hasE = true;
    } else if ((c == 0x2B || c == 0x2D) &&
        hasE &&
        i > 0 &&
        (value.codeUnitAt(i - 1) == 0x65 || value.codeUnitAt(i - 1) == 0x45)) {
      // exponent sign
    } else {
      return false;
    }
  }
  return hasDigit;
}

/// Fast integer check (subset of numeric - no dot, no exponent).
@pragma('vm:prefer-inline')
bool isSimpleInteger(String value) {
  if (value.isEmpty) return false;
  int start = 0;
  final first = value.codeUnitAt(0);
  if (first == 0x2D) start = 1; // '-'
  if (start >= value.length) return false;

  // All remaining chars must be digits
  for (int i = start; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// Fast integer parsing without int.parse() overhead.
@pragma('vm:prefer-inline')
int parseSimpleInteger(String value) {
  int result = 0;
  int start = 0;
  final neg = value.codeUnitAt(0) == 0x2D;
  if (neg) start = 1;

  for (int i = start; i < value.length; i++) {
    result = result * 10 + (value.codeUnitAt(i) - 0x30);
  }
  return neg ? -result : result;
}

/// Unified number parsing (int or double).
/// Returns int for simple integers, double for decimals/exponents.
@pragma('vm:prefer-inline')
dynamic parseNumberFast(String value) {
  if (isSimpleInteger(value)) {
    return parseSimpleInteger(value); // Returns int, not double
  }
  final parsed = double.tryParse(value);
  if (parsed != null) {
    return parsed == 0.0 ? 0 : parsed; // Normalize -0.0 to 0
  }
  return value; // Fallback (should not happen if isNumericLikeFast passed)
}