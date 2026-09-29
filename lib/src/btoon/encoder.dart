/// BTOON encoder.
///
/// The encoder resolves the message layout in three steps:
///
///   1. a *collect* pass that walks the value in the exact order the body
///      will be written, counting string occurrences and scanning lists once
///      for their TypedArray / ObjectTable / RecordBatch form;
///   2. a *choice* step that picks the per-message string table and, when
///      the peer supports it, a RecordBatch representation, by comparing
///      complete message sizes;
///   3. an *emit* pass that writes the selected representation, replacing
///      table/session strings with `StringRef` entries.
///
/// The string-table decision is computed in closed form from the counted
/// frequencies, so it costs no extra traversal; only the RecordBatch
/// comparison needs to measure a second body, and it is opt-in.
///
/// Both passes share the same traversal, so the wire output is fully
/// deterministic.
library btoon_encoder;

import 'dart:convert';
import 'dart:typed_data';

import '../utilities/int64_bounds.dart';
import 'constants.dart';
import 'errors.dart';
import 'io.dart';
import 'numeric.dart';
import 'options.dart';
import 'types.dart';

/// Encode state shared between the collect and emit passes.
class _EncodeState {
  final BtoonSession? session;
  final int minTableFreq;
  final bool useStringTable;
  final bool typedArrays;
  final bool objectTables;
  final bool schemaIdUint16;

  /// Occurrence count per non-session string. A Dart map literal preserves
  /// insertion order, so iterating this also yields first-encounter order
  /// (§7.5) without a separate list.
  final Map<String, int> _freq = {};

  /// Strings that MUST appear in the per-message table regardless of their
  /// frequency (ObjectTable column names when a session dictionary is
  /// active, §14).
  final Set<String> _forced = {};

  /// The per-message table entries the current pass is emitting, in
  /// first-encounter order.
  List<String> table = const [];

  /// [table] entry -> index within the table.
  Map<String, int> tableIndex = const {};

  final List<String> inlineStrings = [];
  final Set<String> _inlineSeen = {};

  /// Whether inline strings are worth tracking. They only feed session
  /// growth, so the work is skipped when no session is being grown.
  final bool trackInlineStrings;

  /// Per-encode memo of list scans (typed-array element type, ObjectTable
  /// plan) keyed by list identity, so the collect and emit passes scan each
  /// list once.
  final Map<List<dynamic>, Object> scanCache = {};

  _EncodeState(
      {required this.session,
      required this.minTableFreq,
      required this.useStringTable,
      required this.typedArrays,
      required this.objectTables,
      required this.schemaIdUint16})
      : trackInlineStrings = session != null;

  /// Collect pass: record a string occurrence (session strings are skipped).
  void recordString(String value) {
    final session = this.session;
    if (session != null && session.indexOf(value) != null) return;
    _freq[value] = (_freq[value] ?? 0) + 1;
  }

  /// Collect pass: force [value] into the per-message table (§14) even when
  /// it occurs once or the table is otherwise disabled.
  void forceTableString(String value) {
    final session = this.session;
    if (session != null && session.indexOf(value) != null) return;
    _forced.add(value);
    _freq[value] = (_freq[value] ?? 0) + 1;
  }

  /// True when a session is active, so ObjectTable column names must be
  /// referenced rather than written inline (§14).
  bool get sessionActive => session != null && session!.length > 0;

  /// True when §14 forces at least one entry into the per-message table (an
  /// ObjectTable column name that is in neither the session dictionary nor
  /// the table), which makes the table mandatory.
  bool get requiresTable => _forced.isNotEmpty;

  /// The candidate per-message table entries in first-encounter order.
  ///
  /// Only strings occurring at least [minTableFreq] times are ordinary
  /// candidates (§7.5); forced entries are always included. With the table
  /// disabled, only forced entries survive — and none can be added when the
  /// table is disabled, so callers must not force in that mode.
  List<String> buildCandidates() {
    final candidates = <String>[];
    // Iterating a map literal yields first-encounter order.
    for (final value in _freq.keys) {
      if (_forced.contains(value) ||
          (useStringTable && (_freq[value] ?? 0) >= minTableFreq)) {
        candidates.add(value);
      }
    }
    return candidates;
  }

  /// The complete size of the message using [candidates] as the per-message
  /// table, and the size using inline strings.
  ///
  /// Tabling swaps every occurrence of a candidate for a StringRef and pays
  /// for a table section. Both costs are fully determined by the collected
  /// frequencies: an inline string costs 1 tag + 4 length + UTF-8 bytes, a ref
  /// costs 1 tag + the canonical integer the encoder would write, and the
  /// table section is a UInt32 count plus one UInt32 length and UTF-8 bytes
  /// per entry, padded to 8.
  ///
  /// Nothing else in the message changes between the two encodings. The body
  /// starts at an 8-byte boundary either way — directly after the header when
  /// there is no table, or after the aligned table section — so every
  /// alignment decision inside the body is identical and cancels out of the
  /// comparison. That makes this closed form the exact complete-message size
  /// difference §7.5 requires, without re-walking the value.
  ({int tableSize, int inlineSize}) measureTableVariants(
      List<String> candidates) {
    var nextId = session?.length ?? 0;
    var stringDelta = 0;
    var tableBytes = 4; // UInt32 entry count
    for (final value in candidates) {
      final utf8Length = utf8BytesOf(value).length;
      final occurrences = _freq[value] ?? 0;
      // A StringRef id is a canonical integer: SmallInt in -32..95, else
      // Int32, else Int64.
      final idBytes = nextId >= smallIntMin && nextId <= smallIntMax
          ? 1
          : (nextId >= -2147483648 && nextId <= 2147483647 ? 5 : 9);
      // Inline: 1 tag + 4 length + bytes. Referenced: 1 tag + the id.
      stringDelta += occurrences * (5 + utf8Length - (1 + idBytes));
      tableBytes += 4 + utf8Length;
      nextId++;
    }
    // The table section is zero-padded to a multiple of 8.
    final paddedTableBytes = (tableBytes + 7) & ~7;
    // Both variants share the same base, so only the difference is needed:
    // the added section minus what the refs save.
    return (
      tableSize: paddedTableBytes - stringDelta,
      inlineSize: 0,
    );
  }

