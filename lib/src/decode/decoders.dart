import '../types.dart';
import '../utilities/constants.dart';
import '../utilities/string-utils.dart';
import 'parser.dart';
import 'scanners.dart';
import 'validation.dart';

// #region Entry decoding

/// Decodes a value from lines.
///
/// Per TOON spec §5 (Root form determination):
/// - Empty document → empty object {}
/// - First non-empty depth-0 line is array header → root array
/// - Exactly one non-empty line, not header or key-value → single primitive
/// - Otherwise → object
/// - In strict mode, multiple primitives at root is invalid
JsonValue decodeValueFromLines(
    LineCursor cursor, ResolvedDecodeOptions options) {
  final first = cursor.peek();
  if (first == null) {
    // Empty document decodes to empty object
    return <String, JsonValue>{};
  }

  // Check for root array header (must start with [ with no key prefix)
  // Per TOON spec §5: Root arrays have headers like [N]: or [N]{fields}:
  // Headers with key prefixes like "key[N]:" are object fields, not root arrays
  if (_isRootArrayHeader(first.content)) {
    final headerInfo = parseArrayHeaderLine(first.content, DEFAULT_DELIMITER);
    if (headerInfo != null) {
      cursor.advance(); // Move past the header line
      return decodeArrayFromHeader(
          headerInfo.header, headerInfo.inlineValues, cursor, 0, options);
    }
  }

  // Check for single primitive value (exactly one line, not a key-value or header)
  // Per TOON spec §5: A single line that is neither a valid array header nor a key-value line
  // decodes as a single primitive. Array headers with key prefixes (like "items[5]:") are
  // key-value lines where the value is an array, so they should NOT be treated as primitives.
  if (cursor.length == 1 &&
      !isKeyValueLine(first) &&
      !_isArrayHeaderLine(first.content)) {
    return parsePrimitiveToken(first.content.trim());
  }

  // In strict mode, check for multiple primitives at root (invalid)
  // We'll detect this during object decoding instead of pre-scanning

  // Default to object
  return decodeObject(cursor, 0, options);
}

/// Checks if a line is an array header (with or without key prefix).
bool _isArrayHeaderLine(String content) {
  final trimmed = content.trim();
  // Root array starts with [
  if (trimmed.startsWith('[')) {
    return trimmed.contains(']') && trimmed.contains(':');
  }
  // Named array: key[...]
  // Find the first [ that's not inside quotes
  final bracketPos = findUnquotedChar(trimmed, '[');
  if (bracketPos == -1) return false;
  final colonPos = findUnquotedChar(trimmed, ':');
  return colonPos != -1 && colonPos > bracketPos;
}

/// Checks if a line is a root array header (no key prefix).
/// Per TOON spec §5: Root arrays start with [ at depth 0.
bool _isRootArrayHeader(String content) {
  final trimmed = content.trim();
  // Must start with [ (no key prefix)
  if (!trimmed.startsWith('[')) {
    return false;
  }
  // Must contain ] and : to be a valid header
  return trimmed.contains(']') && trimmed.contains(':');
}

/// Checks if a line is a key-value line.
///
/// Per TOON spec §8: A key-value line has the form "key: value" or "key:" for nested objects.
/// This function distinguishes key-value lines from array headers and other structures.
bool isKeyValueLine(ParsedLine line) {
  final content = line.content.trim();

  // Empty content is not a key-value line
  if (content.isEmpty) {
    return false;
  }

  // Array headers contain brackets and are not key-value lines
  // (even if they have a key prefix like "items[2]:")
  if (_isArrayHeaderLine(content)) {
    return false;
  }

  // Look for unquoted colon
  final colonPos = findUnquotedChar(content, COLON);
  if (colonPos == -1) {
    return false;
  }

  // There must be content before the colon (the key)
  if (colonPos == 0) {
    return false;
  }

  // Extract the key part and validate it
  final keyPart = content.substring(0, colonPos).trim();

  // Key cannot be empty
  if (keyPart.isEmpty) {
    return false;
  }

  // Valid key: either quoted or matches unquoted key pattern
  if (keyPart.startsWith(DOUBLE_QUOTE)) {
    // Quoted key - must have closing quote
    final closingQuoteIndex = findClosingQuote(keyPart, 0);
    return closingQuoteIndex != -1 && closingQuoteIndex == keyPart.length - 1;
  } else {
    // Unquoted key - use optimized validation (no regex)
    // Per TOON spec §7.3: ^[A-Za-z_][A-Za-z0-9_.]*$
    return isValidUnquotedKey(keyPart);
  }
}

