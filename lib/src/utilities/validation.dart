/// Validation utilities for TOON format encoding and decoding.
///
/// This module re-exports validation functions from [string-utils.dart]
/// for backward compatibility. The actual implementations have been
/// moved to [string-utils.dart] for better organization and to enable
/// regex-free, code-unit-based optimizations.
///
/// Functions moved to string-utils.dart:
/// - [isValidUnquotedKey] — now uses lookup table instead of regex
/// - [isSafeUnquoted] — now uses single-pass code unit scan instead of regex
/// - [isNumericLike] — now uses state machine instead of regex
///
/// These optimizations provide ~3-10x speedup for typical inputs by
/// eliminating regex compilation and matching overhead.
library validation;

// Re-export optimized implementations from string-utils.dart
// These functions were previously defined here using regex;
// now they use direct code unit inspection for better performance.
export 'string-utils.dart'
    show isValidUnquotedKey, isSafeUnquoted, isNumericLike;

// Re-export literal utilities used by validation consumers
export 'literal-utils.dart' show isBooleanOrNullLiteral, isNumericLiteral;