  /// Installs [entries] as the table the emit pass references.
  void useTable(List<String> entries) {
    table = entries;
    if (entries.isEmpty) {
      tableIndex = const {};
      return;
    }
    final index = <String, int>{};
    for (var i = 0; i < entries.length; i++) {
      index[entries[i]] = i;
    }
    tableIndex = index;
  }

  /// Emit pass: record an inline string for later session growth.
  void recordInlineString(String value) {
    // Inline strings are only tracked to grow a session dictionary after the
    // message; skip the bookkeeping entirely when that cannot happen.
    if (!trackInlineStrings) return;
    if (_inlineSeen.add(value)) {
      inlineStrings.add(value);
    }
  }

  /// Clears the inline strings recorded by a discarded pass.
  void resetInlineStrings() {
    inlineStrings.clear();
    _inlineSeen.clear();
  }

  void growSession(BtoonSession target) {
    for (final value in table) {
      target.add(value);
    }
    for (final value in inlineStrings) {
      target.add(value);
    }
  }
}

/// The per-message string table chosen for one message.
class _TableChoice {
  /// The per-message table entries to emit, in first-encounter order.
  final List<String> table;

  const _TableChoice(this.table);
}

/// Encodes [value] into a BTOON binary.
Uint8List btoonEncodeBytes(Object? value, BtoonEncodeOptions options) {
  final state = _EncodeState(
    session: options.session,
    minTableFreq: effectiveMinTableFrequency(options.minStringTableFrequency),
    useStringTable: options.stringTable == BtoonStringTableMode.auto &&
        !options.noStringTable,
    typedArrays: options.typedArrays,
    objectTables: options.objectTables,
    schemaIdUint16: options.schemaIdUint16,
  );

  final schema = _resolveSchema(value, options);

  // Pass 1: collect string frequencies and scan caches.
  if (schema != null) {
    _encodeSchemaBody(value, schema, state, null);
  } else {
    _encodeValue(value, state, null,
        typedArrays: state.typedArrays, objectTables: state.objectTables);
  }

  // Pass 2: choose the representation. §7.5 and §17 require the per-message
  // table to be chosen by comparing complete message sizes rather than by a
  // local frequency heuristic; the counted frequencies make that comparison
  // a closed form, so it costs no extra traversal.
  final choice = _chooseStringTable(state);
  state.useTable(choice.table);
  state.resetInlineStrings();

  final recordBatch = _chooseRecordBatch(value, state, options, choice, schema: schema);

  // Pass 3: emit the selected representation. With no string table and no
  // schema the body starts right after the 8-byte header, so it is written
  // directly into the envelope sink — no intermediate body buffer or copy.
  final sink = BtoonWriter();
  sink.writeBytes(btoonMagic);
  sink.writeByte(btoonVersion);
  final flags = _envelopeFlags(state, schema, options);
  sink.writeByte(flags);
  sink.writeByte(0);
  sink.writeByte(0);

  if (state.table.isNotEmpty) {
    sink.writeUint32(state.table.length);
    for (final entry in state.table) {
      final bytes = utf8.encode(entry);
      sink.writeUint32(bytes.length);
      sink.writeBytes(bytes);
    }
    sink.align(8);
  }

  if (schema != null) {
    _writeSchema(sink, schema, (flags & flagSchemaIdUint16) != 0);
  }

  if (schema != null || state.table.isNotEmpty) {
    sink.align(8);
  }
  if (recordBatch != null) {
    _writeRecordBatch(sink, value! as List<dynamic>, recordBatch, state);
  } else if (schema != null) {
    _encodeSchemaBody(value, schema, state, sink);
  } else {
    _encodeValue(value, state, sink,
        typedArrays: state.typedArrays, objectTables: state.objectTables);
  }

  if (options.session != null && options.growSession) {
    state.growSession(options.session!);
  }

  return sink.takeBytes();
}

/// The v1 minimum number of occurrences for an ordinary string-table
/// candidate (§7.5).
///
/// A string that occurs once never pays for its own table entry, so one
/// occurrence is never a candidate; higher configured thresholds remain
/// available as a stricter filter.
int effectiveMinTableFrequency(int configured) =>
    configured < kMinStringTableFrequency ? kMinStringTableFrequency : configured;

/// The smallest number of occurrences that may make a string a per-message
/// string-table candidate (§7.5).
const int kMinStringTableFrequency = 2;

/// Builds the envelope flags for the sections this message actually emits
/// (§7.3, §7.5.1, §18).
int _envelopeFlags(
    _EncodeState state, BtoonSchema? schema, BtoonEncodeOptions options) {
  var flags = 0;
  if (state.table.isNotEmpty) flags |= flagStringTable;
  if (schema != null) flags |= flagHasSchema;
  if (state.sessionActive) flags |= flagSession;
  if (state.sessionActive && state.table.isEmpty) flags |= flagNoStringTable;
  if (schema != null && options.schemaIdUint16) flags |= flagSchemaIdUint16;
  return flags;
}

