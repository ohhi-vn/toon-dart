/// Stream decoder for TOON format — lazy decoding of large payloads.
///
/// Instead of parsing the entire document upfront and allocating all objects
/// in memory, the stream decoder yields items one at a time. This provides:
///
/// - **Lower memory usage**: Only one item in memory at a time
/// - **Faster first-item latency**: Start processing before full parse
/// - **Phoenix Channels streaming**: Works great with chunked responses
/// - **Isolate-friendly**: Can be run in a separate isolate for heavy payloads
///
/// Usage:
/// ```dart
/// // Stream tabular rows one at a time
/// final stream = ToonStreamDecoder(data);
/// for (final row in stream.decodeTabularRows()) {
///   process(row);  // handle each row without loading all into memory
/// }
///
/// // Schema-based streaming (fastest path)
/// final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
/// for (final row in stream.decodeTabularRowsWithSchema(schema)) {
///   process(row);  // direct field access, no key parsing
/// }
///
/// // Async streaming for isolate usage
/// await for (final row in stream.decodeTabularRowsAsync()) {
///   process(row);
/// }
/// ```
library stream_decoder;

import '../types.dart';
import '../utilities/constants.dart';
import '../utilities/string-utils.dart';
import '../decode/scanners.dart';
import '../decode/parser.dart';
import '../schema/toon_schema.dart';

// #region Stream Decoder

/// Lazy stream decoder for TOON format.
///
/// Parses the document incrementally, yielding decoded items as they
/// become available. This avoids allocating the entire decoded structure
/// in memory at once.
///
/// The decoder operates in two phases:
/// 1. **Header phase**: Parse the array header to determine structure
/// 2. **Row phase**: Yield rows one at a time using a generator
///
/// For tabular arrays, each row is decoded independently and yielded
/// immediately. For list arrays, each list item is decoded and yielded.
///
/// Memory usage is O(1) per item (not O(n) for the entire array).
class ToonStreamDecoder {
  final String _source;
  final int _indentSize;
  final bool _strict;

  /// Pre-parsed lines (lazily initialized on first access).
  ScanResult? _scanResult;

  ToonStreamDecoder(
    this._source, {
    int indentSize = 2,
    bool strict = true,
  })  : _indentSize = indentSize,
        _strict = strict;

  /// Gets the scan result, initializing lazily.
  ScanResult get _lines {
    return _scanResult ??= toParsedLines(_source, _indentSize, _strict);
  }

  // #region Tabular Row Streaming

