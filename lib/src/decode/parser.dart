import '../types.dart';
import '../utilities/constants.dart';
import '../utilities/literal-utils.dart';
import '../utilities/string-utils.dart';

// Pre-compiled regexes for performance
final _numericLiteralRegex = RegExp(r'^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$');
final _leadingZeroCheckRegex = RegExp(r'^0\d+$');

// #region Array header parsing

/// Parses an array header line.
///
/// Per TOON spec §6: Between the closing bracket `]` of the bracket segment
/// and the opening brace `{` of a fields segment (or the colon `:` if no fields
/// segment is present), only whitespace MAY appear. If a decoder encounters
/// non-whitespace content in these positions, the line MUST NOT be interpreted
/// as an array header.
ArrayHeaderParseResult? parseArrayHeaderLine(
  String content,
  String defaultDelimiter,
) {
  final trimmed = content.trimLeft();

  // Find the bracket segment, accounting for quoted keys that may contain brackets
  int bracketStart = -1;

  // For quoted keys, find bracket after closing quote (not inside the quoted string)
  if (trimmed.startsWith(DOUBLE_QUOTE)) {
    final closingQuoteIndex = findClosingQuote(trimmed, 0);
    if (closingQuoteIndex == -1) {
      return null;
    }

    final afterQuote = trimmed.substring(closingQuoteIndex + 1);
    if (!afterQuote.startsWith(OPEN_BRACKET)) {
      return null;
    }

    // Calculate position in original content and find bracket after the quoted key
    final leadingWhitespace = content.length - trimmed.length;
    final keyEndIndex = leadingWhitespace + closingQuoteIndex + 1;
    bracketStart = content.indexOf(OPEN_BRACKET, keyEndIndex);
  } else {
    // Unquoted key - find first bracket
    bracketStart = content.indexOf(OPEN_BRACKET);
  }

  if (bracketStart == -1) {
    return null;
  }

  final bracketEnd = content.indexOf(CLOSE_BRACKET, bracketStart);
  if (bracketEnd == -1) {
    return null;
  }

  // Check for fields segment (braces come after bracket)
  final braceStart = content.indexOf(OPEN_BRACE, bracketEnd);
  int braceEnd = bracketEnd;

  if (braceStart != -1) {
    // Check if brace comes before any colon
    final colonAfterBracket = content.indexOf(COLON, bracketEnd);
    if (colonAfterBracket != -1 && braceStart < colonAfterBracket) {
      final foundBraceEnd = content.indexOf(CLOSE_BRACE, braceStart);
      if (foundBraceEnd != -1) {
        braceEnd = foundBraceEnd + 1;
      }
    } else {
      // Brace is after colon or no colon found - not a valid fields segment
      // Continue without fields segment
    }
  }

  // Per TOON spec §6: Check for non-whitespace between bracket and brace/colon
  // Between ] and { (or : if no {), only whitespace is allowed

  // Find the colon position
  final searchStart =
      braceStart != -1 && braceStart > bracketEnd ? braceEnd : bracketEnd + 1;
  final colonIndex = content.indexOf(COLON, searchStart);

  if (colonIndex == -1) {
    return null;
  }

  // Check content between bracket end and colon (excluding fields segment if present)
  if (braceStart != -1 && braceStart > bracketEnd && braceEnd > braceStart) {
    // Check between ] and {
    final betweenBracketAndBrace =
        content.substring(bracketEnd + 1, braceStart);
    if (betweenBracketAndBrace.trim().isNotEmpty) {
      // Non-whitespace between bracket and brace - not a valid header
      return null;
    }
    // Check between } and :
    final betweenBraceAndColon = content.substring(braceEnd, colonIndex);
    if (betweenBraceAndColon.trim().isNotEmpty) {
      // Non-whitespace between brace and colon - not a valid header
      return null;
    }
  } else {
    // No fields segment - check between ] and :
    final betweenBracketAndColon =
        content.substring(bracketEnd + 1, colonIndex);
    if (betweenBracketAndColon.trim().isNotEmpty) {
      // Non-whitespace between bracket and colon - not a valid header
      return null;
    }
  }

  // Extract and parse the key (might be quoted)
  String? key;
  if (bracketStart > 0) {
    final rawKey = content.substring(0, bracketStart).trim();
    key = rawKey.startsWith(DOUBLE_QUOTE) ? parseStringLiteral(rawKey) : rawKey;
  }

  final afterColon = content.substring(colonIndex + 1).trim();

  final bracketContent = content.substring(bracketStart + 1, bracketEnd);

  // Try to parse bracket segment
  BracketSegmentResult parsedBracket;
  try {
    parsedBracket = parseBracketSegment(bracketContent, defaultDelimiter);
  } catch (e) {
    return null;
  }

  final length = parsedBracket.length;
  final delimiter = parsedBracket.delimiter;
  final hasLengthMarker = parsedBracket.hasLengthMarker;

  // Check for fields segment
  List<String>? fields;
  if (braceStart != -1 && braceStart > bracketEnd && braceEnd > braceStart) {
    final foundBraceEnd = content.indexOf(CLOSE_BRACE, braceStart);
    if (foundBraceEnd != -1 && foundBraceEnd < colonIndex) {
      final fieldsContent = content.substring(braceStart + 1, foundBraceEnd);
      fields = parseDelimitedValues(fieldsContent, delimiter)
          .map((field) => parseStringLiteral(field.trim()))
          .toList();

      // Per TOON spec §6: Validate delimiter consistency between bracket and fields
      // The delimiter in fields segment must match the bracket delimiter
      // This is enforced by using the same delimiter for parsing
    }
  }

  return ArrayHeaderParseResult(
    header: ArrayHeaderInfo(
      key: key,
      length: length,
      delimiter: delimiter,
      fields: fields,
      hasLengthMarker: hasLengthMarker,
    ),
    inlineValues: afterColon.isEmpty ? null : afterColon,
  );
}

