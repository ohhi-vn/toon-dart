import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/encode/encoders.dart';
import '../lib/src/encode/writer.dart';
import '../lib/src/types.dart';

void main() {
  const opts = ResolvedEncodeOptions(indent: 2, delimiter: ',');

  group('encodeKeyValuePair', () {
    test('writes key: value line', () {
      final writer = LineWriter(2);
      encodeKeyValuePair('k', 5, writer, 0, opts);
      expect(writer.toString(), equals('k: 5'));
    });
  });

  group('isTabularArray', () {
    test('returns true for uniform primitive rows', () {
      expect(
        isTabularArray([
          {'a': 1, 'b': 2},
          {'a': 3, 'b': 4},
        ], ['a', 'b']),
        isTrue,
      );
    });

    test('returns false when key counts differ', () {
      expect(isTabularArray([
        {'a': 1},
      ], ['a', 'b']), isFalse);
    });

    test('returns false when keys are missing', () {
      expect(isTabularArray([
        {'a': 1, 'c': 2},
      ], ['a', 'b']), isFalse);
    });

    test('returns false when values are not primitives', () {
      expect(isTabularArray([
        {'a': [1], 'b': 2},
      ], ['a', 'b']), isFalse);
    });
  });

  group('writeTabularRows', () {
    test('writes delimited rows at depth', () {
      final writer = LineWriter(2);
      writeTabularRows([
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ], ['a', 'b'], writer, 1, opts);
      expect(writer.toString(), equals('  1,x\n  2,y'));
    });
  });

  group('encoder list-item branches', () {
    test('encodes empty object as list-item first value', () {
      expect(
        encode({'x': [5, {'empty': {}, 'a': 1}]}),
        equals('x[2]:\n  - 5\n  - empty:\n    a: 1'),
      );
    });

    test('encodes nested array-of-arrays with object items', () {
      expect(
        encode({'x': [[[{'a': 1}]]]}),
        equals('x[1]:\n  [1]:\n    - [1]:\n      - a: 1'),
      );
    });

    test('encodes mixed nested array in list item', () {
      expect(
        encode({'x': [[1, [2]]]}),
        equals('x[1]:\n  [2]:\n    - 1\n    - [1]: 2'),
      );
    });

    test('encodes nested tabular header for object list item', () {
      expect(
        encode({
          'x': [
            {'data': [{'a': {'x': 1}}, {'a': {'x': 2}}], 'z': 1}
          ]
        }),
        equals('x[1]:\n  - data[2]{a{x}}:\n      1\n      2\n    z: 1'),
      );
    });

    test('encodes array-of-arrays with primitive inner arrays in list item', () {
      expect(
        encode({'items': [[[1, 2], [3, 4]], 'hello']}),
        equals('items[2]:\n  [2]:\n    - [2]: 1,2\n    - [2]: 3,4\n  - hello'),
      );
    });

    test('nested tabular header honors length marker', () {
      expect(
        encode({
          'x': [
            {'data': [{'a': {'x': 1}}, {'a': {'x': 2}}], 'z': 1}
          ]
        }, options: const EncodeOptions(lengthMarker: '#')),
        equals('x[#1]:\n  - data[#2]{a{x}}:\n      1\n      2\n    z: 1'),
      );
    });
  });
}
