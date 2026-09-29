# Tasks

## 1. Canonical encoding and exact size selection

- [x] 1.1 Review the current local diffs in `lib/src/btoon/` and `test/btoon/` before editing, and verify implementation changes preserve existing unrelated hunks with a post-change `git diff` review.
- [x] 1.2 Extend the existing encode traversal with a count-only sink for complete-message measurement, and verify measured lengths equal emitted byte lengths for inline, table, session, and ObjectTable fixtures.
- [x] 1.3 Apply the v1 repeated-string floor and complete-message table-size comparison while retaining the existing options surface, and verify single-use strings stay inline, table wins are byte-exact, ties stay inline, session refs resolve, and envelope flags match the selected sections.
- [x] 1.4 Encode Dart doubles including `0.0` and `-0.0` with the narrowest lossless float type, and verify byte vectors preserve floating type and the negative-zero sign bit.
- [x] 1.5 Share typed-payload alignment calculations between writer and reader and reject invalid or non-zero padding, and verify valid TypedArray/ObjectTable views plus malformed-padding tests pass.
- [x] 1.6 Validate schema field values against exact numeric widths and accept only boolean bytes `0` and `1`, and verify out-of-range schema values and malformed boolean bytes are rejected.

## 2. RecordBatch encoding and decoding

- [x] 2.1 Add the `peerSupportsRecordBatch` option defaulting to false and encode only eligible, strictly smaller top-level mixed numeric/string batches, and verify the supplied v1.0 vector and dynamic fallback when support is disabled or the size test ties.
- [x] 2.2 Decode RecordBatch descriptors, nullable fields, validity bitmaps, and row-major values into ordinary object lists, and verify null versus empty-string behavior and round trips for numeric, string, nullable, and all-null fields.
- [x] 2.3 Enforce RecordBatch count, bitmap-size, selector, nullable-byte, truncation, and unused-bit checks before unsafe allocation, and verify malformed-input tests reject each invalid case with `BtoonDecodeError`.

## 3. Conformance, documentation, and verification

- [x] 3.1 Extend BTOON byte-vector and edge-case tests for v1.0 envelope flags, float zeros, string-table and RecordBatch size ties, session ObjectTable references, and typed-payload padding, and verify `dart test test/btoon` passes.
- [x] 3.2 Update BTOON package documentation and changelog with the v1.0 RecordBatch capability gate, string-table selection, and byte-output changes, and verify referenced specification/documentation paths exist.
- [x] 3.3 Run `dart test` and `dart analyze`, resolve regressions in the full package, and verify both commands complete successfully.
- [x] 3.4 Run `dart run benchmark/btoon_benchmark.dart` on the dynamic, TypedArray, ObjectTable, and schema paths, and review the reported results for unintended hot-path regressions.