/// Measures the complete message with [table] installed and returns its size.
///
/// A non-null [recordBatch] measures the RecordBatch encoding of [value],
/// which is always table-free because its field names and values are inline.
int _measureMessage(
  Object? value,
  BtoonSchema? schema,
  _EncodeState state,
  BtoonEncodeOptions options,
  List<String> table, {
  _RecordBatchPlan? recordBatch,
}) {
  final counter = BtoonCounter();
  state.useTable(recordBatch != null ? const [] : table);
  final flags = _envelopeFlags(state, schema, options);
  counter.writeBytes(btoonMagic);
  counter.writeByte(btoonVersion);
  counter.writeByte(flags);
  counter.writeByte(0);
  counter.writeByte(0);
  if (state.table.isNotEmpty) {
    counter.writeUint32(state.table.length);
    for (final entry in state.table) {
      counter.writeUint32(utf8.encode(entry).length);
    }
    counter.align(8);
  }
  if (schema != null) {
    _writeSchema(counter, schema, (flags & flagSchemaIdUint16) != 0);
  }
  if (schema != null || state.table.isNotEmpty) {
    counter.align(8);
  }
  if (recordBatch != null) {
    _writeRecordBatch(counter, value as List<dynamic>, recordBatch, state);
  } else if (schema != null) {
    _encodeSchemaBody(value, schema, state, counter);
  } else {
    _encodeValue(value, state, counter,
        typedArrays: state.typedArrays, objectTables: state.objectTables);
  }
  return counter.length;
}

/// Picks the per-message string table by comparing complete message sizes.
///
/// The candidate table is used only when it makes the whole message strictly
/// smaller than the inline-string encoding; a tie keeps strings inline
/// (§7.5, §17). The inline variant is never valid when a session is active
/// and an ObjectTable column name has to be referenced, so the table is then
/// mandatory.
_TableChoice _chooseStringTable(_EncodeState state) {
  final candidates = state.buildCandidates();
  if (candidates.isEmpty) {
    // Nothing can be referenced, so the inline encoding is the only legal
    // one.
    return const _TableChoice([]);
  }
  if (state.requiresTable) {
    // §14: column names must be StringRef and must live in a table, so the
    // size comparison cannot drop them.
    return _TableChoice(candidates);
  }
  // §7.5, §17: use the table only when it makes the complete message
  // strictly smaller; a tie keeps strings inline.
  final sizes = state.measureTableVariants(candidates);
  if (sizes.tableSize < sizes.inlineSize) {
    return _TableChoice(candidates);
  }
  return const _TableChoice([]);
}

// #region RecordBatch

/// The kind of a RecordBatch column, derived from the non-null values of a
/// field across all rows (§10.3).
enum _RecordBatchKind { integer, float, string, allNull }

/// A pre-computed RecordBatch layout for one top-level row list.
class _RecordBatchPlan {
  /// Field names in UTF-8 byte order; the wire order.
  final List<String> fields;

  /// The non-null kind of each field in [fields].
  final List<_RecordBatchKind> kinds;

  /// Numeric element selector per field, or 0 for string/all-null fields.
  final List<BtoonElementType> numericTypes;

  /// Whether at least one row is null for each field, which requires a
  /// validity bitmap.
  final List<bool> nullable;

  final int rowCount;

  const _RecordBatchPlan({
    required this.fields,
    required this.kinds,
    required this.numericTypes,
    required this.nullable,
    required this.rowCount,
  });
}

/// Returns true when [value] is a RecordBatch candidate: a top-level list of
/// at least two objects with identical string keys, one non-null type per
/// field, and at least one numeric plus one string field (§10.3).
///
/// Numeric-only arrays are not candidates: they keep using ObjectTable.
_RecordBatchPlan? _recordBatchPlan(List<dynamic> value) {
  if (value.length < 2) return null;
  final rows = <Map<String, dynamic>>[];
  final first = value.first;
  if (first is! Map) return null;
  final keySet = <String>{};
  first.forEach((key, v) {
    if (key is! String) return;
    keySet.add(key);
  });
  if (keySet.isEmpty) return null;
  for (final element in value) {
    if (element is! Map) return null;
    if (element.length != keySet.length) return null;
    for (final key in element.keys) {
      if (key is! String || !keySet.contains(key)) return null;
    }
    rows.add(Map<String, dynamic>.from(element));
  }

  final fields = keySet.toList();
  sortUtf8(fields);

  final kinds = <_RecordBatchKind>[];
  final numericTypes = <BtoonElementType>[];
  final nullable = <bool>[];
  var hasNumeric = false;
  var hasString = false;

  for (final field in fields) {
    var sawInt = false;
    var sawDouble = false;
    var sawString = false;
    var sawNull = false;
    var rangeInit = false;
    var min = 0;
    var max = 0;
    Float32List? f32;
    for (var i = 0; i < rows.length; i++) {
      final cell = rows[i][field];
      if (cell == null) {
        sawNull = true;
      } else if (cell is int) {
        sawInt = true;
        if (!sawDouble) {
          if (!rangeInit) {
            min = max = cell;
            rangeInit = true;
          } else if (cell < min) {
            min = cell;
          } else if (cell > max) {
            max = cell;
          }
        }
      } else if (cell is double) {
        sawDouble = true;
        f32 ??= Float32List(rows.length);
        f32[i] = cell;
      } else if (cell is String) {
        sawString = true;
      } else {
        // A non-scalar value disqualifies the batch.
        return null;
      }
    }
    // A field with more than one non-null type is not a RecordBatch field.
    final typeCount = (sawInt ? 1 : 0) +
        (sawDouble ? 1 : 0) +
        (sawString ? 1 : 0);
    if (typeCount > 1) return null;

    if (sawInt) {
      final type = bestIntElementTypeForRange(min, max);
      if (type == null) return null;
      kinds.add(_RecordBatchKind.integer);
      numericTypes.add(
          type == BtoonElementType.uint64 ? BtoonElementType.int64 : type);
      nullable.add(sawNull);
      hasNumeric = true;
    } else if (sawDouble) {
      var lossless = true;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i][field] == null) continue;
        if (f32![i] != rows[i][field]) {
          lossless = false;
          break;
        }
      }
      kinds.add(_RecordBatchKind.float);
      numericTypes.add(lossless
          ? BtoonElementType.float32
          : BtoonElementType.float64);
      nullable.add(sawNull);
      hasNumeric = true;
    } else if (sawString) {
      kinds.add(_RecordBatchKind.string);
      numericTypes.add(BtoonElementType.int8); // unused for strings
      nullable.add(sawNull);
      hasString = true;
    } else {
      // All rows null: the field uses the null selector with no bitmap.
      kinds.add(_RecordBatchKind.allNull);
      numericTypes.add(BtoonElementType.int8); // unused
      nullable.add(false);
    }
  }

  // A batch needs at least one numeric and one string field to be distinct
  // from a pure ObjectTable; numeric-only arrays keep using ObjectTable.
  if (!hasNumeric || !hasString) return null;

  return _RecordBatchPlan(
    fields: fields,
    kinds: kinds,
    numericTypes: numericTypes,
    nullable: nullable,
    rowCount: rows.length,
  );
}

