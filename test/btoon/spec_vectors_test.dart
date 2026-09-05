import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';
import 'package:toon_format/src/btoon/constants.dart' as c;

/// Byte-exact test vectors from the BTOON spec §26, plus the v1.0 features
/// they pin down: SmallInt boundaries (§26.2), TypedArray tie-break (§26.4),
/// string table by default (§26.3, §26.5), schema block padding (§26.6).
void main() {
  Uint8List hex(String hex) {
    final cleaned = hex.replaceAll(RegExp(r'[\s\n]'), '');
    final out = Uint8List(cleaned.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  void expectVector(Object? value, String hexBytes,
      {BtoonEncodeOptions? options}) {
    final actual = btoonEncode(value, options: options);
    final expected = hex(hexBytes);
    expect(
      actual,
      equals(expected),
      reason: 'encoding $value\n'
          ' actual: ${actual.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}\n'
          'expected: $hexBytes',
    );
  }

  group('§26.1 primitives', () {
    test('null', () => expectVector(null, '42 54 4F 4E 01 00 00 00 00'));
    test('false', () => expectVector(false, '42 54 4F 4E 01 00 00 00 01'));
    test('true', () => expectVector(true, '42 54 4F 4E 01 00 00 00 02'));
    test('-32 SmallInt', () => expectVector(-32, '42 54 4F 4E 01 00 00 00 20'));
    test('0 SmallInt', () => expectVector(0, '42 54 4F 4E 01 00 00 00 40'));
    test('42 SmallInt', () => expectVector(42, '42 54 4F 4E 01 00 00 00 6A'));
    test('95 SmallInt', () => expectVector(95, '42 54 4F 4E 01 00 00 00 9F'));
    test('96 Int32',
        () => expectVector(96, '42 54 4F 4E 01 00 00 00 03 60 00 00 00'));
    test('-33 Int32',
        () => expectVector(-33, '42 54 4F 4E 01 00 00 00 03 DF FF FF FF'));
    test(
        '2^31 Int64',
        () => expectVector(
            2147483648, '42 54 4F 4E 01 00 00 00 04 00 00 00 80 00 00 00 00'));
    test('1.5 Float32',
        () => expectVector(1.5, '42 54 4F 4E 01 00 00 00 05 00 00 C0 3F'));
    test(
        '1.1 Float64',
        () => expectVector(
            1.1,
            '42 54 4F 4E 01 00 00 00 '
            '06 9A 99 99 99 99 99 F1 3F'));
    test(
        'Binary(1,2,3)',
        () => expectVector(BtoonBinary(Uint8List.fromList([1, 2, 3])),
            '42 54 4F 4E 01 00 00 00 08 03 00 00 00 01 02 03'));
  });

  test('§26.2 SmallInt boundaries', () {
    expect(btoonEncode(-32)[8], 0x20);
    expect(btoonEncode(-1)[8], 0x3F);
    expect(btoonEncode(0)[8], 0x40);
    expect(btoonEncode(95)[8], 0x9F);
    // 96 and -33 MUST NOT use SmallInt.
    expect(btoonEncode(96).sublist(8), [0x03, 0x60, 0x00, 0x00, 0x00]);
    expect(btoonEncode(-33).sublist(8), [0x03, 0xDF, 0xFF, 0xFF, 0xFF]);
  });

  test('§26.3 "hello" with the default per-message string table', () {
    expectVector(
      'hello',
      '42 54 4F 4E 01 04 00 00'
          '01 00 00 00'
          '05 00 00 00 68 65 6C 6C 6F'
          '00 00 00'
          '0B 40',
    );
  });

  test('§26.3 "hello" with the string table disabled', () {
    expectVector(
      'hello',
      '42 54 4F 4E 01 00 00 00'
          '07 05 00 00 00 68 65 6C 6C 6F',
      options: const BtoonEncodeOptions(noStringTable: true),
    );
  });

  test('§26.4 TypedArray [1, 2, 3] as int8', () {
    expectVector(
      [1, 2, 3],
      '42 54 4F 4E 01 00 00 00'
      '0C 00 03 00 00 00 00 01 02 03',
    );
  });

  test('§26.5 object with default string table', () {
    expectVector(
      {'age': 30, 'name': 'Alice'},
      '42 54 4F 4E 01 04 00 00'
      '03 00 00 00'
      '03 00 00 00 61 67 65'
      '04 00 00 00 6E 61 6D 65'
      '05 00 00 00 41 6C 69 63 65'
      '00 00 00 00'
      '0A 02 00 00 00'
      '0B 40 5E'
      '0B 41 0B 42',
    );
  });

  test('§26.6 schema mode', () {
    final schema = BtoonSchema([
      const BtoonSchemaField('id', elementCode: c.elementInt32),
      const BtoonSchemaField('x', elementCode: c.elementFloat32),
      const BtoonSchemaField('y', elementCode: c.elementFloat32),
      const BtoonSchemaField('hp', elementCode: c.elementUint16),
    ], id: 100, name: 'Player');
    expectVector(
      {'id': 1, 'x': 1.0, 'y': 2.5, 'hp': 100},
      '42 54 4F 4E 01 02 00 00'
      '64 00 00 00'
      '06 00 00 00 50 6C 61 79 65 72'
      '04 00 00 00'
      '02 00 00 00 69 64 04'
      '01 00 00 00 78 07'
      '01 00 00 00 79 07'
      '02 00 00 00 68 70 03'
      '00 00 00 00'
      '64 00 00 00'
      '01 00 00 00'
      '00 00 80 3F'
      '00 00 20 40'
      '64 00',
      options: BtoonEncodeOptions(schema: schema, schemaMode: true),
    );
  });

  group('spec behavior', () {
    test('determinism: two encoders produce identical bytes (§17)', () {
      final value = {
        'z': [1, 2.5],
        'a': {'nested': true},
        'm': 'x',
      };
      expect(btoonEncode(value), btoonEncode(value));
    });

    test('object keys sort by UTF-8 byte sequence (§17)', () {
      // U+FFFF sorts after U+10000 in code-point (UTF-8 byte) order, but
      // before it in UTF-16 code-unit order.
      final value = {
        '\u{10000}': 1,
        '\uFFFF': 2,
        'a': 3,
      };
      final bytes = btoonEncode(value,
          options: const BtoonEncodeOptions(noStringTable: true));
      final decoded = btoonDecode(bytes) as Map;
      expect(decoded.keys.toList(), ['a', '\uFFFF', '\u{10000}']);
      // Round-trip preserves the values despite the reordering.
      expect(btoonDecode(btoonEncode(value)), value);
    });

    test('session dictionary: refs offset by session size (§11.3)', () {
      final session = BtoonSession()..add('hello');
      final bytes = btoonEncode(
        'hello',
        options: BtoonEncodeOptions(session: session, growSession: false),
      );
      // Flags: session dictionary active, no per-message table.
      expect(bytes[5] & c.flagSession, c.flagSession);
      expect(bytes[5] & c.flagNoStringTable, c.flagNoStringTable);
      expect(bytes.sublist(8), [0x0B, 0x40]); // StringRef 0
    });

    test('no-table flag (0x10) is not set when the table is needed (§14)', () {
      final session = BtoonSession()..add('known');
      final bytes = btoonEncode(
        [
          {'col': 1},
        ],
        options: BtoonEncodeOptions(session: session),
      );
      expect(bytes[5] & c.flagStringTable, c.flagStringTable);
      expect(bytes[5] & c.flagNoStringTable, 0);
    });

    test('schema id UInt16 (§7.6.1) shortens the body SchemaID', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', elementCode: c.elementInt8),
      ], id: 300, name: 'S');
      final bytes = btoonEncode(
        {'a': 7},
        options: BtoonEncodeOptions(
          schema: schema,
          schemaMode: true,
          schemaIdUint16: true,
        ),
      );
      expect(bytes[5] & c.flagSchemaIdUint16, c.flagSchemaIdUint16);
      // The body is [SchemaID::UInt16, int8 value] = 2C 01 07.
      expect(bytes.sublist(bytes.length - 3), [0x2C, 0x01, 0x07]);
      expect(btoonDecode(bytes), {'a': 7});
    });
  });

  group('extension types (§23)', () {
    test('known extension values round-trip', () {
      final value = BtoonExtension(0xFC, Uint8List.fromList([1, 2, 3, 4]));
      final bytes = btoonEncode(value);
      expect(bytes[8], 0xFC);
      final decoded = btoonDecode(bytes) as BtoonExtension;
      expect(decoded.tag, 0xFC);
      expect(decoded.payload, [1, 2, 3, 4]);
    });

    test('extension inside a container round-trips', () {
      final value = {
        'ext': BtoonExtension(0xF0, Uint8List.fromList([9])),
      };
      final decoded = btoonDecode(btoonEncode(value)) as Map;
      expect(decoded['ext'], isA<BtoonExtension>());
      expect((decoded['ext'] as BtoonExtension).payload, [9]);
    });

    test('decoder skips an unknown extension payload', () {
      // Hand-build: envelope + [tag 0xF5, length 3, payload 01 02 03, 0x40].
      final bytes = Uint8List.fromList([
        ...c.btoonMagic,
        c.btoonVersion,
        0x00,
        0x00,
        0x00,
        0xF5,
        0x03,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
      ]);
      final decoded = btoonDecode(bytes) as BtoonExtension;
      expect(decoded.tag, 0xF5);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('extension tags outside 0xF0..0xFF are rejected', () {
      expect(
        () => BtoonExtension(0x0F, Uint8List(0)),
        throwsArgumentError,
      );
      expect(
        () => btoonEncode(BtoonExtension(0xEF, Uint8List(0))),
        throwsArgumentError,
      );
    });
  });

  group('decoder limits (§24)', () {
    test('trailing bytes are rejected (§19)', () {
      final bytes = btoonEncode([1, 2]);
      // [1, 2] followed by one extra byte after the body.
      final hostile = Uint8List.fromList([...bytes, 0x00]);
      expect(
        () => btoonDecode(hostile),
        throwsA(isA<BtoonDecodeError>()),
      );
      expect(btoonDecode(bytes), [1, 2]);
    });

    test('hostile array count cannot allocate (§24)', () {
      final bytes = Uint8List.fromList([
        ...c.btoonMagic,
        c.btoonVersion,
        0x00,
        0x00,
        0x00,
        0x09, // tagArray
        0xFF,
        0xFF,
        0xFF,
        0xFF, // count = 2^32-1
      ]);
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('hostile typed array count cannot allocate (§24)', () {
      final bytes = Uint8List.fromList([
        ...c.btoonMagic,
        c.btoonVersion,
        0x00,
        0x00,
        0x00,
        0x0C, // tagTypedArray
        0x08, // float64
        0xFF,
        0xFF,
        0xFF,
        0xFF, // count = 2^32-1
        0x00, // padLen
      ]);
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('oversized strings are rejected', () {
      final bytes = Uint8List.fromList([
        ...c.btoonMagic,
        c.btoonVersion,
        0x00,
        0x00,
        0x00,
        0x07, // tagString
        0xFF,
        0xFF,
        0xFF,
        0x7F, // ~2 GiB claimed length
      ]);
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('configurable limits reject oversized input', () {
      final bytes = btoonEncode('x' * 100);
      expect(
        () => btoonDecode(bytes,
            options: const BtoonDecodeOptions(maxStringSize: 10)),
        throwsA(isA<BtoonDecodeError>()),
      );
      expect(btoonDecode(bytes), 'x' * 100);
    });

    test('non-zero alignment padding is rejected (§16)', () {
      final bytes = btoonEncode('hello');
      // The string table padding lives right before the StringRef body.
      final padOffset = bytes.length - 2;
      bytes[padOffset] = 0x01;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });
}
