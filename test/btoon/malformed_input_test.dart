import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';
import 'package:toon_format/src/btoon/constants.dart' as c;

/// Builds a minimal BTOON envelope (magic, version, flags, reserved) around
/// a hand-crafted [body].
Uint8List env(List<int> body, {int flags = 0}) {
  final b = BytesBuilder();
  b.add(c.btoonMagic);
  b.addByte(c.btoonVersion);
  b.addByte(flags);
  b.addByte(0);
  b.addByte(0);
  while (b.length < c.btoonEnvelopeSize) {
    b.addByte(0);
  }
  b.add(body);
  return b.toBytes();
}

void main() {
  group('envelope validation', () {
    test('rejects input shorter than the envelope', () {
      expect(
        () => btoonDecode(Uint8List.fromList([0x42, 0x54])),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects bad magic bytes', () {
      final bytes = env([c.smallIntBias])..[2] = 0x00;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects unsupported version', () {
      final bytes = env([c.smallIntBias])..[4] = 0x02;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects non-zero reserved bytes', () {
      final bytes = env([c.smallIntBias])..[6] = 0x01;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('value decoding', () {
    test('rejects unknown value tags', () {
      expect(
        () => btoonDecode(env([0x11])),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects non-string object keys', () {
      // Object with one entry whose key tag is null.
      final body = [
        c.tagObject,
        ...uint32LE(1),
        c.tagNull,
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects invalid UTF-8 in inline strings', () {
      final body = [
        c.tagString,
        ...uint32LE(2),
        0xFF,
        0xFE,
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('TypedArray headers', () {
    test('rejects uint64 element type', () {
      expect(
        () => btoonDecode(env([c.tagTypedArray, c.elementUint64])),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects padding length above 7', () {
      final body = [
        c.tagTypedArray,
        c.elementInt8,
        ...uint32LE(1),
        8,
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('ObjectTable headers', () {
    test('rejects non-string column names', () {
      final body = [
        c.tagObjectTable,
        ...uint32LE(1), // rows
        ...uint32LE(1), // fields
        c.tagNull, // column name tag: not a string
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('requires StringRef column names when a session is active', () {
      final body = [
        c.tagObjectTable,
        ...uint32LE(1),
        ...uint32LE(1),
        c.tagString, // inline string instead of the required StringRef
        ...uint32LE(3),
        ...'col'.codeUnits,
      ];
      expect(
        () => btoonDecode(
          env(body, flags: c.flagSession),
          options: BtoonDecodeOptions(session: BtoonSession()),
        ),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a column that does not align its payload', () {
      // A float32 column (4-byte) at this offset needs 1 pad byte; claiming
      // 0 would leave the payload misaligned.
      final body = [
        c.tagObjectTable,
        ...uint32LE(1), // rows
        ...uint32LE(1), // fields
        c.tagString,
        ...uint32LE(3),
        ...'col'.codeUnits,
        c.elementFloat32,
        0x00, // bad PadLen
        ...uint32LE(0x3F800000),
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('RecordBatch descriptors', () {
    test('rejects a zero field count', () {
      expect(
        () => btoonDecode(env([c.tagRecordBatch, ...uint32LE(0)])),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects an invalid element-type selector', () {
      final body = [
        c.tagRecordBatch,
        ...uint32LE(1), // fields
        ...uint32LE(1),
        ...'a'.codeUnits,
        0x0C, // binary selector: not a valid RecordBatch field type
        0x00,
        ...uint32LE(0),
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a nullable byte other than 0 or 1', () {
      final body = [
        c.tagRecordBatch,
        ...uint32LE(1),
        ...uint32LE(1),
        ...'a'.codeUnits,
        c.elementInt8,
        0x02, // invalid nullable byte
        ...uint32LE(0),
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a hostile field count', () {
      final body = [
        c.tagRecordBatch,
        0xFF, 0xFF, 0xFF, 0xFF, // field count = 2^32-1
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a hostile row count', () {
      final body = [
        c.tagRecordBatch,
        ...uint32LE(1),
        ...uint32LE(1),
        ...'a'.codeUnits,
        c.elementInt8,
        0x00,
        0xFF, 0xFF, 0xFF, 0xFF, // row count = 2^32-1
      ];
      expect(
        () => btoonDecode(env(body)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });

  group('RecordBatch bitmaps and values', () {
    Uint8List batch({
      required int rowCount,
      required int selector,
      int nullable = 1,
      List<int>? bitmap,
      List<int> values = const [],
    }) {
      return env([
        c.tagRecordBatch,
        ...uint32LE(1), // fields
        ...uint32LE(1),
        ...'n'.codeUnits,
        selector,
        nullable,
        ...uint32LE(rowCount),
        ...?bitmap,
        ...values,
      ]);
    }

    test('rejects non-zero unused bits in the final bitmap byte', () {
      // 2 rows use 2 bits; bit 2 is unused and MUST be zero.
      final bytes = batch(
        rowCount: 2,
        selector: c.elementString,
        bitmap: [0x81],
        values: [
          ...uint32LE(0),
        ],
      );
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a truncated validity bitmap', () {
      final bytes = batch(
        rowCount: 16, // needs 2 bitmap bytes
        selector: c.elementInt8,
        bitmap: [0x01], // only 1
        values: List<int>.filled(16, 0x41),
      );
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects a truncated row value', () {
      final bytes = batch(
        rowCount: 2,
        selector: c.elementString,
        bitmap: [0x03], // both rows present
        values: [
          ...uint32LE(5), // claims 5 bytes
          ...'ab'.codeUnits, // only 2 present
        ],
      );
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('rejects an all-null field that carries a value', () {
      // A null-selector field must consume no bytes, so a trailing byte is
      // rejected as a RecordBatch value.
      final bytes = env([
        c.tagRecordBatch,
        ...uint32LE(1),
        ...uint32LE(1),
        ...'n'.codeUnits,
        c.elementNull,
        0x00,
        ...uint32LE(1), // 1 row
        0x41, // unexpected value byte
      ]);
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('accepts a zero-length present string as distinct from null', () {
      final bytes = batch(
        rowCount: 2,
        selector: c.elementString,
        bitmap: [0x01], // row 0 present, row 1 null
        values: [
          ...uint32LE(0), // present, empty string
        ],
      );
      final decoded = btoonDecode(bytes) as List;
      expect((decoded[0] as Map)['n'], '');
      expect((decoded[1] as Map)['n'], isNull);
    });
  });

  group('schema body validation', () {
    test('rejects a schema bool byte other than 0 or 1', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('flag', type: BtoonSchemaType.boolean),
      ], id: 1, name: 'S');
      final bytes = btoonEncode({'flag': true},
          options: BtoonEncodeOptions(schema: schema, schemaMode: true));
      // The bool value is the last byte of the body.
      bytes[bytes.length - 1] = 0x02;
      expect(
        () => btoonDecode(bytes),
        throwsA(isA<BtoonDecodeError>()),
      );
    });
  });
}

List<int> uint32LE(int v) => [
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ];
