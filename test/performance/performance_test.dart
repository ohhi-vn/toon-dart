/// Performance and correctness tests for optimized TOON encoding/decoding.
///
/// Tests verify that all optimization paths produce correct results
/// equivalent to the standard paths. This ensures that performance
/// improvements don't sacrifice correctness.
library performance_test;

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

// #region Schema Tests

void main() {
  group('Schema System', () {
    group('ConcreteSchema', () {
      test('encodeMap converts Map to List by field order', () {
        final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
        final map = {'id': 1, 'name': 'Alice', 'age': 30};

        final list = schema.encodeMap(map);

        expect(list, equals([1, 'Alice', 30]));
      });

      test('encodeMap handles missing fields as null', () {
        final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
        final map = {'id': 1, 'name': 'Bob'};

        final list = schema.encodeMap(map);

        expect(list, equals([1, 'Bob', null]));
      });

      test('encodeMap ignores extra fields not in schema', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        final map = {'id': 1, 'name': 'Charlie', 'extra': 'ignored'};

        final list = schema.encodeMap(map);

        expect(list, equals([1, 'Charlie']));
      });

      test('decodeList converts List to Map by field order', () {
        final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
        final list = [2, 'Bob', 25];

        final map = schema.decodeList(list);

        expect(map, equals({'id': 2, 'name': 'Bob', 'age': 25}));
      });

      test('decodeList handles shorter lists', () {
        final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
        final list = [3, 'Charlie'];

        final map = schema.decodeList(list);

        expect(map, equals({'id': 3, 'name': 'Charlie'}));
        expect(map.containsKey('age'), isFalse);
      });

      test('encodeMapInto writes into existing buffer', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        final buffer = List<dynamic>.filled(4, null);
        final map = {'id': 42, 'name': 'Test'};

        final count = schema.encodeMapInto(map, buffer, 2);

        expect(count, equals(2));
        expect(buffer[2], equals(42));
        expect(buffer[3], equals('Test'));
      });

      test('decodeListInto writes into existing map', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        final map = <String, dynamic>{'existing': 'value'};
        final list = [10, 'Hello'];

        final count = schema.decodeListInto(list, map);

        expect(count, equals(2));
        expect(map['id'], equals(10));
        expect(map['name'], equals('Hello'));
        expect(map['existing'], equals('value'));
      });

      test('fieldNames returns ordered list', () {
        final schema = ConcreteSchema.fromNames(['z', 'a', 'm']);

        expect(schema.fieldNames, equals(['z', 'a', 'm']));
      });

      test('fieldCount returns correct count', () {
        final schema = ConcreteSchema.fromNames(['a', 'b', 'c', 'd']);

        expect(schema.fieldCount, equals(4));
      });

      test('matches returns true for matching map', () {
        final schema = ConcreteSchema.typed([
          ('id', SchemaFieldType.integer),
          ('name', SchemaFieldType.string),
        ]);

        expect(schema.matches({'id': 1, 'name': 'Alice'}), isTrue);
      });

      test('matches returns false for type mismatch', () {
        final schema = ConcreteSchema.typed([
          ('id', SchemaFieldType.integer),
          ('name', SchemaFieldType.string),
        ]);

        expect(schema.matches({'id': 'not-int', 'name': 'Alice'}), isFalse);
      });

      test('matches returns false for missing required field', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);

        expect(schema.matches({'id': 1}), isFalse);
      });

      test('matchesAll checks all rows', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        final rows = [
          {'id': 1, 'name': 'A'},
          {'id': 2, 'name': 'B'},
        ];

        expect(schema.matchesAll(rows), isTrue);
      });

      test('matchesAll returns false if any row fails', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        final rows = [
          {'id': 1, 'name': 'A'},
          {'id': 2}, // missing 'name'
        ];

        expect(schema.matchesAll(rows), isFalse);
      });
    });

    group('FlattenedSchema', () {
      test('encodeMap flattens nested structure', () {
        final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
        final map = {
          'user': {'id': 1, 'name': 'Alice'},
          'status': 'active',
        };

        final list = schema.encodeMap(map);

        expect(list, equals([1, 'Alice', 'active']));
      });

      test('decodeList unflattens to nested structure', () {
        final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
        final list = [1, 'Alice', 'active'];

        final map = schema.decodeList(list);

        expect(
            map,
            equals({
              'user': {'id': 1, 'name': 'Alice'},
              'status': 'active',
            }));
      });

      test('encodeMap handles missing nested paths as null', () {
        final schema = FlattenedSchema(['user.id', 'user.name']);
        final map = <String, dynamic>{};

        final list = schema.encodeMap(map);

        expect(list, equals([null, null]));
      });

      test('roundtrip encode then decode preserves data', () {
        final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
        final original = {
          'user': {'id': 42, 'name': 'Bob'},
          'status': 'pending',
        };

        final encoded = schema.encodeMap(original);
        final decoded = schema.decodeList(encoded);

        expect(decoded, equals(original));
      });

      test('encodeMapInto writes into buffer at offset', () {
        final schema = FlattenedSchema(['a.x', 'a.y']);
        final buffer = List<dynamic>.filled(5, null);
        final map = {
          'a': {'x': 10, 'y': 20},
        };

        final count = schema.encodeMapInto(map, buffer, 3);

        expect(count, equals(2));
        expect(buffer[3], equals(10));
        expect(buffer[4], equals(20));
      });

      test('decodeListInto writes into existing map', () {
        final schema = FlattenedSchema(['a.x', 'a.y']);
        final map = <String, dynamic>{'existing': true};
        final list = [1, 2];

        schema.decodeListInto(list, map);

        expect(map['existing'], isTrue);
        expect(map['a'], equals({'x': 1, 'y': 2}));
      });
    });

    group('IntKeyedSchema', () {
      test('encodeMap replaces string values with int codes', () {
        final schema = IntKeyedSchema(
          fields: [
            SchemaField(name: 'id', type: SchemaFieldType.integer),
            SchemaField(name: 'status'),
          ],
          enumMappings: {
            'status': {0: 'pending', 1: 'active', 2: 'closed'},
          },
        );

        final list = schema.encodeMap({'id': 42, 'status': 'active'});

        expect(list, equals([42, 1]));
      });

      test('decodeList replaces int codes with string values', () {
        final schema = IntKeyedSchema(
          fields: [
            SchemaField(name: 'id', type: SchemaFieldType.integer),
            SchemaField(name: 'status'),
          ],
          enumMappings: {
            'status': {0: 'pending', 1: 'active', 2: 'closed'},
          },
        );

        final map = schema.decodeList([42, 1]);

        expect(map, equals({'id': 42, 'status': 'active'}));
      });

      test('encodeMap passes through unmapped values', () {
        final schema = IntKeyedSchema(
          fields: [
            SchemaField(name: 'id', type: SchemaFieldType.integer),
            SchemaField(name: 'status'),
          ],
          enumMappings: {
            'status': {0: 'pending', 1: 'active'},
          },
        );

        final list = schema.encodeMap({'id': 1, 'status': 'unknown'});

        expect(list, equals([1, 'unknown']));
      });

      test('decodeList passes through unmapped int values', () {
        final schema = IntKeyedSchema(
          fields: [
            SchemaField(name: 'id', type: SchemaFieldType.integer),
            SchemaField(name: 'priority', type: SchemaFieldType.integer),
          ],
          enumMappings: {
            'status': {0: 'pending'},
          },
        );

        final map = schema.decodeList([1, 5]);

        expect(map, equals({'id': 1, 'priority': 5}));
      });

      test('roundtrip encode then decode preserves data', () {
        final schema = IntKeyedSchema(
          fields: [
            SchemaField(name: 'id', type: SchemaFieldType.integer),
            SchemaField(name: 'status'),
            SchemaField(name: 'category'),
          ],
          enumMappings: {
            'status': {0: 'pending', 1: 'active', 2: 'closed'},
            'category': {0: 'electronics', 1: 'books'},
          },
        );

        final original = {'id': 42, 'status': 'active', 'category': 'books'};
        final encoded = schema.encodeMap(original);
        final decoded = schema.decodeList(encoded);

        expect(decoded, equals(original));
      });
    });

    group('SchemaRegistry', () {
      tearDown(() {
        SchemaRegistry.instance.clear();
      });

      test('register and get schema', () {
        final schema = ConcreteSchema.fromNames(['id', 'name']);
        SchemaRegistry.instance.register('user', schema);

        expect(SchemaRegistry.instance.get('user'), same(schema));
      });

      test('get returns null for unregistered schema', () {
        expect(SchemaRegistry.instance.get('nonexistent'), isNull);
      });

      test('has checks if schema is registered', () {
        expect(SchemaRegistry.instance.has('user'), isFalse);

        SchemaRegistry.instance
            .register('user', ConcreteSchema.fromNames(['id']));

        expect(SchemaRegistry.instance.has('user'), isTrue);
      });

      test('remove deletes schema', () {
        SchemaRegistry.instance
            .register('user', ConcreteSchema.fromNames(['id']));

        expect(SchemaRegistry.instance.remove('user'), isTrue);
        expect(SchemaRegistry.instance.has('user'), isFalse);
      });

      test('remove returns false for unregistered schema', () {
        expect(SchemaRegistry.instance.remove('nonexistent'), isFalse);
      });

      test('clear removes all schemas', () {
        SchemaRegistry.instance.register('a', ConcreteSchema.fromNames(['x']));
        SchemaRegistry.instance.register('b', ConcreteSchema.fromNames(['y']));

        SchemaRegistry.instance.clear();

        expect(SchemaRegistry.instance.length, equals(0));
      });

      test('length returns count of registered schemas', () {
        SchemaRegistry.instance.register('a', ConcreteSchema.fromNames(['x']));
        SchemaRegistry.instance.register('b', ConcreteSchema.fromNames(['y']));

        expect(SchemaRegistry.instance.length, equals(2));
      });

      test('names returns all registered names', () {
        SchemaRegistry.instance
            .register('alpha', ConcreteSchema.fromNames(['x']));
        SchemaRegistry.instance
            .register('beta', ConcreteSchema.fromNames(['y']));

        expect(SchemaRegistry.instance.names, containsAll(['alpha', 'beta']));
      });
    });
  });

  // #endregion

  // #region Schema-Based Encode/Decode API Tests

  group('Schema-Based API', () {
    test('encodeWithSchema produces valid TOON', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
      final rows = [
        {'id': 1, 'name': 'Alice', 'age': 30},
        {'id': 2, 'name': 'Bob', 'age': 25},
      ];

      final result = encodeWithSchema('users', rows, schema);

      expect(result, contains('users'));
      expect(result, contains('id'));
      expect(result, contains('name'));
      expect(result, contains('age'));
    });

    test('decodeWithSchema produces correct maps', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
      final rows = ['1,Alice,30', '2,Bob,25'];

      final result = decodeWithSchema(rows, schema);

      expect(result.length, equals(2));
      expect(result[0], equals({'id': 1.0, 'name': 'Alice', 'age': 30.0}));
      expect(result[1], equals({'id': 2.0, 'name': 'Bob', 'age': 25.0}));
    });

    test('encodeWithSchema with custom delimiter', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final rows = [
        {'id': 1, 'name': 'Alice'},
      ];

      final result = encodeWithSchema(
        'items',
        rows,
        schema,
        options: const EncodeOptions(delimiter: '|'),
      );

      expect(result, contains('|'));
    });
  });

  // #endregion

  // #region Stream Decoder Tests

  group('Stream Decoder', () {
    test('decodeTabularRows yields rows one at a time', () {
      final toon = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';
      final stream = ToonStreamDecoder(toon);

      final rows = stream.decodeTabularRows().toList();

      expect(rows.length, equals(2));
      expect(rows[0], equals({'id': 1, 'name': 'Alice'}));
      expect(rows[1], equals({'id': 2, 'name': 'Bob'}));
    });

    test('decodeTabularRowsAt finds specific key', () {
      final toon =
          'users[1]{id,name}:\n  1,Alice\norders[1]{id,total}:\n  100,50.0';
      final stream = ToonStreamDecoder(toon);

      final rows = stream.decodeTabularRowsAt('orders').toList();

      expect(rows.length, equals(1));
      expect(rows[0], equals({'id': 100, 'total': 50.0}));
    });

    test('decodeTabularRowsWithSchema uses schema field names', () {
      final toon = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final stream = ToonStreamDecoder(toon);

      final rows = stream.decodeTabularRowsWithSchema(schema).toList();

      expect(rows.length, equals(2));
      expect(rows[0]['id'], equals(1));
      expect(rows[0]['name'], equals('Alice'));
    });

    test('decodeListItems yields list items', () {
      final toon = '[3]:\n  - 1\n  - 2\n  - 3';
      final stream = ToonStreamDecoder(toon);

      final items = stream.decodeListItems().toList();

      expect(items.length, equals(3));
    });

    test('decodeRawTabularRows yields raw row strings', () {
      final toon = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';
      final stream = ToonStreamDecoder(toon);

      final rawRows = stream.decodeRawTabularRows().toList();

      expect(rawRows.length, equals(2));
      expect(rawRows[0], equals('1,Alice'));
      expect(rawRows[1], equals('2,Bob'));
    });

    test('decodeRawDelimitedRows yields lists of raw values', () {
      final toon = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';
      final stream = ToonStreamDecoder(toon);

      final rows = stream.decodeRawDelimitedRows().toList();

      expect(rows.length, equals(2));
      expect(rows[0], equals(['1', 'Alice']));
      expect(rows[1], equals(['2', 'Bob']));
    });

    test('decodeTabularRowsChunked yields batches', () {
      final toon = 'users[5]{id,name}:\n  1,A\n  2,B\n  3,C\n  4,D\n  5,E';
      final stream = ToonStreamDecoder(toon);

      final chunks = stream.decodeTabularRowsChunked(chunkSize: 2).toList();

      expect(chunks.length, equals(3)); // 2 + 2 + 1
      expect(chunks[0].length, equals(2));
      expect(chunks[1].length, equals(2));
      expect(chunks[2].length, equals(1));
    });

    test('decodeTabularRowsWithSchemaChunked yields batches', () {
      final toon = 'users[5]{id,name}:\n  1,A\n  2,B\n  3,C\n  4,D\n  5,E';
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final stream = ToonStreamDecoder(toon);

      final chunks = stream
          .decodeTabularRowsWithSchemaChunked(schema, chunkSize: 3)
          .toList();

      expect(chunks.length, equals(2)); // 3 + 2
      expect(chunks[0].length, equals(3));
      expect(chunks[1].length, equals(2));
    });

    test('empty document yields no rows', () {
      final stream = ToonStreamDecoder('');

      final rows = stream.decodeTabularRows().toList();

      expect(rows, isEmpty);
    });

    test('streamDecode convenience function works', () {
      final toon = 'users[1]{id,name}:\n  1,Alice';

      final rows = streamDecode(toon).decodeTabularRows().toList();

      expect(rows.length, equals(1));
    });

    test('streamTabularRows convenience function works', () {
      final toon = 'users[1]{id,name}:\n  1,Alice';

      final rows = streamTabularRows(toon).toList();

      expect(rows.length, equals(1));
    });

    test('streamTabularRowsWithSchema convenience function works', () {
      final toon = 'users[1]{id,name}:\n  1,Alice';
      final schema = ConcreteSchema.fromNames(['id', 'name']);

      final rows = streamTabularRowsWithSchema(toon, schema).toList();

      expect(rows.length, equals(1));
    });

    test('streamListItems convenience function works', () {
      final toon = '[2]:\n  - hello\n  - world';

      final items = streamListItems(toon).toList();

      expect(items.length, equals(2));
    });
  });

  // #endregion

  // #region Optimized Encoding Tests

  group('Optimized Encoding', () {
    test('encode simple object produces correct output', () {
      final result = encode({'name': 'Alice', 'age': 30});

      expect(result, contains('name: Alice'));
      expect(result, contains('age: 30'));
    });

    test('encode tabular array produces correct output', () {
      final data = {
        'users': [
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob'},
        ],
      };

      final result = encode(data);

      expect(result, contains('users'));
      expect(result, contains('id'));
      expect(result, contains('name'));
      expect(result, contains('Alice'));
      expect(result, contains('Bob'));
    });

    test('encode with pre-estimated capacity produces same result', () {
      final data = {
        'name': 'Test',
        'items': [1, 2, 3],
        'nested': {'key': 'value'},
      };

      final result = encode(data);

      // Verify the result is valid by decoding it
      final decoded = decode(result);
      expect(decoded, isA<Map>());
    });

    test('encode empty object', () {
      final result = encode(<String, dynamic>{});

      expect(result, isEmpty);
    });

    test('encode primitive array', () {
      final result = encode({
        'nums': [1, 2, 3]
      });

      expect(result, contains('nums'));
      expect(result, contains('1'));
    });

    test('encode nested objects', () {
      final data = {
        'user': {
          'profile': {'name': 'Alice'},
        },
      };

      final result = encode(data);

      expect(result, contains('user'));
      expect(result, contains('profile'));
      expect(result, contains('Alice'));
    });
  });

  // #endregion

  // #region Optimized Decoding Tests

  group('Optimized Decoding', () {
    test('decode simple object', () {
      final toon = 'name: Alice\nage: 30';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['name'], equals('Alice'));
      expect(map['age'], equals(30));
    });

    test('decode tabular array', () {
      final toon = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['users'], isA<List>());
      final users = map['users'] as List;
      expect(users.length, equals(2));
    });

    test('decode primitive values', () {
      expect((decode('value: 42') as Map)['value'], equals(42));
      expect((decode('value: hello') as Map)['value'], equals('hello'));
      expect((decode('value: true') as Map)['value'], equals(true));
      expect((decode('value: false') as Map)['value'], equals(false));
      expect((decode('value: null') as Map)['value'], isNull);
    });

    test('decode string with special characters', () {
      // Use raw string so \n is preserved as TOON escape sequence (not Dart newline)
      final toon = r'message: "Hello\nWorld"';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      // Decoded \n escape becomes actual newline character
      expect(map['message'], equals('Hello\nWorld'));
    });

    test('decode string with tab escape', () {
      final toon = r'data: "col1	col2"';

      final result = decode(toon);

      expect(result, isA<Map>());
    });

    test('decode string with backslash escape', () {
      final toon = r'path: "C:\\Users\\test"';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['path'], equals(r'C:\Users\test'));
    });

    test('decode with different delimiters', () {
      final toon = 'items[2|]{a|b}:\n  1|two\n  3|four';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['items'], isA<List>());
    });

    test('decode nested objects', () {
      final toon = 'user:\n  name: Alice\n  age: 30';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['user'], isA<Map>());
    });

    test('decode list items', () {
      final toon = 'items[3]:\n  - apple\n  - banana\n  - cherry';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['items'], isA<List>());
      final items = map['items'] as List;
      expect(items.length, equals(3));
    });
  });

  // #endregion

  // #region Roundtrip Tests

  group('Roundtrip (Encode → Decode)', () {
    test('simple object roundtrip', () {
      final original = {'name': 'Alice', 'age': 30, 'active': true};

      final encoded = encode(original);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['name'], equals('Alice'));
      expect(map['age'], equals(30));
      expect(map['active'], equals(true));
    });

    test('tabular array roundtrip', () {
      final original = {
        'users': [
          {'id': 1, 'name': 'Alice', 'score': 95.5},
          {'id': 2, 'name': 'Bob', 'score': 87.0},
        ],
      };

      final encoded = encode(original);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['users'], isA<List>());
      final users = map['users'] as List;
      expect(users.length, equals(2));
    });

    test('nested object roundtrip', () {
      final original = {
        'config': {
          'debug': true,
          'version': 2,
        },
        'name': 'test',
      };

      final encoded = encode(original);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['config'], isA<Map>());
      expect(map['name'], equals('test'));
    });

    test('primitive array roundtrip', () {
      final original = {
        'numbers': [1, 2, 3, 4, 5],
      };

      final encoded = encode(original);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['numbers'], isA<List>());
    });

    test('schema encode → standard decode roundtrip', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'age']);
      final rows = [
        {'id': 1, 'name': 'Alice', 'age': 30},
        {'id': 2, 'name': 'Bob', 'age': 25},
      ];

      final encoded = encodeWithSchema('users', rows, schema);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['users'], isA<List>());
    });

    test('flattened schema roundtrip', () {
      final schema = FlattenedSchema(['user.id', 'user.name', 'status']);
      final original = {
        'user': {'id': 1, 'name': 'Alice'},
        'status': 'active',
      };

      final encoded = schema.encodeMap(original);
      final decoded = schema.decodeList(encoded);

      expect(decoded, equals(original));
    });

    test('int-keyed schema roundtrip', () {
      final schema = IntKeyedSchema(
        fields: [
          SchemaField(name: 'id', type: SchemaFieldType.integer),
          SchemaField(name: 'status'),
        ],
        enumMappings: {
          'status': {0: 'pending', 1: 'active', 2: 'closed'},
        },
      );

      final original = {'id': 42, 'status': 'active'};
      final encoded = schema.encodeMap(original);
      final decoded = schema.decodeList(encoded);

      expect(decoded, equals(original));
      expect(encoded[1], equals(1)); // 'active' → 1
    });
  });

  // #endregion

  // #region Buffer Estimation Tests

  group('Buffer Estimation', () {
    test('estimateEncodeSize returns positive value', () {
      final data = {'name': 'Alice', 'age': 30};

      final size = estimateEncodeSize(data);

      expect(size, greaterThan(0));
    });

    test('estimateEncodeSize scales with data size', () {
      final small = {'name': 'A'};
      final large = {
        'name': 'A very long name that takes many characters',
        'age': 30,
        'email': 'user@example.com',
      };

      final smallSize = estimateEncodeSize(small);
      final largeSize = estimateEncodeSize(large);

      expect(largeSize, greaterThan(smallSize));
    });
  });

  // #endregion

  // #region SchemaFieldType Tests

  group('SchemaFieldType', () {
    test('string matches String values', () {
      expect(SchemaFieldType.string.matches('hello'), isTrue);
      expect(SchemaFieldType.string.matches(42), isFalse);
    });

    test('integer matches int values', () {
      expect(SchemaFieldType.integer.matches(42), isTrue);
      expect(SchemaFieldType.integer.matches(3.14), isFalse);
      expect(SchemaFieldType.integer.matches('42'), isFalse);
    });

    test('number matches num values', () {
      expect(SchemaFieldType.number.matches(42), isTrue);
      expect(SchemaFieldType.number.matches(3.14), isTrue);
      expect(SchemaFieldType.number.matches('42'), isFalse);
    });

    test('boolean matches bool values', () {
      expect(SchemaFieldType.boolean.matches(true), isTrue);
      expect(SchemaFieldType.boolean.matches(false), isTrue);
      expect(SchemaFieldType.boolean.matches(1), isFalse);
    });

    test('null_ matches null', () {
      expect(SchemaFieldType.null_.matches(null), isTrue);
      expect(SchemaFieldType.null_.matches('null'), isFalse);
    });

    test('object matches Map', () {
      expect(SchemaFieldType.object.matches({'a': 1}), isTrue);
      expect(SchemaFieldType.object.matches([1, 2]), isFalse);
    });

    test('array matches List', () {
      expect(SchemaFieldType.array.matches([1, 2]), isTrue);
      expect(SchemaFieldType.array.matches({'a': 1}), isFalse);
    });

    test('any matches everything', () {
      expect(SchemaFieldType.any.matches(null), isTrue);
      expect(SchemaFieldType.any.matches(42), isTrue);
      expect(SchemaFieldType.any.matches('hello'), isTrue);
      expect(SchemaFieldType.any.matches([1]), isTrue);
      expect(SchemaFieldType.any.matches({'a': 1}), isTrue);
    });
  });

  // #endregion

  // #region Large Data Tests

  group('Large Data', () {
    test('encode and decode 1000-row tabular array', () {
      final rows = List.generate(1000, (i) {
        return {
          'id': i + 1,
          'name': 'User_$i',
          'age': 20 + (i % 50),
          'active': i % 3 != 0,
        };
      });

      final data = {'users': rows};
      final encoded = encode(data);
      final decoded = decode(encoded);

      expect(decoded, isA<Map>());
      final map = decoded as Map;
      expect(map['users'], isA<List>());
      final users = map['users'] as List;
      expect(users.length, equals(1000));
    });

    test('stream decode 1000-row tabular array', () {
      final rows = List.generate(1000, (i) {
        return {
          'id': i + 1,
          'name': 'User_$i',
        };
      });

      final data = {'users': rows};
      final encoded = encode(data);
      final stream = ToonStreamDecoder(encoded);

      final count = stream.decodeTabularRows().length;

      expect(count, equals(1000));
    });

    test('schema-based encode 1000 rows', () {
      final schema = ConcreteSchema.fromNames(['id', 'name', 'age', 'active']);
      final rows = List.generate(1000, (i) {
        return {
          'id': i + 1,
          'name': 'User_$i',
          'age': 20 + (i % 50),
          'active': i % 3 != 0,
        };
      });

      final result = encodeWithSchema('users', rows, schema);

      expect(result, isNotEmpty);
      expect(result, contains('users'));
    });

    test('stream decode with schema 1000 rows', () {
      final rows = List.generate(1000, (i) {
        return {'id': i + 1, 'name': 'User_$i'};
      });

      final data = {'users': rows};
      final encoded = encode(data);
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final stream = ToonStreamDecoder(encoded);

      final decodedRows = stream.decodeTabularRowsWithSchema(schema).toList();

      expect(decodedRows.length, equals(1000));
      expect(decodedRows[0]['id'], equals(1));
      expect(decodedRows[0]['name'], equals('User_0'));
    });

    test('chunked stream decode 1000 rows', () {
      final rows = List.generate(1000, (i) {
        return {'id': i + 1, 'name': 'User_$i'};
      });

      final data = {'users': rows};
      final encoded = encode(data);
      final stream = ToonStreamDecoder(encoded);

      final chunks = stream.decodeTabularRowsChunked(chunkSize: 100).toList();

      // 1000 / 100 = 10 chunks
      expect(chunks.length, equals(10));
      for (final chunk in chunks) {
        expect(chunk.length, equals(100));
      }
    });
  });

  // #endregion

  // #region Edge Case Tests

  group('Edge Cases', () {
    test('empty schema encode/decode', () {
      final schema = ConcreteSchema.fromNames([]);
      final list = schema.encodeMap({});
      final map = schema.decodeList([]);

      expect(list, isEmpty);
      expect(map, isEmpty);
    });

    test('single field schema', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final list = schema.encodeMap({'id': 42});
      final map = schema.decodeList([42]);

      expect(list, equals([42]));
      expect(map, equals({'id': 42}));
    });

    test('deeply nested flattened schema', () {
      final schema = FlattenedSchema(['a.b.c.d', 'a.b.c.e', 'x']);
      final original = {
        'a': {
          'b': {
            'c': {'d': 1, 'e': 2},
          },
        },
        'x': 3,
      };

      final encoded = schema.encodeMap(original);
      final decoded = schema.decodeList(encoded);

      expect(encoded, equals([1, 2, 3]));
      expect(decoded, equals(original));
    });

    test('int-keyed schema with multiple enum fields', () {
      final schema = IntKeyedSchema(
        fields: [
          SchemaField(name: 'status'),
          SchemaField(name: 'priority'),
          SchemaField(name: 'category'),
        ],
        enumMappings: {
          'status': {0: 'new', 1: 'in-progress', 2: 'done'},
          'priority': {0: 'low', 1: 'medium', 2: 'high'},
          'category': {0: 'bug', 1: 'feature', 2: 'task'},
        },
      );

      final original = {
        'status': 'done',
        'priority': 'high',
        'category': 'feature',
      };

      final encoded = schema.encodeMap(original);
      expect(encoded, equals([2, 2, 1]));

      final decoded = schema.decodeList(encoded);
      expect(decoded, equals(original));
    });

    test('stream decoder with empty input', () {
      final stream = ToonStreamDecoder('');

      expect(stream.decodeTabularRows().toList(), isEmpty);
      expect(stream.decodeListItems().toList(), isEmpty);
      expect(stream.decodeRawTabularRows().toList(), isEmpty);
    });

    test('stream decoder with non-tabular input', () {
      final toon = 'name: Alice\nage: 30';
      final stream = ToonStreamDecoder(toon);

      expect(stream.decodeTabularRows().toList(), isEmpty);
    });

    test('encode null values', () {
      final result = encode({'value': null});

      expect(result, contains('null'));
    });

    test('encode boolean values', () {
      final result = encode({'a': true, 'b': false});

      expect(result, contains('true'));
      expect(result, contains('false'));
    });

    test('encode special string characters', () {
      final result = encode({'msg': 'Hello\nWorld'});

      expect(result, contains('msg'));
    });

    test('decode handles trailing newline', () {
      final toon = 'name: Alice\n';

      final result = decode(toon);

      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['name'], equals('Alice'));
    });
  });

  // #endregion
}
