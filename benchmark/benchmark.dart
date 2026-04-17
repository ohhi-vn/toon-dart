import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:toon_format/toon_format.dart';

/// Benchmark result data class
class BenchmarkResult {
  final String name;
  final Duration duration;
  final int iterations;
  final int dataSize;
  final double opsPerSec;
  final double nsPerOp;

  BenchmarkResult({
    required this.name,
    required this.duration,
    required this.iterations,
    required this.dataSize,
  })  : opsPerSec = iterations / duration.inMicroseconds * 1000000,
        nsPerOp = duration.inMicroseconds * 1000 / iterations;

  @override
  String toString() {
    return '$name: ${iterations.toString().padLeft(8)} ops in ${_formatDuration(duration)} '
        '(${opsPerSec.toStringAsFixed(0)} ops/sec, ${nsPerOp.toStringAsFixed(0)} ns/op)';
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1) {
      return '${d.inMicroseconds}μs';
    } else if (d.inSeconds < 1) {
      return '${d.inMilliseconds}ms';
    } else {
      return '${d.inSeconds}.${(d.inMilliseconds % 1000).toString().padLeft(3, '0')}s';
    }
  }
}

/// Benchmark runner
class BenchmarkRunner {
  final List<BenchmarkResult> results = [];
  final bool verbose;

  BenchmarkRunner({this.verbose = false});

