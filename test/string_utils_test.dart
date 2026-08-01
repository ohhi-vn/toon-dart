import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/utilities/literal-utils.dart';
import '../lib/src/utilities/string-utils.dart';

void main() {
  group('isNumericLiteral', () {
    test('accepts valid numbers', () {
      expect(isNumericLiteral('42'), isTrue);
      expect(isNumericLiteral('-1.5'), isTrue);
      expect(isNumericLiteral('1e5'), isTrue);
      expect(isNumericLiteral('0.5'), isTrue);
    });

    test('rejects empty and non-numbers', () {
      expect(isNumericLiteral(''), isFalse);
      expect(isNumericLiteral('abc'), isFalse);
    });

    test('rejects forbidden leading zeros', () {
      expect(isNumericLiteral('05'), isFalse);
      expect(isNumericLiteral('007'), isFalse);
      expect(isNumericLiteral('-05'), isFalse);
    });

    test('accepts valid zero forms', () {
      expect(isNumericLiteral('0'), isTrue);
      expect(isNumericLiteral('0.5'), isTrue);
      expect(isNumericLiteral('0e1'), isTrue);
    });
  });

  group('trimSpaceOnly', () {
    test('trims regular spaces', () {
      expect(trimSpaceOnly('  hello  '), equals('hello'));
    });

    test('trims trailing carriage return', () {
      expect(trimSpaceOnly('hello\r'), equals('hello'));
      expect(trimSpaceOnly('hello  \r'), equals('hello'));
    });

    test('preserves NBSP', () {
      const nbsp = '\u00A0';
      expect(trimSpaceOnly('$nbsp hello$nbsp'), equals('$nbsp hello$nbsp'));
      expect(trimSpaceOnly(' $nbsp hello$nbsp '), equals('$nbsp hello$nbsp'));
    });

    test('returns original string when nothing to trim', () {
      final value = 'hello';
      expect(identical(trimSpaceOnly(value), value), isTrue);
    });

    test('trims tabs? no — tabs are preserved', () {
      expect(trimSpaceOnly('\thello\t'), equals('\thello\t'));
    });

    test('handles empty string', () {
      expect(trimSpaceOnly(''), equals(''));
    });
  });

  group('escapeString', () {
    test('returns original when no escaping needed', () {
      final value = 'hello world';
      expect(identical(escapeString(value), value), isTrue);
    });

    test('escapes backslash', () {
      expect(escapeString(r'a\b'), equals(r'a\\b'));
    });

    test('escapes double quote', () {
      expect(escapeString('a"b'), equals(r'a\"b'));
    });

    test('escapes newline, carriage return, tab', () {
      expect(escapeString('a\nb'), equals(r'a\nb'));
      expect(escapeString('a\rb'), equals(r'a\rb'));
      expect(escapeString('a\tb'), equals(r'a\tb'));
    });

    test('escapes control characters with \\uXXXX', () {
      expect(escapeString('a\u0001b'), equals(r'a\u0001b'));
      expect(escapeString('a\u0002b'), equals(r'a\u0002b'));
    });

    test('keeps other unicode characters', () {
      expect(escapeString('héllo'), equals('héllo'));
    });
  });

  group('unescapeString', () {
    test('returns original when no backslashes', () {
      final value = 'hello';
      expect(identical(unescapeString(value), value), isTrue);
    });

    test('handles basic escape sequences', () {
      expect(unescapeString(r'a\nb'), equals('a\nb'));
      expect(unescapeString(r'a\tb'), equals('a\tb'));
      expect(unescapeString(r'a\rb'), equals('a\rb'));
      expect(unescapeString(r'a\\b'), equals(r'a\b'));
      expect(unescapeString(r'a\"b'), equals('a"b'));
    });

    test('handles unicode escapes', () {
      expect(unescapeString(r'a\u0041b'), equals('aAb'));
    });

    test('throws on backslash at end', () {
      expect(() => unescapeString(r'a\'), throwsFormatException);
    });

    test('throws on invalid escape sequence', () {
      expect(() => unescapeString(r'a\zb'), throwsFormatException);
    });

    test('throws on invalid unicode escape', () {
      expect(() => unescapeString(r'a\uXYZb'), throwsFormatException);
      expect(() => unescapeString(r'a\u12'), throwsFormatException);
    });

    test('throws on surrogate code point', () {
      expect(() => unescapeString(r'a\uD800b'), throwsFormatException);
    });
  });

  group('findClosingQuote', () {
    test('finds closing quote', () {
      expect(findClosingQuote('"abc"', 0), equals(4));
    });

    test('skips escaped quotes', () {
      expect(findClosingQuote(r'a\"b"', 0), equals(4));
    });

    test('returns -1 when unterminated', () {
      expect(findClosingQuote('"abc', 0), equals(-1));
    });
  });

  group('findUnquotedChar', () {
    test('finds character outside quotes', () {
      expect(findUnquotedChar('a,b', ','), equals(1));
      expect(findUnquotedChar('"a,b",c', ','), equals(5));
      expect(findUnquotedChar('hello', ','), equals(-1));
    });

    test('respects start offset', () {
      expect(findUnquotedChar('a,b,c', ',', 2), equals(3));
    });

    test('skips escaped characters inside quotes', () {
      expect(findUnquotedChar(r'"a\"b",c', ','), equals(6));
    });
  });

  group('isValidUnquotedKey', () {
    test('accepts valid keys', () {
      expect(isValidUnquotedKey('name'), isTrue);
      expect(isValidUnquotedKey('_private'), isTrue);
      expect(isValidUnquotedKey('user.name'), isTrue);
      expect(isValidUnquotedKey('a1_b2.c3'), isTrue);
      expect(isValidUnquotedKey('A'), isTrue);
    });

    test('rejects invalid keys', () {
      expect(isValidUnquotedKey(''), isFalse);
      expect(isValidUnquotedKey('1abc'), isFalse);
      expect(isValidUnquotedKey('.start'), isFalse);
      expect(isValidUnquotedKey('has space'), isFalse);
      expect(isValidUnquotedKey('has-dash'), isFalse);
      expect(isValidUnquotedKey('has:colon'), isFalse);
      expect(isValidUnquotedKey('é'), isFalse);
    });
  });

  group('isSafeUnquoted', () {
    test('rejects empty string', () {
      expect(isSafeUnquoted(''), isFalse);
    });

    test('rejects leading/trailing whitespace', () {
      expect(isSafeUnquoted(' leading'), isFalse);
      expect(isSafeUnquoted('trailing '), isFalse);
      expect(isSafeUnquoted(' middle '), isFalse);
    });

    test('rejects literal-like strings', () {
      expect(isSafeUnquoted('true'), isFalse);
      expect(isSafeUnquoted('false'), isFalse);
      expect(isSafeUnquoted('null'), isFalse);
      expect(isSafeUnquoted('42'), isFalse);
      expect(isSafeUnquoted('-1.5'), isFalse);
      expect(isSafeUnquoted('1e3'), isFalse);
    });

    test('rejects structural characters', () {
      expect(isSafeUnquoted('a:b'), isFalse);
      expect(isSafeUnquoted('a"b'), isFalse);
      expect(isSafeUnquoted('a\\b'), isFalse);
      expect(isSafeUnquoted('a[b'), isFalse);
      expect(isSafeUnquoted('a]b'), isFalse);
      expect(isSafeUnquoted('a{b'), isFalse);
      expect(isSafeUnquoted('a}b'), isFalse);
      expect(isSafeUnquoted('a\nb'), isFalse);
      expect(isSafeUnquoted('a\rb'), isFalse);
      expect(isSafeUnquoted('a\tb'), isFalse);
      expect(isSafeUnquoted('a\u0001b'), isFalse);
    });

    test('rejects delimiter', () {
      expect(isSafeUnquoted('a,b'), isFalse);
      expect(isSafeUnquoted('a,b', ','), isFalse);
      expect(isSafeUnquoted('a|b', '|'), isFalse);
      expect(isSafeUnquoted('a,b', '|'), isTrue);
    });

    test('rejects leading hyphen and hash', () {
      expect(isSafeUnquoted('-item'), isFalse);
      expect(isSafeUnquoted('#comment'), isFalse);
    });

    test('accepts plain strings', () {
      expect(isSafeUnquoted('hello'), isTrue);
      expect(isSafeUnquoted('hello world'), isTrue);
      expect(isSafeUnquoted('héllo wörld'), isTrue);
    });
  });

  group('isNumericLike', () {
    test('accepts valid numbers', () {
      expect(isNumericLike('42'), isTrue);
      expect(isNumericLike('-42'), isTrue);
      expect(isNumericLike('+42'), isTrue);
      expect(isNumericLike('3.14'), isTrue);
      expect(isNumericLike('1e5'), isTrue);
      expect(isNumericLike('1E-5'), isTrue);
      expect(isNumericLike('1e+5'), isTrue);
      expect(isNumericLike('0.5'), isTrue);
      expect(isNumericLike('05'), isTrue);
    });

    test('rejects invalid numbers', () {
      expect(isNumericLike(''), isFalse);
      expect(isNumericLike('-'), isFalse);
      expect(isNumericLike('+'), isFalse);
      expect(isNumericLike('abc'), isFalse);
      expect(isNumericLike('3.'), isFalse);
      expect(isNumericLike('3e'), isFalse);
      expect(isNumericLike('1.2.3'), isFalse);
      expect(isNumericLike('.5'), isFalse);
    });
  });

  group('hasForbiddenLeadingZeros', () {
    test('detects forbidden leading zeros', () {
      expect(hasForbiddenLeadingZeros('05'), isTrue);
      expect(hasForbiddenLeadingZeros('007'), isTrue);
      expect(hasForbiddenLeadingZeros('-05'), isTrue);
      expect(hasForbiddenLeadingZeros('+05'), isTrue);
    });

    test('allows valid zero forms', () {
      expect(hasForbiddenLeadingZeros('0'), isFalse);
      expect(hasForbiddenLeadingZeros('0.5'), isFalse);
      expect(hasForbiddenLeadingZeros('0e1'), isFalse);
      expect(hasForbiddenLeadingZeros('42'), isFalse);
      expect(hasForbiddenLeadingZeros(''), isFalse);
    });
  });

  group('buildDelimitedString', () {
    test('builds delimited string', () {
      expect(buildDelimitedString(['a', 'b', 'c'], ','), equals('a,b,c'));
    });

    test('handles empty and single value', () {
      expect(buildDelimitedString([], ','), equals(''));
      expect(buildDelimitedString(['a'], ','), equals('a'));
    });

    test('uses custom delimiter', () {
      expect(buildDelimitedString(['a', 'b'], '|'), equals('a|b'));
    });
  });

  group('buildKeyValueLine', () {
    test('builds key-value line', () {
      expect(buildKeyValueLine('name', 'Alice'), equals('name: Alice'));
    });
  });

  group('estimateUtf8Length', () {
    test('estimates ASCII as 1 byte per char', () {
      expect(estimateUtf8Length('hello'), equals(5));
    });

    test('estimates Latin-1 as 2 bytes', () {
      expect(estimateUtf8Length('héllo'), equals(6));
    });

    test('estimates supplementary chars as 4 bytes', () {
      // Surrogate pair
      expect(estimateUtf8Length('\u{1F600}'), equals(4));
    });

    test('estimates BMP chars as 3 bytes', () {
      // Chinese character U+4E2D (not a surrogate)
      expect(estimateUtf8Length('中'), equals(3));
    });

    test('handles empty string', () {
      expect(estimateUtf8Length(''), equals(0));
    });
  });
}
