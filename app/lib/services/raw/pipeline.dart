// The processing pass of a sync (RECORDINGS_PIPELINE_REDESIGN.md §5): expire discards,
// index each file into its card, plan, publish what closed, release raw files. Every
// step is idempotent and can stop anywhere; a pass keeps nothing that outlives it but
// what the coordinator commits and the cards on disk, so the next pass carries on.

import 'dart:math' show max;
import 'dart:typed_data';

import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/utils/logger.dart';

/// Failure accounting and the set-aside list the recordings page shows (SetAsideBins in
/// the app). The ledger's set-aside list is what the planner and the gate read; a pass
/// mirrors it into this one, which adds the page's details.
abstract class SetAsideBook {
  Set<RawFileKey> listed();

  /// Lists [key], which the ledger has set aside.
  Future<void> list(RawFileKey key);

  void unlist(RawFileKey key);

  /// A pass failed inside [key]. True when it is to be set aside now: three passes in a
  /// row, at most one automatically per build.
  Future<bool> recordFailure(RawFileKey key);

  /// Passes over [keys] went through: their failure counts end.
  void recordSuccess(Iterable<RawFileKey> keys);

  /// Set-aside files a newer build tries once more.
  Set<RawFileKey> retryDue();
}

/// What a pass needs from the app besides the files.
class PassInputs {
  final PolicyHistory policies;

  /// The Priority Recording cap setting now, for a ledger without a cap history yet.
  final int capMinutesNow;

  final PublishSettings settings;

  /// Files the Omi lists that are not here: holes.
  final List<RawFileKey> missing;

  /// Files given up on (the held-back timeout): their holes are waived.
  final Set<RawFileKey> waived;

  /// The sessions the phone saw live (the clock anchors), oldest first, each with when
  /// (phone time). The last is the one the Omi reported last: with a [listing] taken no
  /// earlier, every other session it lists has ended, and so has any session with a file
  /// sealed before it was read (one Omi, so the Omi restarted since).
  final List<({int sessionId, int atMs})> anchors;

  /// Sessions an earlier pass found ended: a session never comes back.
  final Set<int> knownEnded;

  /// The Omi's file list [missing] comes from, when it names every file of each session
  /// that had ended by then: taken by the sync, complete, at [atMs] (phone time), on one
  /// link. [liveSession] is the session the phone read the Omi to be in on that same link
  /// (the Omi restarts to change session, and that ends the link), so every other session
  /// here or on the list had ended. Null: no such list, so no session is newly found ended.
  /// Every file here arrived on that list's link or before it.
  final ({int atMs, int? liveSession})? listing;

  /// What the connect that list was taken on showed the Omi held ([QuietMark]): where the
  /// last conversation of a session still running may close. Null without such a list.
  final QuietMark? quiet;

  final int nowMs;

  const PassInputs({
    required this.policies,
    required this.capMinutesNow,
    required this.settings,
    required this.nowMs,
    this.missing = const [],
    this.waived = const {},
    this.anchors = const [],
    this.knownEnded = const {},
    this.listing,
    this.quiet,
  });
}

enum PassStop {
  /// Everything that closed is published.
  done,
  cancelled,

  /// Not enough space to render; what was rendered before is published.
  storageFull,

  /// Rendering failed; the failure counts against the file the item starts in.
  failed,

  /// A journaled transaction cannot be completed: processing stops until it is looked at.
  journalStuck,
}

class PassReport {
  final PassStop stop;

  /// The last plan made, or null when there was nothing to plan.
  final Plan? plan;
  final int published;
  final Set<RawFileKey> released;
  final int expired;

  /// Files whose card could not be built this pass: where planning waits.
  final Set<RawFileKey> unindexed;

  /// The files this pass planned from (not counting receipts).
  final Set<RawFileKey> seen;

  /// The sessions it took as ended, to be kept for later passes.
  final Set<int> ended;
  final Object? error;

  const PassReport(
    this.stop, {
    this.plan,
    this.published = 0,
    this.released = const {},
    this.expired = 0,
    this.unindexed = const {},
    this.seen = const {},
    this.ended = const {},
    this.error,
  });

