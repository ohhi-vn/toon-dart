import '../utilities/constants.dart';
import 'literal-utils.dart';

// Pre-compiled regexes for performance
final _validUnquotedKeyRegex = RegExp(r'^[A-Z_][\w.]*$', caseSensitive: false);
final _bracketsBracesRegex = RegExp(r'[[\]{}]');
final _controlCharsRegex = RegExp(r'[\n\r\t]');
final _numericLikeRegex =
    RegExp(r'^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$', caseSensitive: false);
final _leadingZeroRegex = RegExp(r'^0\d+$');

/// Checks if a key can be used without quotes.
///
/// Valid unquoted keys must start with a letter or underscore,
/// followed by letters, digits, underscores, or dots.
bool isValidUnquotedKey(String key) {
  return _validUnquotedKeyRegex.hasMatch(key);
}

/// Determines if a string value can be safely encoded without quotes.
///
/// A string needs quoting if it:
/// - Is empty
/// - Has leading or trailing whitespace
/// - Could be confused with a literal (boolean, null, number)
/// - Contains structural characters (colons, brackets, braces)
/// - Contains quotes or backslashes (need escaping)
/// - Contains control characters (newlines, tabs, etc.)
/// - Contains the active delimiter
/// - Starts with a list marker (hyphen)
bool isSafeUnquoted(String value, [String delimiter = COMMA]) {
  if (value.isEmpty) {
    return false;
  }

  // Check for leading/trailing whitespace efficiently
  final firstChar = value.codeUnitAt(0);
  final lastChar = value.codeUnitAt(value.length - 1);
  if (firstChar <= 0x20 || lastChar <= 0x20) {
    return false;
  }

  // Check if it looks like any literal value (boolean, null, or numeric)
  if (isBooleanOrNullLiteral(value) || isNumericLike(value)) {
    return false;
  }

  // Check for structural characters and special chars efficiently
  for (int i = 0; i < value.length; i++) {
    final char = value.codeUnitAt(i);
    switch (char) {
      case 0x3A: // ':'
      case 0x22: // '"'
      case 0x5C: // '\\'
      case 0x5B: // '['
      case 0x5D: // ']'
      case 0x7B: // '{'
      case 0x7D: // '}'
      case 0x0A: // '\n'
      case 0x0D: // '\r'
      case 0x09: // '\t'
        return false;
    }
  }

  // Check for the active delimiter
  if (value.contains(delimiter)) {
    return false;
  }

  // Check for hyphen at start (list marker)
  if (firstChar == 0x2D) {
    // '-'
    return false;
  }

  return true;
}

/// Checks if a string looks like a number.
///
/// Match numbers like `42`, `-3.14`, `1e-6`, `05`, etc.
bool isNumericLike(String value) {
  return _numericLikeRegex.hasMatch(value) || _leadingZeroRegex.hasMatch(value);
}
