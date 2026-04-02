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
    stdout.writeln('\n${'=' * 80}');
    stdout.writeln('BENCHMARK RESULTS');
    stdout.writeln('${'=' * 80}\n');

    // Group by category
    final categories = <String, List<BenchmarkResult>>{};
    for (final result in results) {
      final category = result.name.split(' - ')[0];
      categories.putIfAbsent(category, () => []).add(result);
    }

    for (final entry in categories.entries) {
      stdout.writeln('${entry.key}:');
      stdout.writeln('-' * 80);
      for (final result in entry.value) {
        stdout.writeln('  ${result.name.split(' - ').last.padRight(35)} | '
            '${result.iterations.toString().padLeft(8)} ops | '
            '${_formatDuration(result.duration).padLeft(10)} | '
            '${result.opsPerSec.toStringAsFixed(0).padLeft(10)} ops/s | '
            '${result.nsPerOp.toStringAsFixed(0).padLeft(10)} ns/op');
      }
      stdout.writeln();
    }

    // Performance comparison
    stdout.writeln('${'=' * 80}');
    stdout.writeln('ENCODE vs DECODE COMPARISON');
    stdout.writeln('${'=' * 80}\n');

    final encodeResults =
        results.where((r) => r.name.contains('Encode')).toList();
    final decodeResults =
        results.where((r) => r.name.contains('Decode')).toList();

    for (int i = 0; i < encodeResults.length && i < decodeResults.length; i++) {
      final encode = encodeResults[i];
      final decode = decodeResults[i];
      final ratio = decode.opsPerSec / encode.opsPerSec;

      stdout.writeln('${encode.name.split(' - ').last.padRight(35)} | '
          'Encode: ${encode.opsPerSec.toStringAsFixed(0).padLeft(8)} ops/s | '
          'Decode: ${decode.opsPerSec.toStringAsFixed(0).padLeft(8)} ops/s | '
          'Ratio: ${ratio.toStringAsFixed(2)}x');
    }

    stdout.writeln('\n${'=' * 80}\n');
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

  // 1. Simple object benchmarks
  stdout.writeln('Running simple object benchmarks...');
  final simpleObject = TestDataGenerator.generateFlatObject();
  final simpleObjectSize = calculateDataSize(simpleObject);
  final simpleEncoded = encode(simpleObject);

  await runner.run(
    name: 'Simple Object - Encode',
    benchmark: () => encode(simpleObject),
    dataSize: simpleObjectSize,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  await runner.run(
    name: 'Simple Object - Decode',
    benchmark: () => decode(simpleEncoded),
    dataSize: simpleEncoded.length,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  // 2. Nested object benchmarks
  stdout.writeln('Running nested object benchmarks...');
  final nestedObject = TestDataGenerator.generateNestedObject();
  final nestedObjectSize = calculateDataSize(nestedObject);
  final nestedEncoded = encode(nestedObject);

  await runner.run(
    name: 'Nested Object - Encode',
    benchmark: () => encode(nestedObject),
    dataSize: nestedObjectSize,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  await runner.run(
    name: 'Nested Object - Decode',
    benchmark: () => decode(nestedEncoded),
    dataSize: nestedEncoded.length,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  // 3. Tabular data benchmarks (TOON's sweet spot)
  stdout.writeln('Running tabular data benchmarks...');
  for (final rows in [100, 1000, 10000]) {
    final tabularData = TestDataGenerator.generateTabularData(rows);
    final tabularSize = calculateDataSize(tabularData);
    final tabularEncoded = encode(tabularData);

    await runner.run(
      name: 'Tabular ${rows} rows - Encode',
      benchmark: () => encode(tabularData),
      dataSize: tabularSize,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );

    await runner.run(
      name: 'Tabular ${rows} rows - Decode',
      benchmark: () => decode(tabularEncoded),
      dataSize: tabularEncoded.length,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );
  }

  // 4. Mixed array benchmarks
  stdout.writeln('Running mixed array benchmarks...');
  for (final items in [100, 1000]) {
    final mixedData = TestDataGenerator.generateMixedArrayData(items);
    final mixedSize = calculateDataSize(mixedData);
    final mixedEncoded = encode(mixedData);

    await runner.run(
      name: 'Mixed ${items} items - Encode',
      benchmark: () => encode(mixedData),
      dataSize: mixedSize,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );

    await runner.run(
      name: 'Mixed ${items} items - Decode',
      benchmark: () => decode(mixedEncoded),
      dataSize: mixedEncoded.length,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );
  }

  // 5. Large dataset benchmark
  stdout.writeln('Running large dataset benchmark...');
  final largeData = TestDataGenerator.generateLargeDataset(
      users: 1000, orders: 500, products: 200);
  final largeSize = calculateDataSize(largeData);
  final largeEncoded = encode(largeData);

  await runner.run(
    name: 'Large Dataset - Encode',
    benchmark: () => encode(largeData),
    dataSize: largeSize,
    minDuration: quick ? Duration(milliseconds: 200) : Duration(seconds: 1),
  );

  await runner.run(
    name: 'Large Dataset - Decode',
    benchmark: () => decode(largeEncoded),
    dataSize: largeEncoded.length,
    minDuration: quick ? Duration(milliseconds: 200) : Duration(seconds: 1),
  );

  // 6. Deep nesting benchmark
  stdout.writeln('Running deep nesting benchmarks...');
  for (final depth in [5, 10, 20]) {
    final deepData = TestDataGenerator.generateDeepNestedData(depth);
    final deepSize = calculateDataSize(deepData);
    final deepEncoded = encode(deepData);

    await runner.run(
      name: 'Depth $depth - Encode',
      benchmark: () => encode(deepData),
      dataSize: deepSize,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );

    await runner.run(
      name: 'Depth $depth - Decode',
      benchmark: () => decode(deepEncoded),
      dataSize: deepEncoded.length,
      minDuration:
          quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
    );
  }

  // 7. JSON comparison benchmark
  stdout.writeln('Running JSON comparison benchmarks...');
  final tabular1000 = TestDataGenerator.generateTabularData(1000);
  final tabular1000Encoded = encode(tabular1000);
  final tabular1000Json = jsonEncode(tabular1000);

  await runner.run(
    name: 'JSON Encode (1000 rows)',
    benchmark: () => jsonEncode(tabular1000),
    dataSize: calculateDataSize(tabular1000),
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  await runner.run(
    name: 'JSON Decode (1000 rows)',
    benchmark: () => jsonDecode(tabular1000Json),
    dataSize: tabular1000Json.length,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  await runner.run(
    name: 'TOON Encode (1000 rows)',
    benchmark: () => encode(tabular1000),
    dataSize: calculateDataSize(tabular1000),
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  await runner.run(
    name: 'TOON Decode (1000 rows)',
    benchmark: () => decode(tabular1000Encoded),
    dataSize: tabular1000Encoded.length,
    minDuration:
        quick ? Duration(milliseconds: 100) : Duration(milliseconds: 500),
  );

  // Print results
  runner.printSummary();

  // Size comparison
  stdout.writeln('SIZE COMPARISON');
  stdout.writeln('-' * 80);
  stdout.writeln('Tabular 1000 rows:');
  stdout.writeln('  JSON size: ${tabular1000Json.length} bytes');
  stdout.writeln('  TOON size: ${tabular1000Encoded.length} bytes');
  final savings =
      (1 - tabular1000Encoded.length / tabular1000Json.length) * 100;
  stdout.writeln('  Savings:   ${savings.toStringAsFixed(1)}%');
  stdout.writeln('');
}
