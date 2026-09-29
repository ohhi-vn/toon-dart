import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

final _tabular = encode({
  'users': [
    for (var i = 0; i < 250; i++) {'id': i, 'name': 'user$i'},
  ],
});

final _list = encode({
  'items': [for (var i = 0; i < 60; i++) 'item$i'],
});

void main() {
  group('async tabular streaming', () {
    test('matches synchronous decoding', () async {
      final syncRows = streamDecode(_tabular).decodeTabularRows().toList();
      final asyncRows = await streamDecode(_tabular)
          .decodeTabularRowsAsync(batchSize: 10)
          .toList();
      expect(asyncRows, hasLength(250));
      expect(syncRows, everyElement(isA<Map<String, dynamic>>()));
      expect(asyncRows, equals(syncRows));
    });

    test('async schema streaming matches synchronous decoding', () async {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final syncRows = decodeTabularWithSchema(
        streamDecode(_tabular).decodeRawTabularRows().toList(),
        schema,
      );
      final rows = await streamDecode(_tabular)
          .decodeTabularRowsWithSchemaAsync(schema, batchSize: 32)
          .toList();
      expect(rows, hasLength(250));
      expect(rows, equals(syncRows));
    });
  });

  group('async list streaming', () {
    test('yields every item across batch boundaries', () async {
      final items =
          await streamDecode(_list).decodeListItemsAsync(batchSize: 7).toList();
      expect(items, hasLength(60));
      expect(items[0], 'item0');
      expect(items[59], 'item59');
    });

    test('handles inputs smaller than the batch size', () async {
      final items =
          await streamDecode(_list).decodeListItemsAsync(batchSize: 1000).toList();
      expect(items, hasLength(60));
    });
  });

  group('chunked streaming', () {
    test('splits tabular rows into full and trailing chunks', () {
      final chunks =
          streamDecode(_tabular).decodeTabularRowsChunked(chunkSize: 100).toList();
      expect(chunks, hasLength(3)); // 100 + 100 + 50
      expect(chunks.expand((c) => c), hasLength(250));
      expect(chunks.first, hasLength(100));
      expect(chunks.last, hasLength(50));
    });

    test('chunks with schema match plain chunking', () {
      final schema = ConcreteSchema.fromNames(['id', 'name']);
      final chunks = streamDecode(_tabular)
          .decodeTabularRowsWithSchemaChunked(schema, chunkSize: 64)
          .toList();
      expect(chunks.expand((c) => c), hasLength(250));
      expect(chunks.expand((c) => c).first['id'], 0);
    });

    test('single trailing chunk when input is smaller than chunk size', () {
      final chunks = streamDecode(_list.isEmpty ? _tabular : _tabular)
          .decodeTabularRowsChunked(chunkSize: 5000)
          .toList();
      expect(chunks, hasLength(1));
      expect(chunks.single, hasLength(250));
    });
  });

  group('large payload encoding', () {
    test('pre-estimated buffers handle large values', () {
      final longValue = 'x' * 3000;
      final toon = encode({'key': longValue});
      expect(decode(toon), {'key': longValue});
      expect(toon.length, greaterThan(1024));
    });
  });
}
