// The coordinator (RECORDINGS_PIPELINE_REDESIGN.md §4): the one place ownership changes.
//
// Publication is one transaction per batch of closed items. A job renders them into its
// staging (`processing_temp/<job>/`); the coordinator, in the archive edit queue, checks
// that the generation still matches and that every range and marker is still unowned and
// not tombstoned, reserves names, writes the metas into staging, journals the transaction
// (`ownership_journal.json`), applies it and deletes the journal. A job hands over
// finished staging and the coordinator commits it or drops it: no acknowledgement
// protocol, no run epoch, no checkpoint.
//
// Every operation is idempotent, so recovery (at startup and before every transaction)
// simply applies a journal it finds, then deletes staging no live job owns. A transaction
// is either rejected with nothing written, or journaled and then always completed.
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';
import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';

/// Runs [body] in the archive edit queue.
typedef EditQueue = Future<T> Function<T>(Future<T> Function() body);

/// One step of a transaction. Applying it again has the same result.
sealed class JournalOp {
  const JournalOp();

  Map<String, Object?> toJson();

  static JournalOp fromJson(Map<String, Object?> j) => switch (j['op']) {
        'move' => MoveOp(j['from']! as String, j['to']! as String),
        'writeJson' => WriteJsonOp(j['path']! as String, (j['json']! as Map).cast()),
        'upsertDiscards' => UpsertDiscardsOp(
            j['date']! as String, [for (final r in (j['records']! as List)) (r as Map).cast<String, Object?>()]),
        'claim' => ClaimOp(
            j['day']! as String,
            [for (final c in (j['claims']! as List)) Claim.fromJson((c as Map).cast())],
            [for (final s in (j['summaries']! as List)) EventSummary.fromJson((s as Map).cast())],
          ),
        'setGeneration' => SetGenerationOp(j['generation']! as int),
        _ => throw FormatException('unknown journal op ${j['op']}'),
      };
}

/// Renames a staged file into the archive. Paths are relative to the documents directory.
class MoveOp extends JournalOp {
  final String from;
  final String to;
  const MoveOp(this.from, this.to);
  @override
  Map<String, Object?> toJson() => {'op': 'move', 'from': from, 'to': to};
}

/// Writes a JSON file whole (an EDL).
class WriteJsonOp extends JournalOp {
  final String path;
  final Map<String, Object?> json;
  const WriteJsonOp(this.path, this.json);
  @override
  Map<String, Object?> toJson() => {'op': 'writeJson', 'path': path, 'json': json};
}

/// Puts [records] into `recordings/<date>/discards.jsonl` by id, rewriting it whole.
class UpsertDiscardsOp extends JournalOp {
  final String date;
  final List<Map<String, Object?>> records;
  const UpsertDiscardsOp(this.date, this.records);
  @override
  Map<String, Object?> toJson() => {'op': 'upsertDiscards', 'date': date, 'records': records};
}

/// An owner's frames (byte ranges) and markers in one logical file.
class Claim {
  final RawFileKey key;
  final Owner owner;
  final List<(int, int)> ranges;
  final List<int> markers;

  const Claim(this.key, this.owner, this.ranges, this.markers);

  Map<String, Object?> toJson() => {
        'timerStart': key.timerStart,
        'sessionId': key.sessionId,
        'owner': owner.encode(),
        'ranges': [
          for (final (s, e) in ranges) [s, e]
        ],
        'markers': markers,
      };

  factory Claim.fromJson(Map<String, Object?> j) => Claim(
        RawFileKey(j['timerStart']! as int, j['sessionId'] as int?),
        Owner.decode(j['owner']! as String),
        [for (final r in (j['ranges']! as List).cast<List<Object?>>()) (r[0]! as int, r[1]! as int)],
        (j['markers']! as List).cast<int>(),
      );
}

