/// Error types raised by the BTOON codec.
library btoon_errors;

/// Error raised when a value cannot be encoded to BTOON.
class BtoonEncodeError implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// The offending value, when available.
  final Object? value;

  const BtoonEncodeError(this.message, [this.value]);

  @override
  String toString() {
    if (value == null) return 'BtoonEncodeError: $message';
    return 'BtoonEncodeError: $message (got: $value)';
  }
}

/// Error raised when a BTOON binary cannot be decoded.
class BtoonDecodeError implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// Byte offset of the offending position, or `-1` if not applicable.
  final int offset;

  const BtoonDecodeError(this.message, [this.offset = -1]);

  @override
  String toString() {
    if (offset < 0) return 'BtoonDecodeError: $message';
    return 'BtoonDecodeError: $message (at byte $offset)';
  }
}
