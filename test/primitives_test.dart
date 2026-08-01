import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/encode/encoders.dart';
import '../lib/src/encode/primitives.dart';
import '../lib/src/types.dart';

void main() {
  group('encodePrimitive', () {
    test('encodes numbers', () {
      expect(encodePrimitive(42, ','), equals('42'));
      expect(encodePrimitive(3.14, ','), equals('3.14'));
      expect(encodePrimitive(-5, ','), equals('-5'));
      expect(encodePrimitive(100000, ','), equals('100000'));
      expect(encodePrimitive(0.5, ','), equals('0.5'));
      expect(encodePrimitive(0, ','), equals('0'));
    });

    test('keeps scientific notation outside canonical range', () {
      expect(encodePrimitive(1e-7, ','), equals('1e-7'));
      expect(encodePrimitive(1e21, ','), equals('1e+21'));
    });

    test('converts in-range scientific notation to decimal', () {
      expect(encodePrimitive(1e-5, ','), equals('0.00001'));
      expect(encodePrimitive(1e16, ','), equals('10000000000000000'));
    });

    test('encodes booleans', () {
      expect(encodePrimitive(true, ','), equals('true'));
      expect(encodePrimitive(false, ','), equals('false'));
    });

    test('encodes null', () {
      expect(encodePrimitive(null, ','), equals('null'));
    });

    test('encodes strings', () {
      expect(encodePrimitive('hello', ','), equals('hello'));
      expect(encodePrimitive('', ','), equals('""'));
    });

    test('quotes strings containing delimiter', () {
      expect(encodePrimitive('a,b', ','), equals('"a,b"'));
      expect(encodePrimitive('a|b', '|'), equals('"a|b"'));
      expect(encodePrimitive('a,b', '|'), equals('a,b'));
    });

    test('quotes strings with double quotes', () {
      expect(encodePrimitive('say "hi"', ','), equals(r'"say \"hi\""'));
    });

    test('quotes strings with newline', () {
      expect(encodePrimitive('a\nb', ','), equals(r'"a\nb"'));
    });

    test('quotes strings with leading/trailing whitespace', () {
      expect(encodePrimitive(' leading', ','), equals('" leading"'));
      expect(encodePrimitive('trailing ', ','), equals('"trailing "'));
      expect(encodePrimitive(' mid ', ','), equals('" mid "'));
    });

    test('quotes literal-looking strings', () {
      expect(encodePrimitive('true', ','), equals('"true"'));
      expect(encodePrimitive('false', ','), equals('"false"'));
      expect(encodePrimitive('null', ','), equals('"null"'));
      expect(encodePrimitive('42', ','), equals('"42"'));
      expect(encodePrimitive('1e3', ','), equals('"1e3"'));
    });

    test('quotes strings with leading - or #', () {
      expect(encodePrimitive('-item', ','), equals('"-item"'));
      expect(encodePrimitive('#tag', ','), equals('"#tag"'));
    });

    test('quotes strings containing structural characters', () {
      expect(encodePrimitive('a:b', ','), equals('"a:b"'));
      expect(encodePrimitive('a[b', ','), equals('"a[b"'));
      expect(encodePrimitive('a\\b', ','), equals(r'"a\\b"'));
    });

    test('keeps non-breaking space unquoted (preserved)', () {
      expect(encodePrimitive('a\u00A0b', ','), equals('a\u00A0b'));
    });

    test('quotes strings containing tabs/control chars', () {
      expect(encodePrimitive('a\tb', ','), equals(r'"a\tb"'));
      expect(encodePrimitive('a\u0001b', ','), equals(r'"a\u0001b"'));
    });
  });

  group('encodeStringLiteral', () {
    test('quotes empty string', () {
      expect(encodeStringLiteral('', ','), equals('""'));
    });

    test('encodes plain strings without quotes', () {
      expect(encodeStringLiteral('hello', ','), equals('hello'));
    });

    test('quotes when needed', () {
      expect(encodeStringLiteral('a,b', ','), equals('"a,b"'));
      expect(encodeStringLiteral('42', ','), equals('"42"'));
      expect(encodeStringLiteral('true', ','), equals('"true"'));
    });
  });

  group('encodeKey', () {
    test('encodes plain keys without quotes', () {
      expect(encodeKey('name'), equals('name'));
      expect(encodeKey('user.name'), equals('user.name'));
      expect(encodeKey('_id'), equals('_id'));
    });

    test('quotes keys with spaces', () {
      expect(encodeKey('first name'), equals('"first name"'));
    });

    test('quotes keys with special characters', () {
      expect(encodeKey('a:b'), equals('"a:b"'));
      expect(encodeKey('1abc'), equals('"1abc"'));
      expect(encodeKey('has-dash'), equals('"has-dash"'));
      expect(encodeKey('é'), equals('"é"'));
      expect(encodeKey(''), equals('""'));
    });

    test('quotes keys with double quotes', () {
      expect(encodeKey('say "hi"'), equals(r'"say \"hi\""'));
    });
  });

  group('encodeAndJoinPrimitives', () {
    test('joins primitives with delimiter', () {
      expect(encodeAndJoinPrimitives([1, 2, 3], ','), equals('1,2,3'));
      expect(encodeAndJoinPrimitives(['a', 'b'], '|'), equals('a|b'));
    });

    test('quotes values containing the delimiter', () {
      expect(
        encodeAndJoinPrimitives(['a,b', 'c'], ','),
        equals('"a,b",c'),
      );
    });

    test('handles empty list', () {
      expect(encodeAndJoinPrimitives([], ','), equals(''));
    });
  });

  group('formatHeader', () {
    test('formats header with length only', () {
      expect(formatHeader(2), equals('[2]:'));
    });

    test('formats header with key', () {
      expect(formatHeader(2, key: 'users'), equals('users[2]:'));
    });

    test('formats header with delimiter', () {
      expect(formatHeader(2, delimiter: '|'), equals('[2|]:'));
    });

    test('formats header with length marker', () {
      expect(formatHeader(2, lengthMarker: '#'), equals('[#2]:'));
      expect(formatHeader(2, delimiter: '|', lengthMarker: '#'), equals('[#2|]:'));
    });

    test('handles key needing quotes', () {
      expect(formatHeader(2, key: 'first name'), equals('"first name"[2]:'));
    });
  });

  group('encodeInlineArrayLine', () {
    test('empty array under a key becomes key: []', () {
      expect(encodeInlineArrayLine([], ',', null, null), equals('[0]:'));
      expect(encodeInlineArrayLine([], ',', 'tags', null), equals('tags: []'));
    });

    test('non-empty array builds inline line', () {
      expect(
        encodeInlineArrayLine([1, 2, 3], ',', null, null),
        equals('[3]: 1,2,3'),
      );
      expect(
        encodeInlineArrayLine([1, 2], ',', 'nums', '#'),
        equals('nums[#2]: 1,2'),
      );
    });
  });

  group('encodeValue', () {
    test('primitive values encode directly', () {
      expect(
        encodeValue(5, const ResolvedEncodeOptions(indent: 2, delimiter: ',')),
        equals('5'),
      );
    });
  });
}
