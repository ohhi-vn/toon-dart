import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

import '../lib/src/encode/encoders.dart';
import '../lib/src/encode/writer.dart';
import '../lib/src/types.dart';

void main() {
  const opts = ResolvedEncodeOptions(indent: 2, delimiter: ',');

  group('encodeValue', () {
    test('encodes primitive directly', () {
      expect(encodeValue('hello', opts), equals('hello'));
      expect(encodeValue(42, opts), equals('42'));
      expect(encodeValue(true, opts), equals('true'));
      expect(encodeValue(null, opts), equals('null'));
    });

    test('encodes empty object', () {
      final result = encodeValue(<String, dynamic>{}, opts);
      expect(result, isEmpty);
    });

    test('encodes simple object', () {
      final result = encodeValue({'name': 'Alice', 'age': 30}, opts);
      expect(result, contains('name: Alice'));
      expect(result, contains('age: 30'));
    });

    test('encodes nested object', () {
      final result = encodeValue({'user': {'name': 'Alice'}}, opts);
      expect(result, contains('user:'));
      expect(result, contains('name: Alice'));
    });

    test('encodes empty array', () {
      final result = encodeValue(<dynamic>[], opts);
      expect(result, equals('[]'));
    });

    test('encodes primitive array', () {
      final result = encodeValue([1, 2, 3], opts);
      expect(result, contains('['));
      expect(result, contains('1'));
    });

    test('encodes array of objects (tabular)', () {
      final result = encodeValue([
        {'id': 1, 'name': 'Alice'},
        {'id': 2, 'name': 'Bob'},
      ], opts);
      expect(result, contains('id'));
      expect(result, contains('name'));
    });

    test('encodes array with mixed types', () {
      final result = encodeValue([1, 'hello', {'a': 1}], opts);
      expect(result, isNotEmpty);
    });
  });

  group('encodeObject', () {
    test('encodes object with multiple fields', () {
      final writer = LineWriter(2);
      encodeObject({'a': 1, 'b': 2}, writer, 0, opts);
      expect(writer.toString(), contains('a: 1'));
      expect(writer.toString(), contains('b: 2'));
    });

    test('encodes empty object', () {
      final writer = LineWriter(2);
      encodeObject(<String, dynamic>{}, writer, 0, opts);
      expect(writer.toString(), isEmpty);
    });

    test('encodes object with nested object', () {
      final writer = LineWriter(2);
      encodeObject({'outer': {'inner': 'value'}}, writer, 0, opts);
      expect(writer.toString(), contains('outer:'));
      expect(writer.toString(), contains('inner: value'));
    });
  });

  group('encodeKeyValuePair', () {
    test('encodes primitive value', () {
      final writer = LineWriter(2);
      encodeKeyValuePair('key', 42, writer, 0, opts);
      expect(writer.toString(), equals('key: 42'));
    });

    test('encodes array value', () {
      final writer = LineWriter(2);
      encodeKeyValuePair('key', [1, 2, 3], writer, 0, opts);
      expect(writer.toString(), contains('key['));
    });

    test('encodes nested object value', () {
      final writer = LineWriter(2);
      encodeKeyValuePair('key', {'nested': 'value'}, writer, 0, opts);
      expect(writer.toString(), contains('key:'));
    });

    test('encodes empty object value', () {
      final writer = LineWriter(2);
      encodeKeyValuePair('key', <String, dynamic>{}, writer, 0, opts);
      expect(writer.toString(), equals('key:'));
    });
  });

  group('encodeArray', () {
    test('encodes empty array with key', () {
      final writer = LineWriter(2);
      encodeArray('key', [], writer, 0, opts);
      expect(writer.toString(), equals('key: []'));
    });

    test('encodes empty array without key (root)', () {
      final writer = LineWriter(2);
      encodeArray(null, [], writer, 0, opts);
      expect(writer.toString(), equals('[]'));
    });

    test('encodes primitive array inline', () {
      final writer = LineWriter(2);
      encodeArray('nums', [1, 2, 3], writer, 0, opts);
      expect(writer.toString(), contains('nums'));
      expect(writer.toString(), contains('1'));
    });

    test('encodes array of arrays', () {
      final writer = LineWriter(2);
      encodeArray('arr', [[1, 2], [3, 4]], writer, 0, opts);
      expect(writer.toString(), contains('arr'));
    });

    test('encodes array of objects as tabular', () {
      final writer = LineWriter(2);
      encodeArray('users', [
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 'B'},
      ], writer, 0, opts);
      expect(writer.toString(), contains('users'));
      expect(writer.toString(), contains('id'));
      expect(writer.toString(), contains('name'));
    });

    test('encodes mixed array', () {
      final writer = LineWriter(2);
      encodeArray('mixed', [1, 'hello', [1, 2]], writer, 0, opts);
      expect(writer.toString(), isNotEmpty);
    });
  });

  group('encodeArrayOfArraysAsListItems', () {
    test('encodes array of primitive arrays as list items', () {
      final writer = LineWriter(2);
      encodeArrayOfArraysAsListItems('arr', [[1, 2], [3, 4]], writer, 0, opts);
      expect(writer.toString(), contains('arr'));
      expect(writer.toString(), contains('1,2'));
      expect(writer.toString(), contains('3,4'));
    });
  });

  group('encodeArrayOfObjectsAsTabular', () {
    test('encodes array of objects with tabular format', () {
      final writer = LineWriter(2);
      final fields = [
        TabularField('id', null),
        TabularField('name', null),
      ];
      encodeArrayOfObjectsAsTabular(
        'users',
        [
          {'id': 1, 'name': 'A'},
          {'id': 2, 'name': 'B'},
        ],
        fields,
        writer,
        0,
        opts,
      );
      expect(writer.toString(), contains('users'));
      expect(writer.toString(), contains('id'));
      expect(writer.toString(), contains('name'));
    });
  });

  group('extractTabularHeader', () {
    test('extracts header from uniform array of objects', () {
      final header = extractTabularHeader([
        {'a': 1, 'b': 2},
        {'a': 3, 'b': 4},
      ]);
      expect(header, isNotNull);
      expect(header!.length, equals(2));
    });

    test('returns null for empty array', () {
      expect(extractTabularHeader([]), isNull);
    });

    test('returns null for non-uniform objects', () {
      expect(extractTabularHeader([
        {'a': 1},
        {'a': 2, 'b': 3},
      ]), isNull);
    });
  });

  group('isTabularArray', () {
    test('returns true for uniform objects', () {
      expect(isTabularArray([
        {'a': 1, 'b': 2},
        {'a': 3, 'b': 4},
      ], ['a', 'b']), isTrue);
    });

    test('returns false for different key counts', () {
      expect(isTabularArray([
        {'a': 1},
      ], ['a', 'b']), isFalse);
    });

    test('returns false for missing keys', () {
      expect(isTabularArray([
        {'a': 1, 'c': 2},
      ], ['a', 'b']), isFalse);
    });

    test('returns false for non-primitive values', () {
      expect(isTabularArray([
        {'a': [1], 'b': 2},
      ], ['a', 'b']), isFalse);
    });
  });

  group('writeTabularRows', () {
    test('writes tabular rows at depth', () {
      final writer = LineWriter(2);
      writeTabularRows([
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ], ['a', 'b'], writer, 1, opts);
      expect(writer.toString(), equals('  1,x\n  2,y'));
    });
  });

  group('encodeMixedArrayAsListItems', () {
    test('encodes mixed array as list items', () {
      final writer = LineWriter(2);
      encodeMixedArrayAsListItems('items', [1, 'hello', [1, 2]], writer, 0, opts);
      expect(writer.toString(), isNotEmpty);
    });
  });

  group('encodeObjectAsListItem', () {
    test('encodes empty object as list item', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem(<String, dynamic>{}, writer, 0, opts);
      expect(writer.toString(), equals('-'));
    });

    test('encodes object with primitive first field', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem({'name': 'Alice', 'age': 30}, writer, 0, opts);
      expect(writer.toString(), contains('- name: Alice'));
      expect(writer.toString(), contains('  age: 30'));
    });

    test('encodes object with array first field', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem({'nums': [1, 2, 3]}, writer, 0, opts);
      expect(writer.toString(), contains('nums'));
    });

    test('encodes object with tabular array first field', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem({
        'data': [
          {'a': 1},
          {'a': 2},
        ]
      }, writer, 0, opts);
      expect(writer.toString(), contains('data'));
    });

    test('encodes object with nested object first field', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem({'child': {'name': 'Bob'}}, writer, 0, opts);
      expect(writer.toString(), contains('child:'));
      expect(writer.toString(), contains('name: Bob'));
    });

    test('encodes keyed tabular object first field', () {
      final writer = LineWriter(2);
      encodeObjectAsListItem({
        'items': {
          'x': {'v': 1},
          'y': {'v': 2},
        }
      }, writer, 0, opts);
      expect(writer.toString(), contains('items'));
    });
  });

  group('encodeInlineArrayLine', () {
    test('encodes empty array with prefix', () {
      expect(encodeInlineArrayLine([], ',', 'key', '#'), equals('key: []'));
    });

    test('encodes empty array without prefix', () {
      expect(encodeInlineArrayLine([], ',', null, null), equals('[0]:'));
    });

    test('encodes primitive array', () {
      expect(encodeInlineArrayLine([1, 2, 3], ',', 'nums', null), contains('nums'));
      expect(encodeInlineArrayLine([1, 2, 3], ',', 'nums', null), contains('[3]'));
    });
  });

  group('encodeListItemValue', () {
    test('encodes primitive list item', () {
      final writer = LineWriter(2);
      encodeListItemValue('hello', writer, 0, opts);
      expect(writer.toString(), equals('- hello'));
    });

    test('encodes array list item', () {
      final writer = LineWriter(2);
      encodeListItemValue([1, 2], writer, 0, opts);
      expect(writer.toString(), contains('- '));
    });

    test('encodes object list item', () {
      final writer = LineWriter(2);
      encodeListItemValue({'a': 1}, writer, 0, opts);
      expect(writer.toString(), contains('- '));
    });
  });

  group('LineWriter edge cases', () {
    test('pushArrayHeader with all options', () {
      final writer = LineWriter(2, estimatedCapacity: 100);
      writer.pushArrayHeader(0,
          key: 'test',
          length: 5,
          delimiter: '|',
          fields: ['a', 'b'],
          lengthMarker: '#',
          inlineValues: '1|2');
      expect(writer.toString(), contains('test'));
      expect(writer.toString(), contains('[#5|]'));
      expect(writer.toString(), contains('{a|b}'));
      expect(writer.toString(), contains('1|2'));
    });

    test('pushKeyValue with empty value', () {
      final writer = LineWriter(2);
      writer.pushKeyValue(0, 'key', '');
      expect(writer.toString(), equals('key:'));
    });

    test('pushTabularRows with single row', () {
      final writer = LineWriter(2);
      writer.pushTabularRows(1, ['1,2']);
      expect(writer.toString(), equals('  1,2'));
    });

    test('pushTabularRowsFromBuffer', () {
      final writer = LineWriter(2);
      writer.pushTabularRowsFromBuffer(1, [StringBuffer('1,2'), StringBuffer('3,4')]);
      expect(writer.toString(), equals('  1,2\n  3,4'));
    });

    test('estimateCapacity with various params', () {
      expect(LineWriter.estimateCapacity(fieldCount: 5), greaterThan(64));
      expect(LineWriter.estimateCapacity(tabularRows: 10, tabularFields: 3), greaterThan(64));
      expect(LineWriter.estimateCapacity(listItems: 5), greaterThan(64));
    });

    test('estimateFromMap with nested structures', () {
      expect(LineWriter.estimateFromMap({
        'simple': 'value',
        'nested': {'a': 1},
        'list': [1, 2, 3],
      }), greaterThan(64));
    });
  });
}