/// Parses a bracket segment.
BracketSegmentResult parseBracketSegment(
  String seg,
  String defaultDelimiter,
) {
  bool hasLengthMarker = false;
  String content = seg;

  // Check for length marker
  if (content.startsWith(HASH)) {
    hasLengthMarker = true;
    content = content.substring(1);
  }

  // Check for delimiter suffix
  String delimiter = defaultDelimiter;
  if (content.endsWith(TAB)) {
    delimiter = TAB;
    content = content.substring(0, content.length - 1);
  } else if (content.endsWith(PIPE)) {
    delimiter = PIPE;
    content = content.substring(0, content.length - 1);
  }

  final length = int.tryParse(content);
  if (length == null) {
    throw FormatException('Invalid array length: $seg');
  }

  return BracketSegmentResult(
    length: length,
    delimiter: delimiter,
    hasLengthMarker: hasLengthMarker,
  );
}

// #endregion

// #region Delimited value parsing

/// Parses delimited values from a string.
List<String> parseDelimitedValues(String input, String delimiter) {
  final values = <String>[];
  final current = StringBuffer();
  bool inQuotes = false;
  int i = 0;

  while (i < input.length) {
    final char = input[i];

    if (char == BACKSLASH && i + 1 < input.length && inQuotes) {
      // Escape sequence in quoted string
      current.write(char);
      current.write(input[i + 1]);
      i += 2;
      continue;
    }

    if (char == DOUBLE_QUOTE) {
      inQuotes = !inQuotes;
      current.write(char);
      i++;
      continue;
    }

    if (char == delimiter && !inQuotes) {
      values.add(current.toString().trim());
      current.clear();
      i++;
      continue;
    }

    current.write(char);
    i++;
  }

  // Add last value
  if (current.isNotEmpty || values.isNotEmpty) {
    values.add(current.toString().trim());
  }

  return values;
}

/// Maps row values to primitives.
List<JsonPrimitive> mapRowValuesToPrimitives(List<String> values) {
  return values.map((v) => parsePrimitiveToken(v)).toList();
}

// #endregion

// #region Primitive and key parsing

