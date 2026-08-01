import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

void main() {
  group('ToonStreamDecoder.decodeTabularRows', () {
    test('streams rows from a keyed tabular array', () {
      final stream = ToonStreamDecoder('users[2]{id,name}:\n  1,Alice\n  2,Bob');
      expect(
        stream.decodeTabularRows().toList(),
        equals([
          {'id': 1.0, 'name': 'Alice'},
          {'id': 2.0, 'name': 'Bob'},
        ]),
      );
    });

    test('streams rows from a keyless root tabular array', () {
      final stream = ToonStreamDecoder('[2]{a,b}:\n  1,x\n  2,y');
      expect(
        stream.decodeTabularRows().toList(),
        equals([
          {'a': 1.0, 'b': 'x'},
          {'a': 2.0, 'b': 'y'},
        ]),
      );
    });

    test('stops at a key-value line', () {
      final stream = ToonStreamDecoder(
          'users[2]{id,name}:\n  1,Alice\n  note: hi\n  2,Bob');
      expect(stream.decodeTabularRows().toList(), hasLength(1));
    });

    test('respects header length limit', () {
      final stream =
          ToonStreamDecoder('items[1]{v}:\n  1\n  2\n  3');
      expect(stream.decodeTabularRows().toList(), hasLength(1));
    });

    test('returns nothing when no tabular array exists', () {
      final stream = ToonStreamDecoder('a: 1\nb: 2');
      expect(stream.decodeTabularRows().toList(), isEmpty);
    });

    test('handles empty string input', () {
      final stream = ToonStreamDecoder('');
      expect(stream.decodeTabularRows().toList(), isEmpty);
    });

    test('skips non-tabular lines before finding header', () {
      final stream = ToonStreamDecoder(
          'meta: value\nusers[1]{id}:\n  42');
      expect(
        stream.decodeTabularRows().toList(),
        equals([
          {'id': 42.0},
        ]),
      );
    });
  });

  group('ToonStreamDecoder.decodeTabularRowsAt', () {
    test('streams rows for a specific key', () {
      final source = 'meta: x\nusers[2]{id}:\n  1\n  2\nother[1]{v}:\n  9';
      final stream = ToonStreamDecoder(source);
      expect(
        stream.decodeTabularRowsAt('users').toList(),
        equals([
          {'id': 1.0},
          {'id': 2.0},
        ]),
      );
    });

    test('returns nothing when key not found', () {
      final stream = ToonStreamDecoder('users[1]{id}:\n  1');
      expect(stream.decodeTabularRowsAt('nope').toList(), isEmpty);
    });
  });

  group('ToonStreamDecoder.decodeTabularRowsWithSchema', () {
    test('streams rows using direct field mapping', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final stream =
          ToonStreamDecoder('users[2]{id,name}:\n  1,Alice\n  2,Bob');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'id': 1.0, 'name': 'Alice'},
          {'id': 2.0, 'name': 'Bob'},
        ]),
      );
    });
  });

  group('ToonStreamDecoder.decodeListItems', () {
    test('streams inline primitive array', () {
      final stream = ToonStreamDecoder('nums[3]: 1,2,3');
      expect(stream.decodeListItems().toList(), equals([1, 2, 3]));
    });

    test('streams list array items', () {
      final stream = ToonStreamDecoder('items[2]:\n  - a\n  - b');
      expect(stream.decodeListItems().toList(), equals(['a', 'b']));
    });

    test('streams tabular rows when header has fields', () {
      final stream = ToonStreamDecoder('users[2]{id}:\n  1\n  2');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'id': 1.0},
          {'id': 2.0},
        ]),
      );
    });

    test('yields empty object for bare hyphen item', () {
      final stream = ToonStreamDecoder('items[2]:\n  -\n  -');
      expect(stream.decodeListItems().toList(), equals([<String, dynamic>{}, <String, dynamic>{}]));
    });

    test('yields empty object for empty after-hyphen content', () {
      final stream = ToonStreamDecoder('items[1]:\n  - ');
      expect(stream.decodeListItems().toList(), equals([<String, dynamic>{}]));
    });

    test('streams inline nested array as list item', () {
      final stream = ToonStreamDecoder('rows[1]:\n  - [2]: 1,2');
      expect(stream.decodeListItems().toList(), equals([
        [1, 2],
      ]));
    });

    test('streams nested tabular array as list item', () {
      final stream = ToonStreamDecoder('groups[1]:\n  - [2]{v}:\n    1\n    2');
      expect(
        stream.decodeListItems().toList(),
        equals([
          [
            {'v': 1.0},
            {'v': 2.0},
          ],
        ]),
      );
    });

    test('yields empty array for empty list-item array', () {
      final stream = ToonStreamDecoder('rows[1]:\n  - [0]:');
      expect(stream.decodeListItems().toList(), equals([
        <dynamic>[],
      ]));
    });

    test('streams object from list item first field', () {
      final stream = ToonStreamDecoder('items[1]:\n  - name: Alice\n    age: 30');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'name': 'Alice', 'age': 30.0},
        ]),
      );
    });

    test('streams primitive list items', () {
      final stream = ToonStreamDecoder('items[2]:\n  - 42\n  - hello');
      expect(stream.decodeListItems().toList(), equals([42.0, 'hello']));
    });

    test('returns nothing for non-array input', () {
      final stream = ToonStreamDecoder('a: 1');
      expect(stream.decodeListItems().toList(), isEmpty);
    });
  });

  group('ToonStreamDecoder.decodeListItemsAt', () {
    test('streams items for a specific key', () {
      final source = 'a[1]:\n  - x\nb[2]:\n  - y\n  - z';
      final stream = ToonStreamDecoder(source);
      expect(stream.decodeListItemsAt('b').toList(), equals(['y', 'z']));
    });

    test('streams inline array for specific key', () {
      final stream = ToonStreamDecoder('a[2]: 1,2\nb[2]: 3,4');
      expect(stream.decodeListItemsAt('a').toList(), equals([1, 2]));
    });

    test('returns nothing when key not found', () {
      final stream = ToonStreamDecoder('a[1]:\n  - x');
      expect(stream.decodeListItemsAt('nope').toList(), isEmpty);
    });
  });

  group('ToonStreamDecoder async streaming', () {
    test('decodeTabularRowsAsync', () async {
      final stream = ToonStreamDecoder('users[1]{id}:\n  42');
      final rows = await stream.decodeTabularRowsAsync().toList();
      expect(rows, equals([{'id': 42.0}]));
    });

    test('decodeTabularRowsWithSchemaAsync', () async {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream = ToonStreamDecoder('users[1]{id}:\n  42');
      final rows =
          await stream.decodeTabularRowsWithSchemaAsync(schema).toList();
      expect(rows, equals([{'id': 42.0}]));
    });

    test('decodeListItemsAsync', () async {
      final stream = ToonStreamDecoder('items[2]:\n  - a\n  - b');
      final items = await stream.decodeListItemsAsync().toList();
      expect(items, equals(['a', 'b']));
    });
  });

  group('ToonStreamDecoder chunked streaming', () {
    test('decodeTabularRowsChunked yields chunks', () {
      final stream =
          ToonStreamDecoder('users[3]{id}:\n  1\n  2\n  3');
      final chunks = stream.decodeTabularRowsChunked(chunkSize: 2).toList();
      expect(chunks, hasLength(2));
      expect(chunks[0], hasLength(2));
      expect(chunks[1], hasLength(1));
    });

    test('decodeTabularRowsWithSchemaChunked yields chunks', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream =
          ToonStreamDecoder('users[3]{id}:\n  1\n  2\n  3');
      final chunks = stream
          .decodeTabularRowsWithSchemaChunked(schema, chunkSize: 2)
          .toList();
      expect(chunks, hasLength(2));
      expect(chunks[0], hasLength(2));
    });

    test('empty result produces no chunks', () {
      final stream = ToonStreamDecoder('a: 1');
      expect(stream.decodeTabularRowsChunked().toList(), isEmpty);
    });
  });

  group('ToonStreamDecoder raw streaming', () {
    test('decodeRawTabularRows yields raw row strings', () {
      final stream =
          ToonStreamDecoder('users[2]{id,name}:\n  1,Alice\n  2,Bob');
      expect(stream.decodeRawTabularRows().toList(), equals(['1,Alice', '2,Bob']));
    });

    test('decodeRawDelimitedRows yields value lists', () {
      final stream =
          ToonStreamDecoder('users[2]{id,name}:\n  1,Alice\n  2,Bob');
      expect(
        stream.decodeRawDelimitedRows().toList(),
        equals([
          ['1', 'Alice'],
          ['2', 'Bob'],
        ]),
      );
    });
  });

  group('ToonStreamDecoder internal primitive parsing', () {
    test('parses escaped values in schema streaming', () {
      final schema = ConcreteSchema.fromNames(['v']);
      final stream = ToonStreamDecoder('t[1]{v}:\n  "a\\nb"');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'v': 'a\nb'},
        ]),
      );
    });

    test('parses booleans, nulls, and numbers', () {
      final schema = ConcreteSchema.fromNames(['b', 'n', 'i']);
      final stream = ToonStreamDecoder('t[1]{b,n,i}:\n  true,null,42');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'b': true, 'n': null, 'i': 42},
        ]),
      );
    });

    test('parses false boolean in tabular rows', () {
      final schema = ConcreteSchema.fromNames(['b']);
      final stream = ToonStreamDecoder('t[1]{b}:\n  false');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'b': false},
        ]),
      );
    });

    test('parses unclosed quoted values as literal strings', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final stream = ToonStreamDecoder('t[1]{a}:\n  "unclosed');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'a': '"unclosed'},
        ]),
      );
    });

    test('treats leading-zero numbers as strings', () {
      final schema = ConcreteSchema.fromNames(['v']);
      final stream = ToonStreamDecoder('t[1]{v}:\n  05');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'v': '05'},
        ]),
      );
    });

    test('keeps unclosed quote tokens as strings', () {
      final schema = ConcreteSchema.fromNames(['v']);
      final stream = ToonStreamDecoder('t[1]{v}:\n  "unclosed');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'v': '"unclosed'},
        ]),
      );
    });
  });

  group('ToonStreamDecoder.decodeTabularRowsWithSchema extras', () {
    test('skips non-tabular lines before finding header', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream = ToonStreamDecoder('meta: value\nusers[1]{id}:\n  42');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'id': 42.0},
        ]),
      );
    });

    test('returns nothing when no tabular array exists', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream = ToonStreamDecoder('a: 1\nb: 2');
      expect(stream.decodeTabularRowsWithSchema(schema).toList(), isEmpty);
    });

    test('handles rows with more values than schema fields', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream = ToonStreamDecoder('t[1]{id}:\n  1,2,3');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'id': 1.0},
        ]),
      );
    });

    test('handles quoted values containing delimiters in schema path', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      final stream = ToonStreamDecoder('t[1]{a,b}:\n  "x,y",z');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'a': 'x,y', 'b': 'z'},
        ]),
      );
    });

    test('stops schema streaming at key-value line', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream =
          ToonStreamDecoder('t[2]{id}:\n  1\n  note: hi\n  2');
      expect(stream.decodeTabularRowsWithSchema(schema).toList(), hasLength(1));
    });

    test('stops schema streaming at shallower line', () {
      final schema = ConcreteSchema.fromNames(['id']);
      final stream = ToonStreamDecoder('t[2]{id}:\n  1\nafter: 1');
      expect(stream.decodeTabularRowsWithSchema(schema).toList(), hasLength(1));
    });
  });

  group('ToonStreamDecoder.decodeListItems extras', () {
    test('skips non-array lines before finding header', () {
      final stream = ToonStreamDecoder('a: 1\nitems[2]:\n  - x\n  - y');
      expect(stream.decodeListItems().toList(), equals(['x', 'y']));
    });

    test('streams object with empty first-field value', () {
      final stream = ToonStreamDecoder('items[1]:\n  - name:');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'name': <String, dynamic>{}},
        ]),
      );
    });

    test('streams object with empty sibling field values', () {
      final stream = ToonStreamDecoder('items[1]:\n  - name: Alice\n    age:');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'name': 'Alice', 'age': <String, dynamic>{}},
        ]),
      );
    });

    test('stops object field reading at list-item sibling', () {
      final stream =
          ToonStreamDecoder('items[1]:\n  - name: Alice\n  - other');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'name': 'Alice'},
        ]),
      );
    });

    test('stops object field reading at shallower line', () {
      final stream = ToonStreamDecoder('items[1]:\n  - name: Alice\nafter: 1');
      expect(
        stream.decodeListItems().toList(),
        equals([
          {'name': 'Alice'},
        ]),
      );
    });

    test('yields primitive values', () {
      final stream =
          ToonStreamDecoder('items[3]:\n  - true\n  - null\n  - 1.5');
      expect(stream.decodeListItems().toList(), equals([true, null, 1.5]));
    });

    test('stops list streaming at non-list line', () {
      final stream = ToonStreamDecoder('items[2]:\n  - a\n  note: hi');
      expect(stream.decodeListItems().toList(), equals(['a']));
    });
  });

  group('ToonStreamDecoder inline value edge cases', () {
    test('inline array with quoted values', () {
      final stream = ToonStreamDecoder('nums[2]: "a,b",c');
      expect(stream.decodeListItems().toList(), equals(['a,b', 'c']));
    });

    test('inline array with escaped quotes', () {
      final stream = ToonStreamDecoder(r'words[1]: "say \"hi\""');
      expect(stream.decodeListItems().toList(), equals(['say "hi"']));
    });

    test('inline values with exponent notation', () {
      final stream = ToonStreamDecoder('nums[2]: 1e2,1.5e-3');
      expect(stream.decodeListItems().toList(), equals([100.0, 0.0015]));
    });

    test('inline values with negative zero normalizes', () {
      final stream = ToonStreamDecoder('nums[1]: -0');
      expect(stream.decodeListItems().toList(), equals([0]));
    });
  });

  group('Convenience functions extras', () {
    test('streamListItems with tabular fallthrough', () {
      expect(
        streamListItems('users[2]{id}:\n  1\n  2').toList(),
        equals([
          {'id': 1.0},
          {'id': 2.0},
        ]),
      );
    });

    test('streamTabularRows respects strict flag', () {
      final rows = streamTabularRows(
        't[2]{v}:\n  1\n  2\n  3',
        strict: true,
      ).toList();
      expect(rows, hasLength(2));
    });
  });

  group('ToonStreamDecoder.decodeTabularRows extras', () {
    test('caps values at field count', () {
      final stream = ToonStreamDecoder('t[1]{a}:\n  1,2,3');
      expect(
        stream.decodeTabularRows().toList(),
        equals([
          {'a': 1.0},
        ]),
      );
    });
  });

  group('ToonStreamDecoder.decodeListItemsAt extras', () {
    test('streams tabular rows for a specific key', () {
      final stream = ToonStreamDecoder('a[1]:\n  - x\nb[2]{v}:\n  1\n  2');
      expect(
        stream.decodeListItemsAt('b').toList(),
        equals([
          {'v': 1.0},
          {'v': 2.0},
        ]),
      );
    });

    test('caps nested tabular values at field count', () {
      final stream = ToonStreamDecoder('outer[1]:\n  - [1]{a}:\n    1,2');
      expect(
        stream.decodeListItems().toList(),
        equals([
          [
            {'a': 1.0},
          ],
        ]),
      );
    });
  });

  group('ToonStreamDecoder raw streaming extras', () {
    test('decodeRawTabularRows skips non-tabular lines before header', () {
      final stream =
          ToonStreamDecoder('meta: x\nusers[1]{id}:\n  42');
      expect(stream.decodeRawTabularRows().toList(), equals(['42']));
    });

    test('decodeRawDelimitedRows skips non-tabular lines before header', () {
      final stream =
          ToonStreamDecoder('meta: x\nusers[1]{id}:\n  42');
      expect(stream.decodeRawDelimitedRows().toList(), equals([['42']]));
    });

    test('decodeRawTabularRows stops at key-value line', () {
      final stream = ToonStreamDecoder('t[2]{a}:\n  1\n  note: hi\n  2');
      expect(stream.decodeRawTabularRows().toList(), equals(['1']));
    });
  });

  group('ToonStreamDecoder unescaping variants', () {
    test('unescapes tab, carriage return, backslash', () {
      final schema = ConcreteSchema.fromNames(['a', 'b', 'c']);
      final stream = ToonStreamDecoder(
          't[1]{a,b,c}:' + '\n  "x\\ty",' + r'"x\ry",' + r'"x\\y"');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'a': 'x\ty', 'b': 'x\ry', 'c': 'x\\y'},
        ]),
      );
    });

    test('throws on backslash at end of quoted string', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final stream = ToonStreamDecoder('t[1]{a}:\n  "x\\"');
      expect(
        () => stream.decodeTabularRowsWithSchema(schema).toList(),
        throwsFormatException,
      );
    });

    test('throws on invalid escape sequence', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final stream = ToonStreamDecoder('t[1]{a}:\n  "x\\z"');
      expect(
        () => stream.decodeTabularRowsWithSchema(schema).toList(),
        throwsFormatException,
      );
    });
  });

  group('ToonStreamDecoder numeric variants', () {
    test('parses exponent notation with signs', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      final stream = ToonStreamDecoder('t[1]{a,b}:\n  1e-5,2E+3');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'a': 0.00001, 'b': 2000.0},
        ]),
      );
    });

    test('rejects malformed exponent as string', () {
      final schema = ConcreteSchema.fromNames(['a']);
      final stream = ToonStreamDecoder('t[1]{a}:\n  3e');
      expect(
        stream.decodeTabularRowsWithSchema(schema).toList(),
        equals([
          {'a': '3e'},
        ]),
      );
    });
  });

  group('Convenience functions', () {
    test('streamTabularRows', () {
      expect(
        streamTabularRows('users[1]{id}:\n  42').toList(),
        equals([
          {'id': 42.0},
        ]),
      );
    });

    test('streamTabularRowsWithSchema', () {
      final schema = ConcreteSchema.fromNames(['id']);
      expect(
        streamTabularRowsWithSchema('users[1]{id}:\n  42', schema).toList(),
        equals([
          {'id': 42.0},
        ]),
      );
    });

    test('streamListItems', () {
      expect(streamListItems('items[2]:\n  - a\n  - b').toList(),
          equals(['a', 'b']));
    });

    test('streamTabularRowsWithSchema handles escaped quotes in values', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        streamTabularRowsWithSchema(
            't[1]{a,b}:\n  "a\\"b",c', schema).toList(),
        equals([
          {'a': 'a"b', 'b': 'c'},
        ]),
      );
    });

    test('streamTabularRowsWithSchema handles escaped quotes with multi-char delimiter', () {
      final schema = ConcreteSchema.fromNames(['a', 'b']);
      expect(
        streamTabularRowsWithSchema(
            't[1:|]{a|b}:\n  "a\\"b"|c', schema).toList(),
        equals([
          {'a': 'a"b', 'b': 'c'},
        ]),
      );
    });
  });
}