  /// Run a benchmark with adaptive iteration count
  Future<BenchmarkResult> run({
    required String name,
    required FutureOr<void> Function() benchmark,
    required int dataSize,
    Duration? minDuration,
    int? maxIterations,
  }) async {
    final targetDuration = minDuration ?? Duration(milliseconds: 500);
    final maxIter = maxIterations ?? 1000000;

    // Warmup
    for (int i = 0; i < 3; i++) {
      await benchmark();
    }

    // Adaptive iterations
    int iterations = 1;
    Duration totalDuration = Duration.zero;

    while (totalDuration < targetDuration && iterations < maxIter) {
      final batch = iterations < 100 ? 1 : (iterations < 1000 ? 10 : 100);
      final sw = Stopwatch()..start();

      for (int i = 0; i < batch; i++) {
        await benchmark();
      }

      sw.stop();
      totalDuration += sw.elapsed;
      iterations += batch;

      if (verbose) {
        stdout.write(
            '\r$name: ${iterations.toString().padLeft(8)} iterations, ${_formatDuration(totalDuration)}');
      }
    }

    if (verbose) {
      stdout.writeln();
    }

    final result = BenchmarkResult(
      name: name,
      duration: totalDuration,
      iterations: iterations,
      dataSize: dataSize,
    );

    results.add(result);
    return result;
  }

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1) {
      return '${d.inMicroseconds}μs';
    } else if (d.inSeconds < 1) {
      return '${d.inMilliseconds}ms';
    } else {
      return '${d.inSeconds}.${(d.inMilliseconds % 1000).toString().padLeft(3, '0')}s';
    }
  }

  /// Print summary table
  void printSummary() {
    stdout.writeln('\n${'=' * 100}');
    stdout.writeln('BENCHMARK RESULTS');
    stdout.writeln('${'=' * 100}\n');

    // Group by category
    final categories = <String, List<BenchmarkResult>>{};
    for (final result in results) {
      final category = result.name.split(' - ')[0];
      categories.putIfAbsent(category, () => []).add(result);
    }

    for (final entry in categories.entries) {
      stdout.writeln('${entry.key}:');
      stdout.writeln('-' * 100);
      for (final result in entry.value) {
        stdout.writeln('  ${result.name.split(' - ').last.padRight(45)} | '
            '${result.iterations.toString().padLeft(8)} ops | '
            '${_formatDuration(result.duration).padLeft(10)} | '
            '${result.opsPerSec.toStringAsFixed(0).padLeft(10)} ops/s | '
            '${result.nsPerOp.toStringAsFixed(0).padLeft(10)} ns/op');
      }
      stdout.writeln();
    }

    // Performance comparison: Standard vs Schema vs Stream
    stdout.writeln('${'=' * 100}');
    stdout.writeln('PERFORMANCE COMPARISON: Standard vs Schema vs Stream');
    stdout.writeln('${'=' * 100}\n');

    _printComparison('Tabular 1000 rows', results);
    _printComparison('Tabular 10000 rows', results);

    // Encode vs Decode comparison
    stdout.writeln('${'=' * 100}');
    stdout.writeln('ENCODE vs DECODE COMPARISON');
    stdout.writeln('${'=' * 100}\n');

    final encodeResults =
        results.where((r) => r.name.contains('Encode')).toList();
    final decodeResults =
        results.where((r) => r.name.contains('Decode')).toList();

    for (int i = 0; i < encodeResults.length && i < decodeResults.length; i++) {
      final encode = encodeResults[i];
      final decode = decodeResults[i];
      final ratio = decode.opsPerSec / encode.opsPerSec;

      stdout.writeln('${encode.name.split(' - ').last.padRight(45)} | '
          'Encode: ${encode.opsPerSec.toStringAsFixed(0).padLeft(8)} ops/s | '
          'Decode: ${decode.opsPerSec.toStringAsFixed(0).padLeft(8)} ops/s | '
          'Ratio: ${ratio.toStringAsFixed(2)}x');
    }

    stdout.writeln('\n${'=' * 100}\n');
  }

  void _printComparison(String prefix, List<BenchmarkResult> allResults) {
    final standardEncode =
        allResults.where((r) => r.name == '$prefix - Standard Encode').toList();
    final schemaEncode =
        allResults.where((r) => r.name == '$prefix - Schema Encode').toList();
    final standardDecode =
        allResults.where((r) => r.name == '$prefix - Standard Decode').toList();
    final schemaDecode =
        allResults.where((r) => r.name == '$prefix - Schema Decode').toList();
    final streamDecode =
        allResults.where((r) => r.name == '$prefix - Stream Decode').toList();
    final streamSchemaDecode = allResults
        .where((r) => r.name == '$prefix - Stream Schema Decode')
        .toList();

    if (standardEncode.isNotEmpty && schemaEncode.isNotEmpty) {
      final speedup =
          schemaEncode.first.opsPerSec / standardEncode.first.opsPerSec;
      stdout.writeln(
          '  ${prefix} Encode: Schema is ${speedup.toStringAsFixed(2)}x faster than Standard');
    }

    if (standardDecode.isNotEmpty && schemaDecode.isNotEmpty) {
      final speedup =
          schemaDecode.first.opsPerSec / standardDecode.first.opsPerSec;
      stdout.writeln(
          '  ${prefix} Decode: Schema is ${speedup.toStringAsFixed(2)}x faster than Standard');
    }

    if (standardDecode.isNotEmpty && streamDecode.isNotEmpty) {
      final speedup =
          streamDecode.first.opsPerSec / standardDecode.first.opsPerSec;
      stdout.writeln(
          '  ${prefix} Decode: Stream is ${speedup.toStringAsFixed(2)}x vs Standard (ops/s)');
    }

    if (streamDecode.isNotEmpty && streamSchemaDecode.isNotEmpty) {
      final speedup =
          streamSchemaDecode.first.opsPerSec / streamDecode.first.opsPerSec;
      stdout.writeln(
          '  ${prefix} Decode: Stream+Schema is ${speedup.toStringAsFixed(2)}x faster than Stream alone');
    }

    stdout.writeln();
  }
}

/// Generate test data for benchmarks
class TestDataGenerator {
  static final Random _random = Random(42); // Fixed seed for reproducibility

  /// Generate simple flat object
  static Map<String, dynamic> generateFlatObject() {
    return {
      'id': _random.nextInt(100000),
      'name': 'User_${_random.nextInt(1000)}',
      'email': 'user${_random.nextInt(1000)}@example.com',
      'age': 18 + _random.nextInt(50),
      'active': _random.nextBool(),
      'score': _random.nextDouble() * 100,
    };
  }

