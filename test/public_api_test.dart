import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

/// Removes the embedded-schema section from a schema-mode [bytes] message,
/// simulating a message whose schema was shared out-of-band.
Uint8List _stripEmbeddedSchema(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final flags = bytes[5];
  var offset = 8;
  int readUint32() {
    final v = data.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  if ((flags & 0x04) != 0) {
    final count = readUint32();
    for (var i = 0; i < count; i++) {
      final length = readUint32();
      offset += length;
    }
  }
  if ((flags & 0x02) != 0) {
    readUint32(); // schema id
    final nameLength = readUint32();
    offset += nameLength;
    final fieldCount = readUint32();
    for (var i = 0; i < fieldCount; i++) {
      final fieldNameLength = readUint32();
      offset += fieldNameLength;
      offset += 1; // element code
    }
  }
  while (offset % 8 != 0) {
    offset++;
  }
  final body = Uint8List.sublistView(bytes, offset);
  final result = Uint8List(8 + body.length);
  result.setAll(0, bytes.sublist(0, 8));
  result[5] = flags & ~0x02;
  result.setAll(8, body);
  return result;
}

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

  group('btoonEncodeWithSchema public API', () {
    test('encodes a map in schema mode with an embedded schema', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
        const BtoonSchemaField('name', type: BtoonSchemaType.string),
      ]);
      final bytes = btoonEncodeWithSchema({'id': 1, 'name': 'Alice'}, schema);
      expect(bytes[5] & 0x02, 0x02); // flagHasSchema
      expect(btoonDecode(bytes), {'id': 1, 'name': 'Alice'});
    });

    test('encodes a list of maps', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
        const BtoonSchemaField('name', type: BtoonSchemaType.string),
      ]);
      final bytes = btoonEncodeWithSchema([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ], schema);
      expect(btoonDecode(bytes), [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]);
    });

    test('throws BtoonEncodeError for a non-object root', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
      ]);
      expect(
        () => btoonEncodeWithSchema(42, schema),
        throwsA(isA<BtoonEncodeError>()),
      );
    });
  });

  group('btoonDecodeWithSchema public API', () {
    test('decodes schema-mode bytes with an out-of-band schema', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
        const BtoonSchemaField('name', type: BtoonSchemaType.string),
      ], id: 3, name: 'user');
      final bytes = _stripEmbeddedSchema(
        btoonEncodeWithSchema({'id': 1, 'name': 'Alice'}, schema),
      );
      expect(btoonDecodeWithSchema(bytes, schema), {'id': 1, 'name': 'Alice'});
    });

    test('decodes a single record as a map', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
      ]);
      final bytes = btoonEncodeWithSchema({'id': 1}, schema);
      expect(btoonDecodeWithSchema(bytes, schema), {'id': 1});
    });

    test('mismatched schema id fails', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ], id: 7, name: 'Seven');
      final bytes = _stripEmbeddedSchema(btoonEncodeWithSchema({'a': 1}, schema));
      final other = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ], id: 99, name: 'Other');
      expect(
        () => btoonDecodeWithSchema(bytes, other),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('btoonDeriveSchema public API', () {
    test('derives a schema from a map', () {
      final schema = btoonDeriveSchema({
        'id': 1,
        'name': 'Alice',
        'active': true,
        'score': 9.5,
      });
      expect(schema.fieldNames, ['active', 'id', 'name', 'score']);
      BtoonSchemaType typeOf(String name) =>
          schema.fields.firstWhere((f) => f.name == name).type;
      expect(typeOf('id'), BtoonSchemaType.integer);
      expect(typeOf('name'), BtoonSchemaType.string);
      expect(typeOf('active'), BtoonSchemaType.boolean);
      expect(typeOf('score'), BtoonSchemaType.number);
    });

    test('derives the union of keys across a list of maps', () {
      final schema = btoonDeriveSchema([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob', 'age': 30},
      ]);
      expect(schema.fieldNames, ['age', 'id', 'name']);
      final age = schema.fields.firstWhere((f) => f.name == 'age');
      expect(age.type, BtoonSchemaType.integer);
    });

    test('throws for a non-object root', () {
      expect(() => btoonDeriveSchema(42), throwsA(isA<BtoonEncodeError>()));
      expect(() => btoonDeriveSchema([1, 2, 3]),
          throwsA(isA<BtoonEncodeError>()));
    });
  });

  group('btoonEncodeAuto public API', () {
    test('encodes a map in schema mode with an embedded schema', () {
      final bytes = btoonEncodeAuto({'id': 1, 'name': 'Alice'});
      expect(bytes[5] & 0x02, 0x02); // flagHasSchema
      expect(btoonDecode(bytes), {'id': 1, 'name': 'Alice'});
    });

    test('encodes a list of maps', () {
      final bytes = btoonEncodeAuto([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]);
      expect(btoonDecode(bytes), [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]);
    });

    test('derived schema decodes out-of-band', () {
      final schema = btoonDeriveSchema({'id': 1, 'name': 'Alice'});
      final bytes = _stripEmbeddedSchema(
        btoonEncodeAuto({'id': 1, 'name': 'Alice'}),
      );
      expect(btoonDecodeWithSchema(bytes, schema), {'id': 1, 'name': 'Alice'});
    });

    test('throws for a non-object root', () {
      expect(() => btoonEncodeAuto(42), throwsA(isA<BtoonEncodeError>()));
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