/// Adds claims to one ledger day file, and sets the event summaries of the files they
/// touch.
class ClaimOp extends JournalOp {
  final String day;
  final List<Claim> claims;
  final List<EventSummary> summaries;
  const ClaimOp(this.day, this.claims, this.summaries);
  @override
  Map<String, Object?> toJson() => {
        'op': 'claim',
        'day': day,
        'claims': [for (final c in claims) c.toJson()],
        'summaries': [for (final s in summaries) s.toJson()],
      };
}

/// Sets the ledger's generation (R3).
class SetGenerationOp extends JournalOp {
  final int generation;
  const SetGenerationOp(this.generation);
  @override
  Map<String, Object?> toJson() => {'op': 'setGeneration', 'generation': generation};
}

/// A journaled transaction could not be applied: the archive holds a file where the
/// transaction reserved a name, or a staged file it names is gone. The journal stays, so
/// nothing is lost or guessed; processing stops until it is looked at.
class JournalStuck implements Exception {
  final String message;
  JournalStuck(this.message);
  @override
  String toString() => 'JournalStuck: $message';
}

/// A job's staging and identity.
class JobHandle {
  final String id;
  final Directory staging;
  JobHandle(this.id, this.staging);
}

/// One closed item a job hands over: its frames as byte ranges per file, and, for a
/// recording, what it rendered.
class StagedItem {
  final PlanItem item;
  final Map<RawFileKey, List<(int, int)>> bytes;
  final RenderedRecording? rendered;

  const StagedItem(this.item, this.bytes, [this.rendered]);
}

class CommitRequest {
  final JobHandle job;
  final int generation;
  final List<StagedItem> items;

  /// The event summary of every file an item touches, from the cards the job planned
  /// with: copied into the ledger, so the event layer never depends on files that are
  /// gone (§2).
  final Map<RawFileKey, EventSummary> summaries;

  /// For the meta's upload key.
  final String deviceId;

  /// Checked once the commit has its turn in the queue: a job stopped while its commit
  /// waited commits nothing.
  final bool Function()? isCancelled;

  const CommitRequest({
    required this.job,
    required this.generation,
    required this.items,
    required this.summaries,
    required this.deviceId,
    this.isCancelled,
  });
}

class CommitResult {
  /// Null when committed; else why nothing was.
  final String? rejected;

  /// Each published recording's audio path, relative to the documents directory.
  final List<String> published;

  const CommitResult.accepted(this.published) : rejected = null;
  const CommitResult.rejected(String this.rejected) : published = const [];

  bool get accepted => rejected == null;
}

/// What a job plans from: the generation and the ledger's entries.
class LedgerSnapshot {
  final int generation;
  final StreamState stream;
  final Map<RawFileKey, LedgerEntry> entries;
  const LedgerSnapshot(this.generation, this.stream, this.entries);

  PlanOwnership ownershipFor(Iterable<PlanFile> files) => planOwnershipOf(entries, files);
}

class OwnershipCoordinator {
  final String documentsPath;
  final Ledger ledger;
  final RawChunkStore store;
  final EditQueue _queue;

  /// Jobs of this process whose staging recovery must leave alone.
  final Set<String> _live = {};
  int _jobCounter = 0;

  /// Tests: called at every step a crash could interrupt; throwing there is a crash.
  @visibleForTesting
  void Function(String point)? faultHook;

  OwnershipCoordinator(this.documentsPath, {EditQueue? queue})
      : ledger = Ledger(documentsPath),
        store = RawChunkStore(documentsPath),
        _queue = queue ?? _SerialQueue().run;

  File get journalFile => File('$documentsPath/ownership_journal.json');

  Directory get stagingRoot => Directory('$documentsPath/processing_temp');

  String _rel(String path) {
    final norm = path.replaceAll('\\', '/');
    final root = documentsPath.replaceAll('\\', '/');
    if (!norm.startsWith('$root/')) throw StateError('$path is outside the documents directory');
    return norm.substring(root.length + 1);
  }

  File _abs(String rel) => File('$documentsPath/$rel');

  void _fault(String point) => faultHook?.call(point);

  /// Applies a journal left by a crash, then deletes staging no live job owns. Run at
  /// startup; every transaction runs it first too.
  Future<void> recover() => _queue(_recoverHeld);

