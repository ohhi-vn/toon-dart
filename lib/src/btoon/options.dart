/// Options for BTOON encoding and decoding.
library btoon_options;

import 'types.dart';

/// Options controlling BTOON encoding.
class BtoonEncodeOptions {
  /// An optional session dictionary used for cross-message string dedup.
  final BtoonSession? session;

  /// When true (default) and a [session] is provided, new strings seen in
  /// this message are appended to the session after encoding.
  final bool growSession;

  /// Minimum number of occurrences for a string to be added to the
  /// per-message string table (default: 2, i.e. deduplicated repeats).
  final int minStringTableFrequency;

  /// An optional schema used with (or embedded into) the message.
  final BtoonSchema? schema;

  /// When true, the body is encoded in schema mode: keys and tags are
  /// dropped and values are written positionally using the schema.
  final bool schemaMode;

  const BtoonEncodeOptions({
    this.session,
    this.growSession = true,
    this.minStringTableFrequency = 2,
    this.schema,
    this.schemaMode = false,
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

  const BtoonDecodeOptions({
    this.session,
    this.growSession = true,
    this.schema,
    this.preserveBinary = false,
    this.preserveTypedArrays = false,
  });
}