// #endregion

// #region Object decoding

/// Decodes an object from lines.
JsonObject decodeObject(
    LineCursor cursor, Depth baseDepth, ResolvedDecodeOptions options) {
  final obj = <String, JsonValue>{};

  // Detect the actual depth of the first field (may differ from baseDepth in nested structures)
  Depth? computedDepth;

  while (!cursor.atEnd()) {
    final line = cursor.peek();
    if (line == null || line.depth < baseDepth) {
      break;
    }

    if (computedDepth == null && line.depth >= baseDepth) {
      computedDepth = line.depth;
    }

    if (computedDepth != null && line.depth == computedDepth) {
      final pair = decodeKeyValuePair(line, cursor, computedDepth, options);
      obj[pair.key] = pair.value;
    } else {
      // Different depth (shallower or deeper) - stop object parsing
      break;
    }
  }

  return obj;
}

/// Decodes a key-value pair from content.
KeyValueResult decodeKeyValue(
  String content,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  // Check for array header first (before parsing key)
  final arrayHeader = parseArrayHeaderLine(content, DEFAULT_DELIMITER);
  if (arrayHeader != null && arrayHeader.header.key != null) {
    // For tabular arrays, rows are at baseDepth + 1 (standard case)
    // For list-item objects with tabular first field (§10), rows are at baseDepth + 2
    // The caller should adjust baseDepth accordingly if needed
    final value = decodeArrayFromHeader(arrayHeader.header,
        arrayHeader.inlineValues, cursor, baseDepth, options);
    // After an array, subsequent fields are at baseDepth + 1
    return KeyValueResult(
      key: arrayHeader.header.key!,
      value: value,
      followDepth: baseDepth + 1,
    );
  }

  // Regular key-value pair
  final keyToken = parseKeyToken(content, 0);
  final rest = content.substring(keyToken.end).trim();

  // No value after colon - expect nested object or empty
  if (rest.isEmpty) {
    final nextLine = cursor.peek();
    if (nextLine != null && nextLine.depth > baseDepth) {
      final nested = decodeObject(cursor, baseDepth + 1, options);
      return KeyValueResult(
          key: keyToken.key, value: nested, followDepth: baseDepth + 1);
    }
    // Empty object
    return KeyValueResult(
        key: keyToken.key,
        value: const <String, JsonValue>{},
        followDepth: baseDepth + 1);
  }

  // Inline primitive value
  final value = parsePrimitiveToken(rest);
  return KeyValueResult(
      key: keyToken.key, value: value, followDepth: baseDepth + 1);
}

/// Decodes a key-value pair from a line.
KeyValuePairResult decodeKeyValuePair(
  ParsedLine line,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  cursor.advance();
  final result = decodeKeyValue(line.content, cursor, baseDepth, options);
  return KeyValuePairResult(key: result.key, value: result.value);
}

// #endregion

// #region Array decoding

/// Decodes an array from a header.
JsonArray decodeArrayFromHeader(
  ArrayHeaderInfo header,
  String? inlineValues,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  // Inline primitive array
  if (inlineValues != null) {
    // For inline arrays, cursor should already be advanced or will be by caller
    return decodeInlinePrimitiveArray(header, inlineValues, options);
  }

  // For multi-line arrays (tabular or list), the cursor should already be positioned
  // at the array header line, but we haven't advanced past it yet

  // Tabular array
  if (header.fields != null && header.fields!.isNotEmpty) {
    return decodeTabularArray(header, cursor, baseDepth, options);
  }

  // List array
  return decodeListArray(header, cursor, baseDepth, options);
}

