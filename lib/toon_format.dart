/// Token-Oriented Object Notation (TOON) encoder and decoder for Dart.
///
/// TOON is a compact, human-readable format designed for passing structured
/// data to Large Language Models with significantly reduced token usage.
///
/// This package provides multiple encoding/decoding paths optimized for
/// different use cases:
///
/// - **Standard encode/decode**: Full-featured, handles any JSON-compatible data
/// - **Schema-based encode/decode**: Direct field access, no Map iteration (~3-5x faster)
/// - **Stream decoding**: Lazy decoding for large payloads, lower memory usage
/// - **Batch decoding**: Process tabular rows in chunks for database inserts
///
/// Performance optimizations (vs naive implementation):
/// - Code unit operations instead of regex (~5-10x faster for numeric checks)
/// - Pre-estimated buffer capacity (avoids 2-3x reallocation overhead)
/// - Cached indentation strings per depth level
/// - Inlined hot paths with @pragma annotations
/// - Single-pass string escaping (vs 5x replaceAll)
/// - Schema-based direct field indexing (no Map.keys iteration)
/// - Stream decoding for O(1) memory per item
///
/// For specification, see: https://github.com/johannschopplich/toon/blob/main/SPEC.md
library toon_format;

// #region Options export

export 'src/options.dart';

// #endregion

// #region Schema exports

export 'src/schema/toon_schema.dart'
    show
        ToonSchema,
        ConcreteSchema,
        FlattenedSchema,
        IntKeyedSchema,
        SchemaField,
        SchemaFieldType,
        SchemaRegistry,
        encodeTabularWithSchema,
        decodeTabularWithSchema;

// #endregion

// #region Stream decoder exports

export 'src/stream/stream_decoder.dart'
    show
        ToonStreamDecoder,
        streamTabularRows,
        streamTabularRowsWithSchema,
        streamListItems;

// #endregion

// #region Internal imports

import 'src/decode/decoders.dart';
import 'src/decode/scanners.dart';
import 'src/encode/encoders.dart';
import 'src/encode/normalize.dart';
import 'src/encode/writer.dart';
import 'src/options.dart';
import 'src/schema/toon_schema.dart';
import 'src/stream/stream_decoder.dart';

// #endregion

// #region Standard Encode/Decode API

/// Encodes a value to TOON format.
///
/// [value] The value to encode (will be normalized to JSON-compatible types)
/// [options] Optional encoding options
/// Returns a TOON-formatted string
///
/// Example:
/// ```dart
/// final toon = encode({'name': 'Alice', 'age': 30});
/// // name: Alice
/// // age: 30
/// ```
String encode(Object? value, {EncodeOptions? options}) {
  final normalized = normalizeValue(value);
  final resolvedOptions = (options ?? const EncodeOptions()).resolve();
  return encodeValue(normalized, resolvedOptions);
}

/// Decodes a TOON-formatted string to a Dart value.
///
/// [input] The TOON-formatted string to parse
/// [options] Optional decoding options
/// Returns a Dart value (Map, List, or primitive) representing the parsed TOON data
///
/// Example:
/// ```dart
/// final data = decode('name: Alice\nage: 30');
/// // {'name': 'Alice', 'age': 30}
/// ```
Object? decode(String input, {DecodeOptions? options}) {
  final resolvedOptions = (options ?? const DecodeOptions()).resolve();
  final scanResult =
      toParsedLines(input, resolvedOptions.indent, resolvedOptions.strict);
  final cursor = LineCursor(scanResult.lines, scanResult.blankLines);
  return decodeValueFromLines(cursor, resolvedOptions);
}

// #endregion

// #region Schema-Based Encode/Decode API