/// Parses a primitive token.
/// Optimized with pre-compiled regexes and efficient string operations.
JsonPrimitive parsePrimitiveToken(String token) {
  // Trim efficiently
  final trimmed = token.trim();

  // Empty token
  if (trimmed.isEmpty) {
    return '';
  }

  // Quoted string (if starts with quote, it MUST be properly quoted)
  if (trimmed.codeUnitAt(0) == 0x22) {
    // '"'
    return parseStringLiteral(trimmed);
  }

  // Boolean or null literals - check first char for quick rejection
  final firstChar = trimmed.codeUnitAt(0);
  if (firstChar == 0x74 || firstChar == 0x66 || firstChar == 0x6E) {
    // 't', 'f', 'n'
    if (trimmed == TRUE_LITERAL) return true;
    if (trimmed == FALSE_LITERAL) return false;
    if (trimmed == NULL_LITERAL) return null;
  }

  // Numeric literal - optimized check
  if (_isNumericLiteralFast(trimmed)) {
    final parsedNumber = double.parse(trimmed);
    // Normalize negative zero to positive zero
    return parsedNumber == 0.0 ? 0 : parsedNumber;
  }

  // Unquoted string
  return trimmed;
}

/// Fast numeric literal check with pre-compiled regex
bool _isNumericLiteralFast(String token) {
  if (token.isEmpty) return false;

  // Quick check for forbidden leading zeros
  // Handle both positive (05) and negative (-05) cases
  int startIndex = 0;
  if (token.codeUnitAt(0) == 0x2D || token.codeUnitAt(0) == 0x2B) {
    // '-' or '+'
    startIndex = 1;
  }

  if (token.length > startIndex + 1 && token.codeUnitAt(startIndex) == 0x30) {
    // '0'
    final secondChar = token.codeUnitAt(startIndex + 1);
    if (secondChar != 0x2E && secondChar != 0x65 && secondChar != 0x45) {
      // '.', 'e', 'E'
      return false;
    }
  }

  // Use pre-compiled regex
  return _numericLiteralRegex.hasMatch(token);
}

/// Parses a string literal.
String parseStringLiteral(String token) {
  final trimmedToken = token.trim();

  if (trimmedToken.startsWith(DOUBLE_QUOTE)) {
    // Find the closing quote, accounting for escaped quotes
    final closingQuoteIndex = findClosingQuote(trimmedToken, 0);

    if (closingQuoteIndex == -1) {
      // No closing quote was found
      throw FormatException('Unterminated string: missing closing quote');
    }

    if (closingQuoteIndex != trimmedToken.length - 1) {
      throw FormatException('Unexpected characters after closing quote');
    }

    final content = trimmedToken.substring(1, closingQuoteIndex);
    return unescapeString(content);
  }

  return trimmedToken;
}

/// Parses an unquoted key.
KeyTokenResult parseUnquotedKey(String content, int start) {
  int end = start;
  while (end < content.length && content[end] != COLON) {
    end++;
  }

  // Validate that a colon was found
  if (end >= content.length || content[end] != COLON) {
    throw FormatException('Missing colon after key');
  }

  final key = content.substring(start, end).trim();

  // Skip the colon
  end++;

  return KeyTokenResult(key: key, end: end);
}

/// Parses a quoted key.
KeyTokenResult parseQuotedKey(String content, int start) {
  // Find the closing quote, accounting for escaped quotes
  final closingQuoteIndex = findClosingQuote(content, start);

  if (closingQuoteIndex == -1) {
    throw FormatException('Unterminated quoted key');
  }

  // Extract and unescape the key content
  final keyContent = content.substring(start + 1, closingQuoteIndex);
  final key = unescapeString(keyContent);
  int end = closingQuoteIndex + 1;

  // Validate and skip colon after quoted key
  if (end >= content.length || content[end] != COLON) {
    throw FormatException('Missing colon after key');
  }
  end++;

  return KeyTokenResult(key: key, end: end);
}

/// Parses a key token (quoted or unquoted).
KeyTokenResult parseKeyToken(String content, int start) {
  if (content[start] == DOUBLE_QUOTE) {
    return parseQuotedKey(content, start);
  } else {
    return parseUnquotedKey(content, start);
  }
}

// #endregion

// #region Array content detection helpers

/// Checks if content is an array header after a hyphen.
/// Optimized with efficient string operations.
bool isArrayHeaderAfterHyphen(String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty || trimmed.codeUnitAt(0) != 0x5B) {
    // '['
    return false;
  }
  return findUnquotedChar(content, COLON) != -1;
}

/// Checks if content is an object first field after a hyphen.
bool isObjectFirstFieldAfterHyphen(String content) {
  return findUnquotedChar(content, COLON) != -1;
}

// #endregion
