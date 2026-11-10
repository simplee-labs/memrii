// User actions on the new pipeline (RECORDINGS_PIPELINE_REDESIGN.md §7), each one journaled
// transaction through the coordinator. A user action never waits for a job, and a job
// never needs to be told: its own transaction fails the generation or ownership check.
//
// Only actions that change ownership are here. Deleting, cropping, re-dating or
// re-filing a published recording, retention and passthrough change archive files only:
// the ledger names a recording by its identity when published, and audio owned by a
// recording and audio owned by a deletion have the same effect everywhere (the planner,
// the gate, Reprocess all), so none of them touches the ledger. Discards differ: the gate
// keeps their audio until they are deleted, recovered or expire, which is what hands it
// on here.
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:io';

import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';

const int _minValidEpochSeconds = 946684800;

/// Who owns audio the user deleted (a derived deletion: Reprocess all revokes it, R5).
const deletedDiscard = Owner(OwnerKind.deletion, 'discard');
const deletedByDebug = Owner(OwnerKind.deletion, 'debug');

enum RecoverStop {
  /// Published as one recording.
  recovered,

  /// The discards held no audio still on the phone (muted intervals with nothing
  /// recorded, or audio deleted at its source): they were deleted, as today.
  nothingToRecover,

  /// A discard was deleted, recovered or its file deleted meanwhile; nothing changed.
  stale,

  cancelled,
  storageFull,
  failed,
}

class RecoverResult {
  final RecoverStop stop;

  /// The recording's audio, relative to the documents directory, when recovered.
  final String? published;
  final Object? error;
  const RecoverResult(this.stop, {this.published, this.error});
}

/// A discard record found in the archive.
class _Discard {
  final String id;
  final String date;
  final Map<String, Object?> record;
  _Discard(this.id, this.date, this.record);

  int get startMs => record['startMs']! as int;
  int get endMs => record['endMs']! as int;

  /// Every file whose frames or mute-on it may own: its ranges' files and its id's.
  Set<RawFileKey> get keys => {
        for (final rel in ((record['binRanges'] as Map?) ?? const {}).keys) RawFileKey.fromRel(rel as String),
        RawFileKey.fromRel(id.split('@').first),
      }.whereType<RawFileKey>().toSet();
}

class ArchiveActions {
  final OwnershipCoordinator coordinator;

  ArchiveActions(this.coordinator);

  String get _docs => coordinator.documentsPath;

  Map<String, List<RawFileKey>> _byDay(Iterable<RawFileKey> keys) {
    final out = <String, List<RawFileKey>>{};
    for (final k in keys) {
      out.putIfAbsent(ledgerDayOf(k), () => []).add(k);
    }
    return out;
  }