  /// Conversations still open where reading stopped.
  List<OpenConversation> get open => plan?.open ?? const [];

  /// Files with audio still to process: no card yet, or in items that closed but were not
  /// published (storage, a failure, a stop).
  Set<RawFileKey> get waiting => {
        ...unindexed,
        if (stop != PassStop.done)
          for (final i in plan?.items ?? const <PlanItem>[]) ...[
            for (final s in i.spans) s.key,
          ],
      };
}

class RawPipeline {
  final OwnershipCoordinator coordinator;
  final ArchiveActions actions;
  final RawBinGate gate;
  final CardSource cards;
  final SetAsideBook book;

  /// A publication job for one round.
  final PublishJob Function() newJob;

  /// Rounds of planning and publishing in one pass: a stale commit (a user action meanwhile)
  /// plans again.
  static const maxRounds = 6;

  RawPipeline({
    required this.coordinator,
    required this.actions,
    required this.gate,
    required this.cards,
    required this.book,
    required this.newJob,
  });

  RawChunkStore get _store => coordinator.store;

  /// One pass. With [planOnly], only the plan as things stand: nothing expired, counted,
  /// published or released (Delete Day asks what is open now).
  /// [onProgress] is told how far the pass has come, from 0 to 1, never going back: the
  /// first half as the files here are indexed (a card built for each new one), the second
  /// as the recordings planned are rendered, by their length.
  Future<PassReport> run(PassInputs inputs,
      {bool Function()? isCancelled, bool planOnly = false, void Function(double done)? onProgress}) async {
    final watch = Stopwatch()..start();
    var shown = 0.0;
    void progress(double done) {
      final p = done > 1 ? 1.0 : done;
      if (onProgress == null || p <= shown) return;
      shown = p;
      onProgress(p);
    }

    try {
      final report = await _run(inputs, isCancelled, planOnly, progress);
      Logger.debug('RawPipeline: pass ${report.stop.name} in ${watch.elapsedMilliseconds} ms: '
          '${report.published} published, ${report.released.length} raw file(s) released, '
          '${report.expired} discard(s) expired'
          '${report.unindexed.isEmpty ? '' : ', no card for ${[for (final k in report.unindexed) k.stem]}'}'
          '${report.open.isEmpty ? '' : ', ${report.open.length} conversation(s) open'}'
          '${report.error == null ? '' : ': ${report.error}'}');
      return report;
    } on JournalStuck catch (e) {
      Logger.error('RawPipeline: stopped, $e');
      return PassReport(PassStop.journalStuck, error: e);
    }
  }

  /// The share of a pass's progress its indexing takes; rendering takes the rest.
  static const double _indexShare = 0.5;