/// Returns a RecordBatch representation of [value] when it is eligible, the
/// peer is known to support tag `0x0E`, and the complete RecordBatch message
/// is strictly smaller than the dynamic message. Otherwise returns null.
_RecordBatchPlan? _chooseRecordBatch(
  Object? value,
  _EncodeState state,
  BtoonEncodeOptions options,
  _TableChoice dynamic, {
  required BtoonSchema? schema,
}) {
  if (schema != null) return null; // schema mode is its own body mode
  if (!options.peerSupportsRecordBatch) return null;
  if (value is! List) return null;
  final plan = _recordBatchPlan(value);
  if (plan == null) return null;
  // §10.3: the RecordBatch body is table-free (its field names and values are
  // inline), so it is compared against the same dynamic encoding the encoder
  // would otherwise emit. The two bodies differ structurally, so both are
  // measured through the shared traversal.
  final dynamicSize =
      _measureMessage(value, schema, state, options, dynamic.table);
  final batchSize = _measureMessage(
      value, schema, state, options, const [],
      recordBatch: plan);
  // A tie keeps the dynamic representation (§10.3, §17).
  if (batchSize < dynamicSize) return plan;
  return null;
}

/// Writes a RecordBatch value (tag `0x0E`) using [plan] (§10.3).
void _writeRecordBatch(
    BtoonSink sink, List<dynamic> value, _RecordBatchPlan plan, _EncodeState state) {
  sink.writeByte(tagRecordBatch);
  sink.writeUint32(plan.fields.length);
  for (var f = 0; f < plan.fields.length; f++) {
    final name = utf8.encode(plan.fields[f]);
    sink.writeUint32(name.length);
    sink.writeBytes(name);
    sink.writeByte(_recordBatchSelector(plan, f));
    sink.writeByte(plan.nullable[f] ? 1 : 0);
  }
  sink.writeUint32(plan.rowCount);

  // Validity bitmaps, in field order, before the row values.
  for (var f = 0; f < plan.fields.length; f++) {
    if (!plan.nullable[f]) continue;
    final bitmap = _recordBatchBitmap(value, plan, f);
    sink.writeBytes(bitmap);
  }

  // Row-major values, field by field, in schema order.
  for (var r = 0; r < plan.rowCount; r++) {
    final row = value[r] as Map;
    for (var f = 0; f < plan.fields.length; f++) {
      final cell = row[plan.fields[f]];
      if (cell == null) continue; // null has no payload
      switch (plan.kinds[f]) {
        case _RecordBatchKind.integer:
          _writeRecordBatchNumeric(sink, cell as int, plan.numericTypes[f]);
        case _RecordBatchKind.float:
          _writeRecordBatchNumeric(sink, cell as double, plan.numericTypes[f]);
        case _RecordBatchKind.string:
          final text = cell as String;
          final bytes = utf8.encode(text);
          sink.writeUint32(bytes.length);
          sink.writeBytes(bytes);
          state.recordInlineString(text);
        case _RecordBatchKind.allNull:
          break;
      }
    }
  }
}

int _recordBatchSelector(_RecordBatchPlan plan, int field) {
  switch (plan.kinds[field]) {
    case _RecordBatchKind.integer:
    case _RecordBatchKind.float:
      return elementTagOf(plan.numericTypes[field]);
    case _RecordBatchKind.string:
      return elementString;
    case _RecordBatchKind.allNull:
      return elementNull;
  }
}

/// Builds the validity bitmap for a nullable field: one low-order-first bit
/// per row, set when the value is present (§10.3).
Uint8List _recordBatchBitmap(
    List<dynamic> value, _RecordBatchPlan plan, int field) {
  final byteCount = (plan.rowCount + 7) ~/ 8;
  final bitmap = Uint8List(byteCount);
  final name = plan.fields[field];
  for (var r = 0; r < plan.rowCount; r++) {
    final cell = (value[r] as Map)[name];
    if (cell != null) {
      bitmap[r >> 3] |= 1 << (r & 7);
    }
  }
  // Unused high bits of the final byte are already zero.
  return bitmap;
}

void _writeRecordBatchNumeric(BtoonSink sink, num value, BtoonElementType type) {
  switch (type) {
    case BtoonElementType.int8:
    case BtoonElementType.uint8:
      sink.writeByte(value.toInt());
    case BtoonElementType.int16:
    case BtoonElementType.uint16:
      sink.writeUint16(value.toInt());
    case BtoonElementType.int32:
    case BtoonElementType.uint32:
      sink.writeUint32(value.toInt());
    case BtoonElementType.int64:
    case BtoonElementType.uint64:
      sink.writeInt64(value.toInt());
    case BtoonElementType.float32:
      sink.writeFloat32(value.toDouble());
    case BtoonElementType.float64:
      sink.writeFloat64(value.toDouble());
  }
}

// #endregion

/// Resolves the schema to embed / use for schema mode.
BtoonSchema? _resolveSchema(Object? value, BtoonEncodeOptions options) {
  final schema = options.schema;
  if (schema != null) return schema;
  if (options.schemaMode) {
    final derived = _deriveSchema(value);
    if (derived == null) {
      throw BtoonEncodeError(
        'schema mode requires a map or a list of maps at the root',
        value,
      );
    }
    return derived;
  }
  return null;
}

// #region String emission