  /// Generate nested object
  static Map<String, dynamic> generateNestedObject() {
    return {
      'user': {
        'id': _random.nextInt(100000),
        'profile': {
          'name': 'User_${_random.nextInt(1000)}',
          'email': 'user${_random.nextInt(1000)}@example.com',
          'address': {
            'street': '${_random.nextInt(9999)} Main St',
            'city': 'City_${_random.nextInt(100)}',
            'zip': '${10000 + _random.nextInt(89999)}',
          },
        },
        'settings': {
          'theme': _random.nextBool() ? 'dark' : 'light',
          'notifications': _random.nextBool(),
          'language': 'en',
        },
      },
      'metadata': {
        'createdAt': DateTime(2020 + _random.nextInt(5),
                _random.nextInt(12) + 1, _random.nextInt(28) + 1)
            .toIso8601String(),
        'updatedAt': DateTime(2023 + _random.nextInt(2),
                _random.nextInt(12) + 1, _random.nextInt(28) + 1)
            .toIso8601String(),
        'version': _random.nextInt(10),
      },
    };
  }

  /// Generate tabular data (array of uniform objects)
  static Map<String, dynamic> generateTabularData(int rows) {
    return {
      'users': List.generate(rows, (i) {
        return {
          'id': i + 1,
          'name': 'User_$i',
          'email': 'user$i@example.com',
          'age': 18 + (i % 50),
          'active': i % 3 != 0,
          'score': (i * 1.5) % 100,
        };
      }),
    };
  }

  /// Generate tabular rows only (for schema-based benchmarks)
  static List<Map<String, dynamic>> generateTabularRows(int rows) {
    return List.generate(rows, (i) {
      return {
        'id': i + 1,
        'name': 'User_$i',
        'email': 'user$i@example.com',
        'age': 18 + (i % 50),
        'active': i % 3 != 0,
        'score': (i * 1.5) % 100,
      };
    });
  }

  /// Generate mixed array data
  static Map<String, dynamic> generateMixedArrayData(int items) {
    return {
      'items': List.generate(items, (i) {
        if (i % 4 == 0) {
          return 'string_$i';
        } else if (i % 4 == 1) {
          return i * 1.5;
        } else if (i % 4 == 2) {
          return {'id': i, 'name': 'Item_$i'};
        } else {
          return [i, i + 1, i + 2];
        }
      }),
    };
  }

  /// Generate deeply nested structure
  static Map<String, dynamic> generateDeepNestedData(int depth) {
    Map<String, dynamic> result = {'value': 'leaf'};
    for (int i = depth - 1; i >= 0; i--) {
      result = {'level_$i': result};
    }
    return result;
  }

  /// Generate large dataset with multiple arrays
  static Map<String, dynamic> generateLargeDataset({
    int users = 1000,
    int orders = 500,
    int products = 200,
  }) {
    return {
      'users': List.generate(users, (i) {
        return {
          'id': i + 1,
          'name': 'User_$i',
          'email': 'user$i@example.com',
          'age': 18 + (i % 50),
          'active': i % 3 != 0,
        };
      }),
      'orders': List.generate(orders, (i) {
        return {
          'orderId': 'ORD-${10000 + i}',
          'userId': _random.nextInt(users) + 1,
          'amount': (10 + _random.nextDouble() * 990).roundToDouble(),
          'status': ['pending', 'completed', 'cancelled'][i % 3],
          'date':
              DateTime(2023, _random.nextInt(12) + 1, _random.nextInt(28) + 1)
                  .toIso8601String(),
        };
      }),
      'products': List.generate(products, (i) {
        return {
          'sku': 'SKU-${1000 + i}',
          'name': 'Product_$i',
          'price': (5 + _random.nextDouble() * 195).roundToDouble(),
          'inStock': i % 4 != 0,
          'category': ['Electronics', 'Books', 'Clothing', 'Home'][i % 4],
        };
      }),
      'metadata': {
        'generatedAt': DateTime.now().toIso8601String(),
        'totalRecords': users + orders + products,
        'version': '1.0.0',
      },
    };
  }

