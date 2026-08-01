import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/encode/normalize.dart';
import '../lib/src/types.dart';

void main() {
  group('normalizeValue', () {
    test('passes through primitives', () {
      expect(normalizeValue(null), isNull);
      expect(normalizeValue('hi'), equals('hi'));
      expect(normalizeValue(true), equals(true));
      expect(normalizeValue(42), equals(42));
    });

    test('canonicalizes negative zero', () {
      expect(normalizeValue(-0.0), equals(0));
    });

    test('converts NaN and Infinity to null', () {
      expect(normalizeValue(double.nan), isNull);
      expect(normalizeValue(double.infinity), isNull);
      expect(normalizeValue(double.negativeInfinity), isNull);
    });

    test('converts BigInt within safe range to int', () {
      expect(normalizeValue(BigInt.from(9007199254740991)), equals(9007199254740991));
    });

    test('converts BigInt outside safe range to string', () {
      expect(
        normalizeValue(BigInt.parse('9007199254740992')),
        equals('9007199254740992'),
      );
    });

    test('converts DateTime to ISO string', () {
      final dt = DateTime(2024, 1, 15, 10, 30);
      expect(normalizeValue(dt), equals('2024-01-15T10:30:00.000'));
    });

    test('normalizes lists recursively', () {
      expect(
        normalizeValue([1, 'a', true, null]),
        equals([1, 'a', true, null]),
      );
    });

    test('normalizes sets to arrays', () {
      expect(normalizeValue({1, 2, 3}), equals([1, 2, 3]));
    });

    test('normalizes maps to objects', () {
      expect(
        normalizeValue({'a': 1, 'b': 'x'}),
        equals({'a': 1, 'b': 'x'}),
      );
    });

    test('normalizes map with non-string keys via toString', () {
      expect(
        normalizeValue({1: 'one', true: 'yes'}),
        equals({'1': 'one', 'true': 'yes'}),
      );
    });

    test('falls back to null for unsupported types', () {
      expect(normalizeValue(Object()), isNull);
    });
  });

  group('type guards', () {
    test('isJsonPrimitive', () {
      expect(isJsonPrimitive(null), isTrue);
      expect(isJsonPrimitive('a'), isTrue);
      expect(isJsonPrimitive(1), isTrue);
      expect(isJsonPrimitive(true), isTrue);
      expect(isJsonPrimitive([]), isFalse);
      expect(isJsonPrimitive({}), isFalse);
    });

    test('isJsonArray', () {
      expect(isJsonArray([]), isTrue);
      expect(isJsonArray('x'), isFalse);
    });

    test('isJsonObject', () {
      expect(isJsonObject(<String, Object?>{}), isTrue);
      expect(isJsonObject([1]), isFalse);
    });

    test('isPlainObject', () {
      expect(isPlainObject({'a': 1}), isTrue);
      expect(isPlainObject([]), isFalse);
      expect(isPlainObject('a'), isFalse);
    });

    test('isArrayOfPrimitives', () {
      expect(isArrayOfPrimitives([1, 'a', true]), isTrue);
      expect(isArrayOfPrimitives([1, []]), isFalse);
      expect(isArrayOfPrimitives([]), isTrue);
    });

    test('isArrayOfArrays', () {
      expect(isArrayOfArrays([[1], [2]]), isTrue);
      expect(isArrayOfArrays([[1], 'x']), isFalse);
    });

    test('isArrayOfObjects', () {
      expect(isArrayOfObjects([{'a': 1}]), isTrue);
      expect(isArrayOfObjects([{'a': 1}, 2]), isFalse);
    });
  });

  group('extractTabularFields', () {
    test('returns null for empty rows', () {
      expect(extractTabularFields([]), isNull);
    });

    test('returns null for empty first row', () {
      expect(extractTabularFields([{}]), isNull);
    });

    test('returns null when rows have different keys', () {
      final rows = <JsonObject>[
        {'a': 1, 'b': 2},
        {'a': 1, 'c': 3},
      ];
      expect(extractTabularFields(rows), isNull);
    });

    test('returns null when columns are non-uniform', () {
      final rows = <JsonObject>[
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': [1, 2]},
      ];
      expect(extractTabularFields(rows), isNull);
    });

    test('returns fields for uniform rows', () {
      final rows = <JsonObject>[
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ];
      final fields = extractTabularFields(rows);
      expect(fields, isNotNull);
      expect(fields!.map((f) => f.name), equals(['id', 'name']));
    });

    test('detects nested field groups', () {
      final rows = <JsonObject>[
        {
          'name': 'Alice',
          'address': {'city': 'NYC', 'zip': '10001'},
        },
      ];
      final fields = extractTabularFields(rows);
      expect(fields, isNotNull);
      expect(fields!.length, equals(2));
      expect(fields[1].name, equals('address'));
      expect(fields[1].nestedFields, isNotNull);
      expect(fields[1].leafNames, equals(['city', 'zip']));
      expect(fields[1].leafCount, equals(2));
    });

    test('leaf field has leafCount 1 and leafNames [name]', () {
      const field = TabularField('id');
      expect(field.leafCount, equals(1));
      expect(field.leafNames, equals(['id']));
      expect(field.nestedFields, isNull);
    });
  });

  group('isKeyedTabularEligible', () {
    test('returns false for fewer than 2 entries', () {
      expect(isKeyedTabularEligible({'a': {'x': 1}}), isFalse);
    });

    test('returns false when first value is not an object', () {
      expect(
        isKeyedTabularEligible({'a': 1, 'b': 2}),
        isFalse,
      );
    });

    test('returns false when values are empty objects', () {
      expect(
        isKeyedTabularEligible({'a': {}, 'b': {}}),
        isFalse,
      );
    });

    test('returns false when objects have different keys', () {
      expect(
        isKeyedTabularEligible({
          'a': {'x': 1},
          'b': {'y': 2},
        }),
        isFalse,
      );
    });

    test('returns false when columns are non-uniform', () {
      expect(
        isKeyedTabularEligible({
          'a': {'x': 1},
          'b': {'x': [1, 2]},
        }),
        isFalse,
      );
    });

    test('returns true for eligible objects', () {
      expect(
        isKeyedTabularEligible({
          'a': {'x': 1, 'y': 2},
          'b': {'x': 3, 'y': 4},
        }),
        isTrue,
      );
    });
  });

  group('detectKeyedFields', () {
    test('detects fields from first entry', () {
      final fields = detectKeyedFields({
        'a': {'id': 1, 'name': 'Alice'},
        'b': {'id': 2, 'name': 'Bob'},
      });
      expect(fields.map((f) => f.name), equals(['id', 'name']));
    });
  });
}