  /// Streams tabular rows from a TOON document.
  ///
  /// Yields each row as a `Map<String, dynamic>` as it's parsed.
  /// The header must be the first non-empty line in the document.
  ///
  /// If the document contains multiple arrays, only the first tabular
  /// array is streamed. Use [decodeTabularRowsAt] for a specific key.
  ///
  /// Example:
  /// ```dart
  /// final stream = ToonStreamDecoder(toonData);
  /// for (final row in stream.decodeTabularRows()) {
  ///   print(row);  // {'id': 1, 'name': 'A', 'age': 20}
  /// }
  /// ```
  Iterable<Map<String, dynamic>> decodeTabularRows() sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);
    final options = ResolvedDecodeOptions(indent: _indentSize, strict: _strict);

    // Find the first tabular array header
    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null && headerResult.header.fields != null) {
        cursor.advance();

        // Yield rows from this tabular array
        yield* _streamTabularRows(
          cursor,
          headerResult.header,
          options,
        );
        return;
      }

      cursor.advance();
    }
  }

  /// Streams tabular rows for a specific key.
  ///
  /// Searches for an array header with the given [key] and streams
  /// its rows. Useful when the document contains multiple arrays.
  Iterable<Map<String, dynamic>> decodeTabularRowsAt(String key) sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);
    final options = ResolvedDecodeOptions(indent: _indentSize, strict: _strict);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null &&
          headerResult.header.key == key &&
          headerResult.header.fields != null) {
        cursor.advance();

        yield* _streamTabularRows(
          cursor,
          headerResult.header,
          options,
        );
        return;
      }

      cursor.advance();
    }
  }

  /// Streams tabular rows using a schema (fastest path).
  ///
  /// Uses the schema for direct field name mapping, skipping
  /// header field parsing. This is the fastest streaming decode path.
  ///
  /// Example:
  /// ```dart
  /// final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
  /// final stream = ToonStreamDecoder(toonData);
  /// for (final row in stream.decodeTabularRowsWithSchema(schema)) {
  ///   print(row);  // direct field access, no key parsing
  /// }
  /// ```
  Iterable<Map<String, dynamic>> decodeTabularRowsWithSchema(
    ToonSchema schema,
  ) sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);
    final options = ResolvedDecodeOptions(indent: _indentSize, strict: _strict);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null && headerResult.header.fields != null) {
        cursor.advance();

        yield* _streamTabularRowsWithSchema(
          cursor,
          headerResult.header,
          schema,
          options,
        );
        return;
      }

      cursor.advance();
    }
  }

  /// Internal: streams tabular rows from cursor position.
  Iterable<Map<String, dynamic>> _streamTabularRows(
    LineCursor cursor,
    ArrayHeaderInfo header,
    ResolvedDecodeOptions options,
  ) sync* {
    final rowDepth = header.key != null ? 1 : 1;
    final fields = header.fields!;
    final delimiter = header.delimiter;
    int rowCount = 0;

    while (!cursor.atEnd() && rowCount < header.length) {
      final line = cursor.peek();
      if (line == null || line.depth < rowDepth) break;

      if (line.depth == rowDepth) {
        // Check if this is a key-value line (end of tabular rows)
        if (_isKeyValueLine(line.content, delimiter)) break;

        cursor.advance();
        final values = parseDelimitedValues(line.content, delimiter);
        final primitives = mapRowValuesToPrimitives(values);

        final obj = <String, dynamic>{};
        final count = fields.length < primitives.length
            ? fields.length
            : primitives.length;
        for (int i = 0; i < count; i++) {
          obj[fields[i]] = primitives[i];
        }

        yield obj;
        rowCount++;
      } else {
        break;
      }
    }
  }

  /// Internal: streams tabular rows with schema (direct field mapping).
  Iterable<Map<String, dynamic>> _streamTabularRowsWithSchema(
    LineCursor cursor,
    ArrayHeaderInfo header,
    ToonSchema schema,
    ResolvedDecodeOptions options,
  ) sync* {
    final rowDepth = header.key != null ? 1 : 1;
    final delimiter = header.delimiter;
    final fieldNames = schema.fieldNames;
    int rowCount = 0;

    while (!cursor.atEnd() && rowCount < header.length) {
      final line = cursor.peek();
      if (line == null || line.depth < rowDepth) break;

      if (line.depth == rowDepth) {
        if (_isKeyValueLine(line.content, delimiter)) break;

        cursor.advance();

        // Inline fast parsing — no intermediate list allocation
        final obj = <String, dynamic>{};
        _parseDelimitedIntoMap(line.content, delimiter, fieldNames, obj);

        yield obj;
        rowCount++;
      } else {
        break;
      }
    }
  }

  // #endregion

  // #region List Item Streaming

  /// Streams list items from a TOON document.
  ///
  /// Yields each item as a `dynamic` value (primitive, Map, or List).
  /// The header must be the first non-empty line in the document.
  Iterable<dynamic> decodeListItems() sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);
    final options = ResolvedDecodeOptions(indent: _indentSize, strict: _strict);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null) {
        cursor.advance();

        // Inline primitive array
        if (headerResult.inlineValues != null) {
          final values = parseDelimitedValues(
            headerResult.inlineValues!,
            headerResult.header.delimiter,
          );
          for (final v in mapRowValuesToPrimitives(values)) {
            yield v;
          }
          return;
        }

        // Tabular array
        if (headerResult.header.fields != null) {
          yield* _streamTabularRows(
            cursor,
            headerResult.header,
            options,
          );
          return;
        }

        // List array
        yield* _streamListItems(cursor, headerResult.header, options);
        return;
      }

      cursor.advance();
    }
  }

  /// Streams list items for a specific key.
  Iterable<dynamic> decodeListItemsAt(String key) sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);
    final options = ResolvedDecodeOptions(indent: _indentSize, strict: _strict);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null && headerResult.header.key == key) {
        cursor.advance();

        if (headerResult.inlineValues != null) {
          final values = parseDelimitedValues(
            headerResult.inlineValues!,
            headerResult.header.delimiter,
          );
          for (final v in mapRowValuesToPrimitives(values)) {
            yield v;
          }
          return;
        }

        if (headerResult.header.fields != null) {
          yield* _streamTabularRows(
            cursor,
            headerResult.header,
            options,
          );
          return;
        }

        yield* _streamListItems(cursor, headerResult.header, options);
        return;
      }

      cursor.advance();
    }
  }

  /// Internal: streams list items from cursor position.
  Iterable<dynamic> _streamListItems(
    LineCursor cursor,
    ArrayHeaderInfo header,
    ResolvedDecodeOptions options,
  ) sync* {
    final itemDepth = 1;
    int itemCount = 0;

    while (!cursor.atEnd() && itemCount < header.length) {
      final line = cursor.peek();
      if (line == null || line.depth < itemDepth) break;

      final isListItem =
          line.content.startsWith(LIST_ITEM_PREFIX) || line.content == '-';

      if (line.depth == itemDepth && isListItem) {
        cursor.advance();

        if (line.content == '-') {
          yield <String, dynamic>{};
          itemCount++;
          continue;
        }

        final afterHyphen = line.content.substring(LIST_ITEM_PREFIX.length);

        if (afterHyphen.trim().isEmpty) {
          yield <String, dynamic>{};
          itemCount++;
          continue;
        }

        // Check for array header after hyphen
        if (isArrayHeaderAfterHyphen(afterHyphen)) {
          final arrayHeader =
              parseArrayHeaderLine(afterHyphen, DEFAULT_DELIMITER);
          if (arrayHeader != null) {
            if (arrayHeader.inlineValues != null) {
              final values = parseDelimitedValues(
                arrayHeader.inlineValues!,
                arrayHeader.header.delimiter,
              );
              yield mapRowValuesToPrimitives(values);
            } else if (arrayHeader.header.fields != null) {
              // Yield tabular rows as individual objects
              final tabularRows = <Map<String, dynamic>>[];
              final rowDepth = itemDepth + 1;
              int rowCount = 0;

              while (!cursor.atEnd() && rowCount < arrayHeader.header.length) {
                final rowLine = cursor.peek();
                if (rowLine == null || rowLine.depth < rowDepth) break;

                if (rowLine.depth == rowDepth) {
                  if (_isKeyValueLine(
                      rowLine.content, arrayHeader.header.delimiter)) break;

                  cursor.advance();
                  final values = parseDelimitedValues(
                    rowLine.content,
                    arrayHeader.header.delimiter,
                  );
                  final primitives = mapRowValuesToPrimitives(values);
                  final obj = <String, dynamic>{};
                  final fields = arrayHeader.header.fields!;
                  final count = fields.length < primitives.length
                      ? fields.length
                      : primitives.length;
                  for (int i = 0; i < count; i++) {
                    obj[fields[i]] = primitives[i];
                  }
                  tabularRows.add(obj);
                  rowCount++;
                } else {
                  break;
                }
              }
              yield tabularRows;
            } else {
              yield <dynamic>[]; // Simplified for streaming
            }
            itemCount++;
            continue;
          }
        }

        // Check for object first field
        if (isObjectFirstFieldAfterHyphen(afterHyphen)) {
          // Parse a simple object from the list item
          final obj = <String, dynamic>{};
          final keyToken = parseKeyToken(afterHyphen, 0);
          final rest = afterHyphen.substring(keyToken.end).trim();

          if (rest.isEmpty) {
            obj[keyToken.key] = <String, dynamic>{};
          } else {
            obj[keyToken.key] = parsePrimitiveToken(rest);
          }

          // Read subsequent fields at depth + 1
          final siblingDepth = itemDepth + 1;
          while (!cursor.atEnd()) {
            final nextLine = cursor.peek();
            if (nextLine == null || nextLine.depth < siblingDepth) break;

            if (nextLine.depth == siblingDepth &&
                !nextLine.content.startsWith(LIST_ITEM_PREFIX)) {
              cursor.advance();
              final pairKeyToken = parseKeyToken(nextLine.content, 0);
              final pairRest =
                  nextLine.content.substring(pairKeyToken.end).trim();
              if (pairRest.isEmpty) {
                obj[pairKeyToken.key] = <String, dynamic>{};
              } else {
                obj[pairKeyToken.key] = parsePrimitiveToken(pairRest);
              }
            } else {
              break;
            }
          }

          yield obj;
          itemCount++;
          continue;
        }

        // Primitive value
        yield parsePrimitiveToken(afterHyphen);
        itemCount++;
      } else {
        break;
      }
    }
  }

  // #endregion

  // #region Async Streaming

  /// Async stream of tabular rows.
  ///
  /// Use with `await for` for isolate-friendly decoding.
  /// Each row is yielded asynchronously, allowing the event loop
  /// to process other events between rows.
  ///
  /// Example:
  /// ```dart
  /// final stream = ToonStreamDecoder(toonData);
  /// await for (final row in stream.decodeTabularRowsAsync()) {
  ///   process(row);
  /// }
  /// ```
  Stream<Map<String, dynamic>> decodeTabularRowsAsync() async* {
    for (final row in decodeTabularRows()) {
      yield row;
      // Allow event loop to process other events
      await Future.delayed(Duration.zero);
    }
  }

  /// Async stream of tabular rows with schema.
  Stream<Map<String, dynamic>> decodeTabularRowsWithSchemaAsync(
    ToonSchema schema,
  ) async* {
    for (final row in decodeTabularRowsWithSchema(schema)) {
      yield row;
      await Future.delayed(Duration.zero);
    }
  }

  /// Async stream of list items.
  Stream<dynamic> decodeListItemsAsync() async* {
    for (final item in decodeListItems()) {
      yield item;
      await Future.delayed(Duration.zero);
    }
  }

  // #endregion

  // #region Chunked Streaming

  /// Streams tabular rows in chunks for batch processing.
  ///
  /// Yields lists of [chunkSize] rows at a time, reducing per-item
  /// overhead for batch operations like database inserts.
  ///
  /// Example:
  /// ```dart
  /// final stream = ToonStreamDecoder(toonData);
  /// for (final chunk in stream.decodeTabularRowsChunked(chunkSize: 100)) {
  ///   db.insertBatch(chunk);  // insert 100 rows at a time
  /// }
  /// ```
  Iterable<List<Map<String, dynamic>>> decodeTabularRowsChunked({
    int chunkSize = 100,
  }) sync* {
    final chunk = <Map<String, dynamic>>[];
    for (final row in decodeTabularRows()) {
      chunk.add(row);
      if (chunk.length >= chunkSize) {
        yield List<Map<String, dynamic>>.from(chunk);
        chunk.clear();
      }
    }
    if (chunk.isNotEmpty) {
      yield chunk;
    }
  }

  /// Streams tabular rows in chunks with schema.
  Iterable<List<Map<String, dynamic>>> decodeTabularRowsWithSchemaChunked(
    ToonSchema schema, {
    int chunkSize = 100,
  }) sync* {
    final chunk = <Map<String, dynamic>>[];
    for (final row in decodeTabularRowsWithSchema(schema)) {
      chunk.add(row);
      if (chunk.length >= chunkSize) {
        yield List<Map<String, dynamic>>.from(chunk);
        chunk.clear();
      }
    }
    if (chunk.isNotEmpty) {
      yield chunk;
    }
  }

  // #endregion

  // #region Zero-Copy Line Views

  /// Streams raw tabular row strings (zero-copy views into source).
  ///
  /// Instead of parsing each row into a Map, yields the raw row string.
  /// This is useful when you need maximum performance and want to
  /// parse rows yourself, or when passing data to another system.
  ///
  /// The yielded strings are substrings of the original source,
  /// so they share the same underlying buffer (zero-copy in Dart).
  Iterable<String> decodeRawTabularRows() sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null && headerResult.header.fields != null) {
        cursor.advance();
        final rowDepth = 1;
        int rowCount = 0;

        while (!cursor.atEnd() && rowCount < headerResult.header.length) {
          final rowLine = cursor.peek();
          if (rowLine == null || rowLine.depth < rowDepth) break;

          if (rowLine.depth == rowDepth) {
            if (_isKeyValueLine(rowLine.content, headerResult.header.delimiter))
              break;
            cursor.advance();
            yield rowLine.content;
            rowCount++;
          } else {
            break;
          }
        }
        return;
      }

      cursor.advance();
    }
  }

  /// Streams raw delimited values (zero-copy, no Map construction).
  ///
  /// Yields lists of raw string values for each row. Useful for
  /// custom parsing or when you need the raw values without
  /// type conversion overhead.
  Iterable<List<String>> decodeRawDelimitedRows() sync* {
    final lines = _lines;
    final cursor = LineCursor(lines.lines, lines.blankLines);

    while (!cursor.atEnd()) {
      final line = cursor.peek();
      if (line == null) break;

      final headerResult =
          parseArrayHeaderLine(line.content, DEFAULT_DELIMITER);
      if (headerResult != null && headerResult.header.fields != null) {
        cursor.advance();
        final rowDepth = 1;
        final delimiter = headerResult.header.delimiter;
        int rowCount = 0;

        while (!cursor.atEnd() && rowCount < headerResult.header.length) {
          final rowLine = cursor.peek();
          if (rowLine == null || rowLine.depth < rowDepth) break;

          if (rowLine.depth == rowDepth) {
            if (_isKeyValueLine(rowLine.content, delimiter)) break;
            cursor.advance();
            yield parseDelimitedValues(rowLine.content, delimiter);
            rowCount++;
          } else {
            break;
          }
        }
        return;
      }

      cursor.advance();
    }
  }

  // #endregion

  // #region Internal Helpers

  /// Checks if a line is a key-value pair (not a tabular row).
  bool _isKeyValueLine(String content, String delimiter) {
    final colonPos = findUnquotedChar(content, COLON);
    final delimiterPos = findUnquotedChar(content, delimiter);

    if (colonPos == -1) return false;
    if (delimiterPos != -1 && delimiterPos < colonPos) return false;
    return true;
  }

  /// Parses a delimited row directly into a Map using field names.
  ///
  /// This is the inlined hot path for schema-based streaming.
  /// Avoids creating intermediate lists by writing directly into the map.
  void _parseDelimitedIntoMap(
    String content,
    String delimiter,
    List<String> fieldNames,
    Map<String, dynamic> target,
  ) {
    int fieldIndex = 0;
    final current = StringBuffer();
    bool inQuotes = false;
    final delimCode = delimiter.codeUnitAt(0);

    for (int i = 0; i < content.length; i++) {
      final c = content.codeUnitAt(i);

      if (c == 0x5C && inQuotes && i + 1 < content.length) {
        current.writeCharCode(c);
        current.writeCharCode(content.codeUnitAt(i + 1));
        i++;
        continue;
      }

      if (c == 0x22) {
        inQuotes = !inQuotes;
        current.writeCharCode(c);
        continue;
      }

      if (c == delimCode && !inQuotes) {
        if (fieldIndex < fieldNames.length) {
          target[fieldNames[fieldIndex]] =
              _parsePrimitiveInline(current.toString().trim());
        }
        current.clear();
        fieldIndex++;
        continue;
      }

      current.writeCharCode(c);
    }

    // Last value
    if (fieldIndex < fieldNames.length) {
      final last = current.toString().trim();
      if (last.isNotEmpty || fieldIndex > 0) {
        target[fieldNames[fieldIndex]] = _parsePrimitiveInline(last);
      }
    }
  }

  /// Inline primitive parsing — avoids function call overhead.
  dynamic _parsePrimitiveInline(String token) {
    if (token.isEmpty) return '';
    final first = token.codeUnitAt(0);

    // Quoted string
    if (first == 0x22) {
      if (token.length >= 2 && token.codeUnitAt(token.length - 1) == 0x22) {
        return token.substring(1, token.length - 1);
      }
      return token;
    }

    // Boolean/null
    if (first == 0x74 || first == 0x66 || first == 0x6E) {
      if (token == 'true') return true;
      if (token == 'false') return false;
      if (token == 'null') return null;
    }

    // Numeric
    if (_isNumericLikeFast(token)) {
      final parsed = double.tryParse(token);
      if (parsed != null) {
        return parsed == 0.0 ? 0 : parsed;
      }
    }

    return token;
  }

  /// Fast numeric-like check without regex.
  bool _isNumericLikeFast(String value) {
    if (value.isEmpty) return false;
    int start = 0;
    final first = value.codeUnitAt(0);
    if (first == 0x2D || first == 0x2B) start = 1;
    if (start >= value.length) return false;
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
          (value.codeUnitAt(i - 1) == 0x65 ||
              value.codeUnitAt(i - 1) == 0x45)) {
        // exponent sign
      } else {
        return false;
      }
    }
    return hasDigit;
  }

  // #endregion
}