  /// Generate flattened nested data for FlattenedSchema benchmark
  static List<Map<String, dynamic>> generateFlattenedRows(int rows) {
    return List.generate(rows, (i) {
      return {
        'user': {
          'id': i + 1,
          'name': 'User_$i',
        },
        'status': i % 3 == 0 ? 'active' : 'inactive',
        'score': (i * 1.5) % 100,
      };
    });
  }

  /// Generate int-keyed data for IntKeyedSchema benchmark
  static List<Map<String, dynamic>> generateIntKeyedRows(int rows) {
    return List.generate(rows, (i) {
      return {
        'id': i + 1,
        'status': ['pending', 'active', 'closed'][i % 3],
        'category': ['electronics', 'books', 'clothing', 'home'][i % 4],
        'priority': i % 5,
      };
    });
  }
}

/// Calculate data size in bytes
int calculateDataSize(Object? data) {
  return utf8.encode(jsonEncode(data)).length;
}

/// Main benchmark runner
Future<void> main(List<String> args) async {
  final verbose = args.contains('--verbose') || args.contains('-v');
  final quick = args.contains('--quick') || args.contains('-q');
  final runner = BenchmarkRunner(verbose: verbose);

  stdout.writeln('TOON Format Performance Benchmark');
  stdout.writeln('Dart SDK: ${Platform.version.split(' ').first}');
  stdout.writeln('Mode: ${quick ? "Quick" : "Full"}');
  stdout.writeln('');

  final minDur =
      quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500);
  final minDurLong = quick ? Duration(milliseconds: 200) : Duration(seconds: 1);

  // =========================================================================
  // 1. Simple object benchmarks
  // =========================================================================
  stdout.writeln('Running simple object benchmarks...');
  final simpleObject = TestDataGenerator.generateFlatObject();
  final simpleObjectSize = calculateDataSize(simpleObject);
  final simpleEncoded = encode(simpleObject);

  await runner.run(
    name: 'Simple Object - Standard Encode',
    benchmark: () => encode(simpleObject),
    dataSize: simpleObjectSize,
    minDuration: minDur,
  );

  await runner.run(
    name: 'Simple Object - Standard Decode',
    benchmark: () => decode(simpleEncoded),
    dataSize: simpleEncoded.length,
    minDuration: minDur,
  );

  // =========================================================================
  // 2. Nested object benchmarks
  // =========================================================================
  stdout.writeln('Running nested object benchmarks...');
  final nestedObject = TestDataGenerator.generateNestedObject();
  final nestedObjectSize = calculateDataSize(nestedObject);
  final nestedEncoded = encode(nestedObject);

  await runner.run(
    name: 'Nested Object - Standard Encode',
    benchmark: () => encode(nestedObject),
    dataSize: nestedObjectSize,
    minDuration: minDur,
  );

  await runner.run(
    name: 'Nested Object - Standard Decode',
    benchmark: () => decode(nestedEncoded),
    dataSize: nestedEncoded.length,
    minDuration: minDur,
  );

  // =========================================================================
  // 3. Tabular data benchmarks (TOON's sweet spot)
  //    Compare: Standard vs Schema vs Stream
  // =========================================================================
  stdout.writeln('Running tabular data benchmarks...');

  // Create schema for tabular data
  final userSchema = ConcreteSchema.fromNames(
    ['id', 'name', 'email', 'age', 'active', 'score'],
  );

  for (final rows in [100, 1000, 10000]) {
    final tabularData = TestDataGenerator.generateTabularData(rows);
    final tabularSize = calculateDataSize(tabularData);
    final tabularEncoded = encode(tabularData);
    final tabularRows = TestDataGenerator.generateTabularRows(rows);

    // Standard encode/decode
    await runner.run(
      name: 'Tabular $rows rows - Standard Encode',
      benchmark: () => encode(tabularData),
      dataSize: tabularSize,
      minDuration: minDur,
    );

    await runner.run(
      name: 'Tabular $rows rows - Standard Decode',
      benchmark: () => decode(tabularEncoded),
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );

    // Schema-based encode/decode (fastest path)
    await runner.run(
      name: 'Tabular $rows rows - Schema Encode',
      benchmark: () => encodeWithSchema('users', tabularRows, userSchema),
      dataSize: tabularSize,
      minDuration: minDur,
    );

    // Schema-based decode (parse rows from encoded output)
    await runner.run(
      name: 'Tabular $rows rows - Schema Decode',
      benchmark: () {
        final streamDecoder = ToonStreamDecoder(tabularEncoded);
        final rawRows = streamDecoder.decodeRawTabularRows().toList();
        decodeTabularWithSchema(rawRows, userSchema);
      },
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );

    // Stream decode (lazy, lower memory)
    await runner.run(
      name: 'Tabular $rows rows - Stream Decode',
      benchmark: () {
        final streamDecoder = ToonStreamDecoder(tabularEncoded);
        // Consume all rows to measure full throughput
        for (final _ in streamDecoder.decodeTabularRows()) {
          // iterate all
        }
      },
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );

    // Stream decode with schema (fastest lazy path)
    await runner.run(
      name: 'Tabular $rows rows - Stream Schema Decode',
      benchmark: () {
        final streamDecoder = ToonStreamDecoder(tabularEncoded);
        for (final _ in streamDecoder.decodeTabularRowsWithSchema(userSchema)) {
          // iterate all
        }
      },
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );

    // Stream chunked decode (batch processing)
    await runner.run(
      name: 'Tabular $rows rows - Stream Chunked Decode',
      benchmark: () {
        final streamDecoder = ToonStreamDecoder(tabularEncoded);
        for (final _
            in streamDecoder.decodeTabularRowsChunked(chunkSize: 100)) {
          // iterate all chunks
        }
      },
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );

    // Raw stream decode (zero-copy, no Map construction)
    await runner.run(
      name: 'Tabular $rows rows - Raw Stream Decode',
      benchmark: () {
        final streamDecoder = ToonStreamDecoder(tabularEncoded);
        for (final _ in streamDecoder.decodeRawTabularRows()) {
          // iterate all raw rows
        }
      },
      dataSize: tabularEncoded.length,
      minDuration: minDur,
    );
  }

  // =========================================================================
  // 4. Flattened schema benchmarks
  // =========================================================================
  stdout.writeln('Running flattened schema benchmarks...');

  final flattenedSchema = FlattenedSchema([
    'user.id',
    'user.name',
    'status',
    'score',
  ]);

  final flattenedRows = TestDataGenerator.generateFlattenedRows(1000);
  final flattenedData = {
    'records': flattenedRows.map((row) {
      // Reconstruct nested structure for standard encoding
      return {
        'user': row['user'],
        'status': row['status'],
        'score': row['score'],
      };
    }).toList(),
  };
  final flattenedEncoded = encode(flattenedData);

  await runner.run(
    name: 'Flattened 1000 rows - Standard Encode',
    benchmark: () => encode(flattenedData),
    dataSize: calculateDataSize(flattenedData),
    minDuration: minDur,
  );

  await runner.run(
    name: 'Flattened 1000 rows - Standard Decode',
    benchmark: () => decode(flattenedEncoded),
    dataSize: flattenedEncoded.length,
    minDuration: minDur,
  );

  await runner.run(
    name: 'Flattened 1000 rows - Schema Encode',
    benchmark: () =>
        encodeWithSchema('records', flattenedRows, flattenedSchema),
    dataSize: calculateDataSize(flattenedData),
    minDuration: minDur,
  );

  // =========================================================================
  // 5. Int-keyed schema benchmarks
  // =========================================================================
  stdout.writeln('Running int-keyed schema benchmarks...');

  final intKeyedSchema = IntKeyedSchema(
    fields: [
      SchemaField(name: 'id', type: SchemaFieldType.integer),
      SchemaField(name: 'status'),
      SchemaField(name: 'category'),
      SchemaField(name: 'priority', type: SchemaFieldType.integer),
    ],
    enumMappings: {
      'status': {0: 'pending', 1: 'active', 2: 'closed'},
      'category': {0: 'electronics', 1: 'books', 2: 'clothing', 3: 'home'},
    },
  );

  final intKeyedRows = TestDataGenerator.generateIntKeyedRows(1000);
  final intKeyedData = {
    'items': intKeyedRows,
  };
  final intKeyedEncoded = encode(intKeyedData);

  await runner.run(
    name: 'Int-Keyed 1000 rows - Standard Encode',
    benchmark: () => encode(intKeyedData),
    dataSize: calculateDataSize(intKeyedData),
    minDuration: minDur,
  );

  await runner.run(
    name: 'Int-Keyed 1000 rows - Standard Decode',
    benchmark: () => decode(intKeyedEncoded),
    dataSize: intKeyedEncoded.length,
    minDuration: minDur,
  );

  await runner.run(
    name: 'Int-Keyed 1000 rows - Schema Encode',
    benchmark: () => encodeWithSchema('items', intKeyedRows, intKeyedSchema),
    dataSize: calculateDataSize(intKeyedData),
    minDuration: minDur,
  );

  // =========================================================================
  // 6. Mixed array benchmarks
  // =========================================================================
  stdout.writeln('Running mixed array benchmarks...');
  for (final items in [100, 1000]) {
    final mixedData = TestDataGenerator.generateMixedArrayData(items);
    final mixedSize = calculateDataSize(mixedData);
    final mixedEncoded = encode(mixedData);

    await runner.run(
      name: 'Mixed $items items - Standard Encode',
      benchmark: () => encode(mixedData),
      dataSize: mixedSize,
      minDuration: minDur,
    );

    await runner.run(
      name: 'Mixed $items items - Standard Decode',
      benchmark: () => decode(mixedEncoded),
      dataSize: mixedEncoded.length,
      minDuration: minDur,
    );
  }

  // =========================================================================
  // 7. Large dataset benchmark
  // =========================================================================
  stdout.writeln('Running large dataset benchmark...');
  final largeData = TestDataGenerator.generateLargeDataset(
      users: 1000, orders: 500, products: 200);
  final largeSize = calculateDataSize(largeData);
  final largeEncoded = encode(largeData);

  await runner.run(
    name: 'Large Dataset - Standard Encode',
    benchmark: () => encode(largeData),
    dataSize: largeSize,
    minDuration: minDurLong,
  );

  await runner.run(
    name: 'Large Dataset - Standard Decode',
    benchmark: () => decode(largeEncoded),
    dataSize: largeEncoded.length,
    minDuration: minDurLong,
  );

  // Stream decode for large dataset
  await runner.run(
    name: 'Large Dataset - Stream Decode',
    benchmark: () {
      final streamDecoder = ToonStreamDecoder(largeEncoded);
      for (final _ in streamDecoder.decodeTabularRows()) {
        // iterate all
      }
    },
    dataSize: largeEncoded.length,
    minDuration: minDurLong,
  );

  // =========================================================================
  // 8. Deep nesting benchmark
  // =========================================================================
  stdout.writeln('Running deep nesting benchmarks...');
  for (final depth in [5, 10, 20]) {
    final deepData = TestDataGenerator.generateDeepNestedData(depth);
    final deepSize = calculateDataSize(deepData);
    final deepEncoded = encode(deepData);

    await runner.run(
      name: 'Depth $depth - Standard Encode',
      benchmark: () => encode(deepData),
      dataSize: deepSize,
      minDuration: minDur,
    );

    await runner.run(
      name: 'Depth $depth - Standard Decode',
      benchmark: () => decode(deepEncoded),
      dataSize: deepEncoded.length,
      minDuration: minDur,
    );
  }

  // =========================================================================
  // 9. JSON vs TOON comparison benchmark
  // =========================================================================
  stdout.writeln('Running JSON vs TOON comparison benchmarks...');
  final tabular1000 = TestDataGenerator.generateTabularData(1000);
  final tabular1000Encoded = encode(tabular1000);
  final tabular1000Json = jsonEncode(tabular1000);
  final tabular1000Rows = TestDataGenerator.generateTabularRows(1000);

  await runner.run(
    name: 'JSON Comparison - JSON Encode (1000 rows)',
    benchmark: () => jsonEncode(tabular1000),
    dataSize: calculateDataSize(tabular1000),
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - JSON Decode (1000 rows)',
    benchmark: () => jsonDecode(tabular1000Json),
    dataSize: tabular1000Json.length,
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - TOON Standard Encode (1000 rows)',
    benchmark: () => encode(tabular1000),
    dataSize: calculateDataSize(tabular1000),
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - TOON Standard Decode (1000 rows)',
    benchmark: () => decode(tabular1000Encoded),
    dataSize: tabular1000Encoded.length,
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - TOON Schema Encode (1000 rows)',
    benchmark: () => encodeWithSchema('users', tabular1000Rows, userSchema),
    dataSize: calculateDataSize(tabular1000),
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - TOON Schema Decode (1000 rows)',
    benchmark: () {
      final streamDecoder = ToonStreamDecoder(tabular1000Encoded);
      final rawRows = streamDecoder.decodeRawTabularRows().toList();
      decodeTabularWithSchema(rawRows, userSchema);
    },
    dataSize: tabular1000Encoded.length,
    minDuration: minDur,
  );

  await runner.run(
    name: 'JSON Comparison - TOON Stream Decode (1000 rows)',
    benchmark: () {
      final streamDecoder = ToonStreamDecoder(tabular1000Encoded);
      for (final _ in streamDecoder.decodeTabularRows()) {}
    },
    dataSize: tabular1000Encoded.length,
    minDuration: minDur,
  );

  // =========================================================================
  // 10. Schema encode/decode micro-benchmarks
  // =========================================================================
  stdout.writeln('Running schema micro-benchmarks...');

  final microRows = TestDataGenerator.generateTabularRows(100);
  final microMap = microRows[0];

  // Schema encodeMap (Map → List)
  await runner.run(
    name: 'Schema Micro - encodeMap (1 row)',
    benchmark: () => userSchema.encodeMap(microMap),
    dataSize: 64,
    minDuration: minDur,
  );

  // Schema decodeList (List → Map)
  final microList = userSchema.encodeMap(microMap);
  await runner.run(
    name: 'Schema Micro - decodeList (1 row)',
    benchmark: () => userSchema.decodeList(microList),
    dataSize: 64,
    minDuration: minDur,
  );

  // Schema encodeMapInto (reusable buffer)
  final microBuffer = List<dynamic>.filled(6, null);
  await runner.run(
    name: 'Schema Micro - encodeMapInto (1 row, reusable buffer)',
    benchmark: () => userSchema.encodeMapInto(microMap, microBuffer, 0),
    dataSize: 64,
    minDuration: minDur,
  );

  // Schema decodeListInto (reusable map)
  final microTarget = <String, dynamic>{};
  await runner.run(
    name: 'Schema Micro - decodeListInto (1 row, reusable map)',
    benchmark: () {
      microTarget.clear();
      userSchema.decodeListInto(microList, microTarget);
    },
    dataSize: 64,
    minDuration: minDur,
  );

  // FlattenedSchema encodeMap
  final flatRow = TestDataGenerator.generateFlattenedRows(1)[0];
  await runner.run(
    name: 'Schema Micro - FlattenedSchema encodeMap (1 row)',
    benchmark: () => flattenedSchema.encodeMap(flatRow),
    dataSize: 64,
    minDuration: minDur,
  );

  // FlattenedSchema decodeList
  final flatList = flattenedSchema.encodeMap(flatRow);
  await runner.run(
    name: 'Schema Micro - FlattenedSchema decodeList (1 row)',
    benchmark: () => flattenedSchema.decodeList(flatList),
    dataSize: 64,
    minDuration: minDur,
  );

  // IntKeyedSchema encodeMap
  final intKeyedRow = TestDataGenerator.generateIntKeyedRows(1)[0];
  await runner.run(
    name: 'Schema Micro - IntKeyedSchema encodeMap (1 row)',
    benchmark: () => intKeyedSchema.encodeMap(intKeyedRow),
    dataSize: 64,
    minDuration: minDur,
  );

  // IntKeyedSchema decodeList
  final intKeyedList = intKeyedSchema.encodeMap(intKeyedRow);
  await runner.run(
    name: 'Schema Micro - IntKeyedSchema decodeList (1 row)',
    benchmark: () => intKeyedSchema.decodeList(intKeyedList),
    dataSize: 64,
    minDuration: minDur,
  );

  // =========================================================================
  // 11. Buffer estimation benchmark
  // =========================================================================
  stdout.writeln('Running buffer estimation benchmark...');

  await runner.run(
    name: 'Buffer Estimation - estimateFromMap',
    benchmark: () => estimateEncodeSize(tabular1000),
    dataSize: calculateDataSize(tabular1000),
    minDuration: minDur,
  );

  // =========================================================================
  // Print results
  // =========================================================================
  runner.printSummary();

  // Size comparison
  stdout.writeln('SIZE COMPARISON');
  stdout.writeln('-' * 100);
  stdout.writeln('Tabular 1000 rows:');
  stdout.writeln('  JSON size: ${tabular1000Json.length} bytes');
  stdout.writeln('  TOON size: ${tabular1000Encoded.length} bytes');
  final savings =
      (1 - tabular1000Encoded.length / tabular1000Json.length) * 100;
  stdout.writeln('  Savings:   ${savings.toStringAsFixed(1)}%');
  stdout.writeln('');

  // Schema size comparison
  final schemaEncoded = encodeWithSchema('users', tabular1000Rows, userSchema);
  stdout.writeln('  TOON Schema size: ${schemaEncoded.length} bytes');
  final schemaSavings =
      (1 - schemaEncoded.length / tabular1000Json.length) * 100;
  stdout.writeln('  Schema Savings:   ${schemaSavings.toStringAsFixed(1)}%');
  stdout.writeln('');

  // Int-keyed size comparison
  final intKeyedData1000 = {
    'items': TestDataGenerator.generateIntKeyedRows(1000)
  };
  final intKeyedEncoded1000 = encode(intKeyedData1000);
  final intKeyedJson1000 = jsonEncode(intKeyedData1000);
  final intKeyedSchemaRows = TestDataGenerator.generateIntKeyedRows(1000);
  final intKeyedSchemaEncoded =
      encodeWithSchema('items', intKeyedSchemaRows, intKeyedSchema);

  stdout.writeln('Int-Keyed 1000 rows:');
  stdout.writeln('  JSON size:        ${intKeyedJson1000.length} bytes');
  stdout.writeln('  TOON size:        ${intKeyedEncoded1000.length} bytes');
  stdout.writeln('  TOON Schema size: ${intKeyedSchemaEncoded.length} bytes');
  final intKeyedSavings =
      (1 - intKeyedSchemaEncoded.length / intKeyedJson1000.length) * 100;
  stdout.writeln('  Schema Savings:   ${intKeyedSavings.toStringAsFixed(1)}%');
  stdout.writeln('');
}