  Future<void> _recoverHeld() async {
    if (await journalFile.exists()) {
      final j = jsonDecode(await journalFile.readAsString()) as Map<String, Object?>;
      if (j['v'] != 1) throw JournalStuck('journal version ${j['v']} is not 1');
      final ops = [for (final o in (j['ops']! as List)) JournalOp.fromJson((o as Map).cast())];
      Logger.debug('OwnershipCoordinator: completing journaled transaction ${j['id']} (${ops.length} ops)');
      await _apply(ops);
      _fault('journal.delete');
      await journalFile.delete();
    }
    if (!await stagingRoot.exists()) return;
    await for (final e in stagingRoot.list(followLinks: false)) {
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (e is Directory && name.startsWith('job-') && !_live.contains(name)) {
        _fault('recover.staging');
        await e.delete(recursive: true);
      }
    }
  }

  /// A new job's staging, which recovery leaves alone until [finishJob].
  Future<JobHandle> startJob() => _queue(() async {
        final id = 'job-${DateTime.now().microsecondsSinceEpoch}-${_jobCounter++}';
        _live.add(id);
        final dir = Directory('${stagingRoot.path}/$id');
        await dir.create(recursive: true);
        return JobHandle(id, dir);
      });

  /// Ends a job: its staging, whatever is left of it, goes. A journal still pending (an
  /// apply that failed) is completed first; while it cannot be, the staging it names stays.
  Future<void> finishJob(JobHandle job) => _queue(() async {
        _fault('finishJob');
        _live.remove(job.id);
        if (await journalFile.exists()) await _recoverHeld();
        if (await job.staging.exists()) await job.staging.delete(recursive: true);
      });

  /// The ledger as of now, for [keys], with any journal completed first.
  Future<LedgerSnapshot> snapshot(Iterable<RawFileKey> keys) => _queue(() async {
        await _recoverHeld();
        final stream = await ledger.loadStream();
        return LedgerSnapshot(stream.generation, stream, await ledger.entriesFor(keys));
      });

  /// Advances the generation: transactions planned under the old one are dropped (R3).
  /// Reprocess all (step 5) builds on this.
  Future<int> advanceGeneration() => _queue(() async {
        await _recoverHeld();
        final next = (await ledger.loadStream()).generation + 1;
        await _journalAndApply('generation-$next', [SetGenerationOp(next)]);
        return next;
      });

  /// Publishes [request]'s items as one transaction, or rejects it with nothing written.
  Future<CommitResult> commit(CommitRequest request) => _queue(() async {
        await _recoverHeld();
        final reason = await _check(request);
        if (reason != null) {
          Logger.debug('OwnershipCoordinator: ${request.job.id}: dropped, $reason');
          return CommitResult.rejected(reason);
        }
        final (ops, published) = await _build(request);
        await _journalAndApply('${request.job.id}-${DateTime.now().microsecondsSinceEpoch}', ops);
        return CommitResult.accepted(published);
      });

  /// Why [request] cannot commit, or null.
  Future<String?> _check(CommitRequest request) async {
    if (!_live.contains(request.job.id)) return 'the job is not live';
    if (request.isCancelled?.call() == true) return 'the job was cancelled';
    final stream = await ledger.loadStream();
    if (stream.generation != request.generation) {
      return 'planned under generation ${request.generation}, now ${stream.generation}';
    }
    final keys = {
      for (final s in request.items) ...s.bytes.keys,
      for (final s in request.items) ...s.item.events.map((e) => e.key)
    };
    final entries = await ledger.entriesFor(keys);
    final lengths = <RawFileKey, int>{};
    final claimed = <RawFileKey, List<(int, int)>>{};
    final markers = <EventId>{};
    for (final staged in request.items) {
      for (final MapEntry(key: key, value: ranges) in staged.bytes.entries) {
        final entry = entries[key];
        if (entry?.tombstone != null) return '${key.rel} was deleted';
        final length = lengths[key] ??= (await store.load(key)).length;
        for (final (start, end) in ranges) {
          if (start >= end || end > length) return '${key.rel}: [$start,$end) is not in its $length bytes';
          if (entry != null && entry.overlaps(start, end)) return '${key.rel}: [$start,$end) is owned already';
          final mine = claimed.putIfAbsent(key, () => []);
          if (mine.any((r) => r.$1 < end && start < r.$2)) return '${key.rel}: [$start,$end) is claimed twice';
          mine.add((start, end));
        }
      }
      for (final id in staged.item.events) {
        if (entries[id.key]?.tombstone != null) return '${id.key.rel} was deleted';
        if (entries[id.key]?.events.containsKey(id.offset) ?? false) return 'marker $id is owned already';
        if (!markers.add(id)) return 'marker $id is claimed twice';
      }
      if (staged.item is PlannedRecording && staged.rendered == null) return 'a recording was not rendered';
    }
    return null;
  }

