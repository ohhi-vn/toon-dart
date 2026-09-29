import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

void main() {
  group('keyless keyed root header (§9.5)', () {
    test('decodes keyless keyed tabular object', () {
      expect(
        decode('[2:]{name}:\n  a: 1\n  b: 2'),
        equals({
          'a': {'name': 1.0},
          'b': {'name': 2.0},
        }),
      );
    });
  });

  group('inline array length validation', () {
    test('empty inline values with non-zero length throws in strict mode', () {
      expect(
        () => decode('nums[1]:', options: const DecodeOptions(strict: true)),
        throwsRangeError,
      );
    });

    test('empty inline values with zero length is valid in strict mode', () {
      expect(
        decode('nums[0]:', options: const DecodeOptions(strict: true)),
        equals({'nums': <dynamic>[]}),
      );
    });

    test('empty inline values allowed in lenient mode', () {
      expect(
        decode('nums[1]:', options: const DecodeOptions(strict: false)),
        equals({'nums': <dynamic>[]}),
      );
    });
  });

  group('primitive root decoding', () {
    test('decodes a single line primitive', () {
      expect(decode('42'), equals(42));
      expect(decode('hello'), equals('hello'));
      expect(decode('true'), equals(true));
    });

    test('single line starting with bracket decodes as primitive', () {
      expect(decode('[foo]'), equals('[foo]'));
      expect(decode('[]'), equals([]));
    });
  });

  group('list item edge cases', () {
    test('empty list item produces empty object', () {
      expect(decode('items[1]:\n  -'), equals({'items': [{}]}));
    });

    test('non-list-item line at item depth breaks array in strict mode', () {
      expect(
        () => decode('items[1]:\n  x: 1'),
        throwsRangeError,
      );
    });

    test('deeper orphaned line in list-item object breaks gracefully', () {
      expect(
        decode('[2]:\n  - a: 1\n    b: 2\n      c: 3',
            options: const DecodeOptions(strict: false)),
        equals([{'a': 1, 'b': 2}]),
      );
    });
  });
}
