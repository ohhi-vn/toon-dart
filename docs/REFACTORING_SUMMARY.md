# TOON Dart Implementation - Refactoring Summary

## Overview

This document summarizes the comprehensive refactoring and bug fixes applied to the TOON (Token-Oriented Object Notation) Dart implementation to bring it into full compliance with the TOON Specification v3.0.

## Critical Bugs Fixed

### 1. Number Canonicalization (§2)

**Problem:** Numbers were not being properly canonicalized according to TOON spec requirements.

**Issues Fixed:**
- Scientific notation (e.g., `1e6`) was not converted to decimal form (`1000000`)
- Trailing zeros in fractional parts were not removed (e.g., `1.5000` should be `1.5`)
- Integer-valued doubles were not emitted as integers (e.g., `1.0` should be `1`)
- Negative zero (`-0.0`) was not normalized to `0`
- Large numbers beyond int64 range were clamped instead of being formatted correctly

**Solution:** Implemented `_encodeNumber()` function with proper canonical form handling:
- Detects and converts scientific notation to fixed-point notation
- Removes trailing zeros after decimal point
- Emits integers without decimal points
- Normalizes `-0` to `0`
- Uses `dart:math` for logarithm calculations to determine appropriate precision

**Files Modified:**
- `lib/src/encode/primitives.dart`

### 2. Delimiter-Aware Quoting (§11.1)

**Problem:** The implementation did not properly distinguish between document delimiter and active delimiter for quoting decisions.

**Issues Fixed:**
- Object field values should use the **document delimiter** for quoting decisions
- Inline array values and tabular row cells should use the **active delimiter** from the nearest array header
- This distinction is critical for correct encoding when delimiters differ

**Solution:** 
- Added clear documentation comments explaining the delimiter scoping rules
- Ensured `encodeKeyValuePair` uses document delimiter for object field values
- Ensured tabular row encoding uses the active delimiter from array header

**Files Modified:**
- `lib/src/encode/encoders.dart`

### 3. Objects as List Items (§10)

**Problem:** Tabular arrays inside list-item objects were not being encoded/decoded at the correct depth.

**Issues Fixed:**
- Per spec §10, when a list-item object has a tabular array as its first field:
  - Tabular header appears on the hyphen line
  - Tabular rows must be at depth **+2** relative to the hyphen line
  - Other sibling fields must be at depth **+1** relative to the hyphen line
- Decoder was looking for rows at wrong depth, causing "Expected N tabular rows, but got 0" errors

**Solution:**
- Updated `encodeObjectAsListItem` to write tabular rows at `depth + 2`
- Updated `decodeObjectFromListItem` to pass adjusted depth (`baseDepth + 1`) when decoding tabular arrays, so `decodeTabularArray` (which looks for rows at `passedDepth + 1`) finds them at the correct `baseDepth + 2`

**Files Modified:**
- `lib/src/encode/encoders.dart`
- `lib/src/decode/decoders.dart`

### 4. Root Form Detection (§5)

**Problem:** Root form detection had several issues causing incorrect parsing.

**Issues Fixed:**
- Array headers with key prefixes (e.g., `items[5]: a,b,c`) were being treated as single primitives instead of object fields
- Root array detection was too broad, catching named arrays that should be object fields
- Multiple primitives at root depth were not being rejected in strict mode

**Solution:**
- Added `_isRootArrayHeader()` function that only returns true for headers starting with `[` (no key prefix)
- Updated root form detection to check for array headers with key prefixes and treat them as key-value lines
- Simplified multiple-primitive detection (deferred to object decoding)

**Files Modified:**
- `lib/src/decode/decoders.dart`

### 5. Array Header Validation (§6)

**Problem:** Array header parsing did not properly validate content between bracket/brace segments and colon.

**Issues Fixed:**
- Per spec §6, between `]` and `{` (or `:` if no fields segment), only whitespace MAY appear
- Non-whitespace content in these positions should cause the line to NOT be interpreted as an array header

**Solution:**
- Enhanced `parseArrayHeaderLine()` to validate whitespace-only content between structural elements
- Returns `null` (not a valid header) if non-whitespace is found in forbidden positions

**Files Modified:**
- `lib/src/decode/parser.dart`

### 6. Tabular Array Row Disambiguation (§9.3)

**Problem:** Decoder did not properly distinguish between tabular rows and key-value lines at the same depth.

**Issues Fixed:**
- Added `_isKeyValueLine()` helper function that implements the disambiguation algorithm:
  - Find first unquoted colon and first unquoted delimiter
  - If delimiter appears before colon → data row
  - If colon appears before delimiter (or no delimiter) → key-value line
  - If no colon → data row

**Solution:**
- Implemented proper row disambiguation in `decodeTabularArray()`
- Added `_isKeyValueLine()` function using `findUnquotedChar()` utility

**Files Modified:**
- `lib/src/decode/decoders.dart`