  /// The date folders of the archive.
  Future<List<String>> _dates() async {
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return const [];
    return [
      await for (final e in root.list(followLinks: false))
        if (e is Directory) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)
    ];
  }

  /// The discard records with an id, in every date folder, optionally only [ids].
  Future<List<_Discard>> _discards([Set<String>? ids]) async {
    final out = <_Discard>[];
    for (final date in await _dates()) {
      for (final r in await coordinator.readDiscardLines(date)) {
        final id = r['id'];
        if (id is String && (ids == null || ids.contains(id))) out.add(_Discard(id, date, r));
      }
    }
    return out;
  }

  /// Takes [ds] out of the archive and hands their audio to a derived deletion.
  List<JournalOp> _dropDiscards(List<_Discard> ds) {
    final byDate = <String, List<String>>{};
    for (final d in ds) {
      byDate.putIfAbsent(d.date, () => []).add(d.id);
    }
    return [
      for (final e in byDate.entries) RemoveDiscardsOp(e.key, e.value),
      for (final e in _byDay({for (final d in ds) ...d.keys}).entries)
        TransferOp(e.key, e.value, [for (final d in ds) Owner(OwnerKind.discard, d.id)], deletedDiscard),
    ];
  }

  /// Delete Discard: the records go and their audio becomes a derived deletion, which the
  /// gate can release. Returns how many were found.
  Future<int> deleteDiscards(Iterable<String> ids) => coordinator.transact('deleteDiscards', () async {
        final ds = await _discards(ids.toSet());
        return (_dropDiscards(ds), ds.length);
      });

  /// Discard expiry: the records whose 48-hour window has passed by [nowMs], as Delete
  /// Discard.
  Future<int> expireDiscards({required int nowMs}) => coordinator.transact('expireDiscards', () async {
        final window = DiscardRecord.discardRetentionWindow.inMilliseconds;
        final ds = [
          for (final d in await _discards())
            if (d.endMs + window <= nowMs) d
        ];
        return (_dropDiscards(ds), ds.length);
      });

  /// Recover (§7): the discards [ids] (one row, which may coalesce several) rendered as
  /// one recording, VAD off, no split and no padding as today, published in their place
  /// in one transaction. [cards] must hold their files' cards.
  Future<RecoverResult> recoverDiscards(
    List<String> ids, {
    required Map<RawFileKey, FileCard> cards,
    required FrameDecoder Function() newDecoder,
    required PublishSettings settings,
    AudioEncoder? encoder,
    Future<int?> Function()? freeBytes,
    bool Function()? isCancelled,
  }) async {
    // What the discards own, as the ledger has it now, in files still on the phone: one
    // deleted at its source (tombstoned, perhaps released since) has nothing to recover.
    final found = await coordinator.transact('recover-read', () async {
      final ds = await _discards(ids.toSet())
        ..sort((a, b) => a.startMs.compareTo(b.startMs));
      final keys = {for (final d in ds) ...d.keys};
      final entries = await coordinator.ledger.entriesFor(keys);
      entries.removeWhere((k, e) => e.tombstone != null || e.receipt != null);
      final generation = (await coordinator.ledger.loadStream()).generation;
      return (const <JournalOp>[], (ds, entries, generation));
    });
    final (ds, entries, generation) = found;
    if (ds.length != ids.toSet().length) return const RecoverResult(RecoverStop.stale);

    final pieces = <PlanPiece>[];
    final bytes = <RawFileKey, List<(int, int)>>{};
    final markerKeys = <RawFileKey>{};
    for (final d in ds) {
      final owner = Owner(OwnerKind.discard, d.id);
      for (final key in d.keys.toList()..sort(compareKeys)) {
        final entry = entries[key];
        if (entry == null) continue;
        if (entry.events.values.contains(owner)) markerKeys.add(key);
        for (final r in entry.frames.where((r) => r.owner == owner)) {
          final card = cards[key];
          if (card == null) throw StateError('${key.rel}: no card to recover from');
          final offsets = card.records.frameOffsets;
          final first = _lowerBound(offsets, r.start), end = _lowerBound(offsets, r.end);
          if (first >= end) continue;
          bytes.putIfAbsent(key, () => []).add((r.start, r.end));
          final last = pieces.isEmpty ? null : pieces.last;
          if (last is FramesPiece && last.span.key == key && last.span.end == first) {
            pieces[pieces.length - 1] = FramesPiece(FrameSpan(key, last.span.first, end));
          } else {
            pieces.add(FramesPiece(FrameSpan(key, first, end)));
          }
        }
      }
    }
    if (pieces.isEmpty) {
      // Nothing recorded (muted intervals), or its audio deleted at the source: as today,
      // the row goes.
      await deleteDiscards(ids);
      return const RecoverResult(RecoverStop.nothingToRecover);
    }
    final firstKey = (pieces.first as FramesPiece).span.key;
    final header = cards[firstKey]!.records.header;
    final frames = pieces.fold<int>(0, (n, p) => n + (p as FramesPiece).span.length);
    final recording = PlannedRecording(
      sessionId: firstKey.sessionId,
      closeType: CloseType.recovered,
      closedAt: PlanPosition(firstKey, -1),
      pieces: pieces,
      startMs: ds.first.startMs,
      startUptimeSeconds: null,
      derivedTime: !(header?.hasClock ?? false) && firstKey.timerStart < _minValidEpochSeconds,
      markers: const [],
      durationMs: frames * frameMs,
      frameCount: frames,
      silero: false,
      manual: null,
    );

    final job = await coordinator.startJob(holds: bytes.keys.toSet());
    final renderer = RecordingRenderer(
      source: (key) async => RenderSource(await coordinator.store.load(key), cards[key]!),
      newDecoder: newDecoder,
      encoder: settings.m4a ? encoder : null,
      writeSidecar: settings.opusSidecar,
      isCancelled: isCancelled,
    );
    try {
      final need = bytesToRender(recording,
          m4a: settings.m4a && encoder != null,
          sourceBytes: bytes.values.expand((r) => r).fold(0, (n, r) => n + r.$2 - r.$1),
          sidecar: settings.opusSidecar);
      final free = await freeBytes?.call();
      if (free != null && free - storageHeadroomBytes < need) return const RecoverResult(RecoverStop.storageFull);
      final RenderedRecording rendered;
      try {
        rendered = await renderer.render(recording, Directory('${job.staging.path}/recover'));
      } on RenderCancelled {
        return const RecoverResult(RecoverStop.cancelled);
      } on RenderFailed catch (e) {
        return RecoverResult(e.storageFull ? RecoverStop.storageFull : RecoverStop.failed, error: e);
      }
      if (isCancelled?.call() == true) return const RecoverResult(RecoverStop.cancelled);
      final result = await coordinator.commitRecovery(RecoveryRequest(
        job: job,
        generation: generation,
        discards: {for (final d in ds) d.id: d.date},
        recording: recording,
        rendered: rendered,
        bytes: bytes,
        markerKeys: markerKeys,
        deviceId: settings.deviceId,
      ));
      return result.accepted
          ? RecoverResult(RecoverStop.recovered, published: result.published.single)
          : const RecoverResult(RecoverStop.stale);
    } finally {
      renderer.dispose();
      await coordinator.finishJob(job);
    }
  }

  /// Delete Day: the day's recordings, discards and markers go, and every raw file the
  /// day holds is tombstoned (R5): those named by its recordings and discards, and those
  /// the Omi dated that day, chunks still to come and copies restored later included. The
  /// gate then releases them. Returns the audio files deleted, relative to the documents
  /// directory.
  Future<List<String>> deleteDay(String date, {required int nowMs}) => coordinator.transact('deleteDay', () async {
        final folder = Directory('$_docs/recordings/$date');
        final audio = <String>[];
        final keys = <RawFileKey>{};
        if (await folder.exists()) {
          await for (final e in folder.list(followLinks: false)) {
            if (e is! File) continue;
            final name = e.uri.pathSegments.last;
            if (name.endsWith('.wav') || name.endsWith('.m4a') || name.endsWith('.ogg')) {
              audio.add('recordings/$date/$name');
            }
            // Passthrough keeps metadata after its audio has been removed.
            if (name.endsWith('.meta')) {
              keys.addAll(Conversation.fromFile(e).relativeBins.map(RawFileKey.fromRel).whereType<RawFileKey>());
            }
          }
          for (final r in await coordinator.readDiscardLines(date)) {
            if (r['id'] is String) keys.addAll(_Discard(r['id']! as String, date, r).keys);
            keys.addAll(((r['binRanges'] as Map?) ?? const {})
                .keys
                .map((k) => RawFileKey.fromRel(k as String))
                .whereType<RawFileKey>());
          }
        }
        for (final k in await coordinator.store.listKeys()) {
          if (k.timerStart >= _minValidEpochSeconds && localDateOf(k.timerStart * 1000) == date) keys.add(k);
        }
        // Markers are listed by their own date, but filed beside their recording: one
        // tapped this day may sit in another day's folder.
        final strays = <String>[];
        for (final other in await _dates()) {
          if (other == date) continue;
          await for (final e in Directory('$_docs/recordings/$other').list(followLinks: false)) {
            final name = e.uri.pathSegments.last;
            if (e is! File || !name.startsWith('marker_') || !name.endsWith('.edl')) continue;
            final ms = edlMarkerMs(await e.readAsString());
            if (ms != null && localDateOf(ms) == date) strays.add('recordings/$other/$name');
          }
        }
        final tombstone = Tombstone(nowMs, 'deleteDay');
        return (
          <JournalOp>[
            for (final e in _byDay(keys).entries) TombstoneOp(e.key, e.value, tombstone),
            StreamOp(release: keys.toList()),
            DeletePathsOp(['recordings/$date', ...strays]),
          ],
          audio,
        );
      });

  /// Delete, for a raw or set-aside file: tombstoned, and out of the set-aside list.
  Future<void> deleteRawFile(RawFileKey key, {required int nowMs}) => coordinator.transact(
      'deleteRaw',
      () async => (
            <JournalOp>[
              TombstoneOp(ledgerDayOf(key), [key], Tombstone(nowMs, 'deleteFile')),
              StreamOp(release: [key]),
            ],
            null
          ));

  /// Sets [key] aside after repeated failures: its markers still count, its frames wait.
  Future<void> setAside(RawFileKey key) => coordinator.transact(
      'setAside',
      () async => (
            <JournalOp>[
              StreamOp(setAside: [key])
            ],
            null
          ));

  /// Try again: out of the set-aside list, and its card built again from its chunks.
  Future<void> tryAgain(RawFileKey key) => coordinator.transact(
      'tryAgain',
      () async => (
            <JournalOp>[
              StreamOp(release: [key]),
              DeletePathsOp([cardFileFor(coordinator.store, key).path.substring(_docs.length + 1)]),
            ],
            null
          ));

  /// Force / finish early: a boundary at the end of what is here in each session the
  /// caller names; holes before it are waived, and what is open there closes.
  Future<void> force(List<PlanBoundary> boundaries) =>
      coordinator.transact('force', () async => (<JournalOp>[StreamOp(boundaries: boundaries)], null));

  /// The Priority Recording cap setting, as it changed.
  Future<void> recordCap({required int atMs, required int minutes}) =>
      coordinator.transact('cap', () async => (<JournalOp>[StreamOp(cap: (atMs: atMs, minutes: minutes))], null));

  /// Debug: Delete Phone Conversations. The archive goes; everything not yet owned, and
  /// every discard's audio, becomes a derived deletion.
  Future<void> deletePhoneConversations() => coordinator.transact('deletePhoneConversations', () async {
        final keys = await coordinator.store.listKeys();
        final entries = await coordinator.ledger.entriesFor(keys);
        final claims = <String, List<Claim>>{};
        final discards = <String, (Set<RawFileKey>, Set<Owner>)>{};
        for (final key in keys) {
          final entry = entries[key];
          if (entry?.tombstone != null || entry?.receipt != null) continue;
          final file = await coordinator.store.load(key);
          final records = parseRecords(await file.read(0, file.length));
          final ranges = <(int, int)>[];
          int? runStart;
          for (var i = 0; i <= records.frameCount; i++) {
            final owned = i < records.frameCount &&
                (entry?.frames.any((r) => r.start <= records.frameOffsets[i] && records.frameOffsets[i] < r.end) ??
                    false);
            final open = i < records.frameCount && !owned;
            if (open && runStart == null) runStart = i;
            if (!open && runStart != null) {
              ranges.add(byteRangeOf(records, runStart, i));
              runStart = null;
            }
          }
          final markers = [
            for (final e in records.events)
              if ((e.kind == CardEventKind.tap ||
                      e.kind == CardEventKind.priorityStart ||
                      e.kind == CardEventKind.muteOn) &&
                  !(entry?.events.containsKey(e.offset) ?? false))
                e.offset
          ];
          if (ranges.isNotEmpty || markers.isNotEmpty) {
            claims.putIfAbsent(ledgerDayOf(key), () => []).add(Claim(key, deletedByDebug, ranges, markers));
          }
          final owners = {
            for (final r in entry?.frames ?? const <OwnedRange>[])
              if (r.owner.kind == OwnerKind.discard) r.owner,
            for (final o in entry?.events.values ?? const <Owner>[])
              if (o.kind == OwnerKind.discard) o,
          };
          if (owners.isNotEmpty) {
            final day = discards.putIfAbsent(ledgerDayOf(key), () => (<RawFileKey>{}, <Owner>{}));
            day.$1.add(key);
            day.$2.addAll(owners);
          }
        }
        return (
          <JournalOp>[
            for (final e in discards.entries)
              TransferOp(e.key, e.value.$1.toList(), e.value.$2.toList(), deletedByDebug),
            for (final e in claims.entries) ClaimOp(e.key, e.value, const []),
            const DeletePathsOp(['recordings']),
          ],
          null
        );
      });

  /// Debug: Delete Phone Segments. Every logical file is tombstoned, so a copy restored
  /// later is never processed again, and keeps a receipt of its markers; the raw roots go.
  Future<void> deletePhoneSegments({required int nowMs}) => coordinator.transact('deletePhoneSegments', () async {
        final keys = await coordinator.store.listKeys();
        final entries = await coordinator.ledger.entriesFor(keys);
        final ops = <JournalOp>[];
        for (final key in keys) {
          if (entries[key]?.receipt != null) continue;
          final file = await coordinator.store.load(key);
          if (file.chunks.isEmpty) continue;
          final records = parseRecords(await file.read(0, file.length));
          ops.add(ReceiptOp(
            Receipt(
              length: file.length,
              lifecycle: file.lifecycle,
              advertisedLength: file.advertisedLength,
              firstSealedAtMs: file.firstSealedAtMs,
              provenance: [for (final c in file.chunks) c.provenance],
            ),
            EventSummary(
              key: key,
              length: records.length,
              frameCount: records.frameCount,
              firstFrameOffset: records.frameCount == 0 ? null : records.frameOffsets[0],
              events: records.events,
              hasVad: entries[key]?.summary?.hasVad ?? true,
            ),
          ));
        }
        final tombstone = Tombstone(nowMs, 'deletePhoneSegments');
        return (
          <JournalOp>[
            for (final e in _byDay(keys).entries) TombstoneOp(e.key, e.value, tombstone),
            ...ops,
            const DeletePathsOp(['raw_segments', 'discarded_segments']),
          ],
          null
        );
      });

  /// Reprocess all (Adjustment Mode): the generation advances, so every job planned
  /// before is dropped at its commit (R3); the archive goes; every owner but tombstones
  /// is cleared, so deleted recordings and discards come back if their audio remains
  /// (the I4 exception); and a rebuild end closes each session at the end of what is
  /// here, so the rebuild finishes without waiting for missing audio. Returns the new
  /// generation.
  Future<int> reprocessAll() => coordinator.transact('reprocessAll', () async {
        final generation = (await coordinator.ledger.loadStream()).generation + 1;
        final last = <int?, RawFileKey>{};
        for (final k in await coordinator.store.listKeys()) {
          final had = last[k.sessionId];
          if (had == null || compareKeys(k, had) > 0) last[k.sessionId] = k;
        }
        final ends = [
          for (final k in last.values)
            PlanBoundary(BoundaryKind.rebuildEnd, k, (await coordinator.store.load(k)).length)
        ];
        final days = <String>[];
        if (await coordinator.ledger.dir.exists()) {
          await for (final e in coordinator.ledger.dir.list(followLinks: false)) {
            final name = e.uri.pathSegments.last;
            if (e is File && name.endsWith('.json') && name != 'stream.json') {
              days.add(name.substring(0, name.length - 5));
            }
          }
        }
        return (
          <JournalOp>[
            SetGenerationOp(generation),
            const DeletePathsOp(['recordings']),
            for (final d in days) ClearOwnershipOp(d),
            StreamOp(boundaries: ends),
          ],
          generation
        );
      });

  /// Save original file: the logical file's bytes, its chunks in order, into [out].
  Future<void> exportRaw(RawFileKey key, File out) async {
    final file = await coordinator.store.load(key);
    final sink = out.openWrite();
    try {
      for (final c in file.chunks) {
        await sink.addStream(File(c.path).openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}

int _lowerBound(List<int> sorted, int value) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] < value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
