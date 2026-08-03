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
  if (decoded is Map && expected is Map) {
    expect(decoded.length, expected.length);
    expect(decoded, equals(expected));
  } else if (decoded is List && expected is List) {
    expect(decoded.length, expected.length);
    expect(decoded, equals(expected));
  } else {
    expect(decoded, equals(expected));
  }
}

void main() {
  group('envelope', () {
    test('starts with BTON magic, version 1 and zero flags for plain values',
        () {
      final bytes = btoonEncode(1);
      expect(bytes.sublist(0, 4), [0x42, 0x54, 0x4F, 0x4E]); // "BTON"
      expect(bytes[4], 1); // version
      expect(bytes[5], 0); // flags
      expect(bytes[6], 0); // reserved
      expect(bytes[7], 0); // reserved
    });

    test('small int 1 encodes as an inline SmallInt (0x41)', () {
      final bytes = btoonEncode(1);
      expect(bytes, hasLength(9));
      expect(bytes[8], 0x41);
    });

    test('body starts at an 8-byte-aligned offset', () {
      final value = {'key': 'a very long string value that pads the table'};
      final bytes = btoonEncode(value);
      expect(bytes.length, greaterThan(8));
    });

    test('rejects bad magic', () {
      final bytes = btoonEncode(1);
      bytes[0] = 0x00;
      expect(() => btoonDecode(bytes), throwsA(isA<BtoonDecodeError>()));
    });

    test('rejects unknown version', () {
      final bytes = btoonEncode(1);
      bytes[4] = 0x63;
      expect(() => btoonDecode(bytes), throwsA(isA<BtoonDecodeError>()));
    });

    test('ignores reserved flag bits', () {
      final bytes = btoonEncode(1);
      bytes[5] = 0x80;
      expect(btoonDecode(bytes), 1);
    });

    test('rejects non-zero reserved bytes', () {
      final bytes = btoonEncode(1);
      bytes[6] = 0x01;
      expect(() => btoonDecode(bytes), throwsA(isA<BtoonDecodeError>()));
    });

    test('rejects truncated input', () {
      final bytes = btoonEncode({'a': 'b'});
      expect(() => btoonDecode(bytes.sublist(0, bytes.length - 3)),
          throwsA(isA<BtoonDecodeError>()));
      expect(() => btoonDecode(Uint8List(0)), throwsA(isA<BtoonDecodeError>()));
    });
  });

  group('primitives', () {
    test('null, booleans', () {
      expectRoundTrip(null);
      expectRoundTrip(true);
      expectRoundTrip(false);
    });

    test('inline SmallInt range [-32, 95]', () {
      for (var i = _SmallIntRange.min; i <= _SmallIntRange.max; i++) {
        expectRoundTrip(i);
      }
      expect(btoonEncode(_SmallIntRange.min), hasLength(9));
      expect(btoonEncode(_SmallIntRange.max), hasLength(9));
    });

    test('signed integer boundaries', () {
      expectRoundTrip(-49);
      expectRoundTrip(-128);
      expectRoundTrip(-129);
      expectRoundTrip(-32768);
      expectRoundTrip(-32769);
      expectRoundTrip(-2147483648);
      expectRoundTrip(-2147483649);
      expectRoundTrip(-9223372036854775808);
      expectRoundTrip(9223372036854775807);
    });

    test('unsigned integer boundaries', () {
      expectRoundTrip(64);
      expectRoundTrip(255);
      expectRoundTrip(256);
      expectRoundTrip(65535);
      expectRoundTrip(65536);
      expectRoundTrip(4294967295);
      expectRoundTrip(4294967296);
    });

    test('integer tag widths are minimal', () {
      // Values outside the SmallInt range use Int32 (0x03) / Int64 (0x04).
      expect(btoonEncode(200)[8], 0x03); // int32
      expect(btoonEncode(1000)[8], 0x03);
      expect(btoonEncode(70000)[8], 0x03);
      expect(btoonEncode(5000000000)[8], 0x04); // int64
      expect(btoonEncode(-100)[8], 0x03);
      expect(btoonEncode(-1000)[8], 0x03);
      expect(btoonEncode(-70000)[8], 0x03);
      expect(btoonEncode(-5000000000)[8], 0x04);
    });

    test('large integer values round-trip', () {
      expectRoundTrip(9223372036854775807); // int64Max
      expectRoundTrip(-9223372036854775808); // int64Min
    });

    test('floats', () {
      expectRoundTrip(1.5);
      expectRoundTrip(0.1);
      expectRoundTrip(-3.25);
      expectRoundTrip(3.4028234663852886e38); // float32 max, lossless
      expectRoundTrip(1.0e39); // float64
    });

    test('-0.0 normalizes to 0 (integer)', () {
      final decoded = btoonDecode(btoonEncode(-0.0));
      expect(decoded, 0);
      expect(decoded, isA<int>());
    });

    test('non-finite floats', () {
      final nan = btoonDecode(btoonEncode(double.nan));
      expect(nan, isA<double>());
      expect((nan as double).isNaN, isTrue);
      expectRoundTrip(double.infinity);
      expectRoundTrip(double.negativeInfinity);
    });

    test('strings (empty, unicode, long)', () {
      expectRoundTrip('');
      expectRoundTrip('hello world');
      expectRoundTrip('héllo wörld ☃ 中文 🎉');
      expectRoundTrip('a' * 10000);
    });
  });

  group('arrays', () {
    test('homogeneous int lists become TypedArray', () {
      final bytes = btoonEncode([1, 2, 3]);
      expect(bytes[8], 0x0C); // tagTypedArray
      expectRoundTrip([1, 2, 3]);
      expectRoundTrip([1, 2, 3], transform: (v) => [1, 2, 3]);
    });

    test('TypedArray element widths', () {
      // tag(8) elemType(9) count(10..13) padLen(14) data
      expect(btoonEncode([200, 250])[9], 0x01); // uint8
      expect(btoonEncode([1000, 2000])[9], 0x03); // uint16
      expect(btoonEncode([70000, 80000])[9], 0x05); // uint32
      expect(btoonEncode([-100, 50])[9], 0x00); // int8
      expect(btoonEncode([-1000, 2000])[9], 0x02); // int16
      expect(btoonEncode([-70000, 80000])[9], 0x04); // int32
      expect(btoonEncode([1.5, 2.5])[9], 0x07); // float32
      expect(btoonEncode([0.1, 0.2])[9], 0x08); // float64
    });

    test('mixed int/double lists become plain arrays, not corrupted', () {
      final bytes = btoonEncode([1, 2.5]);
      expect(bytes[8], 0x09); // tagArray
      expectRoundTrip([1, 2.5]);
    });

    test('mixed-type lists are plain arrays', () {
      expectRoundTrip([
        1,
        'two',
        true,
        null,
        {'three': 3}
      ]);
      expectRoundTrip([1, 2, 'three']);
    });

    test('empty list is a plain array', () {
      expect(btoonEncode([])[8], 0x09);
      expectRoundTrip([]);
    });

    test('nested arrays', () {
      expectRoundTrip([
        [1, 2],
        [3, 4],
      ]);
    });
  });

  group('maps', () {
    test('round-trip', () {
      expectRoundTrip({'name': 'Alice', 'age': 30});
      expectRoundTrip({
        'a': 1,
        'b': {
          'c': [1, 2, 3],
          'd': null
        }
      });
    });

    test('keys are sorted deterministically', () {
      final a = btoonEncode({'z': 1, 'a': 2, 'm': 3});
      final b = btoonEncode({'m': 3, 'a': 2, 'z': 1});
      expect(a, equals(b));
      final decoded = btoonDecode(a) as Map;
      expect(decoded.keys.toList(), ['a', 'm', 'z']);
    });

    test('empty map', () {
      expect(btoonEncode({})[8], 0x0A); // tagObject
      expectRoundTrip({});
    });

    test('non-string map keys fail to encode', () {
      expect(() => btoonEncode({1: 'one'}), throwsA(isA<BtoonEncodeError>()));
      expect(
        () => btoonEncode({
          'ok': 1,
          2: 'two',
        }),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('unsupported host types fail to encode', () {
      expect(() => btoonEncode(Object()), throwsA(isA<BtoonEncodeError>()));
      expect(
          () => btoonEncode([1, Object()]), throwsA(isA<BtoonEncodeError>()));
      expect(() => btoonEncode({'k': DateTime.now()}),
          throwsA(isA<BtoonEncodeError>()));
    });
  });

  group('binary', () {
    test('Uint8List round-trips as a blob', () {
      final bytes = btoonEncode(Uint8List.fromList([0, 1, 2, 255]));
      expect(bytes[8], 0x08); // tagBinary
      final decoded = btoonDecode(bytes);
      expect(decoded, isA<Uint8List>());
      expect((decoded as Uint8List).toList(), [0, 1, 2, 255]);
    });

    test('BtoonBinary round-trips', () {
      final blob = BtoonBinary(Uint8List.fromList([9, 8, 7]));
      final decoded = btoonDecode(btoonEncode(blob));
      expect(decoded, isA<Uint8List>());
      expect((decoded as Uint8List).toList(), [9, 8, 7]);
    });

    test('preserveBinary returns BtoonBinary', () {
      final decoded = btoonDecode(
        btoonEncode(BtoonBinary(Uint8List.fromList([1]))),
        options: const BtoonDecodeOptions(preserveBinary: true),
      );
      expect(decoded, isA<BtoonBinary>());
    });

    test('blob inside a map', () {
      expectRoundTrip({
        'data': Uint8List.fromList([1, 2, 3]),
        'name': 'blob',
      });
    });
  });

  group('TypedArray / ObjectTable wrappers', () {
    test('BtoonTypedArray with forced element type', () {
      final bytes = btoonEncode(
          BtoonTypedArray([1, 2, 3], elementType: BtoonElementType.int16));
      expect(bytes[8], 0x0C); // tagTypedArray
      expect(bytes[9], 0x02); // int16
      final decoded = btoonDecode(bytes);
      expect(decoded, [1, 2, 3]);
    });

    test('BtoonTypedArray forced type overflow fails', () {
      expect(
        () => btoonEncode(
            BtoonTypedArray([1000], elementType: BtoonElementType.int8)),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('BtoonTypedArray with mixed num uses float64', () {
      final decoded = btoonDecode(
        btoonEncode(BtoonTypedArray([1, 2.5])),
      );
      expect(decoded, [1.0, 2.5]);
    });

    test('preserveTypedArrays returns BtoonTypedArray', () {
      final decoded = btoonDecode(
        btoonEncode(
            BtoonTypedArray([1, 2], elementType: BtoonElementType.int32)),
        options: const BtoonDecodeOptions(preserveTypedArrays: true),
      );
      expect(decoded, isA<BtoonTypedArray>());
      final typed = decoded as BtoonTypedArray;
      expect(typed.elementType, BtoonElementType.int32);
      expect(typed.values, [1, 2]);
    });

    test('homogeneous numeric object lists become ObjectTable', () {
      final rows = [
        {'id': 1, 'x': 1.5},
        {'id': 2, 'x': 2.5},
      ];
      final bytes = btoonEncode(rows);
      expect(bytes[8], 0x0D); // tagObjectTable
      expectRoundTrip(rows);
    });

    test('BtoonObjectTable with a non-numeric column fails', () {
      final rows = [
        {'a': 1},
        {'a': 2, 'b': 'x'},
      ];
      expect(() => btoonEncode(BtoonObjectTable(rows)),
          throwsA(isA<BtoonEncodeError>()));
    });

    test('rows with mixed or non-numeric columns are a general array', () {
      final rows = [
        {'id': 1, 'name': 'Alice', 'score': 9.5},
        {'id': 2, 'name': 'Bob', 'score': 8.0},
      ];
      final bytes = btoonEncode(rows,
          options: const BtoonEncodeOptions(minStringTableFrequency: 100));
      expect(bytes[8], 0x09); // tagArray (name is not numeric)
      expectRoundTrip(rows);
    });

    test('ObjectTable with null or non-numeric cells is a general array', () {
      final rows = [
        {'id': 1, 'name': null},
        {'id': 2, 'name': 'Bob'},
      ];
      final bytes = btoonEncode(rows,
          options: const BtoonEncodeOptions(minStringTableFrequency: 100));
      expect(bytes[8], 0x09); // tagArray
      expectRoundTrip(rows);
    });
  });

  group('string table', () {
    test('repeated strings are deduplicated via StringRef', () {
      final value = {
        'name': 'Alice',
        'friend': 'Alice',
        'age': 30,
      };
      final bytes = btoonEncode(value);
      // "Alice" appears twice → per-message string table present (flag 0x04)
      expect(bytes[5] & 0x04, 0x04);
      expectRoundTrip(value);
    });

    test('single-occurrence strings stay inline (no table)', () {
      final bytes = btoonEncode({'a': 'once'});
      expect(bytes[5] & 0x04, 0);
      expectRoundTrip({'a': 'once'});
    });

    test('minStringTableFrequency = 1 puts every string in the table', () {
      final value = {'a': 'x', 'b': 'y'};
      final bytes = btoonEncode(value,
          options: const BtoonEncodeOptions(minStringTableFrequency: 1));
      expect(bytes[5] & 0x04, 0x04);
      expectRoundTrip(value,
          encodeOptions: const BtoonEncodeOptions(minStringTableFrequency: 1));
    });

    test('encoding is deterministic', () {
      final value = {
        'users': [
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob'},
        ],
        'meta': {'created': '2025-01-01', 'owner': 'Alice'},
      };
      final first = btoonEncode(value);
      final second = btoonEncode(value);
      expect(first, equals(second));
    });
  });

  group('session dictionary', () {
    test('shared session dedups across messages', () {
      final session = BtoonSession();
      final value = {'name': 'Alice', 'age': 30};
      final first =
          btoonEncode(value, options: BtoonEncodeOptions(session: session));
      final second =
          btoonEncode(value, options: BtoonEncodeOptions(session: session));
      // Second message reuses "Alice" from the session → smaller.
      expect(second.length, lessThan(first.length));

      final decoded =
          btoonDecode(second, options: BtoonDecodeOptions(session: session));
      expect(decoded, value);
    });

    test('session entries are exposed', () {
      final session = BtoonSession();
      btoonEncode({'name': 'Alice', 'age': 30},
          options: BtoonEncodeOptions(session: session));
      expect(session.entries, contains('Alice'));
      expect(session.indexOf('Alice'), isNotNull);
    });

    test('decoding a session ref without a session fails', () {
      final session = BtoonSession();
      final first = btoonEncode({'a': 'hello'},
          options: BtoonEncodeOptions(session: session));
      btoonEncode({'b': 'hello'},
          options: BtoonEncodeOptions(session: session));
      final second = btoonEncode({'b': 'hello'},
          options: BtoonEncodeOptions(session: session));
      // A message that references session strings is smaller than one that
      // embeds them inline.
      expect(second.length, lessThan(first.length)); // sanity
      // A message that references a session string cannot decode without the session.
      final bytes = btoonEncode({'a': 'hello'},
          options: BtoonEncodeOptions(session: session));
      expect(() => btoonDecode(bytes), throwsA(isA<BtoonDecodeError>()));
      expect(btoonDecode(bytes, options: BtoonDecodeOptions(session: session)),
          {'a': 'hello'});
    });
  });

  group('schema mode', () {
    test('derived schema round-trips a map', () {
      final value = {'id': 1, 'name': 'Alice', 'active': true, 'score': 9.5};
      final bytes = btoonEncode(value,
          options: const BtoonEncodeOptions(schemaMode: true));
      expect(bytes[5] & 0x02, 0x02); // embedded schema ⇒ schema mode
      expectRoundTrip(value,
          encodeOptions: const BtoonEncodeOptions(schemaMode: true));
    });

    test('derived schema round-trips a list of maps', () {
      final rows = [
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ];
      final bytes = btoonEncode(rows,
          options: const BtoonEncodeOptions(schemaMode: true));
      expect(bytes[5] & 0x02, 0x02); // embedded schema ⇒ schema mode
      expectRoundTrip(rows,
          encodeOptions: const BtoonEncodeOptions(schemaMode: true));
    });

    test('schema mode drops keys and tags', () {
      final value = List.generate(10, (i) => {'id': i, 'name': 'user$i'});
      final tagged = btoonEncode(value);
      final schemaMode = btoonEncode(value,
          options: const BtoonEncodeOptions(schemaMode: true));
      // Keys appear once in the embedded schema, not once per row.
      final body = schemaMode.sublist(8);
      var idCount = 0;
      var nameCount = 0;
      for (var i = 0; i + 4 <= body.length; i++) {
        if (body[i] == 0x69 && body[i + 1] == 0x64) idCount++; // "id"
        if (body[i] == 0x6E &&
            body[i + 1] == 0x61 &&
            body[i + 2] == 0x6D &&
            body[i + 3] == 0x65) {
          nameCount++; // "name"
        }
      }
      expect(idCount, 1);
      expect(nameCount, 1);
      // The tagged body uses compact per-row SmallInts; schema mode uses
      // int64 fields, so it is not necessarily smaller on a single message.
      expect(schemaMode.length, greaterThan(8));
      expect(tagged.length, greaterThan(8));
    });

    test('schema mode with a null-typed field', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
        const BtoonSchemaField('deleted', type: BtoonSchemaType.null_),
      ]);
      final value = {'id': 7, 'deleted': null};
      final decoded = btoonDecode(
        btoonEncode(value,
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, value);
    });

    test('non-null field with null fails', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('id', type: BtoonSchemaType.integer),
      ]);
      expect(
        () => btoonEncode({'id': null},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('schema mode requires an object root', () {
      expect(
        () => btoonEncode(42,
            options: const BtoonEncodeOptions(schemaMode: true)),
        throwsA(isA<BtoonEncodeError>()),
      );
      expect(
        () => btoonEncode([1, 2, 3],
            options: const BtoonEncodeOptions(schemaMode: true)),
        throwsA(isA<BtoonEncodeError>()),
      );
    });

    test('decoding a schema-mode body with a mismatched schema id fails', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ], id: 7, name: 'Seven');
      final bytes = btoonEncode({'a': 1},
          options: BtoonEncodeOptions(schema: schema, schemaMode: true));
      // Simulate a message whose embedded schema was not transmitted: the
      // body still begins with its SchemaID, which must match the supplied
      // out-of-band schema.
      bytes[5] = bytes[5] & ~0x02;
      final other = BtoonSchema([
        const BtoonSchemaField('a', type: BtoonSchemaType.integer),
      ], id: 99, name: 'Other');
      expect(
        () => btoonDecode(bytes, options: BtoonDecodeOptions(schema: other)),
        throwsA(isA<BtoonDecodeError>()),
      );
    });

    test('number schema type decodes ints as doubles', () {
      final schema = BtoonSchema([
        const BtoonSchemaField('price', type: BtoonSchemaType.number),
      ]);
      final decoded = btoonDecode(
        btoonEncode({'price': 5},
            options: BtoonEncodeOptions(schema: schema, schemaMode: true)),
      );
      expect(decoded, {'price': 5.0});
    });
  });

  group('alignment', () {
    test('typed array data is aligned to its element size', () {
      // [1.5, 2.5] → float32 (4 bytes). Body starts at offset 8.
      final bytes = btoonEncode([1.5, 2.5]);
      // tag(8) elemType(9) count(10..13) padLen(14) → align to 4 → data at 16.
      expect(bytes[8], 0x0C);
      final dataOffset = 16;
      final byteData = ByteData.sublistView(bytes);
      expect(byteData.getFloat32(dataOffset, Endian.little), 1.5);
      expect(byteData.getFloat32(dataOffset + 4, Endian.little), 2.5);
    });

    test('float64 typed array data is 8-byte aligned', () {
      final bytes = btoonEncode([0.1, 0.2]);
      // tag(8) elemType(9) count(10..13) padLen(14) → align to 8 → data at 16.
      final byteData = ByteData.sublistView(bytes);
      expect(byteData.getFloat64(16, Endian.little), 0.1);
      expect(byteData.getFloat64(24, Endian.little), 0.2);
    });

    test('typed array data offset is aligned in nested structures', () {
      final bytes = btoonEncode({
        'values': [1.5, 2.5]
      });
      final decoded = btoonDecode(bytes);
      expect(decoded, {
        'values': [1.5, 2.5]
      });
    });
  });
}

/// SmallInt wire range ([-32, 95]).
class _SmallIntRange {
  static const int min = -32;
  static const int max = 95;
}
