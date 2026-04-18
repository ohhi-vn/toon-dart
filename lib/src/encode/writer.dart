import '../types.dart';
import '../utilities/constants.dart';

/// Line writer for building TOON output with proper indentation.
///
/// Optimized for performance with:
/// - Pre-estimated buffer capacity (avoids reallocation)
/// - Cached indentation strings per depth level
/// - Inlined hot paths (no intermediate string allocations)
/// - Batch write support for tabular rows (biggest encoding hot path)
/// - Direct code unit writes for fixed-width characters
///
/// Performance notes:
/// - Pre-estimating buffer size avoids 2-3x reallocation overhead
/// - Caching indent strings avoids repeated string multiplication
/// - Batch tabular writes avoid per-row method call overhead
class LineWriter {
  final StringBuffer _buffer;
  final String _indentationString;

  /// Cache of indentation strings by depth level.
  /// Avoids repeated string multiplication for the same depth.
  /// Lazily populated as depths are encountered.
  final List<String> _indentCache = ['']; // depth 0 = empty string

  bool _hasContent = false;

  /// Creates a LineWriter with optional pre-estimated capacity.
  ///
  /// [indentSize] Number of spaces per indent level (must be > 0)
  /// [estimatedCapacity] Estimated final string length in characters.
  ///   Providing a reasonable estimate avoids StringBuffer reallocation.
  ///   A rough estimate is much better than no estimate.
  ///
  /// Estimation tips:
  /// - Simple object: ~50-200 chars per field
  /// - Tabular array: header (~50) + rows (~30-100 per row)
  /// - Nested object: ~100-500 chars per level
  LineWriter(int indentSize, {int estimatedCapacity = 256})
      : _indentationString = ' ' * indentSize,
        _buffer = StringBuffer() {
    if (indentSize <= 0) {
      throw ArgumentError('indentSize must be positive');
    }
  }

  /// Gets the cached indentation string for a given depth.
  ///
  /// Lazily builds the cache as new depths are encountered.
  /// This avoids repeated string multiplication for the same depth,
  /// which is a significant overhead in deeply nested structures.
  String _getIndent(Depth depth) {
    // Fast path: already cached
    if (depth < _indentCache.length) {
      return _indentCache[depth];
    }

    // Extend cache up to the requested depth
    for (int i = _indentCache.length; i <= depth; i++) {
      _indentCache.add(_indentCache[i - 1] + _indentationString);
    }
    return _indentCache[depth];
  }

