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
  });
}

List<int> uint32LE(int v) => [
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ];
