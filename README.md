# TOON Format for Dart

[![pub package](https://img.shields.io/pub/v/toon_format.svg)](https://pub.dev/packages/toon_format)
[![Documentation](https://pub.dev/documentation/toon_format/latest/)](https://pub.dev/documentation/toon_format/latest/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

**Token-Oriented Object Notation** is a compact, human-readable format designed for passing structured data to Large Language Models with significantly reduced token usage.

This package implements two encodings:

- **TOON** — the compact, human-readable text format for LLM prompts and responses.
- **BTOON** — a compact **binary** sibling format (8-byte envelope, aligned fixed-width fields, per-message string table, `TypedArray` / columnar `ObjectTable`, optional schema mode, cross-message session dictionary).

## TOON Example

**JSON** (verbose):
```json
{
  "users": [
    { "id": 1, "name": "Alice", "role": "admin" },
    { "id": 2, "name": "Bob", "role": "user" }
  ]
}
```

**TOON** (compact):
```
users[2]{id,name,role}:
  1,Alice,admin
  2,Bob,user
```

## BTOON Example

```dart
import 'package:toon_format/toon_format.dart';

void main() {
  final users = [
    {'id': 1, 'name': 'Alice'},
    {'id': 2, 'name': 'Bob'},
  ];

  // Encode (homogeneous maps become a columnar ObjectTable).
  final bytes = btoonEncode(users);
  final decoded = btoonDecode(bytes); // == users

  // Strings repeated across many messages can share a session dictionary,
  // shrinking every message after the first.
  final session = BtoonSession();
  final first = btoonEncode({'name': 'Alice', 'age': 30},
      options: BtoonEncodeOptions(session: session));
  final second = btoonEncode({'name': 'Alice', 'age': 31},
      options: BtoonEncodeOptions(session: session));
  // second reuses 'name' and 'Alice' from the session.

  // Schema mode: keys and value tags are written once in an embedded schema,
  // then each row carries only raw values.
  final schemaBytes = btoonEncode(users,
      options: const BtoonEncodeOptions(schemaMode: true));
  final rows = btoonDecode(schemaBytes);
}
```

### BTOON features

- **Fixed 8-byte envelope** — `BTON` magic, version, flags; body 8-byte aligned.
- **Compact values** — inline `SmallInt` (`-32..95`), `Int32` / `Int64`,
  `Float32` / `Float64`, strings, binary blobs, arrays, and objects with
  deterministically sorted keys.
- **String table** — repeated strings are emitted once per message and
  referenced elsewhere (`minStringTableFrequency` controls the threshold).
- **Session dictionary** — a `BtoonSession` shared across messages lets later
  messages reference earlier strings by id (`StringRef`), progressively
  shrinking the stream.
- **TypedArray** — homogeneous numeric lists become aligned fixed-width
  buffers (`BtoonTypedArray`, `BtoonElementType`), decodable as zero-copy
  column views.
- **ObjectTable** — homogeneous numeric object lists become columnar tables
  (`BtoonObjectTable`): one aligned fixed-width column per field.
- **Schema mode** — with a shared `BtoonSchema` (`BtoonSchemaField`,
  `BtoonSchemaType`), keys and tags are dropped and each record is a
  positional fixed-width struct after a schema id.
- **Deterministic** — the same input always encodes to the same bytes.

The BTOON wire format is specified in `btoon_spec/spec.md`.

## Usage

```dart
import 'package:toon_format/toon_format.dart';

void main() {
  final data = {
    'users': [
      {'id': 1, 'name': 'Alice', 'role': 'admin'},
      {'id': 2, 'name': 'Bob', 'role': 'user'}
    ]
  };

  final toonString = encode(data);
  final decoded = decode(toonString);
}
```

## Resources

- [TOON Specification](https://github.com/johannschopplich/toon/blob/main/SPEC.md)
- [Main Repository](https://github.com/johannschopplich/toon)
- [Benchmarks & Performance](https://github.com/johannschopplich/toon#benchmarks)
- [Other Language Implementations](https://github.com/johannschopplich/toon#other-implementations)

## Contributing

Interested in implementing TOON for Dart? Check out the [specification](https://github.com/johannschopplich/toon/blob/main/SPEC.md) and feel free to contribute!

## Contributors

- [Tushar Gupta](https://github.com/Tushargupta9800)

## License

MIT License © 2025-PRESENT [Johann Schopplich](https://github.com/johannschopplich) & [Tushar Gupta](https://github.com/Tushargupta9800)
