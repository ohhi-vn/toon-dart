import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:toon_format/toon_format.dart';

dynamic _normalizeJson(dynamic value) {
  if (value is Map) {
    return Map.fromEntries(value.entries
        .map((e) => MapEntry(e.key.toString(), _normalizeJson(e.value))));
  } else if (value is List) {
    return value.map(_normalizeJson).toList();
  } else if (value is num) {
    if (value is int) return value.toDouble();
    return value;
  }
  return value;
}

EncodeOptions? _parseEncodeOptions(Map<String, dynamic>? o) {
  if (o == null) return null;
  return EncodeOptions(
    indent: (o['indentSize'] as int? ?? o['indent'] as int?) ?? 2,
    delimiter: o['delimiter'] as String? ?? ',',
    lengthMarker: o['lengthMarker'] as String?,
  );
}

DecodeOptions? _parseDecodeOptions(Map<String, dynamic>? o) {
  if (o == null) return null;
  return DecodeOptions(
    indent: (o['indentSize'] as int? ?? o['indent'] as int?) ?? 2,
    strict: o['strict'] as bool? ?? true,
  );
}

class _TestCase {
  final String name;
  final dynamic input;
  final dynamic expected;
  final Map<String, dynamic>? options;
  final bool shouldError;
  _TestCase(this.name, this.input, this.expected, this.options, this.shouldError);
}

List<_TestCase> _loadEncode(String cat, String file) {
  final content = File('test/fixtures/$cat/$file').readAsStringSync();
  final json = jsonDecode(content) as Map<String, dynamic>;
  return (json['tests'] as List)
      .map((t) => _TestCase(
          t['name'] as String,
          t['input'],
          t['expected'],
          t['options'] as Map<String, dynamic>?,
          t['shouldError'] as bool? ?? false))
      .toList();
}

void main() {
  for (final f in [
    'primitives.json',
    'objects.json',
    'objects-keyed.json',
    'arrays-primitive.json',
    'arrays-tabular.json',
    'arrays-nested.json',
    'arrays-objects.json',
    'delimiters.json',
    'whitespace.json',
  ]) {
    final cases = _loadEncode('encode', f);
    test('encode $f: ${cases.length} cases', () {
      for (final tc in cases) {
        if (tc.shouldError) {
          expect(() => encode(tc.input, options: _parseEncodeOptions(tc.options)),
              throwsException, reason: tc.name);
        } else {
          final result = encode(tc.input, options: _parseEncodeOptions(tc.options));
          expect(result, equals(tc.expected), reason: tc.name);
        }
      }
    });
  }

  for (final f in [
    'numbers.json',
    'primitives.json',
    'objects.json',
    'objects-keyed.json',
    'arrays-primitive.json',
    'arrays-tabular.json',
    'arrays-nested.json',
    'delimiters.json',
    'whitespace.json',
    'root-form.json',
    'validation-errors.json',
    'indentation-errors.json',
    'blank-lines.json',
    'comments.json',
  ]) {
    final cases = _loadEncode('decode', f);
    test('decode $f: ${cases.length} cases', () {
      for (final tc in cases) {
        if (tc.shouldError) {
          expect(() => decode(tc.input as String, options: _parseDecodeOptions(tc.options)),
              throwsA(anything), reason: tc.name);
        } else {
          final result = decode(tc.input as String, options: _parseDecodeOptions(tc.options));
          expect(_normalizeJson(result), equals(_normalizeJson(tc.expected)),
              reason: tc.name);
        }
      }
    });
  }

  group('Edge Cases', () {
    test('decodes bare hyphen list item as empty object', () {
      expect(decode('items[1]:\n  -'), equals({'items': [{}]}));
    });

    test('decodes hyphen with trailing space as empty object', () {
      expect(decode('items[1]:\n  - '), equals({'items': [{}]}));
    });

    test('errors on empty inline array with count mismatch in strict mode', () {
      expect(() => decode('items[3]:'), throwsA(isA<RangeError>()));
    });

    test('decodes non-strict keyed header without fields', () {
      expect(
        decode('items[2:]:\n  a:\n  b:',
            options: const DecodeOptions(strict: false)),
        equals({'items': {'a': {}, 'b': {}}}),
      );
    });
  });
}