  /// The transaction: names reserved, metas written into staging, then the operations.
  Future<(List<JournalOp>, List<String>)> _build(CommitRequest request) async {
    final names = NameReserver('$documentsPath/recordings');
    final moves = <JournalOp>[];
    final edls = <JournalOp>[];
    final discards = <String, List<Map<String, Object?>>>{};
    final claims = <String, List<Claim>>{};
    final published = <String>[];

    void claim(RawFileKey key, Owner owner, List<(int, int)> ranges, List<int> markers) =>
        claims.putIfAbsent(ledgerDayOf(key), () => []).add(Claim(key, owner, ranges, markers));

    void claimItem(Owner owner, Map<RawFileKey, List<(int, int)>> bytes, Iterable<EventId> events) {
      final byKey = <RawFileKey, List<int>>{};
      for (final e in events) {
        byKey.putIfAbsent(e.key, () => []).add(e.offset);
      }
      for (final key in {...bytes.keys, ...byKey.keys}) {
        claim(key, owner, bytes[key] ?? const [], byKey[key] ?? const []);
      }
    }

    Future<void> orphans(List<PlannedMarker> markers) async {
      for (final m in markers) {
        final date = localDateOf(m.markerMs);
        final edl = await names.edl(date, m.markerMs);
        edls.add(WriteJsonOp('recordings/$date/$edl', edlPayload(marker: m, segmentFilename: '', durationMs: 0)));
        claimItem(Owner(OwnerKind.orphan, '$date/${edl.substring(0, edl.length - '.edl'.length)}'), const {}, [m.id]);
      }
    }

    for (final staged in request.items) {
      switch (staged.item) {
        case final PlannedRecording r:
          final rendered = staged.rendered!;
          final name = await names.recording(r.startMs, derived: r.derivedTime);
          final folder = 'recordings/${name.date}';
          final audioName = name.audio(rendered.extension);
          final meta = File('${rendered.audio.parent.path}/${name.meta}');
          await meta.writeAsBytes(
              buildMeta(
                totalSamples: rendered.totalSamples,
                peaks: rendered.peaks,
                sessionId: r.sessionId,
                startUptimeSeconds: r.startUptimeSeconds,
                uploadKey: uploadKeyOf(request.deviceId, name.nameMs, rendered.extension),
                forceSynced: r.closeType == CloseType.force,
                capEnded: r.closeType == CloseType.cap || r.closeType == CloseType.dayLimit,
                silero: r.silero,
                manual: r.manual,
                relativeBins: [for (final k in staged.bytes.keys) k.rel],
              ),
              flush: true);
          _fault('staged.meta');
          // The meta first and the audio last: a listing that sees the audio sees its meta.
          moves.add(MoveOp(_rel(meta.path), '$folder/${name.meta}'));
          if (rendered.sidecar != null) moves.add(MoveOp(_rel(rendered.sidecar!.path), '$folder/${name.sidecar}'));
          moves.add(MoveOp(_rel(rendered.audio.path), '$folder/$audioName'));
          published.add('$folder/$audioName');
          for (final m in r.markers) {
            final edl = await names.edl(name.date, m.markerMs);
            edls.add(WriteJsonOp(
                '$folder/$edl', edlPayload(marker: m, segmentFilename: audioName, durationMs: rendered.durationMs)));
          }
          claimItem(Owner(OwnerKind.recording, name.id), staged.bytes, r.events);
        case final PlannedDiscard d:
          final id = discardIdOf(d, staged.bytes);
          discards.putIfAbsent(localDateOf(d.startMs), () => []).add(discardRecordOf(d, id, staged.bytes));
          claimItem(Owner(OwnerKind.discard, id), staged.bytes, [if (d.muteOn != null) d.muteOn!]);
          await orphans(d.orphans);
        case final PlannedOrphans o:
          await orphans(o.markers);
      }
    }

    final summaries = request.summaries;
    return (
      [
        ...moves,
        ...edls,
        for (final e in discards.entries) UpsertDiscardsOp(e.key, e.value),
        for (final e in claims.entries)
          ClaimOp(e.key, e.value, [
            for (final k in {for (final c in e.value) c.key})
              if (summaries[k] != null) summaries[k]!
          ]),
      ],
      published,
    );
  }

