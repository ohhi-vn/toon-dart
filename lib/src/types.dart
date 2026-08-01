/// Type definitions for TOON format encoding and decoding.

/// JSON primitive types (string, number, boolean, null).
typedef JsonPrimitive = Object?; // null, String, num, bool

/// JSON array type.
typedef JsonArray = List<JsonValue>;

/// JSON object type.
typedef JsonObject = Map<String, JsonValue>;

/// JSON value type (primitive, array, or object).
typedef JsonValue = Object?; // JsonPrimitive | JsonArray | JsonObject

/// Depth level for indentation (non-negative integer).
typedef Depth = int;

/// Delimiter type for array values and tabular rows.
typedef Delimiter = String;

/// Parsed line information.
class ParsedLine {
  final String raw;
  final int indent;
  final String content;
  final Depth depth;
  final int lineNumber;

  const ParsedLine({
    required this.raw,
    required this.indent,
    required this.content,
    required this.depth,
    required this.lineNumber,
  });
}

/// Blank line information.
class BlankLineInfo {
  final int lineNumber;
  final int indent;
  final Depth depth;

  const BlankLineInfo({
    required this.lineNumber,
    required this.indent,
    required this.depth,
  });
}

/// Array header information.
class ArrayHeaderInfo {
  final String? key;
  final int length;
  final Delimiter delimiter;
  final List<String>? fields;
  final List<TabularField>? tabularFields;
  final bool hasLengthMarker;
  final bool isKeyed;

  const ArrayHeaderInfo({
    this.key,
    required this.length,
    required this.delimiter,
    this.fields,
    this.tabularFields,
    required this.hasLengthMarker,
    this.isKeyed = false,
  });
}

/// Resolved encode options.
class ResolvedEncodeOptions {
  final int indent;
  final Delimiter delimiter;
  final String? lengthMarker;

  const ResolvedEncodeOptions({
    required this.indent,
    required this.delimiter,
    this.lengthMarker,
  });
}

/// Resolved decode options.
class ResolvedDecodeOptions {
  final int indent;
  final bool strict;

  const ResolvedDecodeOptions({
    required this.indent,
    required this.strict,
  });
}

/// Result of parsing an array header line.
class ArrayHeaderParseResult {
  final ArrayHeaderInfo header;
  final String? inlineValues;

  const ArrayHeaderParseResult({
    required this.header,
    this.inlineValues,
  });
}

/// Result of parsing a bracket segment.
class BracketSegmentResult {
  final int length;
  final String delimiter;
  final bool hasLengthMarker;
  final bool isKeyed;

  const BracketSegmentResult({
    required this.length,
    required this.delimiter,
    required this.hasLengthMarker,
    this.isKeyed = false,
  });
}

/// Result of parsing a key token.
class KeyTokenResult {
  final String key;
  final int end;

  const KeyTokenResult({
    required this.key,
    required this.end,
  });
}

/// Result of decoding a key-value pair.
class KeyValueResult {
  final String key;
  final JsonValue value;
  final Depth followDepth;

  const KeyValueResult({
    required this.key,
    required this.value,
    required this.followDepth,
  });
}

/// Result of decoding a key-value pair (simple version).
class KeyValuePairResult {
  final String key;
  final JsonValue value;

  const KeyValuePairResult({
    required this.key,
    required this.value,
  });
}

/// A field entry in a tabular or keyed header field list.
///
/// A leaf field has [nestedFields] == null and corresponds to one cell.
/// A nested field group has [nestedFields] != null and expands to
/// multiple cells in depth-first order.
class TabularField {
  final String name;
  final List<TabularField>? nestedFields;

  const TabularField(this.name, [this.nestedFields]);

  /// Number of leaf cells this field produces in depth-first order.
  int get leafCount {
    if (nestedFields == null) return 1;
    int count = 0;
    for (final f in nestedFields!) {
      count += f.leafCount;
    }
    return count;
  }

  /// All leaf field names in depth-first order (dotted paths for nested).
  List<String> get leafNames {
    if (nestedFields == null) return [name];
    final result = <String>[];
    for (final f in nestedFields!) {
      result.addAll(f.leafNames);
    }
    return result;
  }
}

