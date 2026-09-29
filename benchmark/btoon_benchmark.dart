// Micro-benchmarks for the BTOON codec (encode/decode hot paths).
//
// Run with: dart run benchmark/btoon_benchmark.dart
import 'dart:convert';

import 'package:toon_format/toon_format.dart';

class Bench {
  final String name;
  final void Function() body;
  final int minMs;
  Bench(this.name, this.body, {this.minMs = 400});
}

double _nowMs() => DateTime.now().microsecondsSinceEpoch / 1000;

void runBench(Bench b) {
  // Warm-up (JIT).
  for (var i = 0; i < 200; i++) {
    b.body();
  }
  var iterations = 1;
  var elapsed = 0.0;
  var minMs = b.minMs;
  while (true) {
    final start = _nowMs();
    for (var i = 0; i < iterations; i++) {
      b.body();
    }
    elapsed = _nowMs() - start;
    if (elapsed >= minMs) break;
    if (elapsed < 50) {
      iterations *= 10;
    } else {
      iterations = (iterations * minMs / elapsed * 1.2).ceil();
    }
    minMs = b.minMs;
    if (iterations > 100000000) break;
  }
  final perOpUs = elapsed * 1000 / iterations;
  print('${b.name.padRight(52)} '
      '${perOpUs.toStringAsFixed(1).padLeft(10)} us/op '
      '${(iterations / (elapsed / 1000)).toStringAsFixed(0).padLeft(12)} ops/s');
}

void main(List<String> args) {
  final quick = args.contains('--quick');
  final minMs = quick ? 100 : 500;

  // -- Payloads --------------------------------------------------------------
  final smallMap = {'name': 'Alice', 'age': 30, 'active': true};

  final nestedUsers = <Map<String, Object?>>[];
  for (var i = 0; i < 100; i++) {
    nestedUsers.add({
      'id': i,
      'name': 'user$i',
      'score': i * 1.5,
      'tags': ['a', 'b'],
    });
  }
  final nested = {
    'users': nestedUsers,
    'meta': {'count': 100, 'owner': 'admin'},
  };

  final rows = [
    for (var i = 0; i < 1000; i++) {'id': i, 'x': i * 1.5, 'y': i * 2.5},
  ];

  final ints = List<int>.generate(10000, (i) => i * 7 % 100000);
  final doubles = List<double>.generate(100000, (i) => i * 1.5);
  final strings = [
    for (var i = 0; i < 5000; i++) 'string-value-$i-with-some-length',
  ];

  final session = BtoonSession();
  for (var i = 0; i < 1000; i++) {
    session.add('user$i');
  }
  session.add('id');
  session.add('name');

  final schema = BtoonSchema([
    const BtoonSchemaField('id', type: BtoonSchemaType.integer),
    const BtoonSchemaField('x', type: BtoonSchemaType.number),
    const BtoonSchemaField('y', type: BtoonSchemaType.number),
  ]);

  // -- Encode ----------------------------------------------------------------
  runBench(Bench('encode small map', () {
    btoonEncode(smallMap);
  }, minMs: minMs));

  runBench(Bench('encode nested map 100 users', () {
    btoonEncode(nested);
  }, minMs: minMs));

  runBench(Bench('encode object table 1000x3', () {
    btoonEncode(rows);
  }, minMs: minMs));

  runBench(Bench('encode int list 10k (TypedArray)', () {
    btoonEncode(ints);
  }, minMs: minMs));

  runBench(Bench('encode double list 100k (TypedArray)', () {
    btoonEncode(doubles);
  }, minMs: minMs));

  runBench(Bench('encode string list 5k', () {
    btoonEncode(strings);
  }, minMs: minMs));

  runBench(Bench('encode schema mode 1000 rows', () {
    btoonEncode(rows, options: const BtoonEncodeOptions(schemaMode: true));
  }, minMs: minMs));

  runBench(Bench('encode schema mode + session 1000 rows', () {
    btoonEncode(
      rows,
      options: BtoonEncodeOptions(
        schema: schema,
        schemaMode: true,
        session: session,
      ),
    );
  }, minMs: minMs));

  // -- Decode ----------------------------------------------------------------
  final smallMapBytes = btoonEncode(smallMap);
  final nestedBytes = btoonEncode(nested);
  final rowsBytes = btoonEncode(rows);
  final intsBytes = btoonEncode(ints);
  final doublesBytes = btoonEncode(doubles);
  final stringsBytes = btoonEncode(strings);
  final schemaBytes =
      btoonEncode(rows, options: const BtoonEncodeOptions(schemaMode: true));

  runBench(Bench('decode small map', () {
    btoonDecode(smallMapBytes);
  }, minMs: minMs));

  runBench(Bench('decode nested map 100 users', () {
    btoonDecode(nestedBytes);
  }, minMs: minMs));

  runBench(Bench('decode object table 1000x3', () {
    btoonDecode(rowsBytes);
  }, minMs: minMs));

  runBench(Bench('decode int list 10k (TypedArray)', () {
    btoonDecode(intsBytes);
  }, minMs: minMs));

  runBench(Bench('decode double list 100k (TypedArray)', () {
    btoonDecode(doublesBytes);
  }, minMs: minMs));

  runBench(Bench('decode string list 5k', () {
    btoonDecode(stringsBytes);
  }, minMs: minMs));

  runBench(Bench('decode schema mode 1000 rows', () {
    btoonDecode(schemaBytes);
  }, minMs: minMs));

  // Sanity: JSON baseline for scale.
  final nestedJson = jsonEncode(nested);
  runBench(Bench('jsonEncode nested (baseline)', () {
    jsonEncode(nested);
  }, minMs: minMs));
  runBench(Bench('jsonDecode nested (baseline)', () {
    jsonDecode(nestedJson);
  }, minMs: minMs));
}