### 7. BigInt Handling (§2, §3)

**Problem:** BigInt values outside safe integer range were being converted to unquoted strings, which would be misinterpreted as numbers during decoding.

**Issues Fixed:**
- BigInt values beyond `Number.MAX_SAFE_INTEGER` should be quoted to preserve exact value during round-trip

**Solution:**
- Updated normalization to return BigInt as string
- String quoting rules automatically quote numeric-looking strings, ensuring safe round-trip

**Files Modified:**
- `lib/src/encode/normalize.dart`

## Code Quality Improvements

### 1. Documentation
- Added comprehensive doc comments referencing specific TOON spec sections
- Clarified delimiter scoping rules with inline comments
- Documented depth calculation logic for list-item objects

### 2. Type Safety
- Removed unnecessary casts and null assertions
- Fixed unused imports
- Improved type annotations

### 3. Code Organization
- Consolidated number encoding logic into dedicated function
- Separated root array detection from general array header detection
- Improved function naming for clarity

## Test Coverage

Created comprehensive integration test suite (`test/integration/spec_compliance_test.dart`) with 59 tests covering:

- **Number Canonicalization** (10 tests): -0, trailing zeros, scientific notation, precision, NaN/Infinity
- **String Quoting Rules** (11 tests): Empty strings, whitespace, reserved literals, numeric-like strings, structural characters, delimiters, control characters
- **Array Headers and Delimiter Scoping** (6 tests): Comma/tab/pipe delimiters, empty arrays, delimiter quoting
- **Tabular Arrays** (6 tests): Uniform detection, non-uniform fallback, nested objects, round-trip, strict mode validation
- **Objects as List Items** (4 tests): Tabular first field, primitive first field, empty objects, decoding
- **Root Form Detection** (6 tests): Empty document, single primitive, root arrays, objects, multiple primitives
- **Strict Mode Validation** (6 tests): Indentation, tabs, blank lines, escapes, missing colon, count mismatch
- **Round-trip Fidelity** (5 tests): Primitives, objects, arrays, nested structures, tabular arrays
- **Edge Cases** (5 tests): Quoted keys, dotted keys, deep nesting, arrays of arrays, mixed arrays

All 59 tests pass successfully.

## Specification Compliance Checklist

### Encoder (§13.1)
- ✅ UTF-8 output with LF line endings
- ✅ Consistent indentation (default 2 spaces, no tabs)
- ✅ Escape sequences: `\\`, `\"`, `\n`, `\r`, `\t`
- ✅ Quote strings containing active delimiter, colon, structural characters
- ✅ Emit array lengths [N] matching actual item count
- ✅ Preserve object key order as encountered
- ✅ Normalize numbers to non-exponential decimal form
- ✅ Convert -0 to 0
- ✅ Convert NaN/±Infinity to null
- ✅ No trailing spaces or trailing newline

### Decoder (§13.2)
- ✅ Parse array headers per §6 (length, delimiter, optional fields)
- ✅ Split inline arrays and tabular rows using active delimiter only
- ✅ Unescape quoted strings with only valid escapes
- ✅ Type unquoted primitives correctly
- ✅ Enforce strict-mode rules when `strict=true`
- ✅ Preserve array order and object key order
- ✅ Proper root form detection per §5
- ✅ Objects as list items per §10

### Strict Mode (§14)
- ✅ Array count and width mismatches
- ✅ Syntax errors (missing colon, invalid escapes)
- ✅ Indentation errors (not multiple of indentSize, tabs)
- ✅ Structural errors (blank lines inside arrays)

## Known Limitations

1. **Key Folding/Path Expansion (§13.4)**: Not yet implemented. This is an optional feature for compact dotted-path notation.

2. **Number Precision**: Dart doubles have ~15-17 significant digits. Very large or very precise numbers may have minor precision differences during round-trip, which is acceptable per the spec.

3. **Streaming APIs**: The current implementation loads entire documents into memory. Streaming encode/decode for very large datasets is not yet implemented.

## Migration Guide

### Breaking Changes
None. All changes are bug fixes that bring the implementation into spec compliance.

### API Changes
No public API changes. All modifications are internal implementation details.

### Behavior Changes
1. Numbers are now properly canonicalized (no scientific notation, no trailing zeros)
2. BigInt values outside safe range are now quoted strings
3. Root form detection is more strict and accurate
4. Tabular arrays in list-item objects now use correct depth
5. Strict mode validation is more comprehensive

## Testing

Run the test suite:
```bash
dart test test/integration/spec_compliance_test.dart
```

Run all tests including conformance tests (requires fixtures):
```bash
dart run test/download_fixtures.dart
dart test
```

## References

- TOON Specification v3.0: https://github.com/toon-format/spec/blob/main/SPEC.md
- Reference Implementation: https://github.com/toon-format/toon
- This Implementation: https://github.com/toon-format/toon-dart