import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/decode/scanners.dart';
import '../lib/src/utilities/constants.dart';

void main() {
  group('toParsedLines', () {
    test('returns empty result for empty input', () {
      final result = toParsedLines('', 2, true);
      expect(result.lines, isEmpty);
      expect(result.blankLines, isEmpty);
    });

    test('returns empty result for whitespace-only input', () {
      final result = toParsedLines('   \n\t\n  ', 2, true);
      expect(result.lines, isEmpty);
      expect(result.blankLines, isEmpty);
    });

    test('parses simple key-value line', () {
      final result = toParsedLines('name: Alice', 2, true);
      expect(result.lines, hasLength(1));
      final line = result.lines.first;
      expect(line.content, equals('name: Alice'));
      expect(line.depth, equals(0));
      expect(line.lineNumber, equals(1));
      expect(line.indent, equals(0));
    });

    test('computes depth from indentation', () {
      final result = toParsedLines('a:\n    b: 1', 2, true);
      expect(result.lines, hasLength(2));
      expect(result.lines[0].depth, equals(0));
      expect(result.lines[1].depth, equals(2));
      expect(result.lines[1].content, equals('b: 1'));
    });

    test('tracks blank lines', () {
      final result = toParsedLines('a: 1\n\nb: 2', 2, true);
      expect(result.lines, hasLength(2));
      expect(result.blankLines, hasLength(1));
      expect(result.blankLines.first.lineNumber, equals(2));
    });

    test('skips comment lines', () {
      final result = toParsedLines('# comment\na: 1', 2, true);
      expect(result.lines, hasLength(1));
      expect(result.lines.first.content, equals('a: 1'));
    });

    test('comment must be first non-space char with no tabs', () {
      final result = toParsedLines('  # indented comment\na: 1', 2, true);
      expect(result.lines, hasLength(1));
    });

    test('hash inside value is not a comment', () {
      final result = toParsedLines('a: 1 # value', 2, true);
      expect(result.lines, hasLength(1));
      expect(result.lines.first.content, equals('a: 1 # value'));
    });

    test('throws on tabs in indentation in strict mode', () {
      expect(
        () => toParsedLines('\ta: 1', 2, true),
        throwsFormatException,
      );
    });

    test('throws on non-multiple indentation in strict mode', () {
      expect(
        () => toParsedLines('   a: 1', 2, true),
        throwsFormatException,
      );
    });

    test('allows non-multiple indentation in non-strict mode', () {
      final result = toParsedLines('   a: 1', 2, false);
      expect(result.lines, hasLength(1));
    });

    test('CRLF line endings keep \r in content (trimmed during parsing)', () {
      final result = toParsedLines('a: 1\r\nb: 2', 2, true);
      expect(result.lines, hasLength(2));
      expect(result.lines[0].content, equals('a: 1\r'));
      expect(result.lines[1].content, equals('b: 2'));
      expect(result.lines[1].content, isNot(contains('\r')));
    });

    test('no trailing empty line for trailing newline', () {
      final result = toParsedLines('a: 1\n', 2, true);
      expect(result.lines, hasLength(1));
    });

    test('raw line retains original indentation', () {
      final result = toParsedLines('  a: 1', 2, true);
      expect(result.lines.first.raw, equals('  a: 1'));
    });
  });

  group('LineCursor', () {
    test('peek/next/advance/current/atEnd behavior', () {
      final result = toParsedLines('a: 1\nb: 2', 2, true);
      final cursor = LineCursor(result.lines, result.blankLines);

      expect(cursor.length, equals(2));
      expect(cursor.atEnd(), isFalse);
      expect(cursor.peek()!.content, equals('a: 1'));
      expect(cursor.current(), isNull);

      final first = cursor.next();
      expect(first!.content, equals('a: 1'));
      expect(cursor.current()!.content, equals('a: 1'));

      cursor.advance();
      expect(cursor.atEnd(), isTrue);
      expect(cursor.peek(), isNull);
      expect(cursor.next(), isNull);
    });

    test('peekAtDepth and hasMoreAtDepth', () {
      final result = toParsedLines('a:\n  b: 1\nc: 2', 2, true);
      final cursor = LineCursor(result.lines);

      expect(cursor.peekAtDepth(0)!.content, equals('a:'));
      expect(cursor.hasMoreAtDepth(0), isTrue);
      expect(cursor.peekAtDepth(1), isNull);

      cursor.advance();
      expect(cursor.peekAtDepth(1)!.content, equals('b: 1'));
      expect(cursor.hasMoreAtDepth(0), isFalse);

      cursor.advance();
      expect(cursor.peekAtDepth(0)!.content, equals('c: 2'));
    });

    test('getBlankLines returns provided list', () {
      final result = toParsedLines('a: 1\n\nb: 2', 2, true);
      final cursor = LineCursor(result.lines, result.blankLines);
      expect(cursor.getBlankLines(), hasLength(1));
    });

    test('LineCursor defaults blank lines to empty', () {
      final cursor = LineCursor([]);
      expect(cursor.getBlankLines(), isEmpty);
    });
  });

  group('classifyLine', () {
    test('classifies blank', () {
      expect(classifyLine('', ','), equals(LineType.blank));
    });

    test('classifies list items', () {
      expect(classifyLine('-', ','), equals(LineType.listItem));
      expect(classifyLine('- value', ','), equals(LineType.listItem));
      expect(classifyLine('-key: x', ','), isNot(LineType.listItem));
    });

    test('classifies array headers', () {
      expect(classifyLine('items[2]:', ','), equals(LineType.arrayHeader));
      expect(classifyLine('[2]{a,b}:', ','), equals(LineType.arrayHeader));
      expect(classifyLine('items[2]{a}:', ','), equals(LineType.arrayHeader));
    });

    test('classifies key-value lines', () {
      expect(classifyLine('name: Alice', ','), equals(LineType.keyValue));
      expect(classifyLine('"my key": 1', ','), equals(LineType.keyValue));
    });

    test('classifies data rows', () {
      expect(classifyLine('1,2,3', ','), equals(LineType.dataRow));
      expect(classifyLine('a,b:c', ','), equals(LineType.dataRow));
    });

    test('classifies primitives', () {
      expect(classifyLine('42', ','), equals(LineType.primitive));
      expect(classifyLine('-5', ','), equals(LineType.primitive));
    });

    test('quoted values do not affect classification', () {
      expect(classifyLine('"a,b": 1', ','), equals(LineType.keyValue));
      expect(classifyLine('"a]b": 1', ','), equals(LineType.keyValue));
    });

    test('negative number is not a list item', () {
      expect(classifyLine('-5.5', ','), equals(LineType.primitive));
    });

    test('array header with quoted brackets', () {
      expect(classifyLine('"key[x]": 1', ','), equals(LineType.keyValue));
    });

    test('handles escaped quotes in quoted keys', () {
      expect(classifyLine(r'"a\"b": 1', ','), equals(LineType.keyValue));
    });

    test('colon before delimiter in row', () {
      expect(classifyLine('x:1,2', ','), equals(LineType.keyValue));
    });
  });

  group('Line classification helpers', () {
    test('countLeadingSpaces', () {
      expect(countLeadingSpaces(''), equals(0));
      expect(countLeadingSpaces('abc'), equals(0));
      expect(countLeadingSpaces('   abc'), equals(3));
    });

    test('countLeadingTabs', () {
      expect(countLeadingTabs('abc', 0), equals(0));
      expect(countLeadingTabs('\t\tabc', 0), equals(2));
      expect(countLeadingTabs('  \t\tabc', 2), equals(2));
    });

    test('extractContent', () {
      expect(extractContent('  abc'), equals('abc'));
      expect(extractContent('\tabc'), equals('abc'));
      expect(extractContent('abc'), equals('abc'));
      expect(extractContent('   '), equals(''));
      expect(extractContent(''), equals(''));
    });

    test('computeDepthFromIndent', () {
      expect(computeDepthFromIndent(0, 2), equals(0));
      expect(computeDepthFromIndent(2, 2), equals(1));
      expect(computeDepthFromIndent(5, 2), equals(2));
    });

    test('toParsedLinesClassified', () {
      final result = toParsedLinesClassified('a: 1\nitems[2]:\n  - x', 2, true);
      expect(result.lines, hasLength(3));
      expect(result.lineTypes,
          equals([LineType.keyValue, LineType.arrayHeader, LineType.listItem]));
      expect(result.blankLines, isEmpty);
    });
  });
}
