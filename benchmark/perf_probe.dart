import 'dart:math';

import 'package:toon_format/toon_format.dart';

/// Focused encode/decode benchmark used to validate performance work.
///
/// Run: dart run benchmark/perf_probe.dart
void main() {
  final rng = Random(42);
  String name(int i) => 'user-$i-${rng.nextInt(1000)}';
  final flatRows = [
    for (var i = 0; i < 2000; i++)
      {'id': i, 'name': name(i), 'score': rng.nextDouble() * 100, 'active': i.isEven},
  ];
  final nestedRows = [
    for (var i = 0; i < 1200; i++)
      {
        'id': i,
        'meta': {'a': i, 'b': 'x$i'},
      },
  ];
  final mixedDoc = {
    'users': [
      for (var i = 0; i < 500; i++) {'id': i, 'name': name(i)},
    ],
    'tags': ['alpha', 'beta', 'gamma', 'delta'],
    'config': {'retries': 3, 'timeout': 30.5, 'debug': false},
    'matrix': [
      [1, 2, 3],
      [4, 5, 6],
    ],
    'notes': [
      {'text': 'plain'},
      {'text': 'has, comma'},
      {'id': 1},
    ],
  };

  void bench(String label, int iters, void Function() body) {
    // Warmup.
    for (var i = 0; i < 3; i++) {
      body();
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      body();
    }
    sw.stop();
    final us = sw.elapsedMicroseconds / iters;
    print('$label: ${us.toStringAsFixed(1)} us/op');
  }

  final flatToon = encode({'users': flatRows});
  final nestedToon = encode({'users': nestedRows});
  final mixedToon = encode(mixedDoc);

  print('--- encode ---');
  bench('encode tabular 2000 rows x4 cols', 20, () {
    encode({'users': flatRows});
  });
  bench('encode nested-uniform 1200 rows', 20, () {
    encode({'users': nestedRows});
  });
  bench('encode mixed doc', 50, () {
    encode(mixedDoc);
  });

  print('--- decode ---');
  bench('decode tabular 2000 rows', 20, () {
    decode(flatToon);
  });
  bench('decode inline arrays doc', 200, () {
    decode('points[3]: 1,2,3\nflags[2]: true,false\nnames[2]: a,b');
  });
  bench('decode mixed doc', 50, () {
    decode(mixedToon);
  });
  bench('decode list-item objects (500)', 30, () {
    decode(encode([
      for (var i = 0; i < 500; i++)
        {'id': i, 'name': name(i), 'nested': {'x': i}},
    ]));
  });

  print('--- round trip ---');
  bench('round-trip mixed doc', 30, () {
    decode(encode(mixedDoc));
  });
  print('(sizes) flat=${flatToon.length} nested=${nestedToon.length} '
      'mixed=${mixedToon.length}');

  print('--- btoon ---');
  final ints = [for (var i = 0; i < 10000; i++) rng.nextInt(100000)];
  final table = [
    for (var i = 0; i < 2000; i++)
      {'id': i, 'score': rng.nextDouble() * 100, 'flag': i.isEven ? 1 : 0},
  ];
  bench('btoon encode int list 10000', 50, () {
    btoonEncode(ints);
  });
  bench('btoon encode object table 2000x3', 30, () {
    btoonEncode(table);
  });
  final tableBytes = btoonEncode(table);
  bench('btoon decode object table 2000x3', 30, () {
    btoonDecode(tableBytes);
  });

  // Silence unused warnings when tuning.
  assert(nestedToon.isNotEmpty);
}