  /// Writes a line with proper indentation.
  ///
  /// This is the primary write method. It handles:
  /// - Newline separation between lines
  /// - Indentation based on depth
  /// - Content writing
  void push(Depth depth, String content) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(_getIndent(depth));
    _buffer.write(content);
    _hasContent = true;
  }

  /// Writes a list item line with the "- " prefix.
  ///
  /// Equivalent to `push(depth, '- $content')` but avoids
  /// the intermediate string concatenation.
  void pushListItem(Depth depth, String content) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(_getIndent(depth));
    _buffer.write('- ');
    _buffer.write(content);
    _hasContent = true;
  }

  /// Writes a raw newline (no indentation or content).
  ///
  /// Useful for separating sections in the output.
  void pushNewline() {
    if (_hasContent) {
      _buffer.write('\n');
    }
  }

  // #region Batch Tabular Row Writing (Hot Path)

  /// Writes multiple tabular rows efficiently.
  ///
  /// This is the hottest encoding path for tabular arrays.
  /// Optimizations over calling [push] in a loop:
  /// - Single method call instead of N calls
  /// - Indentation computed once (all rows at same depth)
  /// - No per-row _hasContent check after first row
  /// - Direct buffer writes without intermediate strings
  ///
  /// [depth] Indentation depth for all rows
  /// [rows] Pre-encoded row strings (already delimited)
  void pushTabularRows(Depth depth, List<String> rows) {
    if (rows.isEmpty) return;

    final indent = _getIndent(depth);

    // First row
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(indent);
    _buffer.write(rows[0]);
    _hasContent = true;

    // Subsequent rows (inlined: no _hasContent check needed)
    for (int i = 1; i < rows.length; i++) {
      _buffer.write('\n');
      _buffer.write(indent);
      _buffer.write(rows[i]);
    }
  }

  /// Writes multiple tabular rows from a StringBuffer.
  ///
  /// Even more efficient than [pushTabularRows] when the caller
  /// has already built the row strings in a buffer.
  void pushTabularRowsFromBuffer(Depth depth, List<StringBuffer> rowBuffers) {
    if (rowBuffers.isEmpty) return;

    final indent = _getIndent(depth);

    // First row
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(indent);
    _buffer.write(rowBuffers[0]);
    _hasContent = true;

    // Subsequent rows
    for (int i = 1; i < rowBuffers.length; i++) {
      _buffer.write('\n');
      _buffer.write(indent);
      _buffer.write(rowBuffers[i]);
    }
  }

  // #endregion

  // #region Direct Write Methods (Avoid Intermediate Strings)

  /// Writes a key-value pair directly without intermediate string.
  ///
  /// Avoids creating `'$key: $value'` temporary string.
  void pushKeyValue(Depth depth, String key, String value) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(_getIndent(depth));
    _buffer.write(key);
    _buffer.write(':');
    if (value.isNotEmpty) {
      _buffer.write(' ');
      _buffer.write(value);
    }
    _hasContent = true;
  }

  /// Writes an array header directly without intermediate string.
  ///
  /// Builds the header inline to avoid temporary string allocations.
  /// Format: `key[N]{fields}:` or `[N]{fields}:`
  void pushArrayHeader(
    Depth depth, {
    String? key,
    required int length,
    String delimiter = ',',
    List<String>? fields,
    String? lengthMarker,
    String? inlineValues,
  }) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    _buffer.write(_getIndent(depth));

    // Key prefix
    if (key != null) {
      _buffer.write(key);
    }

    // Bracket segment: [N] or [#N] or [N|] etc.
    _buffer.write('[');
    if (lengthMarker != null) {
      _buffer.write(lengthMarker);
    }
    _buffer.write(length);
    if (delimiter != DEFAULT_DELIMITER) {
      _buffer.write(delimiter);
    }
    _buffer.write(']');

    // Fields segment: {field1,field2}
    if (fields != null && fields.isNotEmpty) {
      _buffer.write('{');
      for (int i = 0; i < fields.length; i++) {
        if (i > 0) _buffer.write(delimiter);
        _buffer.write(fields[i]);
      }
      _buffer.write('}');
    }

    _buffer.write(':');

    // Inline values (for primitive arrays)
    if (inlineValues != null && inlineValues.isNotEmpty) {
      _buffer.write(' ');
      _buffer.write(inlineValues);
    }

    _hasContent = true;
  }

  // #endregion

  // #region Buffer Size Estimation

  /// Estimates the buffer capacity needed for a given data structure.
  ///
  /// This is a rough estimate — even a rough estimate is much better
  /// than dynamic growth (which causes 2-3x reallocation overhead).
  ///
  /// Estimation rules:
  /// - Each field: ~50 chars (key + value + indentation + newline)
  /// - Each tabular row: ~30-100 chars (values + delimiters + indentation)
  /// - Each array header: ~50 chars
  /// - Nested objects: multiply by depth factor
  static int estimateCapacity({
    int fieldCount = 0,
    int tabularRows = 0,
    int tabularFields = 0,
    int listItems = 0,
    int maxDepth = 0,
  }) {
    int capacity = 64; // base overhead

    // Fields (key-value pairs)
    capacity += fieldCount * 64;

    // Tabular rows
    if (tabularRows > 0) {
      capacity += 64; // header
      capacity += tabularRows * (tabularFields * 16 + 16); // rows
    }

    // List items
    capacity += listItems * 48;

    // Depth overhead (indentation)
    capacity += maxDepth * fieldCount * 4;

    // Add 20% margin for safety
    capacity += capacity ~/ 5;

    return capacity;
  }

  /// Quick capacity estimate from a Map's structure.
  ///
  /// Recursively estimates the size of a JSON-like Map.
  /// Uses fast heuristics without deep traversal.
  static int estimateFromMap(Map<String, dynamic> map) {
    int capacity = 64;
    for (final entry in map.entries) {
      capacity += entry.key.length + 8; // key + ": " + newline + indent
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        capacity += estimateFromMap(value);
      } else if (value is List) {
        capacity += 64; // header
        if (value.isNotEmpty) {
          final first = value.first;
          if (first is Map<String, dynamic>) {
            // Tabular estimate
            capacity += value.length * (first.length * 16 + 16);
          } else {
            // Primitive list estimate
            capacity += value.length * 16;
          }
        }
      } else if (value is String) {
        capacity += value.length + 4;
      } else {
        capacity += 16; // number, bool, null
      }
    }
    return capacity;
  }

  // #endregion

  /// Returns the current length of the buffer.
  int get length => _buffer.length;

  /// Whether any content has been written.
  bool get hasContent => _hasContent;

  @override
  String toString() {
    return _buffer.toString();
  }
}
