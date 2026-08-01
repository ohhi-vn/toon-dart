import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/decode/parser.dart';
import '../lib/src/utilities/literal-utils.dart';
import '../lib/src/utilities/string-utils.dart';

void main() {
  group('isNumericLiteralFast', () {
    test('accepts valid numbers', () {
      expect(isNumericLiteralFast('42'), isTrue);
      expect(isNumericLiteralFast('-3.14'), isTrue);
      expect(isNumericLiteralFast('0'), isTrue);
      expect(isNumericLiteralFast('0.5'), isTrue);
      expect(isNumericLiteralFast('0e1'), isTrue);
      expect(isNumericLiteralFast('1e5'), isTrue);
      expect(isNumericLiteralFast('1e-5'), isTrue);
      expect(isNumericLiteralFast('1E5'), isTrue);
      expect(isNumericLiteralFast('1e+5'), isTrue);
      expect(isNumericLiteralFast('1234567890'), isTrue);
    });

    test('rejects invalid numbers', () {
      expect(isNumericLiteralFast(''), isFalse);
      expect(isNumericLiteralFast('+5'), isFalse);
      expect(isNumericLiteralFast('-'), isFalse);
      expect(isNumericLiteralFast('+'), isFalse);
      expect(isNumericLiteralFast('05'), isFalse);
      expect(isNumericLiteralFast('007'), isFalse);
      expect(isNumericLiteralFast('-05'), isFalse);
      expect(isNumericLiteralFast('3.'), isFalse);
      expect(isNumericLiteralFast('3e'), isFalse);
      expect(isNumericLiteralFast('abc'), isFalse);
      expect(isNumericLiteralFast('1.2.3'), isFalse);
      expect(isNumericLiteralFast('1e'), isFalse);
      expect(isNumericLiteralFast('0x10'), isFalse);
    });
  });

  group('isBooleanOrNullLiteral / isNumericLiteral', () {
    test('boolean/null literals', () {
      expect(isBooleanOrNullLiteral('true'), isTrue);
      expect(isBooleanOrNullLiteral('false'), isTrue);
      expect(isBooleanOrNullLiteral('null'), isTrue);
      expect(isBooleanOrNullLiteral('True'), isFalse);
      expect(isBooleanOrNullLiteral('nul'), isFalse);
    });

    test('numeric literal', () {
      expect(isNumericLiteral('42'), isTrue);
      expect(isNumericLiteral('-1.5'), isTrue);
      expect(isNumericLiteral('05'), isFalse);
      expect(isNumericLiteral('abc'), isFalse);
      expect(isNumericLiteral(''), isFalse);
    });
  });

  group('parseFieldEntries', () {
    test('parses flat field list', () {
      final fields = parseFieldEntries('id,name,age', ',');
      expect(fields.map((f) => f.name), equals(['id', 'name', 'age']));
      expect(fields.every((f) => f.nestedFields == null), isTrue);
      expect(fields.map((f) => f.leafCount).toList(), equals([1, 1, 1]));
    });

    test('parses nested field groups', () {
      final fields = parseFieldEntries('id,customer{name,country},total', ',');
      expect(fields, hasLength(3));
      expect(fields[0].name, equals('id'));
      expect(fields[1].name, equals('customer'));
      expect(fields[1].nestedFields, hasLength(2));
      expect(fields[1].nestedFields![0].name, equals('name'));
      expect(fields[1].nestedFields![1].name, equals('country'));
      expect(fields[1].leafCount, equals(2));
      expect(fields[1].leafNames, equals(['name', 'country']));
      expect(fields[2].name, equals('total'));
    });

    test('parses deeply nested groups', () {
      final fields = parseFieldEntries('a{b{c,d},e}', ',');
      expect(fields, hasLength(1));
      expect(fields[0].leafNames, equals(['c', 'd', 'e']));
      expect(fields[0].leafCount, equals(3));
    });

    test('handles quoted field names (quotes are unquoted)', () {
      final fields = parseFieldEntries('"first name",age', ',');
      expect(fields[0].name, equals('first name'));
      expect(fields[1].name, equals('age'));
    });

    test('skips leading/trailing delimiters', () {
      final fields = parseFieldEntries(',a,,b,', ',');
      expect(fields.map((f) => f.name), equals(['a', 'b']));
    });

    test('handles custom delimiter', () {
      final fields = parseFieldEntries('a|b|c', '|');
      expect(fields, hasLength(3));
    });
  });

  group('parseBracketSegment', () {
    test('parses simple length', () {
      final result = parseBracketSegment('5', ',');
      expect(result.length, equals(5));
      expect(result.delimiter, equals(','));
      expect(result.hasLengthMarker, isFalse);
      expect(result.isKeyed, isFalse);
    });

    test('parses length marker', () {
      final result = parseBracketSegment('#5', ',');
      expect(result.length, equals(5));
      expect(result.hasLengthMarker, isTrue);
    });

    test('parses custom delimiter suffixes', () {
      expect(parseBracketSegment('5|', ',').delimiter, equals('|'));
      expect(parseBracketSegment('5\t', ',').delimiter, equals('\t'));
    });

    test('parses keyed segments', () {
      final result = parseBracketSegment('5:', ',');
      expect(result.isKeyed, isTrue);
      expect(result.length, equals(5));
    });

    test('parses keyed segments with custom delimiter', () {
      expect(parseBracketSegment('5:|', ',').delimiter, equals('|'));
      expect(parseBracketSegment('5:\t', ',').delimiter, equals('\t'));
    });

    test('rejects invalid lengths', () {
      expect(() => parseBracketSegment('', ','), throwsFormatException);
      expect(() => parseBracketSegment('05', ','), throwsFormatException);
      expect(() => parseBracketSegment('+5', ','), throwsFormatException);
      expect(() => parseBracketSegment('-5', ','), throwsFormatException);
      expect(() => parseBracketSegment('2 ', ','), throwsFormatException);
      expect(() => parseBracketSegment('abc', ','), throwsFormatException);
      expect(() => parseBracketSegment('5:?', ','), throwsFormatException);
    });
  });

  group('parseArrayHeaderLine', () {
    test('parses keyed primitive array header', () {
      final result = parseArrayHeaderLine('items[3]: 1,2,3', ',')!;
      expect(result.header.key, equals('items'));
      expect(result.header.length, equals(3));
      expect(result.header.fields, isNull);
      expect(result.inlineValues, equals('1,2,3'));
    });

    test('parses tabular header with fields', () {
      final result = parseArrayHeaderLine('users[2]{id,name}:', ',')!;
      expect(result.header.key, equals('users'));
      expect(result.header.length, equals(2));
      expect(result.header.fields, equals(['id', 'name']));
      expect(result.inlineValues, isNull);
    });

    test('parses keyless root header', () {
      final result = parseArrayHeaderLine('[2]{a,b}:', ',')!;
      expect(result.header.key, isNull);
      expect(result.header.fields, equals(['a', 'b']));
    });

    test('parses quoted key', () {
      final result = parseArrayHeaderLine('"my key"[2]: 1,2', ',')!;
      expect(result.header.key, equals('my key'));
    });

    test('parses keyed header', () {
      final result = parseArrayHeaderLine('m[2:]{v}:', ',')!;
      expect(result.header.isKeyed, isTrue);
      expect(result.header.key, equals('m'));
      expect(result.header.fields, equals(['v']));
    });

    test('parses custom delimiter and length marker', () {
      final result = parseArrayHeaderLine('t[#3|]{a|b}: 1|2|3', ',')!;
      expect(result.header.delimiter, equals('|'));
      expect(result.header.hasLengthMarker, isTrue);
      expect(result.header.length, equals(3));
    });

    test('parses nested fields', () {
      final result = parseArrayHeaderLine('o[1]{id,customer{name}}:', ',')!;
      expect(result.header.tabularFields![1].name, equals('customer'));
      expect(result.header.fields, equals(['id', 'name']));
    });

    test('returns null for non-header lines', () {
      expect(parseArrayHeaderLine('name: Alice', ','), isNull);
      expect(parseArrayHeaderLine('42', ','), isNull);
      expect(parseArrayHeaderLine('', ','), isNull);
    });

    test('returns null for whitespace before bracket', () {
      expect(parseArrayHeaderLine('items [2]:', ','), isNull);
    });

    test('returns null for whitespace after bracket', () {
      expect(parseArrayHeaderLine('items[2] : 1,2', ','), isNull);
    });

    test('returns null for non-whitespace between bracket and brace', () {
      expect(parseArrayHeaderLine('items[2]x{a,b}:', ','), isNull);
    });

    test('returns null for unquoted key containing colon before bracket', () {
      expect(parseArrayHeaderLine('a:b[2]:', ','), isNull);
    });

    test('allows whitespace between brace and colon', () {
      final result = parseArrayHeaderLine('tags[2]{a,b} :', ',')!;
      expect(result.header.key, equals('tags'));
      expect(result.header.length, equals(2));
      expect(result.header.fields, equals(['a', 'b']));
    });

    test('rejects whitespace between bracket and brace', () {
      expect(parseArrayHeaderLine('tags[2] {a,b}:', ','), isNull);
    });

    test('rejects non-whitespace between brace and colon', () {
      expect(parseArrayHeaderLine('tags[2]{a,b}x:', ','), isNull);
    });
  });

  group('parseDelimitedValues slow path (multi-char delimiter)', () {
    test('handles quoted values with delimiter inside', () {
      expect(
        parseDelimitedValues('"a--b" --c', '--'),
        equals(['"a--b"', 'c']),
      );
    });

    test('handles escaped content inside quotes', () {
      expect(
        parseDelimitedValues('"a\\"b" -- c', '--'),
        equals(['"a\\"b"', 'c']),
      );
    });

    test('handles quoted strings with escape sequences', () {
      expect(
        parseDelimitedValues('"x\\ny" --z', '--'),
        equals(['"x\\ny"', 'z']),
      );
    });
  });

  group('parseDelimitedRowsBatch quoted content', () {
    test('handles escaped values in fast path', () {
      expect(
        parseDelimitedRowsBatch([r'"a\nb",c'], ',', ['a', 'b']),
        equals([
          {'a': 'a\nb', 'b': 'c'},
        ]),
      );
    });

    test('handles quoted values with delimiter in fast path', () {
      expect(
        parseDelimitedRowsBatch(['"x,y",z'], ',', ['a', 'b']),
        equals([
          {'a': 'x,y', 'b': 'z'},
        ]),
      );
    });

    test('handles escaped values in slow path (multi-char delimiter)', () {
      expect(
        parseDelimitedRowsBatch([r'"a\nb" --c'], '--', ['a', 'b']),
        equals([
          {'a': 'a\nb', 'b': 'c'},
        ]),
      );
    });

    test('handles quoted delimiter in slow path', () {
      expect(
        parseDelimitedRowsBatch(['"a--b" --c'], '--', ['a', 'b']),
        equals([
          {'a': 'a--b', 'b': 'c'},
        ]),
      );
    });
  });

  group('parseDelimitedValues', () {
    test('splits simple values', () {
      expect(parseDelimitedValues('1,2,3', ','), equals(['1', '2', '3']));
    });

    test('trims values', () {
      expect(parseDelimitedValues(' 1 , 2 ', ','), equals(['1', '2']));
    });

    test('handles quoted values with delimiters inside', () {
      expect(
        parseDelimitedValues('"a,b",c', ','),
        equals(['"a,b"', 'c']),
      );
    });

    test('handles escaped quotes inside quoted values', () {
      expect(
        parseDelimitedValues('"a\\"b",c', ','),
        equals(['"a\\"b"', 'c']),
      );
    });

    test('handles multi-character delimiter', () {
      expect(
        parseDelimitedValues('a--b--c', '--'),
        equals(['a', 'b', 'c']),
      );
    });

    test('trailing delimiter yields empty trailing value', () {
      expect(parseDelimitedValues('1,2,', ','), equals(['1', '2', '']));
    });

    test('handles empty string', () {
      expect(parseDelimitedValues('', ','), isEmpty);
    });
  });

  group('mapRowValuesToPrimitives', () {
    test('maps string values to primitives', () {
      expect(
        mapRowValuesToPrimitives(['1', 'true', 'hello']),
        equals([1, true, 'hello']),
      );
    });
  });

  group('parsePrimitiveToken', () {
    test('parses numbers', () {
      expect(parsePrimitiveToken('42'), equals(42));
      expect(parsePrimitiveToken('-1.5'), equals(-1.5));
      expect(parsePrimitiveToken('0'), equals(0));
      expect(parsePrimitiveToken('1e3'), equals(1000));
    });

    test('parses booleans and null', () {
      expect(parsePrimitiveToken('true'), isTrue);
      expect(parsePrimitiveToken('false'), isFalse);
      expect(parsePrimitiveToken('null'), isNull);
    });

    test('parses quoted strings', () {
      expect(parsePrimitiveToken('"hello"'), equals('hello'));
      expect(parsePrimitiveToken('"a\\nb"'), equals('a\nb'));
    });

    test('returns empty string for empty token', () {
      expect(parsePrimitiveToken(''), equals(''));
      expect(parsePrimitiveToken('   '), equals(''));
    });

    test('returns unquoted strings as-is', () {
      expect(parsePrimitiveToken('hello'), equals('hello'));
      expect(parsePrimitiveToken('05'), equals('05'));
      expect(parsePrimitiveToken('truex'), equals('truex'));
    });

    test('trims surrounding spaces', () {
      expect(parsePrimitiveToken('  hello  '), equals('hello'));
    });
  });

  group('parseStringLiteral', () {
    test('parses simple quoted string', () {
      expect(parseStringLiteral('"hello"'), equals('hello'));
    });

    test('parses escaped string', () {
      expect(parseStringLiteral(r'"a\nb\tc"'), equals('a\nb\tc'));
      expect(parseStringLiteral(r'"say \"hi\""'), equals('say "hi"'));
      expect(parseStringLiteral(r'"back\\slash"'), equals(r'back\slash'));
    });

    test('returns unquoted token unchanged', () {
      expect(parseStringLiteral('hello'), equals('hello'));
    });

    test('throws on unterminated string', () {
      expect(() => parseStringLiteral('"abc'), throwsFormatException);
    });

    test('throws on content after closing quote', () {
      expect(() => parseStringLiteral('"abc" extra'), throwsFormatException);
    });
  });

  group('parseKeyToken', () {
    test('parses unquoted key', () {
      final result = parseKeyToken('name: Alice', 0);
      expect(result.key, equals('name'));
      expect(result.end, equals(5));
    });

    test('parses quoted key', () {
      final result = parseKeyToken('"my key": 1', 0);
      expect(result.key, equals('my key'));
    });

    test('parses quoted key with escapes', () {
      final result = parseKeyToken('"a\\tb": 1', 0);
      expect(result.key, equals('a\tb'));
    });

    test('throws on missing colon after unquoted key', () {
      expect(() => parseKeyToken('name', 0), throwsFormatException);
    });

    test('throws on unterminated quoted key', () {
      expect(() => parseKeyToken('"abc', 0), throwsFormatException);
    });

    test('throws on missing colon after quoted key', () {
      expect(() => parseKeyToken('"abc"', 0), throwsFormatException);
    });
  });

  group('array content detection', () {
    test('isArrayHeaderAfterHyphen', () {
      expect(isArrayHeaderAfterHyphen('[2]:'), isTrue);
      expect(isArrayHeaderAfterHyphen('[2]{a}:'), isTrue);
      expect(isArrayHeaderAfterHyphen('items[2]:'), isFalse);
      expect(isArrayHeaderAfterHyphen(''), isFalse);
      expect(isArrayHeaderAfterHyphen('hello'), isFalse);
    });

    test('isObjectFirstFieldAfterHyphen', () {
      expect(isObjectFirstFieldAfterHyphen('name: Alice'), isTrue);
      expect(isObjectFirstFieldAfterHyphen('hello'), isFalse);
    });
  });

  group('parseDelimitedIntoMap', () {
    test('writes values directly into map', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('1,Alice,true', ',', ['id', 'name', 'active'], map);
      expect(map, equals({'id': 1, 'name': 'Alice', 'active': true}));
    });

    test('stops when fields run out', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('1,2,3', ',', ['a'], map);
      expect(map, equals({'a': 1}));
    });

    test('handles empty last value', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('1,,3', ',', ['a', 'b', 'c'], map);
      expect(map, equals({'a': 1, 'b': '', 'c': 3}));
    });

    test('handles multi-character delimiter', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('1--x', '--', ['a', 'b'], map);
      expect(map, equals({'a': 1, 'b': 'x'}));
    });

    test('handles quoted values', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('"a,b",c', ',', ['x', 'y'], map);
      expect(map, equals({'x': 'a,b', 'y': 'c'}));
    });

    test('handles escaped quotes with multi-char delimiter', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap(r'"a\"b"--c', '--', ['x', 'y'], map);
      expect(map, equals({'x': 'a"b', 'y': 'c'}));
    });

    test('handles escaped quotes with single-char delimiter', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap(r'"a\"b",c', ',', ['x', 'y'], map);
      expect(map, equals({'x': 'a"b', 'y': 'c'}));
    });

    test('handles false and null tokens', () {
      final map = <String, dynamic>{};
      parseDelimitedIntoMap('false,null', ',', ['x', 'y'], map);
      expect(map, equals({'x': false, 'y': null}));
    });

    test('handles unclosed quoted values via parseStringLiteral', () {
      final map = <String, dynamic>{};
      expect(
        () => parseDelimitedIntoMap('"unclosed', ',', ['x'], map),
        throwsFormatException,
      );
    });

    test('handles escaped quotes in field entries', () {
      final fields = parseFieldEntries(r'"a\"b",c', ',');
      expect(fields.map((f) => f.name), equals(['a"b', 'c']));
    });

    test('handles escaped quotes in nested field entries', () {
      final fields = parseFieldEntries(r'"a\"b"{c}', ',');
      expect(fields.map((f) => f.name), equals(['a"b']));
      expect(fields[0].nestedFields, isNotNull);
      expect(fields[0].nestedFields![0].name, equals('c'));
    });

    test('handles escaped quotes inside nested field group braces', () {
      final fields = parseFieldEntries(r'"a"{"b\"c"}', ',');
      expect(fields.map((f) => f.name), equals(['a']));
      expect(fields[0].nestedFields, isNotNull);
      expect(fields[0].nestedFields![0].name, equals('b"c'));
    });
  });

  group('parseDelimitedRowsBatch', () {
    test('parses multiple rows in batch', () {
      final rows = parseDelimitedRowsBatch(
        ['1,Alice', '2,Bob'],
        ',',
        ['id', 'name'],
      );
      expect(rows, equals([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ]));
    });

    test('handles multi-character delimiter', () {
      final rows = parseDelimitedRowsBatch(
        ['1--x'],
        '--',
        ['a', 'b'],
      );
      expect(rows, equals([
        {'a': 1, 'b': 'x'},
      ]));
    });
  });
}
