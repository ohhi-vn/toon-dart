import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';
import 'package:toon_format/src/btoon/constants.dart' as c;
import 'package:toon_format/src/btoon/io.dart';
import 'package:toon_format/src/btoon/options.dart' show BtoonStringTableMode;

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

  test('§26.3 "hello" is inline: one occurrence never pays for a table', () {
    expectVector(
      'hello',
      '42 54 4F 4E 01 00 00 00'
          '07 05 00 00 00 68 65 6C 6C 6F',
    );
  });

  test('§26.3 a repeated "hello!" uses a table when it shrinks the message', () {
    expectVector(
      ['hello!', 'hello!'],
      '42 54 4F 4E 01 04 00 00'
          '01 00 00 00'
          '06 00 00 00 68 65 6C 6C 6F 21'
          '00 00'
          '09 02 00 00 00'
          '0B 40 0B 40',
    );
  });

  test('§26.4 TypedArray [1, 2, 3] as int8', () {
    expectVector(
      [1, 2, 3],
      '42 54 4F 4E 01 00 00 00'
      '0C 00 03 00 00 00 00 01 02 03',
    );
  });

  test('§26.5 object uses inline strings when each occurs once', () {
    expectVector(
      {'age': 30, 'name': 'Alice'},
      '42 54 4F 4E 01 00 00 00'
      '0A 02 00 00 00'
      '07 03 00 00 00 61 67 65 5E'
      '07 04 00 00 00 6E 61 6D 65'
      '07 05 00 00 00 41 6C 69 63 65',
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

  group('measurement sink parity (design: exact size selection)', () {
    test('the counter and the byte writer agree on every write', () {
      // The encoder chooses between representations by counting bytes, so
      // the counting sink must describe exactly the same layout as the
      // materializing one.
      void replay(void Function(BtoonSink) body) {
        final writer = BtoonWriter();
        final counter = BtoonCounter();
        body(writer);
        body(counter);
        expect(counter.length, writer.length);
      }

      replay((sink) {
        sink
          ..writeBytes(c.btoonMagic)
          ..writeByte(c.btoonVersion)
          ..writeByte(0);
      });

      replay((sink) {
        sink
          ..writeUint16(1)
          ..writeInt16(-2)
          ..writeUint32(3)
          ..writeInt32(-4)
          ..writeUint64(5)
          ..writeInt64(-6)
          ..writeFloat32(1.5)
          ..writeFloat64(0.1)
          ..writeBytes([1, 2, 3, 4, 5]);
      });

      // Alignment and typed-payload padding across every element width.
      for (final size in [1, 2, 4, 8]) {
        for (final prefix in [0, 1, 3, 5, 7, 8, 11, 13]) {
          replay((sink) {
            sink.writePadding(prefix);
            final padLen = sink.padLengthFor(size);
            sink.writeByte(padLen);
            sink.writePadding(padLen);
            sink.writeBytes(List<int>.filled(size * 2, 0xAB));
          });
        }
      }

      replay((sink) => sink.align(8));
      replay((sink) {
        sink.writeBytes([1, 2, 3, 4, 5, 6, 7]);
        sink.align(8);
        sink.writeBytes([8]);
      });
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
      // A repeated string makes the encoder emit a per-message table whose
      // end is zero-padded to an 8-byte boundary; that padding sits directly
      // before the body.
      final bytes = btoonEncode(['hello!', 'hello!']);
      expect(bytes[5] & c.flagStringTable, c.flagStringTable);
      final padOffset = bytes.length - 4;
      bytes[padOffset] = 0x01;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('a misaligned typed payload is rejected (§16)', () {
      // [1.5, 2.5] is a float32 TypedArray whose PadLen must bring the raw
      // buffer to a 4-byte boundary. Claiming less padding must not decode.
      final bytes = btoonEncode([1.5, 2.5]);
      expect(bytes[8], 0x0C); // tagTypedArray
      expect(bytes[9], 0x07); // float32
      expect(bytes[14], 0x01); // canonical PadLen for a 4-byte boundary
      bytes[14] = 0x00; // under-pad: the payload no longer starts aligned
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('float canonicalization (§9.4, §17)', () {
    test('0.0 stays a Float32 and keeps its type', () {
      final bytes = btoonEncode(0.0);
      expect(bytes.sublist(8), [0x05, 0x00, 0x00, 0x00, 0x00]);
      final decoded = btoonDecode(bytes);
      expect(decoded, isA<double>());
      expect(decoded, 0.0);
    });

    test('-0.0 keeps the sign bit', () {
      final bytes = btoonEncode(-0.0);
      expect(bytes.sublist(8), [0x05, 0x00, 0x00, 0x00, 0x80]);
      final decoded = btoonDecode(bytes) as double;
      expect(decoded, 0.0);
      expect(decoded.isNegative, isTrue);
    });

    test('a zero in a list keeps the TypedArray path', () {
      final bytes = btoonEncode([0.0, 1.5]);
      expect(bytes[8], 0x0C); // tagTypedArray
      expect(btoonDecode(bytes), [0.0, 1.5]);
    });
  });

  group('string-table size selection (§7.5, §17)', () {
    test('a single occurrence is never tabled', () {
      final bytes = btoonEncode({
        'name': 'Alice',
        'friend': 'Bob',
      });
      expect(bytes[5] & c.flagStringTable, 0);
    });

    test('a repeated string uses a table', () {
      final bytes = btoonEncode({
        'name': 'Alice',
        'friend': 'Alice',
        'other': 'Alice',
      });
      expect(bytes[5] & c.flagStringTable, c.flagStringTable);
    });

    test('a table that does not shrink the message is not emitted', () {
      // A tie between the two encodings keeps strings inline (§7.5).
      final tie = {
        'name': 'Alice',
        'friend': 'Alice',
      };
      expect(btoonEncode(tie)[5] & c.flagStringTable, 0);
      expect(btoonDecode(btoonEncode(tie)), tie);

      // Short repeated strings never cover the table section.
      final value = {
        'aaaaa': 'bbbbb',
        'ccccc': 'ddddd',
      };
      final bytes = btoonEncode(value);
      expect(bytes[5] & c.flagStringTable, 0);
      expect(btoonDecode(bytes), value);
    });

    test('minStringTableFrequency below two still never tables one-offs', () {
      final bytes = btoonEncode(
        {
          'name': 'Alice',
          'friend': 'Bob',
        },
        options: const BtoonEncodeOptions(minStringTableFrequency: 1),
      );
      expect(bytes[5] & c.flagStringTable, 0);
    });

    test('the table is used exactly when it makes the message smaller', () {
      // The size difference between the two encodings is computed in closed
      // form from the collected frequencies, so this checks that shortcut
      // against real encoded sizes across many shapes.
      final alphabet = [
        'a',
        'ab',
        'abc',
        'abcd',
        'abcde',
        'abcdefghij',
        '',
        'hello',
        'Alice',
        'user1',
        'a-long-value',
        'x' * 40,
      ];
      final random = Random(7);
      for (var iteration = 0; iteration < 500; iteration++) {
        final value = <String, Object?>{};
        final keys = 1 + random.nextInt(6);
        for (var k = 0; k < keys; k++) {
          value['k${random.nextInt(4)}'] = switch (random.nextInt(5)) {
            0 => random.nextInt(100),
            1 => alphabet[random.nextInt(alphabet.length)],
            2 => [
                alphabet[random.nextInt(alphabet.length)],
                alphabet[random.nextInt(alphabet.length)],
              ],
            3 => {'n': alphabet[random.nextInt(alphabet.length)]},
            _ => alphabet[random.nextInt(alphabet.length)],
          };
        }
        final chosen = btoonEncode(value);
        final inline = btoonEncode(value,
            options: const BtoonEncodeOptions(
                stringTable: BtoonStringTableMode.off));
        final usedTable = chosen[5] & c.flagStringTable != 0;
        expect(
          usedTable,
          chosen.length < inline.length,
          reason: 'table=$usedTable chosen=${chosen.length} '
              'inline=${inline.length} for $value',
        );
        // Either way the value survives the round trip unchanged.
        expect(btoonDecode(chosen), equals(value));
      }
    });
  });

  group('envelope flag consistency (§7.3, §7.5.1, §14)', () {
    test('ObjectTable column names are StringRefs with an active session', () {
      // A column name already in the session needs no table entry, so the
      // no-per-message-table flag (0x10) is set alongside 0x08.
      final session = BtoonSession()..add('col');
      final bytes = btoonEncode([
        {'col': 1},
      ], options: BtoonEncodeOptions(session: session));
      expect(bytes[5] & c.flagSession, c.flagSession);
      expect(bytes[5] & c.flagStringTable, 0);
      expect(bytes[5] & c.flagNoStringTable, c.flagNoStringTable);
      expect(bytes[5] & (c.flagStringTable | c.flagNoStringTable),
          c.flagNoStringTable);
      expect(
        btoonDecode(bytes, options: BtoonDecodeOptions(session: session)),
        [
          {'col': 1}
        ],
      );
    });

    test('an unknown column name is forced into the per-message table', () {
      // §14: with a session active the name must be a StringRef, and a name
      // in neither dictionary must be added to the per-message table — so the
      // table flag is set and 0x10 cannot be.
      final session = BtoonSession()..add('known');
      final bytes = btoonEncode([
        {'col': 1},
      ], options: BtoonEncodeOptions(session: session));
      expect(bytes[5] & c.flagSession, c.flagSession);
      expect(bytes[5] & c.flagStringTable, c.flagStringTable);
      expect(bytes[5] & c.flagNoStringTable, 0);
      expect(
        btoonDecode(bytes, options: BtoonDecodeOptions(session: session)),
        [
          {'col': 1}
        ],
      );
    });

    test('the table and no-table flags are never both set', () {
      final session = BtoonSession()..add('col');
      for (final value in <Object?>[
        'hello!',
        ['hello!', 'hello!'],
        42,
        {'a': 1},
        [
          {'col': 1},
        ],
      ]) {
        final bytes = btoonEncode(value,
            options: BtoonEncodeOptions(session: session));
        expect(
          bytes[5] & c.flagStringTable != 0 &&
              bytes[5] & c.flagNoStringTable != 0,
          isFalse,
          reason: 'flags for $value: 0x${bytes[5].toRadixString(16)}',
        );
      }
    });
  });

  group('RecordBatch (§10.3, §26.7)', () {
    const rows = [
      {'id': 1, 'name': 'A', 'note': null, 'score': 1.5},
      {'id': 2, 'name': null, 'note': null, 'score': 2.5},
    ];
    const supported = BtoonEncodeOptions(peerSupportsRecordBatch: true);

    test('encodes the v1.0 byte-exact vector', () {
      expectVector(
        rows,
        '42 54 4F 4E 01 00 00 00'
            '0E'
            '04 00 00 00'
            '02 00 00 00 69 64 00 00'
            '04 00 00 00 6E 61 6D 65 0B 01'
            '04 00 00 00 6E 6F 74 65 09 00'
            '05 00 00 00 73 63 6F 72 65 07 00'
            '02 00 00 00'
            '01'
            '01 01 00 00 00 41 00 00 C0 3F'
            '02 00 00 20 40',
        options: supported,
      );
    });

    test('decodes to ordinary objects', () {
      final decoded = btoonDecode(btoonEncode(rows, options: supported));
      expect(decoded, rows);
      expect(decoded, isA<List<Map<String, dynamic>>>());
    });

    test('an empty string is present, not null', () {
      final value = [
        {'id': 1, 'name': '', 'score': 1.5},
        {'id': 2, 'name': null, 'score': 2.5},
      ];
      final decoded =
          btoonDecode(btoonEncode(value, options: supported)) as List;
      expect((decoded[0] as Map)['name'], '');
      expect((decoded[1] as Map)['name'], isNull);
    });

    test('peer support defaults to false', () {
      final bytes = btoonEncode(rows);
      expect(bytes[8], isNot(c.tagRecordBatch));
      expect(btoonDecode(bytes), rows);
    });

    test('numeric-only rows stay an ObjectTable', () {
      final bytes = btoonEncode([
        {'x': 1, 'y': 2.5},
        {'x': 3, 'y': 4.5},
      ], options: supported);
      expect(bytes[8], 0x0D); // tagObjectTable
    });

    test('rows with different keys are not eligible', () {
      final bytes = btoonEncode([
        {'id': 1},
        {'name': 'A'},
      ], options: supported);
      expect(bytes[8], 0x09); // tagArray
      expect(btoonDecode(bytes), [
        {'id': 1},
        {'name': 'A'},
      ]);
    });

    test('a single row is not eligible', () {
      final bytes = btoonEncode([
        {'id': 1, 'name': 'A'},
      ], options: supported);
      expect(bytes[8], 0x09);
    });

    test('a field with mixed types is not eligible', () {
      final bytes = btoonEncode([
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 7},
      ], options: supported);
      // 'id' repeats and tables, so the body does not start at offset 8;
      // with the table disabled the body tag is directly readable.
      final plain = btoonEncode([
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 7},
      ], options: const BtoonEncodeOptions(
          peerSupportsRecordBatch: true, noStringTable: true));
      expect(plain[8], 0x09); // tagArray
      expect(bytes[8], isNot(c.tagRecordBatch));
      expect(btoonDecode(bytes), [
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 7},
      ]);
    });

    test('is not used when it does not shrink the message', () {
      // Long repeated strings dedup well through the per-message string
      // table, which the dynamic encoding can use but a RecordBatch cannot,
      // so the complete dynamic message is smaller.
      final value = [
        {'id': 1, 'name': 'a-very-long-repeated-string-value'},
        {'id': 2, 'name': 'a-very-long-repeated-string-value'},
      ];
      final bytes = btoonEncode(value, options: supported);
      final dynamic = btoonEncode(value);
      expect(bytes.length, greaterThanOrEqualTo(dynamic.length));
      // The dynamic encoding wins by deduplicating through a per-message
      // string table, which a RecordBatch cannot use.
      expect(dynamic[5] & c.flagStringTable, c.flagStringTable);
      expect(btoonDecode(bytes), value);
    });

    test('is used when it shrinks the message', () {
      final value = [
        {'i': 1, 'n': 'x'},
        {'i': 2, 'n': 'y'},
      ];
      final bytes = btoonEncode(value, options: supported);
      final dynamic = btoonEncode(value);
      expect(bytes[8], c.tagRecordBatch);
      expect(bytes.length, lessThan(dynamic.length));
      expect(btoonDecode(bytes), value);
    });
  });
}