void _emitString(String value, _EncodeState state, BtoonSink? sink) {
  final isCollect = sink == null;
  final session = state.session;
  final sessionIndex = session?.indexOf(value);

  if (isCollect) {
    if (sessionIndex == null) state.recordString(value);
    return;
  }

  final tableEntry = state.tableIndex[value];
  if (sessionIndex != null) {
    // Session entries own ids 0..n-1 (§11.3).
    sink.writeByte(tagStringRef);
    _writeIntValue(sink, sessionIndex);
  } else if (tableEntry != null) {
    // Table entries start at the current session size.
    sink.writeByte(tagStringRef);
    _writeIntValue(sink, (session?.length ?? 0) + tableEntry);
  } else {
    state.recordInlineString(value);
    final bytes = utf8.encode(value);
    sink.writeByte(tagString);
    sink.writeUint32(bytes.length);
    sink.writeBytes(bytes);
  }
}

/// Writes [value] as a canonical integer value (SmallInt / Int32 / Int64),
/// used for StringRef ids (§9.6).
void _writeIntValue(BtoonSink sink, int value) {
  if (value >= smallIntMin && value <= smallIntMax) {
    sink.writeByte(smallIntBias + value);
  } else if (value >= -2147483648 && value <= 2147483647) {
    sink.writeByte(tagInt32);
    sink.writeInt32(value);
  } else {
    sink.writeByte(tagInt64);
    sink.writeInt64(value);
  }
}

// #endregion

// #region Tagged value encoding

void _encodeValue(Object? value, _EncodeState state, BtoonSink? sink,
    {bool typedArrays = true, bool objectTables = true}) {
  final isCollect = sink == null;

  if (value == null) {
    if (!isCollect) sink.writeByte(tagNull);
    return;
  }
  if (value is bool) {
    if (!isCollect) sink.writeByte(value ? tagTrue : tagFalse);
    return;
  }
  if (value is int) {
    if (isCollect) return;
    if (value >= smallIntMin && value <= smallIntMax) {
      sink.writeByte(smallIntBias + value);
    } else if (value >= -2147483648 && value <= 2147483647) {
      sink.writeByte(tagInt32);
      sink.writeInt32(value);
    } else if (isInInt64Range(value)) {
      sink.writeByte(tagInt64);
      sink.writeInt64(value);
    } else {
      throw BtoonEncodeError('integer out of int64 range', value);
    }
    return;
  }
  if (value is double) {
    if (isCollect) return;
    // §9.4: the narrowest lossless float width. Floating zero is a float
    // too, so 0.0 and -0.0 keep their type (and -0.0 its sign bit) instead
    // of collapsing into the integer SmallInt 0.
    if (isLosslessFloat32(value)) {
      sink.writeByte(tagFloat32);
      sink.writeFloat32(value);
    } else {
      sink.writeByte(tagFloat64);
      sink.writeFloat64(value);
    }
    return;
  }
  if (value is String) {
    _emitString(value, state, sink);
    return;
  }
  if (value is Uint8List) {
    if (!isCollect) {
      sink.writeByte(tagBinary);
      sink.writeUint32(value.length);
      sink.writeBytes(value);
    }
    return;
  }
  if (value is BtoonBinary) {
    if (!isCollect) {
      sink.writeByte(tagBinary);
      sink.writeUint32(value.bytes.length);
      sink.writeBytes(value.bytes);
    }
    return;
  }
  if (value is BtoonTypedArray) {
    if (!isCollect) _writeTypedArray(sink, value.values, value.elementType);
    return;
  }
  if (value is BtoonObjectTable) {
    // Rows are already typed maps — encode directly, no defensive copy.
    final plan = _objectTablePlan(value.rows, state);
    if (plan != null) {
      _encodeObjectTable(plan.rows, state, sink,
          fields: plan.fields, columnTypes: plan.columnTypes);
    } else {
      // Not a valid table — the direct encoding reports the offending
      // column.
      _encodeObjectTable(value.rows, state, sink);
    }
    return;
  }
  if (value is BtoonExtension) {
    if (!isCollect) {
      sink.writeByte(value.tag);
      sink.writeUint32(value.payload.length);
      sink.writeBytes(value.payload);
    }
    return;
  }
  if (value is List) {
    if (value.isEmpty) {
      if (!isCollect) {
        sink.writeByte(tagArray);
        sink.writeUint32(0);
      }
      return;
    }
    if (typedArrays) {
      final scan = _typedArrayScan(value, state);
      if (scan.type != null) {
        if (!isCollect) {
          _emitScannedTypedArray(sink, value, scan);
        }
        return;
      }
    }
    if (objectTables) {
      final plan = _objectTablePlan(value, state);
      if (plan != null) {
        _encodeObjectTable(plan.rows, state, sink,
            fields: plan.fields, columnTypes: plan.columnTypes);
        return;
      }
    }
    if (!isCollect) {
      sink.writeByte(tagArray);
      sink.writeUint32(value.length);
    }
    for (final item in value) {
      _encodeValue(item, state, sink,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    }
    return;
  }
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw BtoonEncodeError('map keys must be strings', key);
      }
      keys.add(key);
    }
    // Keys are sorted by their UTF-8 byte sequence (§17).
    sortUtf8(keys);
    if (!isCollect) {
      sink.writeByte(tagObject);
      sink.writeUint32(keys.length);
    }
    for (final key in keys) {
      _emitString(key, state, sink);
      _encodeValue(value[key], state, sink,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    }
    return;
  }
  throw BtoonEncodeError('unsupported value type: ${value.runtimeType}', value);
}

// #endregion

// #region TypedArray

/// Result of scanning a list for a TypedArray encoding (memoized across the
/// collect and emit passes).
class _ListScan {
  /// Element type, or null when the list is not a homogeneous numeric
  /// array (falls through to ObjectTable / general array).
  final BtoonElementType? type;

  /// Prebuilt float32/float64 buffer when [type] is a float type; null for
  /// integer types (written per element).
  final TypedData? buffer;

  const _ListScan(this.type, this.buffer);
}

