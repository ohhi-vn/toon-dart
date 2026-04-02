import '../types.dart';
import '../utilities/constants.dart';

/// Line writer for building TOON output with proper indentation.
/// Optimized to use StringBuffer for efficient string building.
class LineWriter {
  final StringBuffer _buffer = StringBuffer();
  final String _indentationString;
  bool _hasContent = false;

  LineWriter(int indentSize) : _indentationString = ' ' * indentSize {
    if (indentSize <= 0) {
      throw ArgumentError('indentSize must be positive');
    }
  }

  void push(Depth depth, String content) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    // Write indentation efficiently
    for (int i = 0; i < depth; i++) {
      _buffer.write(_indentationString);
    }
    _buffer.write(content);
    _hasContent = true;
  }

  void pushListItem(Depth depth, String content) {
    if (_hasContent) {
      _buffer.write('\n');
    }
    // Write indentation efficiently
    for (int i = 0; i < depth; i++) {
      _buffer.write(_indentationString);
    }
    _buffer.write(LIST_ITEM_PREFIX);
    _buffer.write(content);
    _hasContent = true;
  }

  @override
  String toString() {
    return _buffer.toString();
  }
}