  Future<PassReport> _run(
      PassInputs inputs, bool Function()? isCancelled, bool planOnly, void Function(double) progress) async {
    bool cancelled() => isCancelled?.call() == true;
    await coordinator.recover();
    final expired = planOnly ? 0 : await actions.expireDiscards(nowMs: inputs.nowMs);
    if (!planOnly) await _mirrorSetAside();
    if (cancelled()) return PassReport(PassStop.cancelled, expired: expired);

    // ---- index ----
    final keys = (await _store.listKeys()).toList()..sort(compareKeys);
    final entries = await coordinator.ledger.entriesFor(keys);
    final stream = await coordinator.ledger.loadStream();
    final files = <RawFileKey, PlanFile>{};
    final cardsOf = <RawFileKey, FileCard>{};
    final unindexed = <RawFileKey>{};
    var indexed = 0;
    for (final key in keys) {
      progress(_indexShare * indexed++ / keys.length);
      if (cancelled()) return PassReport(PassStop.cancelled, expired: expired, unindexed: unindexed);
      final entry = entries[key];
      // A copy of a released file that came back: its receipt plans it, the gate deletes it.
      if (entry?.receipt != null) continue;
      final file = await _store.load(key);
      if (file.chunks.isEmpty) continue;
      if (stream.setAside.contains(key) || entry?.tombstone != null) {
        // Its frames wait (set aside) or are owned (deleted): its markers are all that
        // count, and its parse says them.
        files[key] = await _parsed(file, setAside: true);
        continue;
      }
      try {
        final card = await cards.current(key);
        // The file as the card saw it: grown since, the rest is still to come.
        final same = _sameChunks(card, file);
        cardsOf[key] = card;
        files[key] = PlanFile(
          key: key,
          records: card.records,
          audio: card.audio,
          hasVad: card.hasVad,
          lifecycle: same ? file.lifecycle : SourceLifecycle.receiving,
          firstSealedAtMs: file.firstSealedAtMs,
        );
      } on CardBuildCancelled {
        return PassReport(PassStop.cancelled, expired: expired, unindexed: unindexed);
      } catch (e) {
        unindexed.add(key);
        Logger.error('RawPipeline: ${key.rel}: no card: $e');
        // A hole: planning stops here until the card is made or the file set aside.
        files[key] = await _parsed(file, setAside: false);
      }
    }
    progress(_indexShare);
    // One strike a pass, on the first file planning waits for: the failure count is one
    // file's at a time (SetAsideBins), so two failing files must not reset each other.
    var struck = false;
    if (!planOnly && unindexed.isNotEmpty) {
      final key = (unindexed.toList()..sort(compareKeys)).first;
      struck = true;
      if (await book.recordFailure(key)) {
        await actions.setAside(key);
        await book.list(key);
        files[key] = await _parsed(await _store.load(key), setAside: true);
      }
    }
    if (files.isEmpty) {
      if (planOnly) return PassReport(PassStop.done, expired: expired);
      final released = await gate.release();
      return PassReport(PassStop.done, released: released, expired: expired);
    }

    final all = [...files.values, ...await _receipts(files.keys.toSet())];
    final missing = inputs.missing.where((k) => !files.containsKey(k)).toList()..sort(compareKeys);
    final ended = _endedSessions(all, missing, inputs.anchors, inputs.knownEnded, inputs.listing);
    _logQuiet(inputs.quiet, all, ended);

    // ---- plan and publish ----
    Plan? last;
    var published = 0;
    var stop = PassStop.done;
    Object? error;
    for (var round = 0; round < maxRounds; round++) {
      if (cancelled()) {
        stop = PassStop.cancelled;
        break;
      }
      final snap = await coordinator.snapshot(all.map((f) => f.key));
      final p = plan(PlanInput(
        files: all,
        missing: missing,
        waived: inputs.waived,
        boundaries: snap.stream.boundaries,
        owned: snap.ownershipFor(all),
        policies: inputs.policies,
        caps: snap.stream.caps.isEmpty ? CapHistory.constant(inputs.capMinutesNow) : CapHistory(snap.stream.caps),
        endedSessions: ended,
        quiet: inputs.quiet,
      ));
      last = p;
      Logger.debug('RawPipeline: plan ${p.describe()}');
      if (p.items.isEmpty || planOnly) break;
      // Rendering takes about as long as the audio a recording holds; a discard renders nothing.
      final weights = [
        for (final i in p.items)
          if (i is PlannedRecording) max(1, i.durationMs) else 0
      ];
      final total = weights.fold(0, (a, b) => a + b);
      var rendered = 0;
      final report = await newJob().publish(
        items: p.items,
        generation: snap.generation,
        files: {for (final f in all) f.key: f},
        cards: cardsOf,
        settings: inputs.settings,
        onItem: (i) {
          rendered += weights[i];
          if (total > 0) progress(_indexShare + (1 - _indexShare) * rendered / total);
        },
      );
      published += report.published;
      if (report.stop == PublishStop.done || report.stop == PublishStop.stale) continue;
      if (report.stop == PublishStop.cancelled) {
        stop = PassStop.cancelled;
      } else if (report.stop == PublishStop.storageFull) {
        stop = PassStop.storageFull;
      } else {
        stop = PassStop.failed;
        error = report.error;
        final item = report.failedItem;
        final key = item == null ? null : (item.spans.isEmpty ? item.closedAt.key : item.spans.first.key);
        if (key != null && !struck && await book.recordFailure(key)) {
          await actions.setAside(key);
          await book.list(key);
        }
      }
      break;
    }
    final endedSessions = ended.keys.whereType<int>().toSet();
    if (planOnly) {
      return PassReport(stop, plan: last, unindexed: unindexed, seen: files.keys.toSet(), ended: endedSessions);
    }
    if (stop == PassStop.done) book.recordSuccess(cardsOf.keys);

    await _setAsideDamaged(cardsOf, files);
    final released = cancelled() ? const <RawFileKey>{} : await gate.release();
    return PassReport(stop,
        plan: last,
        published: published,
        released: released,
        expired: expired,
        unindexed: unindexed,
        seen: files.keys.toSet(),
        ended: endedSessions,
        error: error);
  }

