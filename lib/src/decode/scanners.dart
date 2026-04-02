import '../types.dart';
import '../utilities/constants.dart';

/// Scan result containing parsed lines and blank line information.
class ScanResult {
  final List<ParsedLine> lines;
  final List<BlankLineInfo> blankLines;

  const ScanResult({
    required this.lines,
    required this.blankLines,
  });
}

/// Line cursor for traversing parsed lines.
/// Optimized for fast traversal with minimal overhead.
class LineCursor {
  final List<ParsedLine> _lines;
  int _index;
  final List<BlankLineInfo> _blankLines;

  LineCursor(this._lines, [List<BlankLineInfo>? blankLines])
      : _index = 0,
        _blankLines = blankLines ?? [];

  List<BlankLineInfo> getBlankLines() {
    return _blankLines;
  }

  ParsedLine? peek() {
    if (_index >= _lines.length) return null;
    return _lines[_index];
  }

  ParsedLine? next() {
    if (_index >= _lines.length) return null;
    return _lines[_index++];
  }

  ParsedLine? current() {
    return _index > 0 ? _lines[_index - 1] : null;
  }

  void advance() {
    _index++;
  }

  bool atEnd() {
    return _index >= _lines.length;
  }

  int get length => _lines.length;

  ParsedLine? peekAtDepth(Depth targetDepth) {
    final line = peek();
    if (line == null || line.depth < targetDepth) {
      return null;
    }
    if (line.depth == targetDepth) {
      return line;
    }
    return null;
  }

  bool hasMoreAtDepth(Depth targetDepth) {
    return peekAtDepth(targetDepth) != null;
  }
}

/// Converts source string to parsed lines.
/// Optimized for performance with efficient string operations.
ScanResult toParsedLines(String source, int indentSize, bool strict) {
  // Fast path for empty input
  if (source.isEmpty) {
    return const ScanResult(lines: [], blankLines: []);
  }

  // Check if source is all whitespace
  bool allWhitespace = true;
  for (int i = 0; i < source.length; i++) {
    final char = source.codeUnitAt(i);
    if (char != 0x20 && char != 0x0A && char != 0x0D && char != 0x09) {
      allWhitespace = false;
      break;
    }
  }
  if (allWhitespace) {
    return const ScanResult(lines: [], blankLines: []);
  }

  final parsed = <ParsedLine>[];
  final blankLines = <BlankLineInfo>[];

  // Manual line splitting for better performance
  int lineStart = 0;
  int lineNumber = 0;

  for (int i = 0; i <= source.length; i++) {
    final isEnd = i == source.length;
    final isNewline = !isEnd && source.codeUnitAt(i) == 0x0A; // '\n'

    if (isEnd || isNewline) {
      lineNumber++;
      final lineEnd = isEnd ? source.length : i;
      final raw = source.substring(lineStart, lineEnd);

      // Skip trailing newline
      if (isEnd && raw.isEmpty) {
        break;
      }

      // Count leading spaces efficiently
      int indent = 0;
      final rawLen = raw.length;
      while (indent < rawLen && raw.codeUnitAt(indent) == 0x20) {
        // ' '
        indent++;
      }
      // Also count tabs in leading whitespace for proper strict mode validation
      int tabCount = 0;
      int pos = indent;
      while (pos < rawLen && raw.codeUnitAt(pos) == 0x09) {
        // '\t'
        tabCount++;
        pos++;
      }

      // Check if line is blank (only whitespace)
      bool isBlank = pos == rawLen;
      if (!isBlank) {
        // Check remaining characters
        for (int j = pos; j < rawLen; j++) {
          final char = raw.codeUnitAt(j);
          if (char != 0x20 && char != 0x09) {
            isBlank = false;
            break;
          }
        }
        isBlank = pos == rawLen || isBlank;
      }

      if (isBlank) {
        final depth = indent ~/ indentSize;
        blankLines.add(BlankLineInfo(
            lineNumber: lineNumber, indent: indent, depth: depth));
      } else {
        final content = raw.substring(pos);
        final depth = indent ~/ indentSize;

        // Strict mode validation
        if (strict) {
          // Check for tabs in leading whitespace
          if (tabCount > 0) {
            throw FormatException(
                'Line $lineNumber: Tabs are not allowed in indentation in strict mode');
          }

          // Check for exact multiples of indentSize
          if (indent > 0 && indent % indentSize != 0) {
            throw FormatException(
                'Line $lineNumber: Indentation must be exact multiple of $indentSize, but found $indent spaces');
          }
        }

        parsed.add(ParsedLine(
          raw: raw,
          indent: indent,
          content: content,
          depth: depth,
          lineNumber: lineNumber,
        ));
      }

      lineStart = i + 1;
    }
  }

  return ScanResult(lines: parsed, blankLines: blankLines);
}

/// Computes depth from indent spaces.
Depth computeDepthFromIndent(int indentSpaces, int indentSize) {
  return indentSpaces ~/ indentSize;
}