/// Single-pass scan of [list]: classifies it as an int or double typed
/// array, choosing the narrowest lossless element type and, for doubles,
/// building the conversion buffer in the same pass. Statically-typed lists
/// get a specialized loop without per-element dynamic dispatch.
_ListScan _scanTypedArray(List<dynamic> list) {
  if (list is List<int>) return _scanIntList(list);
  if (list is List<double>) return _scanDoubleList(list);
  return _scanMixedList(list);
}

_ListScan _scanIntList(List<int> list) {
  var min = 0;
  var max = 0;
  for (var i = 0; i < list.length; i++) {
    final e = list[i];
    if (e < int64Min || e > int64Max) return const _ListScan(null, null);
    if (i == 0) {
      min = max = e;
    } else if (e < min) {
      min = e;
    } else if (e > max) {
      max = e;
    }
  }
  var type = bestIntElementTypeForRange(min, max);
  if (type == null) return const _ListScan(null, null);
  // uint64 is not a valid TypedArray selector (§12); the values fit int64.
  if (type == BtoonElementType.uint64) type = BtoonElementType.int64;
  return _ListScan(type, null);
}

_ListScan _scanDoubleList(List<double> list) {
  final length = list.length;
  final f32 = Float32List(length);
  var lossless32 = true;
  for (var i = 0; i < length; i++) {
    final e = list[i];
    f32[i] = e;
    if (lossless32 && f32[i] != e) lossless32 = false;
  }
  if (lossless32) return _ListScan(BtoonElementType.float32, f32);
  // Rare path: rebuild as float64 (NaN payloads and out-of-float32 values).
  final f64 = Float64List(length);
  for (var i = 0; i < length; i++) {
    f64[i] = list[i];
  }
  return _ListScan(BtoonElementType.float64, f64);
}

_ListScan _scanMixedList(List<dynamic> list) {
  var allInt = true;
  var allDouble = true;
  var min = 0;
  var max = 0;
  Float32List? f32;
  Float64List? f64;
  var lossless32 = true;
  final length = list.length;
  for (var i = 0; i < length; i++) {
    final e = list[i];
    if (e is int) {
      allDouble = false;
      if (e < int64Min || e > int64Max) return const _ListScan(null, null);
      if (i == 0) {
        min = max = e;
      } else if (e < min) {
        min = e;
      } else if (e > max) {
        max = e;
      }
    } else if (e is double) {
      allInt = false;
      f64 ??= Float64List(length);
      f64[i] = e;
      f32 ??= Float32List(length);
      f32[i] = e;
      if (lossless32 && f32[i] != e) lossless32 = false;
    } else {
      return const _ListScan(null, null);
    }
  }
  if (allInt) {
    var type = bestIntElementTypeForRange(min, max);
    if (type == null) return const _ListScan(null, null);
    // uint64 is not a valid TypedArray selector (§12); the values fit int64.
    if (type == BtoonElementType.uint64) type = BtoonElementType.int64;
    return _ListScan(type, null);
  }
  if (allDouble) {
    if (lossless32) return _ListScan(BtoonElementType.float32, f32);
    return _ListScan(BtoonElementType.float64, f64);
  }
  return const _ListScan(null, null);
}

/// Memoized [_ListScan] for [list] within one encode.
_ListScan _typedArrayScan(List<dynamic> list, _EncodeState state) {
  final cached = state.scanCache[list];
  if (cached is _ListScan) return cached;
  final scan = _scanTypedArray(list);
  state.scanCache[list] = scan;
  return scan;
}

/// Emits a TypedArray for a scan that already classified [list] (and, for
/// float types, prebuilt its buffer).
void _emitScannedTypedArray(
  BtoonSink sink,
  List<dynamic> list,
  _ListScan scan,
) {
  final type = scan.type!;
  sink.writeByte(tagTypedArray);
  sink.writeByte(elementTagOf(type));
  sink.writeUint32(list.length);
  // PadLen counts the zero bytes that follow it (§16); the shared helper
  // accounts for the PadLen byte itself.
  final padLen = sink.padLengthFor(type.size);
  sink.writeByte(padLen);
  sink.writePadding(padLen);
  final buffer = scan.buffer;
  if (buffer != null) {
    sink.writeBytes(Uint8List.sublistView(buffer));
  } else {
    writeRawNumericData(sink, asNumList(list), type);
  }
}

void _writeTypedArray(
  BtoonSink sink,
  List<num> values,
  BtoonElementType? forced,
) {
  final type = forced ?? bestNumericElementType(values);
  if (type == BtoonElementType.uint64) {
    throw BtoonEncodeError(
      'uint64 is not a valid TypedArray element type (only 0x00..0x08)',
      values,
    );
  }
  if (forced != null) validateNumericRange(values, type);
  _emitTypedArray(sink, values, type);
}

/// Writes a TypedArray whose [values] are already known to fit [type]
/// (auto-detected element types guarantee this; user-supplied types go
/// through [_writeTypedArray], which validates).
void _emitTypedArray(
  BtoonSink sink,
  List<num> values,
  BtoonElementType type,
) {
  sink.writeByte(tagTypedArray);
  sink.writeByte(elementTagOf(type));
  sink.writeUint32(values.length);
  // PadLen counts the zero bytes that follow it (§16), so account for the
  // PadLen byte itself when computing how many remain to align the buffer.
  final padLen = sink.padLengthFor(type.size);
  sink.writeByte(padLen);
  sink.writePadding(padLen);
  writeRawNumericData(sink, values, type);
}

// #endregion

// #region ObjectTable

/// Memoized [ObjectTablePlan] for [list] within one encode, so the collect
/// and emit passes classify each table once.
ObjectTablePlan? _objectTablePlan(List<dynamic> list, _EncodeState state) {
  final cached = state.scanCache[list];
  if (cached is ObjectTablePlan) return cached;
  if (cached is _NullPlan) return null;
  final plan = buildObjectTablePlan(list);
  state.scanCache[list] = plan ?? const _NullPlan();
  return plan;
}

