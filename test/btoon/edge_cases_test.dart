import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

void expectRoundTrip(Object? value,
    {BtoonEncodeOptions? encodeOptions,
    BtoonDecodeOptions? decodeOptions,
    Object? Function(Object?)? transform}) {
  final bytes = btoonEncode(value, options: encodeOptions);
  final decoded = btoonDecode(bytes, options: decodeOptions);
  final expected = transform == null ? value : transform(value);
  expect(decoded, equals(expected));
}

void main() {
  group('integer wire boundaries', () {
    test('SmallInt min/max use bare bytes 0x20 and 0x9F', () {
      expect(btoonEncode(-32)[8], 0x20);
      expect(btoonEncode(95)[8], 0x9F);
    });

    test('just outside SmallInt switches to Int32', () {
      expect(btoonEncode(-33)[8], 0x03); // tagInt32
      expect(btoonEncode(96)[8], 0x03);
      expect(btoonDecode(btoonEncode(-33)), -33);
      expect(btoonDecode(btoonEncode(96)), 96);
    });

    test('int32 ↔ int64 switching happens at 2^31 and -2^31-1', () {
      expect(btoonEncode(2147483647)[8], 0x03); // int32 max → Int32
      expect(btoonEncode(2147483648)[8], 0x04); // +1 → Int64
      expect(btoonEncode(-2147483648)[8], 0x03); // int32 min → Int32
      expect(btoonEncode(-2147483649)[8], 0x04); // -1 → Int64
      expectRoundTrip(2147483647);
      expectRoundTrip(2147483648);
      expectRoundTrip(-2147483648);
      expectRoundTrip(-2147483649);
    });

    test('int64 min/max round-trip', () {
      expectRoundTrip(9223372036854775807);
      expectRoundTrip(-9223372036854775808);
      expect(btoonEncode(9223372036854775807)[8], 0x04);
      expect(btoonEncode(-9223372036854775808)[8], 0x04);
    });

    test('int64 endianness is little-endian', () {
      final bytes = btoonEncode(0x0102030405060708);
      final body = bytes.sublist(8);
      expect(body[0], 0x04); // tagInt64
      expect(body.sublist(1), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]);
    });
  });

  group('float wire boundaries', () {
    test('infinity and NaN choose correct width', () {
      expect(btoonEncode(double.infinity)[8], 0x05); // float32
      expect(btoonEncode(double.negativeInfinity)[8], 0x05);
      expect(
          btoonEncode(double.nan)[8], 0x06); // float64 (not float32-lossless)
      final nan = btoonDecode(btoonEncode(double.nan)) as double;
      expect(nan.isNaN, isTrue);
    });

    test('float32-max is lossless and stays float32; 0.1 needs float64', () {
      expect(btoonEncode(3.4028234663852886e38)[8], 0x05);
      expect(btoonEncode(0.1)[8], 0x06);
      expectRoundTrip(3.4028234663852886e38);
    });

    test('-0.0 normalizes to integer 0', () {
      final decoded = btoonDecode(btoonEncode(-0.0));
      expect(decoded, 0);
      expect(decoded, isA<int>());
    });

    test('subnormal float32 round-trips losslessly', () {
      // Smallest positive normal-ish value near the float32 subnormal floor.
      expectRoundTrip(1.401298464324817e-45); // float32 min subnormal
    });
  });

  group('string edge cases', () {
    test('NUL bytes and control characters survive', () {
      expectRoundTrip('a\x00b\x01\x1F');
    });

    test('all single-byte code points round-trip', () {
      expectRoundTrip(String.fromCharCodes(List.generate(128, (i) => i)));
    });

    test('supplementary-plane (surrogate pair) characters round-trip', () {
      expectRoundTrip('\u{10000}\u{10FFFF}\u{1F600}');
    });

    test('strings longer than 16 bits round-trip', () {
      final long = 'x' * 70000;
      expectRoundTrip(long);
      final decoded = btoonDecode(btoonEncode(long)) as String;
      expect(decoded, long);
      expect(decoded.length, 70000);
    });

    test('empty strings are kept (not mistaken for null)', () {
      final value = {'a': '', 'b': 'x', 'c': ''};
      final decoded = btoonDecode(btoonEncode(value));
      expect(decoded, value);
    });
  });

  group('trailing data and truncation', () {
    test('trailing bytes after the value are ignored on decode', () {
      final bytes = btoonEncode(1);
      final withTrailing = Uint8List.fromList([...bytes, 0x41, 0x42]);
      expect(btoonDecode(withTrailing), 1);
    });

    test('every truncation point of a nested value fails cleanly', () {
      final bytes = btoonEncode({
        'list': [1, 2.5, 'three', true, null],
        'map': {'k': 'v'},
        'blob': Uint8List.fromList([1, 2, 3]),
      });
      for (var cut = 1; cut < bytes.length; cut++) {
        expect(
          () => btoonDecode(bytes.sublist(0, cut)),
          throwsA(isA<BtoonDecodeError>()),
          reason: 'truncation at $cut of ${bytes.length} should fail',
        );
      }
    });
  });

  group('TypedArray boundaries', () {
    test('element widths round-trip at their exact limits', () {
      for (final (type, values) in [
        (BtoonElementType.int8, const [-128, 127]),
        (BtoonElementType.uint8, const [0, 255]),
        (BtoonElementType.int16, const [-32768, 32767]),
        (BtoonElementType.uint16, const [0, 65535]),
        (BtoonElementType.int32, const [-2147483648, 2147483647]),
        (BtoonElementType.uint32, const [0, 4294967295]),
        (BtoonElementType.int64, const [5000000000]),
        (BtoonElementType.float32, const [0.5, -0.25]),
        (BtoonElementType.float64, const [0.1, 0.2]),
      ]) {
        final decoded = btoonDecode(
          btoonEncode(BtoonTypedArray(values, elementType: type)),
          options: const BtoonDecodeOptions(preserveTypedArrays: true),
        ) as BtoonTypedArray;
        expect(decoded.elementType, type, reason: '$type width');
        expect(decoded.values, values, reason: '$type values');
      }
    });

    test('forced types reject values that do not fit', () {
      for (final (type, value) in [
        (BtoonElementType.int8, 128),
        (BtoonElementType.int8, -129),
        (BtoonElementType.int16, 32768),
        (BtoonElementType.int16, -32769),
        (BtoonElementType.int32, 2147483648),
        (BtoonElementType.uint8, 256),
        (BtoonElementType.uint16, 65536),
        (BtoonElementType.uint32, 4294967296),
      ]) {
        expect(
          () => btoonEncode(BtoonTypedArray([value], elementType: type)),
          throwsA(isA<BtoonEncodeError>()),
          reason: '$type should reject $value',
        );
      }
    });

    test('uint64 is not a valid TypedArray element type', () {
      expect(
        () => btoonEncode(
            BtoonTypedArray(const [1], elementType: BtoonElementType.uint64)),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('integers beyond uint32 collapse to int64, not uint64', () {
      final bytes = btoonEncode([5000000000]);
      expect(bytes[8], 0x0C); // tagTypedArray
      expect(bytes[9], 0x06); // int64
      expectRoundTrip([5000000000]);
    });

    test('empty forced TypedArray round-trips', () {
      final intBytes = btoonEncode(
          BtoonTypedArray(const [], elementType: BtoonElementType.int32));
      expect(intBytes[8], 0x0C); // tagTypedArray
      expect(intBytes[9], 0x04); // int32
      expect(btoonDecode(intBytes), isEmpty);

      final floatBytes = btoonEncode(
          BtoonTypedArray(const [], elementType: BtoonElementType.float64));
      expect(floatBytes[9], 0x08); // float64
      expect(btoonDecode(floatBytes), isEmpty);
    });

    test('automatic width picks the narrowest lossless type', () {
      expect(btoonEncode([1, 2])[9], 0x01); // uint8
      expect(btoonEncode([200, 1000])[9], 0x03); // uint16
      expect(btoonEncode([-1, 1])[9], 0x00); // int8
      expect(btoonEncode([-1, 300])[9], 0x02); // int16
      expect(btoonEncode([1.5, 2.5])[9], 0x07); // float32
      expect(btoonEncode([0.1, 0.2])[9], 0x08); // float64
    });
  });

  group('ObjectTable edge cases', () {
    test('empty ObjectTable round-trips', () {
      final bytes = btoonEncode(BtoonObjectTable(const []));
      expect(bytes[8], 0x0D); // tagObjectTable
      expect(btoonDecode(bytes), isEmpty);
    });

    test('single-row ObjectTable round-trips', () {
      final decoded = btoonDecode(btoonEncode(BtoonObjectTable(const [
        {'id': 1, 'x': 2.5},
      ])));
      expect(decoded, [
        {'id': 1, 'x': 2.5},
      ]);
    });

    test('uint64 column is allowed in ObjectTable', () {
      final rows = [
        {'a': 1},
        {'a': 5000000000},
      ];
      final bytes = btoonEncode(rows);
      expect(bytes[8], 0x0D);
      // The single column's element type is 0x0F (uint64).
      expect(bytes.sublist(8).any((b) => b == 0x0F), isTrue);
      expectRoundTrip(rows);
    });

    test('mixed int/double columns use a single column width', () {
      final rows = [
        {'id': 1, 'score': 9.5},
        {'id': 2, 'score': 8.0},
      ];
      final decoded = btoonDecode(btoonEncode(rows));
      expect(decoded, [
        {'id': 1, 'score': 9.5},
        {'id': 2, 'score': 8.0},
      ]);
    });

    test('list of empty maps is a general array, not a crash', () {
      final bytes = btoonEncode([{}, {}]);
      expect(bytes[8], 0x09); // tagArray
      expectRoundTrip([{}, {}]);
    });

    test('list mixing empty and non-empty maps is a general array', () {
      expectRoundTrip([
        {},
        {'a': 1},
      ]);
    });
  });

  group('string table and session', () {
    test('empty strings participate in the string table', () {
      final bytes = btoonEncode({'a': '', 'b': ''});
      expect(bytes[5] & 0x04, 0x04); // string table present
      expectRoundTrip({'a': '', 'b': ''});
    });

    test('minStringTableFrequency = 2 excludes single occurrences', () {
      final bytes = btoonEncode({'a': 'once'});
      expect(bytes[5] & 0x04, 0);
      // but a repeated string is added
      final repeated = btoonEncode({'a': 'x', 'b': 'x'});
      expect(repeated[5] & 0x04, 0x04);
    });

    test('session with pre-seeded entries encodes StringRefs', () {
      final session = BtoonSession()
        ..add('hello')
        ..add('world');
      final bytes = btoonEncode({'a': 'hello', 'b': 'world'},
          options: BtoonEncodeOptions(session: session, growSession: false));
      expect(bytes[5] & 0x08, 0x08); // session flag
      final decoded =
          btoonDecode(bytes, options: BtoonDecodeOptions(session: session));
      expect(decoded, {'a': 'hello', 'b': 'world'});
    });

    test('session indices above 95 use Int32 StringRef ids', () {
      final session = BtoonSession();
      for (var i = 0; i < 100; i++) {
        session.add('s$i');
      }
      final bytes = btoonEncode({'a': 's99'},
          options: BtoonEncodeOptions(session: session, growSession: false));
      final decoded =
          btoonDecode(bytes, options: BtoonDecodeOptions(session: session));
      expect(decoded, {'a': 's99'});
    });

    test('growSession = false does not mutate the session', () {
      final session = BtoonSession()..add('pre');
      btoonEncode({'a': 'new'}, options: BtoonEncodeOptions(session: session));
      // The key 'a' is an inline string too, so it is grown as well.
      expect(session.entries, ['pre', 'a', 'new']);
      session.clear();
      session.add('pre');
      btoonEncode({'a': 'new'},
          options: BtoonEncodeOptions(session: session, growSession: false));
      expect(session.entries, ['pre']);
    });
  });

  group('schema mode edge cases', () {
    test('schema id and name round-trip through the embedded schema', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('x', type: BtoonSchemaType.integer),
      ], id: 42, name: 'MySchema');
      final decoded = btoonDecode(
        btoonEncode({'x': 5},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, {'x': 5});
    });

    test('unknown keys are dropped in schema mode', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ]);
      final decoded = btoonDecode(
        btoonEncode({'a': 1, 'extra': 2},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, {'a': 1});
    });

    test('missing required fields fail to encode', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ]);
      expect(
        () => btoonEncode({'other': 1},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('nested array/object fields round-trip in schema mode', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('tags', type: BtoonSchemaType.array),
        const BtoonSchemaField('meta', type: BtoonSchemaType.object),
      ]);
      final value = {
        'tags': ['x', 'y'],
        'meta': {'k': 1}
      };
      final decoded = btoonDecode(
        btoonEncode(value,
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, value);
    });

    test('narrow numeric schema fields keep their width', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('x', elementCode: 0x07), // float32
      ]);
      final decoded = btoonDecode(
        btoonEncode({'x': 1.5},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, {'x': 1.5});
    });

    test('a one-element list is byte-identical to a single record', () {
      // Per §15 a one-element list and a single record produce the same
      // bytes, so both decode to a single map.
      final single = btoonEncode({'a': 1},
          options: const BtoonEncodeOptions(schemaMode: true));
      final oneList = btoonEncode([
        {'a': 1},
      ], options: const BtoonEncodeOptions(schemaMode: true));
      expect(oneList, equals(single));
      expect(btoonDecode(single), {'a': 1});
      expect(btoonDecode(oneList), {'a': 1});
    });
  });
}
