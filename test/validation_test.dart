import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/decode/scanners.dart';
import '../lib/src/decode/validation.dart';
import '../lib/src/types.dart';

void main() {
  const strict = ResolvedDecodeOptions(indent: 2, strict: true);
  const lenient = ResolvedDecodeOptions(indent: 2, strict: false);

  group('assertExpectedCount', () {
    test('throws RangeError in strict mode on mismatch', () {
      expect(
        () => assertExpectedCount(2, 3, 'items', strict),
        throwsRangeError,
      );
    });

    test('passes in strict mode on match', () {
      assertExpectedCount(3, 3, 'items', strict);
    });

    test('does not throw in lenient mode', () {
      assertExpectedCount(2, 3, 'items', lenient);
    });
  });

  group('validateNoExtraListItems', () {
    test('passes at end of cursor', () {
      final cursor = LineCursor(toParsedLines('a: 1', 2, true).lines);
      validateNoExtraListItems(cursor, 1, 2);
    });

    test('passes when no extra list items', () {
      final cursor = LineCursor(toParsedLines('x: 1', 2, true).lines);
      validateNoExtraListItems(cursor, 0, 2);
    });

    test('throws when extra list items found', () {
      final cursor = LineCursor(toParsedLines('- item', 2, true).lines);
      expect(
        () => validateNoExtraListItems(cursor, 0, 2),
        throwsRangeError,
      );
    });
  });

  group('validateNoExtraTabularRows', () {
    const header = ArrayHeaderInfo(
      key: 'rows',
      length: 1,
      delimiter: ',',
      hasLengthMarker: false,
      fields: null,
    );

    test('passes at end of cursor', () {
      final cursor = LineCursor(toParsedLines('a: 1', 2, true).lines);
      validateNoExtraTabularRows(cursor, 1, header);
    });

    test('passes when next line is not a data row', () {
      final cursor = LineCursor(toParsedLines('other: 1', 2, true).lines);
      validateNoExtraTabularRows(cursor, 0, header);
    });

    test('throws when extra data row found', () {
      final cursor = LineCursor(toParsedLines('1,2', 2, true).lines);
      expect(
        () => validateNoExtraTabularRows(cursor, 0, header),
        throwsRangeError,
      );
    });
  });

  group('validateNoBlankLinesInRange', () {
    test('passes in lenient mode', () {
      validateNoBlankLinesInRange(
        1,
        5,
        const [BlankLineInfo(lineNumber: 3, depth: 0, indent: 0)],
        false,
        'list array',
      );
    });

    test('passes in strict mode without blank lines', () {
      validateNoBlankLinesInRange(1, 5, const [], true, 'list array');
    });

    test('ignores blank lines outside range', () {
      validateNoBlankLinesInRange(
        3,
        5,
        const [BlankLineInfo(lineNumber: 2, depth: 0, indent: 0)],
        true,
        'list array',
      );
    });

    test('throws in strict mode with blank line in range', () {
      expect(
        () => validateNoBlankLinesInRange(
          1,
          5,
          const [BlankLineInfo(lineNumber: 3, depth: 0, indent: 0)],
          true,
          'list array',
        ),
        throwsFormatException,
      );
    });

    test('throws in strict mode with blank line at boundary edges excluded', () {
      validateNoBlankLinesInRange(
        1,
        5,
        const [
          BlankLineInfo(lineNumber: 1, depth: 0, indent: 0),
          BlankLineInfo(lineNumber: 5, depth: 0, indent: 0),
        ],
        true,
        'list array',
      );
    });
  });

  group('isDataRow', () {
    test('no colon is a data row', () {
      expect(isDataRow('1,2,3', ','), isTrue);
      expect(isDataRow('a|b', '|'), isTrue);
    });

    test('delimiter before colon is a data row', () {
      expect(isDataRow('1,2:3', ','), isTrue);
    });

    test('colon before delimiter is key-value', () {
      expect(isDataRow('a: 1,2', ','), isFalse);
    });

    test('colon without delimiter is key-value', () {
      expect(isDataRow('a: 1', ','), isFalse);
    });
  });
}