/// Cache sentinel for lists that do not qualify as ObjectTables (null is
/// ambiguous with an absent cache entry).
class _NullPlan {
  const _NullPlan();
}

void _encodeObjectTable(
  List<Map<dynamic, dynamic>> rows,
  _EncodeState state,
  BtoonSink? sink, {
  List<String>? fields,
  Map<String, BtoonElementType>? columnTypes,
}) {
  final isCollect = sink == null;
  final resolvedFields = fields ?? objectTableFields(rows);

  if (!isCollect) {
    sink.writeByte(tagObjectTable);
    sink.writeUint32(rows.length);
    sink.writeUint32(resolvedFields.length);
  }
  for (final field in resolvedFields) {
    final columnType = columnTypes?[field] ?? columnElementType(rows, field);
    if (columnType == null) {
      throw BtoonEncodeError(
        'ObjectTable column "$field" must be a homogeneous numeric column',
        rows,
      );
    }
    final session = state.session;
    if (session != null &&
        session.length > 0 &&
        session.indexOf(field) == null) {
      // With the session flag (0x08) set, column names MUST be StringRefs
      // (§14); force the name into the per-message table so it can be
      // referenced (and so the no-table flag 0x10 is not set).
      state.forceTableString(field);
    } else {
      state.recordString(field);
    }
    if (!isCollect) {
      _emitString(field, state, sink);
      sink.writeByte(elementTagOf(columnType));
      final padLen = sink.padLengthFor(columnType.size);
      sink.writeByte(padLen);
      sink.writePadding(padLen);
      _writeColumnValues(sink, rows, field, columnType);
    }
  }
}

/// Writes a single ObjectTable column by reading each row's value for
/// [field] directly — no intermediate column list.
void _writeColumnValues(
  BtoonSink sink,
  List<Map<dynamic, dynamic>> rows,
  String field,
  BtoonElementType type,
) {
  final n = rows.length;
  switch (type) {
    case BtoonElementType.float64:
      final buffer = Float64List(n);
      for (var i = 0; i < n; i++) {
        buffer[i] = rows[i][field] as double;
      }
      sink.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.float32:
      final buffer = Float32List(n);
      for (var i = 0; i < n; i++) {
        buffer[i] = rows[i][field] as double;
      }
      sink.writeBytes(Uint8List.sublistView(buffer));
    case BtoonElementType.int8:
    case BtoonElementType.uint8:
      for (var i = 0; i < n; i++) {
        sink.writeByte(rows[i][field] as int);
      }
    case BtoonElementType.int16:
    case BtoonElementType.uint16:
      for (var i = 0; i < n; i++) {
        sink.writeInt16(rows[i][field] as int);
      }
    case BtoonElementType.int32:
    case BtoonElementType.uint32:
      for (var i = 0; i < n; i++) {
        sink.writeInt32(rows[i][field] as int);
      }
    case BtoonElementType.int64:
    case BtoonElementType.uint64:
      for (var i = 0; i < n; i++) {
        sink.writeInt64(rows[i][field] as int);
      }
  }
}

// #endregion

// #region Schema

void _writeSchema(BtoonSink sink, BtoonSchema schema, bool idUint16) {
  if (idUint16) {
    if (schema.id < 0 || schema.id > 0xFFFF) {
      throw BtoonEncodeError('schema id does not fit UInt16', schema.id);
    }
    sink.writeUint16(schema.id);
  } else {
    if (schema.id < 0 || schema.id > 0xFFFFFFFF) {
      throw BtoonEncodeError('schema id does not fit UInt32', schema.id);
    }
    sink.writeUint32(schema.id);
  }
  final name = utf8.encode(schema.name);
  sink.writeUint32(name.length);
  sink.writeBytes(name);
  sink.writeUint32(schema.fields.length);
  for (final field in schema.fields) {
    final bytes = utf8.encode(field.name);
    sink.writeUint32(bytes.length);
    sink.writeBytes(bytes);
    sink.writeByte(field.code);
  }
}

void _encodeSchemaBody(
  Object? value,
  BtoonSchema schema,
  _EncodeState state,
  BtoonSink? sink,
) {
  final isCollect = sink == null;
  if (!isCollect) {
    if (state.schemaIdUint16) {
      if (schema.id < 0 || schema.id > 0xFFFF) {
        throw BtoonEncodeError('schema id does not fit UInt16', schema.id);
      }
      sink.writeUint16(schema.id);
    } else {
      if (schema.id < 0 || schema.id > 0xFFFFFFFF) {
        throw BtoonEncodeError('schema id does not fit UInt32', schema.id);
      }
      sink.writeUint32(schema.id);
    }
  }

  if (value is Map) {
    _encodeSchemaFields(_stringKeyMap(value), schema, state, sink);
    return;
  }
  if (value is List) {
    for (final element in value) {
      if (element is! Map) {
        throw BtoonEncodeError(
          'schema mode rows must be maps',
          element,
        );
      }
      _encodeSchemaFields(_stringKeyMap(element), schema, state, sink);
    }
    return;
  }
  throw BtoonEncodeError(
    'schema mode requires a map or a list of maps at the root',
    value,
  );
}

void _encodeSchemaFields(
  Map<String, dynamic> map,
  BtoonSchema schema,
  _EncodeState state,
  BtoonSink? sink,
) {
  for (final field in schema.fields) {
    _encodeSchemaFieldValue(field, map[field.name], state, sink);
  }
}

