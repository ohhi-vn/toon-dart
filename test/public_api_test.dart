import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

void main() {
  group('encode public API', () {
    test('encodes a map with default options', () {
      final toon = encode({'name': 'Alice', 'age': 30});
      expect(toon, equals('name: Alice\nage: 30'));
    });

    test('encodes nested structures', () {
      final toon = encode({
        'name': 'Alice',
        'tags': ['a', 'b'],
        'address': {'city': 'NYC'},
      });
      expect(toon, contains('name: Alice'));
      expect(toon, contains('tags[2]: a,b'));
      expect(toon, contains('city: NYC'));
    });

    test('respects custom encode options', () {
      final toon = encode(
        {'items': [1, 2]},
        options: const EncodeOptions(indent: 4, delimiter: '|'),
      );
      expect(toon, equals('items[2|]: 1|2'));
    });

    test('encodes with length marker', () {
      final toon = encode(
        {'items': [1, 2]},
        options: const EncodeOptions(lengthMarker: '#'),
      );
      expect(toon, equals('items[#2]: 1,2'));
    });

    test('EncodeOptions asserts positive indent', () {
      expect(() => EncodeOptions(indent: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('decode public API', () {
    test('decodes a simple document', () {
      final data = decode('name: Alice\nage: 30');
      expect(data, equals({'name': 'Alice', 'age': 30}));
    });

    test('decodes nested structures', () {
      final data = decode('tags[2]: a,b\naddress:\n  city: NYC');
      expect(data, equals({
        'tags': ['a', 'b'],
        'address': {'city': 'NYC'},
      }));
    });

    test('respects custom decode options', () {
      final data = decode('a: 1', options: const DecodeOptions(indent: 4));
      expect(data, equals({'a': 1}));
    });

    test('lenient mode tolerates mismatched array length', () {
      final data = decode(
        'tags[3]: a,b',
        options: const DecodeOptions(strict: false),
      );
      expect(data, equals({'tags': ['a', 'b']}));
    });

    test('DecodeOptions asserts positive indent', () {
      expect(() => DecodeOptions(indent: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('encodeWithSchema public API', () {
    test('encodes tabular data with schema', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final toon = encodeWithSchema('users', [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ], schema);
      expect(toon, equals('users[2]{id,name}:\n  1,Alice\n  2,Bob'));
    });

    test('keyless encoding', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final toon = encodeWithSchema(null, [
        {'id': 1, 'name': 'Alice'},
      ], schema);
      expect(toon, equals('[1]{id,name}:\n  1,Alice'));
    });

    test('respects options', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final toon = encodeWithSchema(
        'rows',
        [
          {'id': 1},
        ],
        schema,
        options: const EncodeOptions(delimiter: '|', lengthMarker: '#'),
      );
      expect(toon, equals('rows[#1|]{id}:\n  1'));
    });
  });

  group('decodeWithSchema public API', () {
    test('decodes rows with schema', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final rows = decodeWithSchema(['1,Alice', '2,Bob'], schema);
      expect(rows, equals([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]));
    });

    test('respects custom delimiter', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final rows = decodeWithSchema(
        ['1|Alice'],
        schema,
        delimiter: '|',
      );
      expect(rows, equals([
        {'id': 1, 'name': 'Alice'},
      ]));
    });
  });

  group('streamDecode public API', () {
    test('streams tabular rows', () {
      final stream = streamDecode('users[2]{id,name}:\n  1,Alice\n  2,Bob');
      final rows = stream.decodeTabularRows().toList();
      expect(rows, equals([
        {'id': 1.0, 'name': 'Alice'},
        {'id': 2.0, 'name': 'Bob'},
      ]));
    });

    test('streamTabularRowsConvenience', () {
      final rows = streamTabularRowsConvenience(
        'users[2]{id,name}:\n  1,Alice\n  2,Bob',
      ).toList();
      expect(rows, hasLength(2));
    });

    test('respects options', () {
      final stream = streamDecode(
        'a: 1',
        options: const DecodeOptions(indent: 4),
      );
      expect(stream, isNotNull);
    });
  });

  group('estimateEncodeSize public API', () {
    test('estimates size for a map', () {
      final size = estimateEncodeSize({
        'name': 'Alice',
        'age': 30,
        'tags': ['a', 'b'],
      });
      expect(size, greaterThan(0));
    });
  });
}
