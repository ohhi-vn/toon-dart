import '../utilities/constants.dart';
import '../decode/parser.dart';

/// Checks if a token is a boolean or null literal (`true`, `false`, `null`).
bool isBooleanOrNullLiteral(String token) {
  return token == TRUE_LITERAL ||
      token == FALSE_LITERAL ||
      token == NULL_LITERAL;
}

/// Checks if a token represents a valid numeric literal.
///
/// Optimized: uses fast code unit state machine instead of double.tryParse.
/// The tryParse approach is ~5-10x slower due to parsing overhead.
bool isNumericLiteral(String token) {
  if (token.isEmpty) return false;

  // Use the fast code unit state machine (now public API)
  if (!isNumericLiteralFast(token)) return false;

  // Additional check: must not have forbidden leading zeros
  // (The state machine in parser already handles this, but let's be explicit)
  String checkToken = token;
  if (checkToken.startsWith('-')) {
    checkToken = checkToken.substring(1);
  }

  // If starts with 0 and has more characters
  if (checkToken.length > 1 && checkToken[0] == '0') {
    final secondChar = checkToken[1];
    // Valid: 0.5 (decimal), 0e1 or 0E1 (exponent)
    // Invalid: 05, 007 (forbidden leading zeros)
    if (secondChar != '.' && secondChar != 'e' && secondChar != 'E') {
      return false;
    }
  }

  return true;
}
