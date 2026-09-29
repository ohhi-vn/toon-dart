# Proposal

## Why

The Dart package already ships a substantial BTOON codec, but it does not yet implement the stable v1.0 specification end to end: RecordBatch is absent and automatic string-table selection does not follow the normative frequency and full-message-size rules. Recording the codec contract and closing these gaps will make its output interoperable and deterministic across conforming implementations.

## What Changes

- Define BTOON v1.0 as a project capability, covering the envelope, dynamic values, dictionaries, typed payloads, schema mode, extensions, decoder limits, and conformance behavior.
- Add RecordBatch encoding for eligible mixed numeric/string object arrays only when the peer is known to support tag `0x0E` and the complete message is smaller than dynamic encoding; decode it back to ordinary objects and reject malformed descriptors, bitmaps, and values.
- Make automatic per-message string-table selection consider repeated non-session strings and choose a table only when the complete encoded message is smaller; keep ties inline and set envelope flags to match emitted sections.
- Preserve floating-point values (including `0.0` and `-0.0`) with the narrowest lossless float encoding; validate typed-payload alignment and zero padding; and add byte-exact, round-trip, and malformed-input vectors for the v1.0 rules.
- Preserve the existing Dart codec entry points and wrappers; add an encoder option for RecordBatch peer support. Optional transport negotiation and change-set protocols remain application responsibilities.
- **BREAKING:** Default encoded bytes can change where the existing encoder tables single-use strings, normalizes floating zero, or selects a representation differently. The wire version remains `0x01`, and v1.0 decoders continue to decode the resulting values.

## Capabilities

### New Capabilities

- `btoon`: Specify and complete the Dart implementation of the BTOON v1.0 binary wire format.

### Modified Capabilities

None. The project has no existing OpenSpec capability specs.

## Impact

- Existing BTOON implementation in `lib/src/btoon/`, public exports in `lib/toon_format.dart`, and BTOON tests under `test/btoon/`.
- Default binary output and BTOON encode options; no new dependencies or changes to the TOON text codec.
