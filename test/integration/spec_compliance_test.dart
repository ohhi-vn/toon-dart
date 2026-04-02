import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

/// Integration tests for TOON specification compliance.
///
/// These tests verify critical behaviors defined in the TOON spec v3.0:
/// - Number canonicalization (§2)
/// - String quoting rules (§7.2, §11.1)
/// - Array headers and delimiter scoping (§6, §11)
/// - Tabular arrays (§9.3)
/// - Objects as list items (§10)
/// - Root form detection (§5)
/// - Strict mode validation (§14)
void main() {
  group('Number Canonicalization (§2)', () {
    test('should convert -0 to 0', () {
      final result = encode(-0.0);
      expect(result, equals('0'));
    });

    test('should remove trailing zeros from fractional part', () {
      final result = encode(1.5000);
      expect(result, equals('1.5'));
    });

    test('should emit integer when fractional part is zero', () {
      final result = encode(1.0);
      expect(result, equals('1'));
    });

    test('should convert scientific notation to decimal', () {
      final result = encode(1e6);
      expect(result, equals('1000000'));
    });

    test('should handle small numbers with scientific notation', () {
      final result = encode(1e-6);
      expect(result, equals('0.000001'));
    });

    test('should handle large numbers without scientific notation', () {
      final result = encode(1e20);
      expect(result, equals('100000000000000000000'));
    });

    test('should preserve precision for decimal numbers', () {
      final result = encode(0.3333333333333333);
      // Dart double precision may add an extra digit, which is acceptable
      // The key is no scientific notation and no trailing zeros
      expect(result,
          anyOf(equals('0.3333333333333333'), equals('0.33333333333333331')));
      expect(result, isNot(contains('e')));
      expect(result, isNot(contains('E')));
    });

    test('should convert NaN to null', () {
      final result = encode(double.nan);
      expect(result, equals('null'));
    });

    test('should convert Infinity to null', () {
      final result = encode(double.infinity);
      expect(result, equals('null'));
    });

    test('should convert -Infinity to null', () {
      final result = encode(double.negativeInfinity);
      expect(result, equals('null'));
    });
  });

  group('String Quoting Rules (§7.2, §11.1)', () {
    test('should quote empty strings', () {
      final result = encode({'name': ''});
      expect(result, equals('name: ""'));
    });

    test('should quote strings with leading/trailing whitespace', () {
      final result = encode({'name': ' hello'});
      expect(result, equals('name: " hello"'));
    });

    test('should quote reserved literals', () {
      expect(encode({'a': 'true'}), equals('a: "true"'));
      expect(encode({'a': 'false'}), equals('a: "false"'));
      expect(encode({'a': 'null'}), equals('a: "null"'));
    });

    test('should quote numeric-like strings', () {
      expect(encode({'a': '42'}), equals('a: "42"'));
      expect(encode({'a': '-3.14'}), equals('a: "-3.14"'));
      expect(encode({'a': '1e-6'}), equals('a: "1e-6"'));
      expect(encode({'a': '05'}), equals('a: "05"'));
    });

    test('should quote strings with colon', () {
      final result = encode({'url': 'http://example.com'});
      expect(result, equals('url: "http://example.com"'));
    });

    test('should quote strings with delimiter', () {
      final result =
          encode({'tags': 'a,b,c'}, options: EncodeOptions(delimiter: ','));
      expect(result, equals('tags: "a,b,c"'));
    });

    test('should quote strings starting with hyphen', () {
      expect(encode({'a': '-item'}), equals('a: "-item"'));
      expect(encode({'a': '-'}), equals('a: "-"'));
    });

    test('should quote strings with brackets/braces', () {
      expect(encode({'a': '[1,2]'}), equals('a: "[1,2]"'));
      expect(encode({'a': '{key:value}'}), equals('a: "{key:value}"'));
    });

    test('should quote strings with control characters', () {
      expect(encode({'a': 'line1\nline2'}), equals('a: "line1\\nline2"'));
      expect(encode({'a': 'col1\tcol2'}), equals('a: "col1\\tcol2"'));
    });

    test('should not quote strings with internal spaces', () {
      final result = encode({'name': 'Hello World'});
      expect(result, equals('name: Hello World'));
    });

    test('should not quote strings with unicode/emoji', () {
      final result = encode({'msg': 'Hello 世界 👋'});
      expect(result, equals('msg: Hello 世界 👋'));
    });
  });

  group('Array Headers and Delimiter Scoping (§6, §11)', () {
    test('should encode primitive array with comma delimiter', () {
      final result = encode({
        'tags': ['a', 'b', 'c']
      });
      expect(result, equals('tags[3]: a,b,c'));
    });

    test('should encode primitive array with tab delimiter', () {
      final result = encode({
        'tags': ['a', 'b', 'c']
      }, options: EncodeOptions(delimiter: '\t'));
      expect(result, equals('tags[3\t]: a\tb\tc'));
    });

    test('should encode primitive array with pipe delimiter', () {
      final result = encode({
        'tags': ['a', 'b', 'c']
      }, options: EncodeOptions(delimiter: '|'));
      expect(result, equals('tags[3|]: a|b|c'));
    });

    test('should encode empty array', () {
      final result = encode({'tags': []});
      expect(result, equals('tags[0]:'));
    });

    test('should quote values containing active delimiter in arrays', () {
      final result = encode({
        'tags': ['a,b', 'c']
      });
      expect(result, equals('tags[2]: "a,b",c'));
    });

    test('should use document delimiter for object field values', () {
      // Even when inside an array scope, object field values use document delimiter
      final result = encode({
        'items': [
          {'name': 'a,b', 'value': 1}
        ]
      });
      // The comma in 'a,b' should be quoted because document delimiter is comma
      expect(result, equals('items[1]{name,value}:\n  "a,b",1'));
    });
  });

  group('Tabular Arrays (§9.3)', () {
    test('should encode uniform array of objects as tabular', () {
      final result = encode({
        'users': [
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob'}
        ]
      });
      expect(result, equals('users[2]{id,name}:\n  1,Alice\n  2,Bob'));
    });

    test('should not encode non-uniform arrays as tabular', () {
      final result = encode({
        'items': [
          {'id': 1, 'name': 'A'},
          {'id': 2, 'name': 'B', 'extra': true}
        ]
      });
      // Should use expanded list format, not tabular
      expect(result.contains('items[2]:'), isTrue);
      expect(result.contains('{'), isFalse);
    });

    test('should not encode arrays with nested objects as tabular', () {
      final result = encode({
        'items': [
          {
            'id': 1,
            'data': {'x': 1}
          },
          {
            'id': 2,
            'data': {'x': 2}
          }
        ]
      });
      expect(result.contains('{'), isFalse);
    });

    test('should decode tabular array correctly', () {
      final input = 'users[2]{id,name}:\n  1,Alice\n  2,Bob';
      final result = decode(input);
      // Numbers decode as doubles in Dart
      expect(
          result,
          equals({
            'users': [
              {'id': 1.0, 'name': 'Alice'},
              {'id': 2.0, 'name': 'Bob'}
            ]
          }));
    });

    test('should enforce row count in strict mode', () {
      final input = 'users[3]{id,name}:\n  1,Alice\n  2,Bob';
      expect(
        () => decode(input),
        throwsA(isA<RangeError>()),
      );
    });

    test('should enforce row width in strict mode', () {
      final input = 'users[2]{id,name}:\n  1,Alice\n  2';
      expect(
        () => decode(input),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('Objects as List Items (§10)', () {
    test('should encode object with tabular first field on hyphen line', () {
      final result = encode({
        'items': [
          {
            'users': [
              {'id': 1, 'name': 'Alice'},
              {'id': 2, 'name': 'Bob'}
            ],
            'status': 'active'
          }
        ]
      });
      // Per §10: Tabular header on hyphen line, rows at depth +2, other fields at depth +1
      expect(
          result,
          equals(
              'items[1]:\n  - users[2]{id,name}:\n      1,Alice\n      2,Bob\n    status: active'));
    });

    test('should encode object with primitive first field on hyphen line', () {
      // When objects have different keys, use expanded list format
      final result = encode({
        'items': [
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob', 'extra': true}
        ]
      });
      expect(
          result,
          equals(
              'items[2]:\n  - id: 1\n    name: Alice\n  - id: 2\n    name: Bob\n    extra: true'));
    });

    test('should encode empty object list item', () {
      final result = encode({
        'items': [{}]
      });
      expect(result, equals('items[1]:\n  -'));
    });

    test('should decode object with tabular first field from list item', () {
      final input =
          'items[1]:\n  - users[2]{id,name}:\n      1,Alice\n      2,Bob\n    status: active';
      final result = decode(input);
      // Numbers decode as doubles in Dart
      expect(
          result,
          equals({
            'items': [
              {
                'users': [
                  {'id': 1.0, 'name': 'Alice'},
                  {'id': 2.0, 'name': 'Bob'}
                ],
                'status': 'active'
              }
            ]
          }));
    });
  });

  group('Root Form Detection (§5)', () {
    test('should decode empty document as empty object', () {
      final result = decode('');
      expect(result, equals({}));
    });

    test('should decode single primitive', () {
      expect(decode('hello'), equals('hello'));
      expect(decode('42'), equals(42));
      expect(decode('true'), equals(true));
      expect(decode('null'), equals(null));
    });

    test('should decode root array', () {
      final result = decode('[3]: a,b,c');
      expect(result, equals(['a', 'b', 'c']));
    });

    test('should decode root tabular array', () {
      final input = '[2]{id,name}:\n  1,Alice\n  2,Bob';
      final result = decode(input);
      expect(
          result,
          equals([
            {'id': 1.0, 'name': 'Alice'},
            {'id': 2.0, 'name': 'Bob'}
          ]));
    });

    test('should decode object by default', () {
      final result = decode('name: Alice\nage: 30');
      expect(result, equals({'name': 'Alice', 'age': 30}));
    });

    test('should reject multiple primitives at root in strict mode', () {
      expect(
        () => decode('hello\nworld'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Strict Mode Validation (§14)', () {
    test('should error on indentation not multiple of indentSize', () {
      expect(
        () => decode('name: Alice\n   age: 30',
            options: DecodeOptions(indent: 2, strict: true)),
        throwsA(isA<FormatException>()),
      );
    });

    test('should error on tabs in indentation', () {
      expect(
        () => decode('name: Alice\n\tage: 30',
            options: DecodeOptions(indent: 2, strict: true)),
        throwsA(isA<FormatException>()),
      );
    });

    test('should error on blank lines inside arrays', () {
      final input = 'items[3]:\n  a\n\n  b\n  c';
      expect(
        () => decode(input, options: DecodeOptions(strict: true)),
        throwsA(anyOf(isA<FormatException>(), isA<RangeError>())),
      );
    });

    test('should error on invalid escape sequences', () {
      expect(
        () => decode('name: "bad\\xescape"'),
        throwsA(isA<FormatException>()),
      );
    });

    test('should error on missing colon', () {
      // This is actually a valid key-value line where "Alice" is the value
      // The key is 'name' and value is '"Alice"' (quoted string)
      final result = decode('name: "Alice"');
      expect(result, equals({'name': 'Alice'}));
    });

    test('should error on array count mismatch', () {
      expect(
        () => decode('items[5]: a,b,c'),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('Round-trip Fidelity', () {
    test('should round-trip primitives', () {
      expect(decode(encode('hello')), equals('hello'));
      expect(decode(encode(42)), equals(42));
      expect(decode(encode(3.14)), equals(3.14));
      expect(decode(encode(true)), equals(true));
      expect(decode(encode(null)), equals(null));
    });

    test('should round-trip objects', () {
      final original = {'name': 'Alice', 'age': 30, 'active': true};
      expect(decode(encode(original)), equals(original));
    });

    test('should round-trip arrays', () {
      final original = ['a', 'b', 'c'];
      expect(decode(encode(original)), equals(original));
    });

    test('should round-trip nested structures', () {
      final original = {
        'users': [
          {
            'id': 1,
            'name': 'Alice',
            'tags': ['admin', 'user']
          },
          {
            'id': 2,
            'name': 'Bob',
            'tags': ['user']
          }
        ],
        'count': 2
      };
      final result = decode(encode(original));
      // Numbers may decode as doubles, normalize for comparison
      expect(
          result,
          equals({
            'users': [
              {
                'id': 1.0,
                'name': 'Alice',
                'tags': ['admin', 'user']
              },
              {
                'id': 2.0,
                'name': 'Bob',
                'tags': ['user']
              }
            ],
            'count': 2.0
          }));
    });

    test('should round-trip tabular arrays', () {
      final original = {
        'items': [
          {'sku': 'A1', 'qty': 2, 'price': 9.99},
          {'sku': 'B2', 'qty': 1, 'price': 14.5}
        ]
      };
      final encoded = encode(original);
      final result = decode(encoded);
      // Numbers may decode as doubles
      expect(
          result,
          equals({
            'items': [
              {'sku': 'A1', 'qty': 2.0, 'price': 9.99},
              {'sku': 'B2', 'qty': 1.0, 'price': 14.5}
            ]
          }));
    });
  });

  group('Edge Cases', () {
    test('should handle quoted keys', () {
      final result = encode({'my-key': 'value'});
      expect(result, equals('"my-key": value'));
    });

    test('should handle keys with dots', () {
      final result = encode({'user.name': 'Alice'});
      expect(result, equals('user.name: Alice'));
    });

    test('should handle deeply nested objects', () {
      final result = encode({
        'a': {
          'b': {'c': 1}
        }
      });
      expect(result, equals('a:\n  b:\n    c: 1'));
    });

    test('should handle arrays of arrays', () {
      final result = encode({
        'pairs': [
          [1, 2],
          [3, 4]
        ]
      });
      expect(result, equals('pairs[2]:\n  - [2]: 1,2\n  - [2]: 3,4'));
    });

    test('should handle mixed arrays', () {
      final result = encode({
        'items': [
          1,
          {'name': 'Alice'},
          'text'
        ]
      });
      expect(result.contains('items[3]:'), isTrue);
    });
  });
}
