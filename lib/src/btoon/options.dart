/// Options for BTOON encoding and decoding.
library btoon_options;

import 'types.dart';

enum BtoonStringTableMode { auto, off }

/// Options controlling BTOON encoding.
class BtoonEncodeOptions {
  /// An optional session dictionary used for cross-message string dedup.
  final BtoonSession? session;

  /// When true (default) and a [session] is provided, new strings seen in
  /// this message are appended to the session after encoding.
  final bool growSession;

  /// Minimum number of occurrences for a string to be added to the
  /// per-message string table.
  ///
  /// The default of 1 matches the spec test vectors (§26.3, §26.5): every
  /// string is added to the table in first-encounter order and referenced
  /// via `StringRef`. Raise it to only table repeated strings.
  final int minStringTableFrequency;

  /// Whether the per-message table is built automatically or disabled.
  final BtoonStringTableMode stringTable;

  /// When true, no per-message string table is emitted (§7.5.1): strings are
  /// either `StringRef`s into the session dictionary or inline. The
  /// `no-string-table` envelope flag (0x10) is set when a session dictionary
  /// is active and the table ends up empty.
  final bool noStringTable;

  /// Enables the homogeneous numeric fast path.
  final bool typedArrays;

  /// Enables the homogeneous numeric object-table fast path.
  final bool objectTables;

  /// Encode schema IDs in the compact UInt16 form.
  final bool schemaIdUint16;

  /// An optional schema used with (or embedded into) the message.
  final BtoonSchema? schema;

  /// When true, the body is encoded in schema mode: keys and tags are
  /// dropped and values are written positionally using the schema.
  final bool schemaMode;

  const BtoonEncodeOptions({
    this.session,
    this.growSession = true,
    this.minStringTableFrequency = 1,
    this.stringTable = BtoonStringTableMode.auto,
    this.noStringTable = false,
    this.typedArrays = true,
    this.objectTables = true,
    this.schema,
    this.schemaMode = false,
    this.schemaIdUint16 = false,
  }) : assert(minStringTableFrequency > 0,
            'minStringTableFrequency must be positive');
}

/// Options controlling BTOON decoding.
class BtoonDecodeOptions {
  /// An optional session dictionary used for cross-message string dedup.
  final BtoonSession? session;

  /// When true (default) and a [session] is provided, new strings seen in
  /// this message are appended to the session after decoding.
  final bool growSession;

  /// An external schema used to decode schema-mode messages that did not
  /// embed a schema.
  final BtoonSchema? schema;

  /// When true, binary blobs decode as [BtoonBinary] instead of `Uint8List`.
  final bool preserveBinary;

  /// When true, numeric typed arrays decode as [BtoonTypedArray] instead of
  /// `List<num>`.
  final bool preserveTypedArrays;

  /// Maximum recursive container depth. Defaults to the spec recommendation.
  final int maxDepth;

  /// Maximum inline string length in bytes (§24). Strings longer than this
  /// — including per-message string-table entries and schema names — are
  /// rejected as a defense against hostile length fields.
  final int maxStringSize;

  /// Maximum binary payload length in bytes (§24), including extension
  /// payloads.
  final int maxBinarySize;

  /// Maximum element/entry count for arrays, objects, typed arrays, object
  /// tables and string tables (§24). Counts are additionally validated
  /// against the bytes actually available.
  final int maxContainerCount;

  const BtoonDecodeOptions({
    this.session,
    this.growSession = true,
    this.schema,
    this.preserveBinary = false,
    this.preserveTypedArrays = false,
    this.maxDepth = 100,
    this.maxStringSize = 1 << 24,
    this.maxBinarySize = 1 << 24,
    this.maxContainerCount = 1 << 26,
  })  : assert(maxDepth > 0, 'maxDepth must be positive'),
        assert(maxStringSize > 0, 'maxStringSize must be positive'),
        assert(maxBinarySize > 0, 'maxBinarySize must be positive'),
        assert(maxContainerCount > 0, 'maxContainerCount must be positive');
}
