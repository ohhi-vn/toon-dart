import '../utilities/constants.dart';

/// Checks if a token is a boolean or null literal (`true`, `false`, `null`).
bool isBooleanOrNullLiteral(String token) {
  return token == TRUE_LITERAL ||
      token == FALSE_LITERAL ||
      token == NULL_LITERAL;
}

/// Checks if a token represents a valid numeric literal.
///
/// Rejects numbers with leading zeros (except `"0"` itself or decimals like `"0.5"`).
bool isNumericLiteral(String token) {
  if (token.isEmpty) return false;

  // Check if it's a valid number first
  final numericValue = double.tryParse(token);
  if (numericValue == null || !numericValue.isFinite) {
    return false;
  }

  // Must not have forbidden leading zeros (e.g., "05", "0001", "-05")
  // Exception: single zero followed by decimal point or exponent is valid (e.g., "0.5", "0e1", "-0e1")
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
