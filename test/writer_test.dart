import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/encode/writer.dart';

void main() {
  group('LineWriter', () {
    test('throws for non-positive indent', () {
      expect(() => LineWriter(0), throwsArgumentError);
      expect(() => LineWriter(-1), throwsArgumentError);
    });

    test('push writes indented lines with newline separation', () {
      final writer = LineWriter(2);
      writer.push(0, 'a: 1');
      writer.push(1, 'b: 2');
      expect(writer.toString(), equals('a: 1\n  b: 2'));
    });

    test('push with deeper indentation', () {
      final writer = LineWriter(4);
      writer.push(0, 'a:');
      writer.push(1, 'b: 1');
      expect(writer.toString(), equals('a:\n    b: 1'));
    });

    test('caches indentation strings per depth', () {
      final writer = LineWriter(2);
      writer.push(3, 'x');
      writer.push(3, 'y');
      expect(writer.toString(), equals('      x\n      y'));
    });

    test('pushListItem writes - prefix', () {
      final writer = LineWriter(2);
      writer.pushListItem(1, 'value');
      expect(writer.toString(), equals('  - value'));
    });

    test('pushNewline only writes when content exists', () {
      final writer = LineWriter(2);
      writer.pushNewline();
      expect(writer.toString(), equals(''));
      writer.push(0, 'a: 1');
      writer.pushNewline();
      expect(writer.toString(), equals('a: 1\n'));
    });

    test('pushTabularRows writes rows at same depth', () {
      final writer = LineWriter(2);
      writer.push(0, 'items[2]{a}:');
      writer.pushTabularRows(1, ['1', '2']);
      expect(writer.toString(), equals('items[2]{a}:\n  1\n  2'));
    });

    test('pushTabularRows with empty rows is a no-op', () {
      final writer = LineWriter(2);
      writer.pushTabularRows(1, []);
      expect(writer.toString(), equals(''));
    });

    test('pushTabularRowsFromBuffer', () {
      final writer = LineWriter(2);
      writer.pushTabularRowsFromBuffer(1, [StringBuffer('1'), StringBuffer('2')]);
      expect(writer.toString(), equals('  1\n  2'));
    });

    test('pushTabularRowsFromBuffer with existing content writes newline', () {
      final writer = LineWriter(2);
      writer.push(0, 'existing');
      writer.pushTabularRowsFromBuffer(1, [StringBuffer('1'), StringBuffer('2')]);
      expect(writer.toString(), equals('existing\n  1\n  2'));
    });

    test('pushTabularRowsFromBuffer with empty list is a no-op', () {
      final writer = LineWriter(2);
      writer.pushTabularRowsFromBuffer(1, []);
      expect(writer.toString(), equals(''));
    });

    test('pushKeyValue writes key: value', () {
      final writer = LineWriter(2);
      writer.pushKeyValue(0, 'name', 'Alice');
      expect(writer.toString(), equals('name: Alice'));
    });

    test('pushKeyValue omits space for empty value', () {
      final writer = LineWriter(2);
      writer.pushKeyValue(0, 'obj', '');
      expect(writer.toString(), equals('obj:'));
    });

    test('pushArrayHeader with key, length, and fields', () {
      final writer = LineWriter(2);
      writer.pushArrayHeader(0,
          key: 'users', length: 2, fields: ['id', 'name']);
      expect(writer.toString(), equals('users[2]{id,name}:'));
    });

    test('pushArrayHeader keyless', () {
      final writer = LineWriter(2);
      writer.pushArrayHeader(0, length: 2, fields: ['a']);
      expect(writer.toString(), equals('[2]{a}:'));
    });

    test('pushArrayHeader with delimiter and length marker', () {
      final writer = LineWriter(2);
      writer.pushArrayHeader(0,
          key: 't', length: 3, delimiter: '|', lengthMarker: '#');
      expect(writer.toString(), equals('t[#3|]:'));
    });

    test('pushArrayHeader with inline values', () {
      final writer = LineWriter(2);
      writer.pushArrayHeader(0, key: 'n', length: 3, inlineValues: '1,2,3');
      expect(writer.toString(), equals('n[3]: 1,2,3'));
    });

    test('pushArrayHeader with empty inline values omits them', () {
      final writer = LineWriter(2);
      writer.pushArrayHeader(0, key: 'n', length: 0, inlineValues: '');
      expect(writer.toString(), equals('n[0]:'));
    });

    test('length and hasContent track buffer state', () {
      final writer = LineWriter(2);
      expect(writer.length, equals(0));
      expect(writer.hasContent, isFalse);
      writer.push(0, 'a: 1');
      expect(writer.length, equals(4));
      expect(writer.hasContent, isTrue);
    });

    test('estimateCapacity produces positive estimate', () {
      expect(
        LineWriter.estimateCapacity(fieldCount: 3, tabularRows: 5, tabularFields: 2),
        greaterThan(0),
      );
      expect(LineWriter.estimateCapacity(), greaterThan(0));
    });

    test('estimateFromMap estimates nested structures', () {
      final map = {
        'name': 'Alice',
        'age': 30,
        'active': true,
        'tags': ['a', 'b'],
        'address': {
          'city': 'NYC',
        },
        'friends': [
          {'id': 1},
          {'id': 2},
        ],
      };
      expect(LineWriter.estimateFromMap(map), greaterThan(0));
    });
  });
}
