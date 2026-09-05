/// Low-level byte I/O for BTOON encoding and decoding.
///
/// All multi-byte integers and floats are little-endian (never varints).
/// Both [BtoonWriter] and [BtoonReader] can pad to an alignment measured
/// from the start of the message, so decoders can expose zero-copy views of
/// `TypedArray` / columnar `ObjectTable` payloads.
library btoon_io;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Scratch buffer for exact float32 round-trip detection.
final Float32List _f32Scratch = Float32List(1);

/// Returns true if [value] survives a `float32` round-trip unchanged.
///
/// `NaN` always returns false (a `NaN` payload is not preserved), so `NaN`
/// values are encoded as `float64`. `±Infinity` returns true.
bool isLosslessFloat32(double value) {
  if (value == 0.0) return true;
  if (value != value) return false; // NaN
  _f32Scratch[0] = value;
  return _f32Scratch[0] == value;
}

/// Sorts [strings] in place by their UTF-8 byte sequence (§17).
///
/// UTF-8 byte order equals code-point order. Dart's [String.compareTo]
/// compares UTF-16 code units, which differs from code-point order only when
/// a string contains surrogate or `U+E000..U+FFFF` units, so the fast path
/// uses the built-in sort and only strings with high code units fall back to
/// a byte-wise comparison.
void sortUtf8(List<String> strings) {
  var needsByteOrder = false;
  for (final s in strings) {
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) >= 0xD800) {
        needsByteOrder = true;
        break;
      }
    }
    if (needsByteOrder) break;
  }
  if (!needsByteOrder) {
    strings.sort();
    return;
  }
  strings.sort((a, b) => compareUtf8Bytes(a, b));
}

/// Compares two strings by their UTF-8 byte sequence.
int compareUtf8Bytes(String a, String b) {
  final ab = utf8BytesOf(a);
  final bb = utf8BytesOf(b);
  final minLen = ab.length < bb.length ? ab.length : bb.length;
  for (var i = 0; i < minLen; i++) {
    final diff = ab[i] - bb[i];
    if (diff != 0) return diff;
  }
  return ab.length - bb.length;
}

/// The UTF-8 bytes of [value].
Uint8List utf8BytesOf(String value) => utf8.encode(value);

/// A growable little-endian byte writer.
///
/// Backed by a single growable [Uint8List] with a [ByteData] view over it,
/// so every multi-byte value is one native store instead of per-byte calls.
class BtoonWriter {
  /// A pre-sized initial capacity chosen to cover the fixed envelope plus a
  /// typical small body without regrowth.
  static const int _initialCapacity = 64;

  Uint8List _buffer = Uint8List(_initialCapacity);
  late ByteData _view = ByteData.sublistView(_buffer);
  int _length = 0;

  /// Total number of bytes written so far (the current message offset).
  int get length => _length;

  void _ensure(int additional) {
    final required = _length + additional;
    final current = _buffer.length;
    if (required <= current) return;
    // Doubling amortizes small appends; a single exact jump avoids
    // zero-initializing more than needed when one large write lands.
    var capacity = current * 2;
    if (capacity < required) capacity = required;
    final grown = Uint8List(capacity);
    grown.setRange(0, _length, _buffer);
    _buffer = grown;
    _view = ByteData.sublistView(grown);
  }

  void writeByte(int value) {
    _ensure(1);
    _buffer[_length++] = value & 0xFF;
  }

  void writeBytes(List<int> bytes) {
    final count = bytes.length;
    _ensure(count);
    _buffer.setRange(_length, _length + count, bytes);
    _length += count;
  }

  /// Appends the bytes of [other] without [other] having to produce a
  /// compacted copy first.
  void writeWriter(BtoonWriter other) {
    final count = other._length;
    if (count == 0) return;
    _ensure(count);
    _buffer.setRange(_length, _length + count, other._buffer);
    _length += count;
  }

  void writeUint16(int value) {
    _ensure(2);
    _view.setUint16(_length, value, Endian.little);
    _length += 2;
  }

  void writeInt16(int value) {
    _ensure(2);
    _view.setInt16(_length, value, Endian.little);
    _length += 2;
  }

  void writeUint32(int value) {
    _ensure(4);
    _view.setUint32(_length, value, Endian.little);
    _length += 4;
  }

  void writeInt32(int value) {
    _ensure(4);
    _view.setInt32(_length, value, Endian.little);
    _length += 4;
  }

