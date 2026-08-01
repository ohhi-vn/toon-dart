import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

class UserSchema extends ToonSchema {
  @override
  List<SchemaField> get fields => const [
        SchemaField(name: 'id', type: SchemaFieldType.integer),
        SchemaField(name: 'name', type: SchemaFieldType.string),
        SchemaField(name: 'age', type: SchemaFieldType.integer),
      ];
}

void main() {
  group('SchemaFieldType', () {
    test('matches values by type', () {
      expect(SchemaFieldType.string.matches('a'), isTrue);
      expect(SchemaFieldType.string.matches(1), isFalse);
      expect(SchemaFieldType.integer.matches(1), isTrue);
      expect(SchemaFieldType.integer.matches(1.5), isFalse);
      expect(SchemaFieldType.number.matches(1.5), isTrue);
      expect(SchemaFieldType.number.matches(1), isTrue);
      expect(SchemaFieldType.boolean.matches(true), isTrue);
      expect(SchemaFieldType.boolean.matches('true'), isFalse);
      expect(SchemaFieldType.null_.matches(null), isTrue);
      expect(SchemaFieldType.null_.matches(0), isFalse);
      expect(SchemaFieldType.object.matches({'a': 1}), isTrue);
      expect(SchemaFieldType.object.matches(1), isFalse);
      expect(SchemaFieldType.array.matches([1]), isTrue);
      expect(SchemaFieldType.array.matches('x'), isFalse);
      expect(SchemaFieldType.any.matches('anything'), isTrue);
    });
  });

  group('ConcreteSchema', () {
    test('fromNames creates schema with any-typed fields', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      expect(schema.fieldNames, equals(['id', 'name']));
      expect(schema.fieldCount, equals(2));
      expect(schema.fields[0].type, equals(SchemaFieldType.any));
    });

    test('typed creates schema with types', () {
      final schema = ConcreteSchema.typed([
        ('id', SchemaFieldType.integer),
        ('name', SchemaFieldType.string),
      ]);
      expect(schema.fields[0].type, equals(SchemaFieldType.integer));
      expect(schema.fields[1].type, equals(SchemaFieldType.string));
    });

    test('direct constructor creates schema with fields', () {
      final schema = ConcreteSchema([
        SchemaField(name: 'id', type: SchemaFieldType.integer),
        SchemaField(name: 'name', type: SchemaFieldType.string),
      ]);
      expect(schema.fieldNames, equals(['id', 'name']));
      expect(schema.fields[0].type, equals(SchemaFieldType.integer));
    });

    test('encodeMap produces positional list', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
      expect(
        schema.encodeMap({'id': 1, 'name': 'A', 'age': 30}),
        equals([1, 'A', 30]),
      );
    });

    test('encodeMap returns null for missing fields', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      expect(schema.encodeMap({'id': 1}), equals([1, null]));
    });

    test('encodeMapInto writes into a pre-allocated buffer', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final buffer = List<dynamic>.filled(4, null);
      final written = schema.encodeMapInto({'id': 1, 'name': 'A'}, buffer, 1);
      expect(written, equals(2));
      expect(buffer, equals([null, 1, 'A', null]));
    });

    test('decodeList produces map', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      expect(schema.decodeList([1, 'A']), equals({'id': 1, 'name': 'A'}));
    });

    test('decodeList ignores extra values', () {
      final schema = ConcreteSchema.fromNames(['id']);
      expect(schema.decodeList([1, 'extra']), equals({'id': 1}));
    });

    test('decodeListInto writes into provided map', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final map = <String, dynamic>{};
      final written = schema.decodeListInto([1, 'A'], map);
      expect(written, equals(2));
      expect(map, equals({'id': 1, 'name': 'A'}));
    });

    test('matches checks presence and types', () {
      final schema = ConcreteSchema.typed([
        ('id', SchemaFieldType.integer),
        ('name', SchemaFieldType.string),
      ]);
      expect(schema.matches({'id': 1, 'name': 'A'}), isTrue);
      expect(schema.matches({'id': '1', 'name': 'A'}), isFalse);
      expect(schema.matches({'id': 1}), isFalse);
    });

    test('matches ignores null values for type check', () {
      final schema = ConcreteSchema.typed([('id', SchemaFieldType.integer)]);
      expect(schema.matches({'id': null}), isTrue);
    });

    test('matchesAll checks all rows', () {
      final schema = ConcreteSchema.typed([('id', SchemaFieldType.integer)]);
      expect(schema.matchesAll([{'id': 1}, {'id': 2}]), isTrue);
      expect(schema.matchesAll([{'id': 1}, {'id': 'x'}]), isFalse);
    });
  });

  group('ToonSchema base class', () {
    test('encodeMap/decodeList via abstract interface', () {
      final schema = UserSchema();
      expect(schema.fieldNames, equals(['id', 'name', 'age']));
      expect(
        schema.encodeMap({'id': 1, 'name': 'A', 'age': 30}),
        equals([1, 'A', 30]),
      );
      expect(schema.decodeList([1, 'A', 30]),
          equals({'id': 1, 'name': 'A', 'age': 30}));
    });
  });

  group('FlattenedSchema', () {
    test('encodeMap flattens nested maps', () {
      final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
      expect(
        schema.encodeMap({
          'user': {'id': 1, 'name': 'A'},
          'status': 'ok',
        }),
        equals([1, 'A', 'ok']),
      );
    });

    test('encodeMap returns null for missing nested paths', () {
      final schema = FlattenedSchema(['user.id', 'user.name']);
      expect(schema.encodeMap({'user': {'id': 1}}), equals([1, null]));
    });

    test('encodeMapInto writes nested values into buffer', () {
      final schema = FlattenedSchema(['user.id', 'status']);
      final buffer = List<dynamic>.filled(2, null);
      schema.encodeMapInto({'user': {'id': 7}, 'status': 'ok'}, buffer, 0);
      expect(buffer, equals([7, 'ok']));
    });

    test('decodeList builds nested maps', () {
      final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
      expect(
        schema.decodeList([1, 'A', 'ok']),
        equals({
          'user': {'id': 1, 'name': 'A'},
          'status': 'ok',
        }),
      );
    });

    test('decodeListInto writes into provided map', () {
      final schema = FlattenedSchema(['user.id', 'status']);
      final map = <String, dynamic>{};
      final written = schema.decodeListInto([1, 'ok'], map);
      expect(written, equals(2));
      expect(map, equals({'user': {'id': 1}, 'status': 'ok'}));
    });

    test('decodeList ignores extra values', () {
      final schema = FlattenedSchema(['a']);
      expect(schema.decodeList([1, 2]), equals({'a': 1}));
    });

    test('decodeList with empty segments sets the value directly', () {
      final schema = FlattenedSchema(['']);
      expect(schema.decodeList([1]), equals({'': 1}));
    });
  });

  group('IntKeyedSchema', () {
    final schema = IntKeyedSchema(
      fields: [
        SchemaField(name: 'id', type: SchemaFieldType.integer),
        SchemaField(name: 'status'),
      ],
      enumMappings: {
        'status': {0: 'pending', 1: 'active', 2: 'closed'},
      },
    );

    test('encodeMap replaces string values with int codes', () {
      expect(schema.encodeMap({'id': 42, 'status': 'active'}),
          equals([42, 1]));
    });

    test('encodeMap leaves unmapped strings unchanged', () {
      expect(schema.encodeMap({'id': 42, 'status': 'unknown'}).last,
          equals('unknown'));
    });

    test('encodeMap passes non-string enum fields through', () {
      expect(schema.encodeMap({'id': 'x', 'status': null}), equals(['x', null]));
    });

    test('decodeList replaces int codes with strings', () {
      expect(schema.decodeList([42, 2]), equals({'id': 42, 'status': 'closed'}));
    });

    test('decodeList leaves unmapped ints unchanged', () {
      expect(schema.decodeList([42, 99]), equals({'id': 42, 'status': 99}));
    });

    test('decodeList passes non-int values through', () {
      expect(schema.decodeList(['a', 'pending']),
          equals({'id': 'a', 'status': 'pending'}));
    });
  });

  group('SchemaRegistry', () {
    setUp(() {
      SchemaRegistry.instance.clear();
    });

    test('register/get/has/remove/length/names', () {
      final registry = SchemaRegistry.instance;
      final schema = ConcreteSchema.fromNames(['id']);

      expect(registry.length, equals(0));
      registry.register('user', schema);
      expect(registry.has('user'), isTrue);
      expect(registry.get('user'), same(schema));
      expect(registry.get('missing'), isNull);
      expect(registry.names, equals(['user']));
      expect(registry.length, equals(1));

      expect(registry.remove('user'), isTrue);
      expect(registry.remove('user'), isFalse);
      expect(registry.has('user'), isFalse);
    });

    test('register overwrites existing schema', () {
      final registry = SchemaRegistry.instance;
      final a = ConcreteSchema.fromNames(['a']);
      final b = ConcreteSchema.fromNames(['b']);
      registry.register('x', a);
      registry.register('x', b);
      expect(registry.get('x'), same(b));
    });
  });

  group('encodeTabularWithSchema', () {
    test('encodes keyed tabular array', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final rows = [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ];
      expect(
        encodeTabularWithSchema('users', rows, schema),
        equals('users[2]{id,name}:\n  1,Alice\n  2,Bob'),
      );
    });

    test('encodes keyless tabular array', () {
      final schema = ConcreteSchema.fromNames(['id']);
      expect(
        encodeTabularWithSchema(null, [
          {'id': 1},
        ], schema),
        equals('[1]{id}:\n  1'),
      );
    });

    test('honors custom delimiter and length marker', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        encodeTabularWithSchema(
          't',
          [
            {'a': 1, 'b': 2},
          ],
          schema,
          delimiter: '|',
          lengthMarker: '#',
        ),
        equals('t[#1|]{a|b}:\n  1|2'),
      );
    });

    test('honors indent size', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': 1},
        ], schema, indent: 4),
        equals('t[1]{a}:\n    1'),
      );
    });

    test('encodes strings with quoting when needed', () {
      final schema = ConcreteSchema.fromNames(['name']);
      expect(
        encodeTabularWithSchema('t', [
          {'name': 'a,b'},
        ], schema),
        equals('t[1]{name}:\n  "a,b"'),
      );
      // Internal spaces are valid unquoted per §7.2
      expect(
        encodeTabularWithSchema('t', [
          {'name': 'hello world'},
        ], schema),
        equals('t[1]{name}:\n  hello world'),
      );
    });

    test('encodes null and bool values', () {
      final schema = ConcreteSchema.fromNames(['n', 'b']);
      expect(
        encodeTabularWithSchema('t', [
          {'n': null, 'b': true},
        ], schema),
        equals('t[1]{n,b}:\n  null,true'),
      );
    });
  });

  group('decodeTabularWithSchema', () {
    test('decodes rows into maps with type conversion', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'active']);
      expect(
        decodeTabularWithSchema(['1,Alice,true', '2,Bob,false'], schema),
        equals([
          {'id': 1, 'name': 'Alice', 'active': true},
          {'id': 2, 'name': 'Bob', 'active': false},
        ]),
      );
    });

    test('handles empty rows list', () {
      final schema = ConcreteSchema.fromNames(['id']);
      expect(decodeTabularWithSchema([], schema), isEmpty);
    });

    test('handles custom delimiter', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        decodeTabularWithSchema(['1|2'], schema, delimiter: '|'),
        equals([
          {'a': 1, 'b': 2},
        ]),
      );
    });

    test('handles quoted and escaped values', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        decodeTabularWithSchema(['"x\\ny",3'], schema),
        equals([
          {'a': 'x\ny', 'b': 3},
        ]),
      );
    });
  });

  group('encodeTabularWithSchema number edge cases', () {
    test('normalizes negative zero', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': -0.0},
        ], schema),
        equals('t[1]{a}:\n  0'),
      );
    });

    test('converts non-finite doubles to null', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': double.infinity},
        ], schema),
        equals('t[1]{a}:\n  null'),
      );
    });

    test('renders whole-number doubles without decimal point', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': 1.0},
        ], schema),
        equals('t[1]{a}:\n  1'),
      );
    });

    test('converts small scientific notation to decimal', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': 1e-7},
        ], schema),
        equals('t[1]{a}:\n  0.0000001'),
      );
    });

    test('handles very large doubles', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 1e21},
      ], schema);
      expect(encoded.split('\n')[1].trim(), equals('1e+21'));
    });

    test('converts small non-integer scientific notation to decimal', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 1.5e-7},
      ], schema);
      expect(encoded.split('\n')[1].trim(), equals('0.00000015'));
    });

    test('underflows very small doubles to 0', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 1e-21},
      ], schema);
      expect(encoded.split('\n')[1].trim(), equals('0'));
    });

    test('renders plain decimals', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        encodeTabularWithSchema('t', [
          {'a': 1.5},
        ], schema),
        equals('t[1]{a}:\n  1.5'),
      );
    });
  });

  group('encodeTabularWithSchema string quoting edge cases', () {
    test('quotes boolean/null literals', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 'true'},
        {'a': 'false'},
        {'a': 'null'},
      ], schema);
      expect(encoded.split('\n').skip(1).map((l) => l.trim()).toList(),
          equals(['"true"', '"false"', '"null"']));
    });

    test('quotes numeric-like strings', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': '42'},
        {'a': '1e3'},
        {'a': '-1.5'},
      ], schema);
      expect(encoded.split('\n').skip(1).map((l) => l.trim()).toList(),
          equals(['"42"', '"1e3"', '"-1.5"']));
    });

    test('keeps leading-zero strings unquoted (decode treats as string)', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': '05'},
      ], schema);
      expect(encoded.split('\n')[1].trim(), equals('05'));
    });

    test('escapes backslashes, newlines, carriage returns, quotes, and tabs', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 'a\\b'},
        {'a': 'a\nb'},
        {'a': 'a\rb'},
        {'a': 'a"b'},
        {'a': 'a\tb'},
      ], schema);
      expect(encoded.split('\n').skip(1).map((l) => l.trim()).toList(),
          equals([r'"a\\b"', r'"a\nb"', r'"a\rb"', r'"a\"b"', r'"a\tb"']));
    });

    test('quotes structural characters', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': 'a:b'},
        {'a': ' a'},
        {'a': 'a '},
        {'a': 'a[b'},
        {'a': 'a\tb'},
      ], schema);
      expect(
        encoded.split('\n').skip(1).map((l) => l.trim()).toList(),
        equals(['"a:b"', '" a"', '"a "', '"a[b"', r'"a\tb"']),
      );
    });

    test('renders non-primitive values via toString', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final encoded = encodeTabularWithSchema('t', [
        {'a': {'x': 1}},
      ], schema);
      expect(encoded.split('\n')[1].trim(), equals('{x: 1}'));
    });
  });

  group('decodeTabularWithSchema edge cases', () {
    test('handles quoted values containing the delimiter', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        decodeTabularWithSchema(['"a,b",c'], schema),
        equals([
          {'a': 'a,b', 'b': 'c'},
        ]),
      );
    });

    test('handles escaped quotes, backslashes, newlines, carriage returns, and tabs', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        decodeTabularWithSchema([
          r'"a\"b"',
          r'"a\\b"',
          r'"a\nb"',
          r'"a\rb"',
          r'"a\tb"',
        ], schema),
        equals([
          {'a': 'a"b'},
          {'a': 'a\\b'},
          {'a': 'a\nb'},
          {'a': 'a\rb'},
          {'a': 'a\tb'},
        ]),
      );
    });

    test('keeps unclosed quote tokens as-is', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        decodeTabularWithSchema(['"unclosed'], schema),
        equals([
          {'a': '"unclosed'},
        ]),
      );
    });

    test('parses empty row as empty map', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        decodeTabularWithSchema([''], schema),
        equals([
          <String, dynamic>{},
        ]),
      );
    });

    test('throws FormatException on invalid escape', () {
      final schema = ConcreteSchema.fromNames(['a']);
      expect(
        () => decodeTabularWithSchema([r'"a\z"'], schema),
        throwsFormatException,
      );
      expect(
        () => decodeTabularWithSchema([r'"a\"'], schema),
        throwsFormatException,
      );
    });

    test('parses null, true, and false tokens', () {
      final schema = ConcreteSchema.fromNames(['a', 'b', 'c']);
      expect(
        decodeTabularWithSchema(['null,true,false'], schema),
        equals([
          {'a': null, 'b': true, 'c': false},
        ]),
      );
    });

    test('parses numeric strings with exponent signs', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        decodeTabularWithSchema(['1e-7,1e+3'], schema),
        equals([
          {'a': 1e-7, 'b': 1000.0},
        ]),
      );
    });
  });
}
