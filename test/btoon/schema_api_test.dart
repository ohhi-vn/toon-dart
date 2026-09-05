import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';
import 'package:toon_format/src/btoon/constants.dart' as c;
import 'package:toon_format/src/btoon/numeric.dart' show validateNumericRange;
import 'package:toon_format/src/btoon/options.dart' show BtoonStringTableMode;

void main() {
  group('btoonEncodeWithSchema / btoonDecodeWithSchema', () {
    test('single map round-trips with typed fields', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('name', type: BtoonSchemaType.string),
        const BtoonSchemaField('age', type: BtoonSchemaType.integer),
        const BtoonSchemaField('score', type: BtoonSchemaType.number),
        const BtoonSchemaField('active', type: BtoonSchemaType.boolean),
        const BtoonSchemaField('nick', type: BtoonSchemaType.null_),
      ]);
      final value = {
        'name': 'Alice',
        'age': 30,
        'score': 9.5,
        'active': true,
        'nick': null,
      };
      final bytes = btoonEncodeWithSchema(value, schema);
      expect(btoonDecodeWithSchema(bytes, schema), value);
    });

    test('list of maps round-trips', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
        const BtoonSchemaField('name', type: BtoonSchemaType.string),
      ]);
      final rows = [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ];
      final bytes = btoonEncodeWithSchema(rows, schema);
      expect(btoonDecodeWithSchema(bytes, schema), rows);
    });

    test('narrow numeric element codes round-trip exactly', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a',
            type: BtoonSchemaType.integer, elementCode: c.elementInt8),
        const BtoonSchemaField('b',
            type: BtoonSchemaType.integer, elementCode: c.elementUint8),
        const BtoonSchemaField('d',
            type: BtoonSchemaType.integer, elementCode: c.elementInt16),
        const BtoonSchemaField('e',
            type: BtoonSchemaType.integer, elementCode: c.elementUint16),
        const BtoonSchemaField('f',
            type: BtoonSchemaType.integer, elementCode: c.elementInt32),
        const BtoonSchemaField('g',
            type: BtoonSchemaType.integer, elementCode: c.elementUint32),
      ]);
      final value = {
        'a': -128,
        'b': 255,
        'd': -32768,
        'e': 65535,
        'f': -2147483648,
        'g': 4294967295
      };
      final bytes = btoonEncodeWithSchema(value, schema);
      expect(btoonDecodeWithSchema(bytes, schema), value);
    });

    test('float32 element code round-trips lossless values', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('x',
            type: BtoonSchemaType.number, elementCode: c.elementFloat32),
      ]);
      final bytes = btoonEncodeWithSchema({'x': 0.5}, schema);
      expect(btoonDecodeWithSchema(bytes, schema), {'x': 0.5});
    });

    test('binary field decodes to raw bytes by default', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('blob', type: BtoonSchemaType.binary),
      ]);
      final bytes = btoonEncodeWithSchema(
        {
          'blob': BtoonBinary(Uint8List.fromList([1, 2, 3]))
        },
        schema,
      );
      final decoded = btoonDecodeWithSchema(bytes, schema) as Map;
      expect(decoded['blob'], isA<Uint8List>());
      expect(List<int>.from(decoded['blob'] as List), [1, 2, 3]);
    });

    test('array and object typed fields round-trip tagged values', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('tags', type: BtoonSchemaType.array),
        const BtoonSchemaField('meta', type: BtoonSchemaType.object),
      ]);
      final value = {
        'tags': [1, 2],
        'meta': {'x': true},
      };
      final bytes = btoonEncodeWithSchema(value, schema);
      expect(btoonDecodeWithSchema(bytes, schema), value);
    });
  });

  group('btoonEncodeAuto / btoonDeriveSchema', () {
    test('auto mode round-trips a map', () {
      final bytes = btoonEncodeAuto({'id': 1, 'name': 'Alice'});
      expect(btoonDecode(bytes), {'id': 1, 'name': 'Alice'});
    });

    test('derive reports sorted field names', () {
      final schema = btoonDeriveSchema({
        'zeta': 1,
        'alpha': 'x',
      });
      expect(schema.fieldNames, ['alpha', 'zeta']);
    });

    test('derive rejects scalar roots', () {
      expect(() => btoonDeriveSchema(42), throwsA(isA<BtoonEncodeError>()));
    });

    test('schema-mode list with non-map row is rejected', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ]);
      expect(
        () => btoonEncodeWithSchema([
          {'a': 1},
          2,
        ], schema),
        throwsA(isA<BtoonEncodeError>()),
      );
    });
  });

  group('session dictionary across messages', () {
    test('later messages reuse session strings in both directions', () {
      final session = BtoonSession();
      final first = btoonEncode(
        {'name': 'Alice', 'role': 'admin'},
        options: BtoonEncodeOptions(session: session),
      );
      // Decoding grows the same session (growSession defaults to true).
      expect(
        btoonDecode(first, options: BtoonDecodeOptions(session: session)),
        {'name': 'Alice', 'role': 'admin'},
      );

      final second = btoonEncode(
        {'name': 'Alice', 'role': 'user'},
        options: BtoonEncodeOptions(session: session),
      );
      expect(second.length, lessThan(first.length));
      expect(
        btoonDecode(second, options: BtoonDecodeOptions(session: session)),
        {'name': 'Alice', 'role': 'user'},
      );
    });

    test('options are forwarded by the wrappers', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
      ]);
      final rows = [
        {'id': 1},
        {'id': 2},
      ];
      final session = BtoonSession();
      final bytes = btoonEncodeWithSchema(
        rows,
        schema,
        options: BtoonEncodeOptions(
          session: session,
          growSession: false,
          minStringTableFrequency: 3,
        ),
      );
      final decoded = btoonDecodeWithSchema(
        bytes,
        schema,
        options: BtoonDecodeOptions(
          session: session,
          growSession: false,
          preserveBinary: true,
          preserveTypedArrays: true,
        ),
      );
      expect(decoded, rows);
      // growSession: false means the session stayed empty.
      expect(session.length, 0);
    });

    test('auto mode forwards options and embeds the derived schema', () {
      final session = BtoonSession();
      final bytes = btoonEncodeAuto(
        {'id': 1},
        options: BtoonEncodeOptions(
          session: session,
          growSession: false,
          minStringTableFrequency: 3,
        ),
      );
      expect(btoonDecode(bytes), {'id': 1});
    });

    test('large session ids decode through wide StringRef ids', () {
      final session = BtoonSession();
      for (var i = 0; i < 120; i++) {
        session.add('s$i');
      }
      final bytes = btoonEncode(
        {'s119': 1},
        options: BtoonEncodeOptions(session: session),
      );
      expect(
        btoonDecode(bytes, options: BtoonDecodeOptions(session: session)),
        {'s119': 1},
      );
    });

    test('ObjectTable column names outside the session go to the table (§14)',
        () {
      final session = BtoonSession()..add('known');
      final bytes = btoonEncode(
        [
          {'col': 1},
        ],
        options: BtoonEncodeOptions(session: session),
      );
      // The column name is not in the session dictionary, so it must be
      // added to the per-message string table and referenced from there;
      // the no-string-table flag (0x10) must not be set.
      expect(bytes[5] & c.flagStringTable, c.flagStringTable);
      expect(bytes[5] & c.flagNoStringTable, 0);
      expect(
        btoonDecode(bytes, options: BtoonDecodeOptions(session: session)),
        [
          {'col': 1},
        ],
      );
    });
  });

  group('decode options', () {
    test('maxDepth guards against deep payloads', () {
      final bytes = btoonEncode({
        'a': {
          'b': {'c': 1},
        },
      });
      expect(
        () =>
            btoonDecode(bytes, options: const BtoonDecodeOptions(maxDepth: 1)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('preserveTypedArrays returns typed views', () {
      final bytes = btoonEncode([1, 2, 3]);
      final decoded = btoonDecode(bytes,
          options: const BtoonDecodeOptions(preserveTypedArrays: true));
      expect(decoded, isA<BtoonTypedArray>());
    });

    test('string table can be disabled entirely', () {
      final value = {
        'k${'x' * 40}': 'v${'y' * 40}',
        'k2${'x' * 40}': 'v${'y' * 40}'
      };
      final bytes = btoonEncode(
        value,
        options:
            const BtoonEncodeOptions(stringTable: BtoonStringTableMode.off),
      );
      expect(btoonDecode(bytes), value);
    });
  });

  group('error types', () {
    test('BtoonEncodeError toString includes message and value', () {
      expect(const BtoonEncodeError('boom').toString(), contains('boom'));
      final err = const BtoonEncodeError('bad input', 7);
      expect(err.toString(), contains('bad input'));
      expect(err.toString(), contains('7'));
    });

    test('BtoonDecodeError carries offset and message', () {
      final err = const BtoonDecodeError('truncated', 12);
      expect(err.offset, 12);
      expect(err.toString(), contains('truncated'));
    });
  });

  group('supporting types', () {
    test('BtoonBinary equality, hash, and description', () {
      final a = BtoonBinary(Uint8List.fromList([1, 2]));
      final b = BtoonBinary(Uint8List.fromList([1, 2]));
      final cBin = BtoonBinary(Uint8List.fromList([1, 3]));
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(cBin)));
      expect(a.toString(), contains('2 bytes'));
    });

    test('BtoonSchemaType.code rejects any; fromCode rejects unknown', () {
      expect(
        () => BtoonSchemaType.any.code,
        throwsA(isA<BtoonEncodeError>()),
      );
      expect(
        () => BtoonSchemaType.fromCode(0x7F),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('BtoonSchema.fieldNames mirrors fields', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('one'),
        const BtoonSchemaField('two'),
      ]);
      expect(schema.fieldNames, ['one', 'two']);
    });
  });

  group('schema ids and element codes', () {
    test('uint16 schema ids and wide uint64 fields round-trip', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('n',
            type: BtoonSchemaType.integer, elementCode: c.elementUint64),
      ], id: 70000, name: 'wide');
      final bytes = btoonEncodeWithSchema(
        {'n': 9007199254740991},
        schema,
        options: const BtoonEncodeOptions(schemaIdUint16: true),
      );
      expect(btoonDecode(bytes), {'n': 9007199254740991});
    });

    test('schema id must fit UInt16 when schemaIdUint16 is set', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ], id: 0x10000);
      expect(
        () => btoonEncode(
          {'a': 1},
          options: BtoonEncodeOptions(
            schema: schema,
            schemaMode: true,
            schemaIdUint16: true,
          ),
        ),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('unknown custom element codes are rejected on encode', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('x',
            type: BtoonSchemaType.integer, elementCode: 0x7E),
      ]);
      expect(
        () => btoonEncodeWithSchema({'x': 1}, schema),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('schema field type mismatches are rejected', () {
      expect(
        () => btoonEncodeWithSchema(
          {'f': 'str'},
          BtoonSchema(
              [const BtoonSchemaField('f', type: BtoonSchemaType.integer)]),
        ),
        throwsA(isA<BtoonEncodeError>()),
      );
      expect(
        () => btoonEncodeWithSchema(
          {'f': 1},
          BtoonSchema(
              [const BtoonSchemaField('f', type: BtoonSchemaType.boolean)]),
        ),
        throwsA(isA<BtoonEncodeError>()),
      );
      expect(
        () => btoonEncodeWithSchema(
          {'f': 1},
          BtoonSchema(
              [const BtoonSchemaField('f', type: BtoonSchemaType.string)]),
        ),
        throwsA(isA<BtoonEncodeError>()),
      );
      expect(
        () => btoonEncodeWithSchema(
          {'f': 1},
          BtoonSchema(
              [const BtoonSchemaField('f', type: BtoonSchemaType.binary)]),
        ),
        throwsA(isA<BtoonEncodeError>()),
      );
    });
  });

  group('numeric range validation', () {
    test('rejects values outside each element type', () {
      void expectThrows(List<num> values, BtoonElementType type) {
        expect(
          () => validateNumericRange(values, type),
          throwsA(isA<BtoonEncodeError>()),
        );
      }

      expectThrows([128], BtoonElementType.int8);
      expectThrows([-129], BtoonElementType.int8);
      expectThrows([-1], BtoonElementType.uint8);
      expectThrows([70000], BtoonElementType.uint16);
      expectThrows([-40000], BtoonElementType.int16);
      expectThrows([5000000000 as num], BtoonElementType.int32);
      expectThrows([-1], BtoonElementType.uint32);
      expectThrows([1.5], BtoonElementType.uint8);
    });

    test('accepts boundary values for each element type', () {
      validateNumericRange([-128, 127], BtoonElementType.int8);
      validateNumericRange([0, 255], BtoonElementType.uint8);
      validateNumericRange([0, 65535], BtoonElementType.uint16);
      validateNumericRange([4294967295], BtoonElementType.uint32);
      validateNumericRange([1.5, -2.25], BtoonElementType.float32);
    });
  });
}