  Future<void> _journalAndApply(String id, List<JournalOp> ops) async {
    _fault('journal.write');
    await AtomicFile.writeString(
        journalFile,
        jsonEncode({
          'v': 1,
          'id': id,
          'ops': [for (final o in ops) o.toJson()],
        }));
    _fault('journal.written');
    await _apply(ops);
    _fault('journal.delete');
    await journalFile.delete();
  }

  Future<void> _apply(List<JournalOp> ops) async {
    for (var i = 0; i < ops.length; i++) {
      _fault('op.$i');
      await _applyOne(ops[i]);
    }
  }

  Future<void> _applyOne(JournalOp op) async {
    switch (op) {
      case MoveOp(:final from, :final to):
        final src = _abs(from), dst = _abs(to);
        final srcThere = await src.exists(), dstThere = await dst.exists();
        if (!srcThere && dstThere) return; // moved before a crash
        if (!srcThere) throw JournalStuck('$from is gone and $to was never written');
        if (dstThere) throw JournalStuck('$to exists; it was reserved for $from');
        await dst.parent.create(recursive: true);
        await src.rename(dst.path);
      case WriteJsonOp(:final path, :final json):
        final file = _abs(path);
        await file.parent.create(recursive: true);
        await AtomicFile.writeString(file, jsonEncode(json));
      case UpsertDiscardsOp(:final date, :final records):
        final file = _abs('recordings/$date/discards.jsonl');
        final ids = {for (final r in records) r['id']};
        final keep = <String>[];
        if (await file.exists()) {
          for (final line in (await file.readAsString()).split('\n')) {
            if (line.isEmpty) continue;
            try {
              final m = jsonDecode(line) as Map<String, Object?>;
              if (ids.contains(m['id'])) continue;
            } catch (_) {
              // Kept: a line nothing can parse is not this transaction's to drop.
            }
            keep.add(line);
          }
        }
        await file.parent.create(recursive: true);
        await AtomicFile.writeString(file, '${[...keep, for (final r in records) jsonEncode(r)].join('\n')}\n');
      case ClaimOp(:final day, :final claims, :final summaries):
        final loaded = await ledger.loadDay(day);
        for (final c in claims) {
          loaded.entryFor(c.key).claim(c.owner, c.ranges, c.markers);
        }
        for (final s in summaries) {
          // Sealed bytes only grow: a job that planned from a shorter card never replaces
          // the summary a newer one wrote.
          final entry = loaded.entryFor(s.key);
          if (entry.summary == null || entry.summary!.length <= s.length) entry.summary = s;
        }
        await ledger.saveDay(loaded);
      case SetGenerationOp(:final generation):
        final stream = await ledger.loadStream();
        stream.generation = generation;
        await ledger.saveStream(stream);
    }
  }
}

/// Runs bodies one at a time, in order.
class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