  /// The ledger's set-aside list is the one that counts: the book follows it (Delete Day,
  /// Delete and Try again take files off it), and a newer build tries each once more.
  Future<void> _mirrorSetAside() async {
    final inLedger = (await coordinator.ledger.loadStream()).setAside.toSet();
    for (final k in book.listed().difference(inLedger)) {
      book.unlist(k);
    }
    for (final k in inLedger.difference(book.listed())) {
      await book.list(k);
    }
    for (final k in book.retryDue()) {
      Logger.debug('RawPipeline: ${k.rel}: a newer build tries it again');
      await actions.tryAgain(k);
      book.unlist(k);
    }
  }

  /// A file without a card, from its parse: its markers, no audio.
  Future<PlanFile> _parsed(LogicalRawFile file, {required bool setAside}) async => PlanFile(
        key: file.key,
        records: parseRecords(await file.read(0, file.length)),
        audio: null,
        hasVad: true,
        lifecycle: file.lifecycle,
        setAside: setAside,
        firstSealedAtMs: file.firstSealedAtMs,
      );

  static bool _sameChunks(FileCard card, LogicalRawFile file) {
    if (card.chunks.length != file.chunks.length) return false;
    for (var i = 0; i < card.chunks.length; i++) {
      final c = file.chunks[i];
      if (card.chunks[i] != (c.offset, c.length)) return false;
    }
    return true;
  }