void _encodeSchemaFieldValue(
  BtoonSchemaField field,
  Object? value,
  _EncodeState state,
  BtoonSink? sink,
) {
  final isCollect = sink == null;
  switch (field.code) {
    case elementNull:
      if (value != null) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects null',
          value,
        );
      }
    case elementBool:
      if (value is! bool) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a bool',
          value,
        );
      }
      if (!isCollect) sink.writeByte(value ? 1 : 0);
    case elementString:
      if (value is! String) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a string',
          value,
        );
      }
      _emitString(value, state, sink);
    case elementBinary:
      final bytes = _binaryBytes(value);
      if (bytes == null) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects binary',
          value,
        );
      }
      if (!isCollect) {
        sink.writeByte(tagBinary);
        sink.writeUint32(bytes.length);
        sink.writeBytes(bytes);
      }
    case elementArray:
    case elementObject:
      _encodeValue(value, state, sink,
          typedArrays: state.typedArrays, objectTables: state.objectTables);
    case elementFloat32:
    case elementFloat64:
      if (value is! num) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects a number',
          value,
        );
      }
      if (!isCollect) _writeSchemaNumeric(sink, field.code, value);
    default:
      if (value is! int) {
        throw BtoonEncodeError(
          'schema field "${field.name}" expects an integer',
          value,
        );
      }
      if (!isCollect) _writeSchemaNumeric(sink, field.code, value);
  }
}

/// Writes a single fixed-width numeric schema field value of [code].
///
/// The value is checked against the declared width first: a schema body is a
/// struct-cast over the wire, so a value that does not fit its field would
/// otherwise be silently truncated (§15.2).
void _writeSchemaNumeric(BtoonSink sink, int code, num value) {
  if (value is int) {
    _checkSchemaIntegerWidth(code, value);
  }
  switch (code) {
    case elementInt8:
    case elementUint8:
      sink.writeByte(value.toInt());
    case elementInt16:
    case elementUint16:
      sink.writeUint16(value.toInt());
    case elementInt32:
    case elementUint32:
      sink.writeUint32(value.toInt());
    case elementInt64:
    case elementUint64:
      sink.writeUint64(value.toInt());
    case elementFloat32:
      sink.writeFloat32(value.toDouble());
    case elementFloat64:
      sink.writeFloat64(value.toDouble());
    default:
      throw BtoonEncodeError('invalid schema element-type code $code');
  }
}

/// Throws when [value] does not fit the integer width declared by [code].
void _checkSchemaIntegerWidth(int code, int value) {
  bool fits(int min, int max) {
    if (value >= min && value <= max) return true;
    throw BtoonEncodeError(
      'value $value does not fit the schema field width '
      '(${_schemaWidthName(code)})',
      value,
    );
  }

  switch (code) {
    case elementInt8:
      fits(-128, 127);
    case elementUint8:
      fits(0, 0xFF);
    case elementInt16:
      fits(-32768, 32767);
    case elementUint16:
      fits(0, 0xFFFF);
    case elementInt32:
      fits(-2147483648, 2147483647);
    case elementUint32:
      fits(0, 0xFFFFFFFF);
    case elementInt64:
    case elementUint64:
      if (!isInInt64Range(value)) {
        throw BtoonEncodeError(
          'value $value does not fit the schema field width (int64)',
          value,
        );
      }
    case elementFloat32:
    case elementFloat64:
      break;
    default:
      throw BtoonEncodeError('invalid schema element-type code $code');
  }
}

String _schemaWidthName(int code) {
  switch (code) {
    case elementInt8:
      return 'int8';
    case elementUint8:
      return 'uint8';
    case elementInt16:
      return 'int16';
    case elementUint16:
      return 'uint16';
    case elementInt32:
      return 'int32';
    case elementUint32:
      return 'uint32';
    case elementInt64:
      return 'int64';
    case elementUint64:
      return 'int64';
    default:
      return 'numeric';
  }
}

// #endregion

// #region Schema derivation

/// Derives a [BtoonSchema] from [value] by inspecting map keys and value
/// types, or returns null when [value] is neither a `Map` nor a `List` of
/// maps.
///
/// Fields are the sorted union of all keys; each field's type is inferred
/// from the first non-null value seen across the rows.
BtoonSchema? deriveBtoonSchema(Object? value) => _deriveSchema(value);

Map<String, dynamic> _stringKeyMap(Map<dynamic, dynamic> map) {
  final result = <String, dynamic>{};
  map.forEach((key, value) {
    if (key is! String) {
      throw BtoonEncodeError('map keys must be strings', key);
    }
    result[key] = value;
  });
  return result;
}

BtoonSchema? _deriveSchema(Object? value) {
  List<Map<dynamic, dynamic>> rows;
  if (value is Map) {
    _validateStringKeys(value);
    rows = [value];
  } else if (value is List) {
    rows = <Map<dynamic, dynamic>>[];
    for (final element in value) {
      if (element is! Map) return null;
      _validateStringKeys(element);
      rows.add(element);
    }
  } else {
    return null;
  }

  final keySet = <String>{};
  for (final row in rows) {
    for (final key in row.keys) {
      if (key is String) keySet.add(key);
    }
  }
  final keys = keySet.toList();
  sortUtf8(keys);
  final fields = <BtoonSchemaField>[];
  for (final key in keys) {
    var type = BtoonSchemaType.null_;
    for (final row in rows) {
      final rowValue = row[key];
      if (rowValue != null) {
        type = _inferType(rowValue);
        break;
      }
    }
    fields.add(BtoonSchemaField(key, type: type));
  }
  return BtoonSchema(fields);
}

/// Validates that every key of [map] is a string.
void _validateStringKeys(Map<dynamic, dynamic> map) {
  for (final key in map.keys) {
    if (key is! String) {
      throw BtoonEncodeError('map keys must be strings', key);
    }
  }
}

BtoonSchemaType _inferType(Object? value) {
  if (value is bool) return BtoonSchemaType.boolean;
  if (value is int) return BtoonSchemaType.integer;
  if (value is double) return BtoonSchemaType.number;
  if (value is String) return BtoonSchemaType.string;
  if (value is Uint8List || value is BtoonBinary) return BtoonSchemaType.binary;
  if (value is List) return BtoonSchemaType.array;
  if (value is Map) return BtoonSchemaType.object;
  return BtoonSchemaType.any;
}

Uint8List? _binaryBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is BtoonBinary) return value.bytes;
  return null;
}

// #endregion