/// Decodes an inline primitive array.
List<JsonPrimitive> decodeInlinePrimitiveArray(
  ArrayHeaderInfo header,
  String inlineValues,
  ResolvedDecodeOptions options,
) {
  if (inlineValues.trim().isEmpty) {
    assertExpectedCount(0, header.length, 'inline array items', options);
    return [];
  }

  final values = parseDelimitedValues(inlineValues, header.delimiter);
  final primitives = mapRowValuesToPrimitives(values);

  assertExpectedCount(
      primitives.length, header.length, 'inline array items', options);

  return primitives;
}

/// Decodes a list array.
List<JsonValue> decodeListArray(
  ArrayHeaderInfo header,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  final items = <JsonValue>[];
  final itemDepth = baseDepth + 1;

  // Track line range for blank line validation
  int? startLine;
  int? endLine;

  while (!cursor.atEnd() && items.length < header.length) {
    final line = cursor.peek();
    if (line == null || line.depth < itemDepth) {
      break;
    }

    // Check for list item (with or without space after hyphen)
    final isListItem =
        line.content.startsWith(LIST_ITEM_PREFIX) || line.content == '-';

    if (line.depth == itemDepth && isListItem) {
      // Track first and last item line numbers
      if (startLine == null) {
        startLine = line.lineNumber;
      }
      endLine = line.lineNumber;

      final item = decodeListItem(cursor, itemDepth, options);
      items.add(item);

      // Update endLine to the current cursor position (after item was decoded)
      final currentLine = cursor.current();
      if (currentLine != null) {
        endLine = currentLine.lineNumber;
      }
    } else {
      break;
    }
  }

  assertExpectedCount(items.length, header.length, 'list array items', options);

  // In strict mode, check for blank lines inside the array
  if (options.strict && startLine != null && endLine != null) {
    validateNoBlankLinesInRange(
      startLine, // From first item line
      endLine, // To last item line
      cursor.getBlankLines(),
      options.strict,
      'list array',
    );
  }

  // In strict mode, check for extra items
  if (options.strict) {
    validateNoExtraListItems(cursor, itemDepth, header.length);
  }

  return items;
}

/// Decodes a tabular array.
///
/// Per TOON spec §9.3: Rows appear at depth +1 under the header.
/// Per TOON spec §10: When inside a list-item object with tabular first field,
/// rows appear at depth +2 relative to the hyphen line.
List<JsonObject> decodeTabularArray(
  ArrayHeaderInfo header,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  final objects = <JsonObject>[];
  // Rows are at baseDepth + 1 (standard case)
  // When called from list-item context, baseDepth is already adjusted
  final rowDepth = baseDepth + 1;

  // Track line range for blank line validation
  int? startLine;
  int? endLine;

  while (!cursor.atEnd() && objects.length < header.length) {
    final line = cursor.peek();
    if (line == null || line.depth < rowDepth) {
      break;
    }

    if (line.depth == rowDepth) {
      // Per TOON spec §9.3: Disambiguation at row depth
      // Check if this line is a row or a key-value line
      if (_isKeyValueLine(line.content, header.delimiter)) {
        // This is a key-value line, end of tabular rows
        break;
      }

      // Track first and last row line numbers
      startLine ??= line.lineNumber;
      endLine = line.lineNumber;

      cursor.advance();
      final values = parseDelimitedValues(line.content, header.delimiter);
      assertExpectedCount(
          values.length, header.fields!.length, 'tabular row values', options);

      final primitives = mapRowValuesToPrimitives(values);
      final obj = <String, JsonValue>{};

      for (int i = 0; i < header.fields!.length; i++) {
        obj[header.fields![i]] = primitives[i];
      }

      objects.add(obj);
    } else if (line.depth > rowDepth) {
      // Deeper indentation - shouldn't happen in valid tabular arrays
      // Skip or break depending on strict mode
      break;
    } else {
      // Shallower depth - end of array
      break;
    }
  }

  assertExpectedCount(objects.length, header.length, 'tabular rows', options);

  // In strict mode, check for blank lines inside the array
  if (options.strict && startLine != null && endLine != null) {
    validateNoBlankLinesInRange(
      startLine, // From first row line
      endLine, // To last row line
      cursor.getBlankLines(),
      options.strict,
      'tabular array',
    );
  }

  // In strict mode, check for extra rows
  if (options.strict) {
    validateNoExtraTabularRows(cursor, rowDepth, header);
  }

  return objects;
}

