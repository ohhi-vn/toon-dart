# Design

## Context

See `proposal.md` for motivation and `specs/btoon/spec.md` for the wire contract. The Dart codec already has a deterministic collect-and-emit encoder, memoized TypedArray/ObjectTable scans, a bounds-checked reader, and options for schemas and session dictionaries. Its current defaults table single-use strings, its floating-point path normalizes zero to an integer, and decoder dispatch has no RecordBatch case. Existing BTOON tests include byte-exact vectors and malformed-input coverage that can be extended in place. The source and test files currently contain local modifications, so implementation must review and preserve those diffs rather than replacing affected files wholesale.

## Goals / Non-Goals

**Goals:**
- Complete the v1.0 wire behavior in the existing BTOON encoder/decoder without creating a second codec path.
- Compare complete candidate message sizes exactly while keeping selection deterministic and avoiding full duplicate message buffers.
- Keep default RecordBatch emission safe for peers that have not negotiated support.
- Preserve existing Dart entry points and wrapper types while updating their documented wire behavior.

**Non-Goals:**
- Define connection handshakes, session-dictionary synchronization, or schema negotiation; the application remains responsible for establishing those shared states.
- Add entity change-set or field-delta protocols.
- Add a transport framing protocol or a new incremental-decoder API. BTOON remains a complete message value whose boundaries come from the transport.
- Guarantee mutable zero-copy aliases of the caller's input buffer. The specification recommends views where practical, but changing from detached decoded buffers would alter ownership behavior; keep the current safe-copy semantics in this conformance change.

## Decisions

### Reuse the current encoder traversal and add exact size measurement

Keep the collect/emit traversal and list-scan cache. Extend collection to build ordinary string candidates and detect eligible RecordBatch structure, then measure legal encodings using a count-only output sink that implements the same write and alignment operations as the byte writer. Measure the complete message, including envelope fields, candidate table, padding, and body, so the size decision cannot drift from the final byte layout. Emit only the selected representation into the real writer.

For dynamic encoding, compare its table and inline variants under the same full-message rule, including forced ObjectTable column references when a session is active. RecordBatch field names and values are inline by definition, so measure that candidate without a per-message table. Measure the selected dynamic representation first; consider RecordBatch only when eligible and explicitly enabled, and select it only when strictly smaller than dynamic encoding. A tie remains dynamic. Keep table and RecordBatch decisions local to one encode call; do not mutate the session dictionary until the final representation has been emitted.

**Alternative considered:** Serialize complete temporary buffers for every candidate and compare lengths. This is simpler initially, but duplicates allocations and copies on the CPU-sensitive encoder path and scales memory with the largest competing representation.

### Put RecordBatch in the existing tag dispatch

Add tag `0x0E` to the existing dynamic encoder and decoder paths. Reuse UTF-8 ordering, integer-width selection, reader bounds checks, and existing map/list output shapes. Decode descriptor and bitmap structure with bounds and configured-count checks before allocating row maps; then reconstruct an ordinary list of objects. Keep capability gating in the existing encode options and default it to false, so callers must explicitly confirm peer support.

**Alternative considered:** Expose RecordBatch as a required wrapper type. The specification defines it as an encoding of an ordinary top-level array, so a wrapper would leak wire representation into the logical value API and make dynamic fallback less transparent.

### Share alignment calculations and validate encoded padding

Use one offset-based padding calculation for TypedArray and ObjectTable writing and decoding. The decoder verifies that `PadLen` is within `0..7`, that the declared padding reaches the required element boundary, and that every padding byte is zero. Retain the existing message-relative offsets and the 8-byte body alignment, so nested optimized values use the same rule.

**Alternative considered:** Continue skipping pad bytes after validating only their count. That accepts non-canonical encodings and makes the encoder's deterministic zero-padding guarantee unenforceable at the wire boundary.

### Preserve floating zero and keep Dart option compatibility

Route all Dart `double` values, including positive and negative zero, through the float-width rule; use Float32 only after an exact round trip, otherwise Float64. Keep `BtoonEncodeOptions` source-compatible: set `minStringTableFrequency` default to two and treat values below two as the v1 minimum, while retaining higher thresholds as an optional stricter candidate filter. `stringTable: off` continues to disable ordinary per-message candidates, and existing session-required ObjectTable StringRefs remain governed by the wire requirement.

**Alternative considered:** Remove `minStringTableFrequency` and replace the current options shape. The reference API does not require this Dart-only field, but removing it would add an unrelated source break; the existing field can be retained while preventing non-conforming single-use entries.

### Preserve the version and make byte changes explicit

Keep wire version `0x01`; the new tag assignment is part of v1.0. Update byte-exact vectors where table selection or floating zero changes output, and add RecordBatch vectors from the supplied specification. Consumers that depend on byte identity rather than decoded values must update golden data. RecordBatch remains opt-in, and decoders that do not support tag `0x0E` continue to fail safely on that tag.

## Risks / Trade-offs

- [Risk] The size counter and byte writer could disagree on a prefix or padding length → Use the same sink operations for both and verify measured lengths equal emitted lengths across vectors and boundary cases.
- [Risk] Default bytes change for callers using golden files, hashes, or byte signatures → Call out the change in package documentation and changelog; keep the wire version and ordinary decoded values stable.
- [Risk] Sending `0x0E` to an older peer fails decoding → Keep peer support false by default and require explicit capability information from the application.
- [Risk] Malformed row counts or bitmaps could trigger large allocations or overflow → Validate counts, bitmap sizing, row offsets, and remaining bytes before allocating decoded rows.
- [Trade-off] Copying decoded binary and numeric buffers is less efficient than a shared view → Retain current ownership-safe copies in this change; zero-copy aliases are a SHOULD-level optimization and can be considered separately with an explicit ownership contract.

## Migration Plan

1. Add the v1.0 vectors and decoder malformed-input checks alongside the existing tests.
2. Update the encoder behavior and options, then run all BTOON tests and the package test suite.
3. Document that exact encoded bytes may change while the wire version remains `0x01`; consumers with byte snapshots should refresh them after reviewing the new canonical vectors.
4. Rollback is a package release rollback. Keep RecordBatch disabled by default so applications can continue exchanging supported tags while upgrading peers independently.

## Open Questions

None. Transport capability negotiation and session dictionary lifecycle remain application concerns under this design.