  /// Released files around the ones here, from their receipts: the ledger days from the
  /// day before the earliest file here on, and the pre-sync days of every session here (a
  /// session's files from before the Omi had the time, released while its later files
  /// wait: a Priority Recording started in them is still on). Their markers and walls are
  /// what the files here are planned against.
  Future<List<PlanFile>> _receipts(Set<RawFileKey> here) async {
    final dir = coordinator.ledger.dir;
    if (!await dir.exists()) return const [];
    final dated = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    final hereDays = {
      ...here.map(ledgerDayOf),
      for (final k in here)
        if (k.sessionId != null) ledgerDayOf(RawFileKey(0, k.sessionId)),
    };
    final datedHere = hereDays.where(dated.hasMatch).toList()..sort();
    final from = datedHere.isEmpty ? null : _dayBefore(datedHere.first);
    final days = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.json') || name == 'stream.json') continue;
      final day = name.substring(0, name.length - '.json'.length);
      if (dated.hasMatch(day) ? (from != null && day.compareTo(from) >= 0) : hereDays.contains(day)) days.add(day);
    }
    final out = <PlanFile>[];
    for (final day in days) {
      for (final entry in (await coordinator.ledger.loadDay(day)).entries.values) {
        final receipt = entry.receipt;
        final summary = entry.summary;
        if (receipt == null || summary == null || here.contains(entry.key)) continue;
        out.add(PlanFile.released(summary, firstSealedAtMs: receipt.firstSealedAtMs));
      }
    }
    return out;
  }

  static String _dayBefore(String day) {
    final p = day.split('-').map(int.parse).toList();
    final d = DateTime.utc(p[0], p[1], p[2]).subtract(const Duration(days: 1));
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// The sessions that have ended, so nothing more of them will come and their last
  /// conversations close: those found before, and those [PassInputs.listing] shows ended. A
  /// session is newly found ended only against a list of the Omi's files taken after it
  /// ended: a list from before can leave out the file it was still writing, and its last
  /// conversation would close short of that file (which then becomes a recording of its own).
  ///
  /// When the phone read which session the Omi was in on the link the list was taken on,
  /// every other session here or on the list had ended by then. Otherwise the anchors, with
  /// a list taken no earlier than the newest was read: every other session the phone saw
  /// live has ended, and so has any other session with a file sealed before that read (one
  /// Omi: it restarted since). A session first seen after the read may be the live one,
  /// read before its anchor.
  static Map<int?, int?> _endedSessions(List<PlanFile> files, List<RawFileKey> missing,
      List<({int sessionId, int atMs})> anchors, Set<int> knownEnded, ({int atMs, int? liveSession})? listing) {
    final ended = <int?, int?>{for (final s in knownEnded) s: null};
    final newest = anchors.isEmpty ? null : anchors.last;
    final String how;
    if (listing == null) {
      how = 'no complete list of the Omi\'s files taken since the app started';
    } else if (listing.liveSession != null) {
      how = 'the list from ${_time(listing.atMs)} was taken in session ${listing.liveSession}';
      for (final s in [for (final f in files) f.key.sessionId, for (final k in missing) k.sessionId]) {
        if (s != null) ended[s] = null;
      }
    } else if (newest == null || listing.atMs < newest.atMs) {
      how = newest == null
          ? 'the list from ${_time(listing.atMs)} has no session read with it'
          : 'the list from ${_time(listing.atMs)} predates the last session read (${_time(newest.atMs)})';
    } else {
      how = 'sessions read before ${newest.sessionId}, list from ${_time(listing.atMs)}';
      for (final a in anchors) {
        ended[a.sessionId] = null;
      }
      for (final f in files) {
        final s = f.key.sessionId;
        if (s == null || s == newest.sessionId) continue;
        if ((f.firstSealedAtMs ?? 0) < newest.atMs) ended[s] = null;
      }
    }
    ended.remove(listing?.liveSession ?? newest?.sessionId);
    final found = ended.keys.where((s) => !knownEnded.contains(s)).toList();
    Logger.debug('RawPipeline: ${found.isEmpty ? 'no session newly ended' : 'sessions ended: $found'} ($how)');
    return ended;
  }

  static String _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

  /// For the debug log: the sessions still running here that the quiet mark cannot close,
  /// having no clock anchor to measure the silence by. The mark itself, or why there is
  /// none, the app logs (AppPipeline.quietOf).
  static void _logQuiet(QuietMark? quiet, List<PlanFile> files, Map<int?, int?> ended) {
    if (quiet == null) return;
    final unmeasured = {
      for (final f in files)
        if (!ended.containsKey(f.key.sessionId) && !quiet.uptimeAt.containsKey(f.key.sessionId)) f.key.sessionId
    };
    if (unmeasured.isEmpty) return;
    Logger.debug('RawPipeline: no clock anchor for session(s) ${unmeasured.toList()}: the quiet mark '
        '${_time(quiet.atMs)} leaves their last conversation open');
  }

  /// A damaged file (unreadable from some point on) is set aside once everything readable
  /// in it is owned, so the recordings page offers Save original file and Delete; the gate
  /// keeps it until then (§2).
  Future<void> _setAsideDamaged(Map<RawFileKey, FileCard> cards, Map<RawFileKey, PlanFile> files) async {
    final damaged = [
      for (final e in cards.entries)
        if (e.value.records.endFor(files[e.key]!.lifecycle) == FileEnd.damaged) e.key
    ];
    if (damaged.isEmpty) return;
    final entries = await coordinator.ledger.entriesFor(damaged);
    for (final key in damaged) {
      final offsets = cards[key]!.records.frameOffsets;
      final owned = entries[key]?.frames ?? const <OwnedRange>[];
      if (!_allOwned(offsets, owned)) continue;
      Logger.warning('RawPipeline: ${key.rel} is damaged at ${cards[key]!.records.parsedEnd}; set aside, '
          'everything readable in it saved');
      await actions.setAside(key);
      await book.list(key);
    }
  }

  static bool _allOwned(Uint32List offsets, List<OwnedRange> owned) {
    var at = 0;
    for (final o in offsets) {
      while (at < owned.length && owned[at].end <= o) {
        at++;
      }
      if (at == owned.length || owned[at].start > o) return false;
    }
    return true;
  }
}