/// Checks if a line is a key-value pair (not a tabular row).
///
/// Per TOON spec §9.3: Compare first-unquoted positions of delimiter and colon.
/// - Delimiter before colon → row
/// - Colon before delimiter → key-value line
bool _isKeyValueLine(String content, String delimiter) {
  final colonPos = findUnquotedChar(content, COLON);
  final delimiterPos = findUnquotedChar(content, delimiter);

  // No colon = definitely a row
  if (colonPos == -1) {
    return false;
  }

  // Has delimiter and it comes before colon = row
  if (delimiterPos != -1 && delimiterPos < colonPos) {
    return false;
  }

  // Colon before delimiter or no delimiter = key-value line
  return true;
}

// #endregion

// #region List item decoding

/// Decodes a list item.
JsonValue decodeListItem(
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  final line = cursor.next();
  if (line == null) {
    throw StateError('Expected list item');
  }

  // Check for list item (with or without space after hyphen)
  String afterHyphen;

  // Empty list item should be an empty object
  if (line.content == '-') {
    return <String, JsonValue>{};
  } else if (line.content.startsWith(LIST_ITEM_PREFIX)) {
    afterHyphen = line.content.substring(LIST_ITEM_PREFIX.length);
  } else {
    throw FormatException(
        'Expected list item to start with "$LIST_ITEM_PREFIX"');
  }

  // Empty content after list item should also be an empty object
  if (afterHyphen.trim().isEmpty) {
    return <String, JsonValue>{};
  }

  // Check for array header after hyphen
  if (isArrayHeaderAfterHyphen(afterHyphen)) {
    final arrayHeader = parseArrayHeaderLine(afterHyphen, DEFAULT_DELIMITER);
    if (arrayHeader != null) {
      return decodeArrayFromHeader(arrayHeader.header, arrayHeader.inlineValues,
          cursor, baseDepth, options);
    }
  }

  // Check for object first field after hyphen
  if (isObjectFirstFieldAfterHyphen(afterHyphen)) {
    return decodeObjectFromListItem(line, cursor, baseDepth, options);
  }

  // Primitive value
  return parsePrimitiveToken(afterHyphen);
}

/// Decodes an object from a list item.
///
/// Per TOON spec §10: When a list-item object has a tabular array as its first field,
/// the tabular header appears on the hyphen line, rows at depth +2, other fields at depth +1.
JsonObject decodeObjectFromListItem(
  ParsedLine firstLine,
  LineCursor cursor,
  Depth baseDepth,
  ResolvedDecodeOptions options,
) {
  final afterHyphen = firstLine.content.substring(LIST_ITEM_PREFIX.length);

  // Check if first field is an array to adjust depth
  final arrayHeader = parseArrayHeaderLine(afterHyphen, DEFAULT_DELIMITER);
  final isArrayFirstField = arrayHeader != null;

  // Per TOON spec §10: When first field of list-item object is an array,
  // array contents (rows or items) are at depth +2 from hyphen line.
  // We pass baseDepth + 1 so that decodeArrayFromHeader (which looks for
  // contents at passedDepth + 1) finds them at baseDepth + 2.
  final adjustedDepth = isArrayFirstField ? baseDepth + 1 : baseDepth;
  final result = decodeKeyValue(afterHyphen, cursor, adjustedDepth, options);

  final obj = <String, JsonValue>{result.key: result.value};

  // Subsequent fields are at depth +1 from hyphen line
  final siblingDepth = baseDepth + 1;

  // Read subsequent fields
  while (!cursor.atEnd()) {
    final line = cursor.peek();
    if (line == null || line.depth < siblingDepth) {
      break;
    }

    if (line.depth == siblingDepth &&
        !line.content.startsWith(LIST_ITEM_PREFIX)) {
      // Check if this is a key-value line (not a tabular row)
      // Tabular rows would be at depth +2, so we only process depth +1 here
      final pair = decodeKeyValuePair(line, cursor, siblingDepth, options);
      obj[pair.key] = pair.value;
    } else if (line.depth > siblingDepth) {
      // Deeper lines are part of nested structures (like tabular rows)
      // They should have been handled by decodeKeyValue already
      break;
    } else {
      break;
    }
  }

  return obj;
}

// #endregion