  /// Writes a 64-bit value using two 32-bit halves (web-safe).
  void writeUint64(int value) {
    _ensure(8);
    _view.setUint32(_length, value & 0xFFFFFFFF, Endian.little);
    _view.setUint32(_length + 4, (value >> 32) & 0xFFFFFFFF, Endian.little);
    _length += 8;
  }

  void writeInt64(int value) {
    _ensure(8);
    _view.setInt32(_length, value & 0xFFFFFFFF, Endian.little);
    _view.setInt32(_length + 4, (value >> 32) & 0xFFFFFFFF, Endian.little);
    _length += 8;
  }

  void writeFloat32(double value) {
    _ensure(4);
    _view.setFloat32(_length, value, Endian.little);
    _length += 4;
  }

  void writeFloat64(double value) {
    _ensure(8);
    _view.setFloat64(_length, value, Endian.little);
    _length += 8;
  }

  void writePadding(int count) {
    if (count <= 0) return;
    _ensure(count);
    _buffer.fillRange(_length, _length + count, 0);
    _length += count;
  }

  /// Pads with zero bytes so the current length becomes a multiple of
  /// [alignment], measured from the start of the message.
  void align(int alignment) {
    final remainder = _length % alignment;
    if (remainder != 0) {
      writePadding(alignment - remainder);
    }
  }

  Uint8List takeBytes() {
    if (_length == _buffer.length) return _buffer;
    final view = Uint8List.sublistView(_buffer, 0, _length);
    // Return a view when the buffer is nearly full; otherwise compact into
    // an exact-size buffer so the grown capacity can be collected.
    if (_length * 8 >= _buffer.length * 7) return view;
    return Uint8List.fromList(view);
  }
}

/// A bounds-checked little-endian byte reader.
class BtoonReader {
  final Uint8List bytes;
  final ByteData _data;
  int offset;
  final int limit;

  BtoonReader(this.bytes, {int? limit})
      : _data = ByteData.sublistView(bytes),
        offset = 0,
        limit = limit ?? bytes.length;

  /// Bytes remaining before [limit].
  int get remaining => limit - offset;

  /// Current message offset.
  int get position => offset;

  int readByte() {
    _check(1);
    return bytes[offset++];
  }

  int readUint16() {
    _check(2);
    final value = _data.getUint16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int readInt16() {
    _check(2);
    final value = _data.getInt16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int readUint32() {
    _check(4);
    final value = _data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int readInt32() {
    _check(4);
    final value = _data.getInt32(offset, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads an unsigned 64-bit value via two 32-bit halves (web-safe).
  int readUint64() {
    _check(8);
    final low = _data.getUint32(offset, Endian.little);
    final high = _data.getUint32(offset + 4, Endian.little);
    offset += 8;
    return high * 0x100000000 + low;
  }

  int readInt64() {
    _check(8);
    final low = _data.getUint32(offset, Endian.little);
    final high = _data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (high >= 0x80000000) {
      return (high - 0x100000000) * 0x100000000 + low;
    }
    return high * 0x100000000 + low;
  }

  double readFloat32() {
    _check(4);
    final value = _data.getFloat32(offset, Endian.little);
    offset += 4;
    return value;
  }

  double readFloat64() {
    _check(8);
    final value = _data.getFloat64(offset, Endian.little);
    offset += 8;
    return value;
  }

  /// Reads [length] bytes as a fresh copy.
  Uint8List readBytes(int length) {
    _check(length);
    final result = Uint8List.fromList(
      Uint8List.sublistView(bytes, offset, offset + length),
    );
    offset += length;
    return result;
  }

  void skip(int count) {
    _check(count);
    offset += count;
  }

  /// Skips and validates the zero padding that aligns the offset to
  /// [alignment], measured from the start of the message.
  void skipPaddingTo(int alignment) {
    final remainder = offset % alignment;
    if (remainder != 0) {
      skipZeroPadding(alignment - remainder);
    }
  }

  /// Skips and validates explicit zero padding.
  void skipZeroPadding(int count) {
    _check(count);
    for (var i = 0; i < count; i++) {
      if (bytes[offset + i] != 0) {
        throw BtoonDecodeError('non-zero alignment padding', offset + i);
      }
    }
    offset += count;
  }

  void _check(int count) {
    if (offset + count > limit) {
      throw BtoonDecodeError(
        'truncated input: need $count byte(s) at offset $offset, '
        'only ${limit - offset} remaining',
        offset,
      );
    }
  }
}
