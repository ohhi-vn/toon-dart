/// Low-level byte I/O for BTOON encoding and decoding.
///
/// All multi-byte integers and floats are little-endian (never varints).
/// Both [BtoonWriter] and [BtoonReader] can pad to an alignment measured
/// from the start of the message, so decoders can expose zero-copy views of
/// `TypedArray` / columnar `ObjectTable` payloads.
library btoon_io;

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

/// A growable little-endian byte writer.
class BtoonWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;

  /// Total number of bytes written so far (the current message offset).
  int get length => _length;

  void writeByte(int value) {
    _builder.addByte(value & 0xFF);
    _length++;
  }

  void writeBytes(List<int> bytes) {
    _builder.add(bytes);
    _length += bytes.length;
  }

  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >> 8);
  }

  void writeInt16(int value) {
    writeUint16(value);
  }

  void writeUint32(int value) {
    writeByte(value);
    writeByte(value >> 8);
    writeByte(value >> 16);
    writeByte(value >> 24);
  }

  void writeInt32(int value) {
    writeUint32(value);
  }

  /// Writes a 64-bit value using two 32-bit halves (web-safe).
  void writeUint64(int value) {
    writeUint32(value & 0xFFFFFFFF);
    writeUint32((value >> 32) & 0xFFFFFFFF);
  }

  void writeInt64(int value) {
    writeUint64(value);
  }

  void writeFloat32(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    writeBytes(bytes.buffer.asUint8List(0, 4));
  }

  void writeFloat64(double value) {
    final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
    writeBytes(bytes.buffer.asUint8List(0, 8));
  }

  void writePadding(int count) {
    for (int i = 0; i < count; i++) {
      _builder.addByte(0);
    }
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

  Uint8List takeBytes() => _builder.takeBytes();
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

  /// Skips zero padding so the offset becomes a multiple of [alignment]
  /// measured from the start of the message.
  void skipPaddingTo(int alignment) {
    final remainder = offset % alignment;
    if (remainder != 0) {
      skip(alignment - remainder);
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