// #endregion

// #region Convenience Functions

/// Streams tabular rows from a TOON string.
///
/// Convenience function that creates a [ToonStreamDecoder] and
/// streams the first tabular array found.
///
/// Example:
/// ```dart
/// for (final row in streamTabularRows(toonData)) {
///   print(row);
/// }
/// ```
Iterable<Map<String, dynamic>> streamTabularRows(
  String source, {
  int indentSize = 2,
  bool strict = true,
}) {
  return ToonStreamDecoder(source, indentSize: indentSize, strict: strict)
      .decodeTabularRows();
}

/// Streams tabular rows with a schema.
///
/// Example:
/// ```dart
/// final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
/// for (final row in streamTabularRowsWithSchema(toonData, schema)) {
///   print(row);
/// }
/// ```
Iterable<Map<String, dynamic>> streamTabularRowsWithSchema(
  String source,
  ToonSchema schema, {
  int indentSize = 2,
  bool strict = true,
}) {
  return ToonStreamDecoder(source, indentSize: indentSize, strict: strict)
      .decodeTabularRowsWithSchema(schema);
}

/// Streams list items from a TOON string.
Iterable<dynamic> streamListItems(
  String source, {
  int indentSize = 2,
  bool strict = true,
}) {
  return ToonStreamDecoder(source, indentSize: indentSize, strict: strict)
      .decodeListItems();
}

// #endregion