/// Encodes a list of Maps to TOON tabular format using a schema.
///
/// This is the fastest encoding path for tabular data because:
/// 1. No isTabularArray() detection needed (schema defines layout)
/// 2. No Map.keys iteration (direct field access by index)
/// 3. Pre-estimated buffer size (no reallocation)
///
/// [key] Optional key prefix for the array header
/// [rows] List of Maps to encode
/// [schema] Schema defining field order and types
/// [options] Optional encoding options
/// Returns a TOON-formatted string
///
/// Example:
/// ```dart
/// final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
/// final rows = [
///   {'id': 1, 'name': 'Alice', 'age': 30},
///   {'id': 2, 'name': 'Bob', 'age': 25},
/// ];
/// final toon = encodeWithSchema('users', rows, schema);
/// // users[2]{id,name,age}:
/// // 1,Alice,30
/// // 2,Bob,25
/// ```
String encodeWithSchema(
  String? key,
  List<Map<String, dynamic>> rows,
  ToonSchema schema, {
  EncodeOptions? options,
}) {
  final resolvedOptions = (options ?? const EncodeOptions()).resolve();
  return encodeTabularWithSchema(
    key,
    rows,
    schema,
    indent: resolvedOptions.indent,
    delimiter: resolvedOptions.delimiter,
    lengthMarker: resolvedOptions.lengthMarker,
  );
}

/// Decodes a TOON tabular array using a schema.
///
/// This is the fastest decoding path for tabular data because:
/// 1. No header field parsing needed (schema defines field names)
/// 2. No Map key lookup (direct positional assignment)
/// 3. Schema validates types if configured
///
/// [rows] List of delimited value strings (one per row)
/// [schema] Schema defining field names and types
/// [delimiter] Delimiter used in the tabular rows
/// Returns a list of Maps with schema-defined field names
///
/// Example:
/// ```dart
/// final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
/// final rows = ['1,Alice,30', '2,Bob,25'];
/// final data = decodeWithSchema(rows, schema);
/// // [{'id': 1, 'name': 'Alice', 'age': 30}, ...]
/// ```
List<Map<String, dynamic>> decodeWithSchema(
  List<String> rows,
  ToonSchema schema, {
  String delimiter = ',',
}) {
  return decodeTabularWithSchema(rows, schema, delimiter: delimiter);
}

// #endregion

// #region Stream Decode API

/// Creates a stream decoder for lazy decoding of large TOON payloads.
///
/// Stream decoding provides:
/// - **Lower memory usage**: Only one item in memory at a time
/// - **Faster first-item latency**: Start processing before full parse
/// - **Isolate-friendly**: Can be run in a separate isolate
///
/// [input] The TOON-formatted string to parse
/// [options] Optional decoding options
/// Returns a [ToonStreamDecoder] for incremental decoding
///
/// Example:
/// ```dart
/// final stream = streamDecode(toonData);
/// for (final row in stream.decodeTabularRows()) {
///   process(row);  // handle each row without loading all into memory
/// }
/// ```
ToonStreamDecoder streamDecode(String input, {DecodeOptions? options}) {
  final resolvedOptions = (options ?? const DecodeOptions()).resolve();
  return ToonStreamDecoder(
    input,
    indentSize: resolvedOptions.indent,
    strict: resolvedOptions.strict,
  );
}

/// Streams tabular rows from a TOON string.
///
/// Convenience function that creates a [ToonStreamDecoder] and
/// streams the first tabular array found.
///
/// Example:
/// ```dart
/// for (final row in streamTabularRows(toonData)) {
///   print(row);  // {'id': 1, 'name': 'Alice', 'age': 30}
/// }
/// ```
/// Note: This function is also available as a direct export from
/// the stream module. It is re-declared here for API convenience.
Iterable<Map<String, dynamic>> streamTabularRowsConvenience(
  String source, {
  DecodeOptions? options,
}) {
  final resolvedOptions = (options ?? const DecodeOptions()).resolve();
  return streamTabularRows(
    source,
    indentSize: resolvedOptions.indent,
    strict: resolvedOptions.strict,
  );
}

// #endregion

// #region Buffer Estimation API

/// Estimates the buffer capacity needed for encoding a Map.
///
/// Useful for pre-allocating buffers when you know the approximate
/// size of the data you'll be encoding. Even a rough estimate is
/// much better than dynamic growth (which causes 2-3x reallocation).
///
/// [map] The Map to estimate size for
/// Returns estimated character count for the TOON-encoded string
///
/// Example:
/// ```dart
/// final estimatedSize = estimateEncodeSize(data);
/// // Use this to pre-allocate buffers in downstream systems
/// ```
int estimateEncodeSize(Map<String, dynamic> map) {
  return LineWriter.estimateFromMap(map);
}

// #endregion
