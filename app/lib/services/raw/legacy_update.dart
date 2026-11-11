// The update from a build before the new pipeline (RECORDINGS_PIPELINE_REDESIGN.md §13):
// once, at the first launch of the switched build, before any download or processing.
// The release notes ask for a Force Sync first, so the state it leaves (no checkpoint,
// no drafts) is the expected one; anything else found is carried over as below and
// logged.
//
// 1. Bins the old pipeline moved to `discarded_segments/` come back to `raw_segments/`,
//    where discard records name them.
// 2. Every bin becomes a sealed file of one imported chunk: complete, or still receiving
//    when its transfer had not finished.
// 3. Drafts are finished as they are.
// 4. The ledger is seeded, in one journaled transaction: `deleted_bins.json` gives
//    tombstones, except for a bin still holding discards or a set-aside bin's unsaved
//    audio, which is owned as below; a bin a recording or draft names is owned whole by a legacy owner,
//    markers included, except the ranges discard records hold, which their discards
//    own (each record gets an id); a discard without ranges owns its bins whole when no
//    recording names them; a set-aside bin stays set aside, owned up to where its unsaved
//    audio begins when that is known; everything else is unowned and processed afresh.
//    The cap history starts with today's setting. The old checkpoint, priority sentinel
//    and deleted list go.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/wal_file_manager.dart';

/// Who owns audio today's pipeline already processed. Reprocess all revokes it.
const legacyOwner = Owner(OwnerKind.recording, 'legacy');

class LegacyUpdate {
  final OwnershipCoordinator coordinator;
  final int capMinutesNow;

  LegacyUpdate(this.coordinator, {required this.capMinutesNow});

  String get _docs => coordinator.documentsPath;
  RawChunkStore get _store => coordinator.store;

  File get doneFile => File('$_docs/pipeline_update.json');

  Future<void> runOnce() async {
    if (await doneFile.exists()) return;
    final watch = Stopwatch()..start();
    final found = <String, Object?>{};
    found['returnedFromDiscarded'] = await _returnDiscardedBins();
    final keys = await _adoptBins();
    found['bins'] = keys.length;
    found['drafts'] = await _finishDrafts();
    for (final name in ['vad_checkpoint.json', 'vad_priority_latch.json', 'deleted_bins.json']) {
      found[name] = await File('$_docs/$name').exists();
    }
    found['oldStaging'] = await _oldStaging();
    await _seed(keys);
    await AtomicFile.writeString(doneFile, jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'found': found}));
    final clean = found['drafts'] == 0 && found['vad_checkpoint.json'] == false && found['oldStaging'] == 0;
    Logger.info('LegacyUpdate: done in ${watch.elapsedMilliseconds} ms; '
        '${clean ? 'the state a Force Sync leaves' : 'NOT the state a Force Sync leaves'}: $found');
  }

  /// Bins the old pipeline moved aside for their discards, back where the records name them.
  Future<int> _returnDiscardedBins() async {
    final root = Directory('$_docs/discarded_segments');
    if (!await root.exists()) return 0;
    var moved = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.bin')) continue;
      final rel = e.path.replaceAll('\\', '/').split('/discarded_segments/').last;
      final target = File('$_docs/raw_segments/$rel');
      if (await target.exists()) {
        Logger.warning('LegacyUpdate: discarded_segments/$rel is also in raw_segments; kept aside');
        continue;
      }
      await target.parent.create(recursive: true);
      await e.rename(target.path);
      moved++;
    }
    return moved;
  }

  /// Every bin without a manifest becomes a sealed file of one imported chunk.
  Future<List<RawFileKey>> _adoptBins() async {
    final wals = <String, Wal>{};
    try {
      for (final w in await WalFileManager.loadWals()) {
        wals[w.relativeBinPath] = w;
      }
    } catch (e) {
      Logger.error('LegacyUpdate: wals.json unreadable ($e); every bin is taken as complete');
    }
    final keys = <RawFileKey>[];
    for (final key in await _store.listKeys()) {
      final file = await _store.load(key);
      if (file.chunks.isEmpty) continue;
      keys.add(key);
      if (file.hasManifest) continue;
      final wal = wals[key.rel];
      final receiving = wal != null && wal.status != WalStatus.synced && wal.isIncompleteTransfer;
      final first = File(file.chunks.first.path);
      await _store.adoptLegacy(
        key,
        lifecycle: receiving ? SourceLifecycle.receiving : SourceLifecycle.complete,
        advertisedLength: receiving ? wal.storageTotalBytes : file.length,
        firstSealedAtMs: (await first.lastModified()).millisecondsSinceEpoch,
      );
    }
    return keys;
  }

  /// Drafts become recordings as they are: `_draft` leaves their names.
  Future<int> _finishDrafts() async {
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return 0;
    var finished = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.contains('_draft.')) continue;
      final target = File('${e.parent.path}/${name.replaceFirst('_draft.', '.')}');
      if (await target.exists()) {
        Logger.warning('LegacyUpdate: ${e.path} kept as a draft: ${target.path} exists');
        continue;
      }
      await e.rename(target.path);
      if (name.endsWith('.meta')) finished++;
    }
    return finished;
  }

  Future<int> _oldStaging() async {
    final root = Directory('$_docs/processing_temp');
    if (!await root.exists()) return 0;
    var n = 0;
    await for (final e in root.list(followLinks: false)) {
      if (!e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('job-')) n++;
    }
    return n;
  }

  Future<void> _seed(List<RawFileKey> keys) async {
    final here = keys.toSet();
    final named = await _namedBins();
    final discards = await _discardsWithIds();
    final setAside = {for (final e in SetAsideBins.list()) e.relBin: e};
    final deleted = await _deletedBins();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Claims never overlap: what an earlier claim took is cut out of a later one, so old
    // records that overlap cannot make the transaction fail (a claim refuses a conflict).
    final claims = <String, List<Claim>>{};
    final taken = <RawFileKey, List<(int, int)>>{};
    final markersTaken = <RawFileKey, Set<int>>{};
    void claim(RawFileKey key, Owner owner, List<(int, int)> ranges, List<int> markers) {
      final had = taken.putIfAbsent(key, () => []);
      final fresh = <(int, int)>[];
      for (final (s, e) in ranges) {
        final pieces = [
          for (final r in _complement(had, e))
            if (r.$2 > s && r.$2 > (r.$1 < s ? s : r.$1)) (r.$1 < s ? s : r.$1, r.$2)
        ];
        had.addAll(pieces);
        fresh.addAll(pieces);
      }
      final newMarkers = [
        for (final m in markers)
          if (markersTaken.putIfAbsent(key, () => {}).add(m)) m
      ];
      if (fresh.isEmpty && newMarkers.isEmpty) return;
      claims.putIfAbsent(ledgerDayOf(key), () => []).add(Claim(key, owner, fresh, newMarkers));
    }

    // Discard ranges first: they are exact, and a recording naming the same bin owns
    // the rest of it.
    final discardRanges = <RawFileKey, List<(int, int)>>{};
    final wholeByDiscard = <RawFileKey, Owner>{};
    for (final d in discards) {
      final ranges = binRangesOf(d.record);
      if (ranges.isNotEmpty) {
        for (final MapEntry(key: rel, value: list) in ranges.entries) {
          final key = RawFileKey.fromRel(rel);
          if (key == null || !here.contains(key)) continue;
          for (final r in list) {
            discardRanges.putIfAbsent(key, () => []).add(r);
            claim(key, Owner(OwnerKind.discard, d.id), [r], const []);
          }
        }
      } else {
        for (final rel in ((d.record['relativeBins'] as List?) ?? const []).cast<String>()) {
          final key = RawFileKey.fromRel(rel);
          if (key == null || !here.contains(key) || named.contains(key) || discardRanges.containsKey(key)) continue;
          wholeByDiscard.putIfAbsent(key, () => Owner(OwnerKind.discard, d.id));
        }
      }
    }

    // A discard that owns bins whole says so in its record, as ranges: Delete and Recover
    // find a discard's files from its ranges.
    final wholeRanges = <String, Map<String, List<List<int>>>>{};
    for (final MapEntry(key: key, value: owner) in wholeByDiscard.entries) {
      wholeRanges.putIfAbsent(owner.id, () => {})[key.rel] = [
        [0, (await _store.load(key)).length]
      ];
    }
    await _giveRanges(wholeRanges);

    final setAsideKeys = <RawFileKey>[];
    for (final key in keys) {
      final file = await _store.load(key);
      final records = parseRecords(await file.read(0, file.length));
      final markers = [
        for (final e in records.events)
          if (e.kind == CardEventKind.tap || e.kind == CardEventKind.priorityStart || e.kind == CardEventKind.muteOn)
            e.offset
      ];
      final aside = setAside[key.rel];
      if (aside != null) setAsideKeys.add(key);
      final unsavedFrom = aside?.startByte;
      if (unsavedFrom != null) {
        // Set aside where its unsaved audio begins: only what precedes it was processed,
        // whether or not a recording names the bin.
        final upTo = unsavedFrom.clamp(0, file.length);
        claim(key, legacyOwner, _complement(discardRanges[key] ?? const [], upTo), [
          for (final m in markers)
            if (m < upTo) m
        ]);
      } else if (named.contains(key)) {
        claim(key, legacyOwner, _complement(discardRanges[key] ?? const [], file.length), markers);
      } else if (wholeByDiscard.containsKey(key)) {
        claim(key, wholeByDiscard[key]!, [(0, file.length)], markers);
      } else if (discardRanges.containsKey(key)) {
        // Processed into discards only: the audio between them was published or dropped
        // by today's pipeline, which recorded nothing else of it.
        claim(key, legacyOwner, _complement(discardRanges[key]!, file.length), markers);
      }
    }

    // `deleted_bins.json` names the bins of deleted recordings (by the user or by
    // retention), of deleted set-aside bins and of deleted days that something still kept
    // on the phone. Today's app never decoded them again, so they are tombstoned, except
    // where it still owed them something: a set-aside bin's unsaved audio from where it
    // begins (its Try again saved that), and discards (Recover, until they expire). Those
    // stay owned by the claims above, as any bin a recording names.
    final tombstones = <String, List<RawFileKey>>{};
    var keptFor = 0;
    for (final key in deleted) {
      final unsavedFrom = setAside[key.rel]?.startByte;
      final discarded = discardRanges.containsKey(key) || wholeByDiscard.containsKey(key);
      if (here.contains(key) && (unsavedFrom != null || discarded)) {
        keptFor++;
        Logger.debug('LegacyUpdate: ${key.rel} is deleted but not tombstoned: kept for '
            '${[
          if (unsavedFrom != null) 'its unsaved audio from byte $unsavedFrom',
          if (discarded) 'its discards'
        ].join(' and ')}');
        continue;
      }
      tombstones.putIfAbsent(ledgerDayOf(key), () => []).add(key);
    }
    await coordinator.transact(
        'update',
        () async => (
              <JournalOp>[
                for (final e in tombstones.entries) TombstoneOp(e.key, e.value, Tombstone(nowMs, 'update')),
                for (final e in claims.entries) ClaimOp(e.key, e.value, const []),
                StreamOp(setAside: setAsideKeys, cap: (atMs: 0, minutes: capMinutesNow)),
                const DeletePathsOp(['vad_checkpoint.json', 'vad_priority_latch.json', 'deleted_bins.json']),
              ],
              null
            ));
    Logger.info('LegacyUpdate: seeded the ledger: ${claims.values.fold(0, (n, l) => n + l.length)} claim(s), '
        '${deleted.length - keptFor} tombstone(s), $keptFor deleted bin(s) kept for unsaved audio or discards, '
        '${setAsideKeys.length} set aside, ${discards.length} discard(s)');
  }

  /// A discard record's byte ranges per file, sorted. Today's pipeline writes one flat
  /// `[start, end]` per file; the new one, and a coalesced row, a list of them. Anything
  /// else is left out, and a record left with none counts as having no ranges.
  @visibleForTesting
  static Map<String, List<(int, int)>> binRangesOf(Map<String, Object?> record) {
    final raw = record['binRanges'];
    if (raw is! Map) return const {};
    final out = <String, List<(int, int)>>{};
    raw.forEach((rel, v) {
      if (rel is! String || v is! List || v.isEmpty) return;
      final pairs = v.first is List ? v : [v];
      final ranges = <(int, int)>[
        for (final p in pairs)
          if (p is List && p.length == 2 && p[0] is int && p[1] is int && (p[1] as int) > (p[0] as int))
            (p[0] as int, p[1] as int)
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      if (ranges.isNotEmpty) out[rel] = ranges;
    });
    return out;
  }

  /// [0, length) less [owned], as byte ranges.
  static List<(int, int)> _complement(List<(int, int)> owned, int length) {
    final sorted = [...owned]..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, int)>[];
    var at = 0;
    for (final (s, e) in sorted) {
      if (s > at) out.add((at, s));
      if (e > at) at = e;
    }
    if (at < length) out.add((at, length));
    return out;
  }

  /// The bins recordings and drafts name (a cropped copy names its original's, which
  /// stay the original's).
  Future<Set<RawFileKey>> _namedBins() async {
    final out = <RawFileKey>{};
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return out;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.meta')) continue;
      try {
        final c = Conversation.fromFile(e);
        if (c.isCropped) continue;
        out.addAll(c.relativeBins.map(RawFileKey.fromRel).whereType<RawFileKey>());
      } catch (err) {
        Logger.error('LegacyUpdate: ${e.path} unreadable: $err');
      }
    }
    return out;
  }

  /// Every discard record, each with an id; records written before ids get one, and their
  /// files are rewritten with it.
  Future<List<({String id, Map<String, Object?> record})>> _discardsWithIds() async {
    final out = <({String id, Map<String, Object?> record})>[];
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return out;
    final used = <String>{};
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || e.uri.pathSegments.last != 'discards.jsonl') continue;
      var changed = false;
      final lines = <String>[];
      for (final line in (await e.readAsString()).split('\n')) {
        if (line.isEmpty) continue;
        Map<String, Object?> r;
        try {
          r = (jsonDecode(line) as Map).cast();
        } catch (_) {
          lines.add(line);
          continue;
        }
        final had = r['id'];
        var id = had is String ? had : _legacyId(r);
        if (had is! String) {
          final base = id;
          var n = 1;
          while (used.contains(id)) {
            id = '$base#${n++}';
          }
          r = {'id': id, ...r};
          changed = true;
        }
        used.add(id);
        out.add((id: id, record: r));
        lines.add(jsonEncode(r));
      }
      if (changed) await AtomicFile.writeString(e, '${lines.join('\n')}\n');
    }
    return out;
  }

  /// Adds [byId]'s ranges to the records with those ids that have none.
  Future<void> _giveRanges(Map<String, Map<String, List<List<int>>>> byId) async {
    if (byId.isEmpty) return;
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || e.uri.pathSegments.last != 'discards.jsonl') continue;
      var changed = false;
      final lines = <String>[];
      for (final line in (await e.readAsString()).split('\n')) {
        if (line.isEmpty) continue;
        try {
          final r = (jsonDecode(line) as Map).cast<String, Object?>();
          final ranges = byId[r['id']];
          if (ranges != null && binRangesOf(r).isEmpty) {
            r['binRanges'] = ranges;
            lines.add(jsonEncode(r));
            changed = true;
            continue;
          }
        } catch (_) {}
        lines.add(line);
      }
      if (changed) await AtomicFile.writeString(e, '${lines.join('\n')}\n');
    }
  }

  /// A record without an id: its first range's file and start, or its first bin and start
  /// time, as the pipeline names discards.
  static String _legacyId(Map<String, Object?> r) {
    final ranges = binRangesOf(r);
    if (ranges.isNotEmpty) {
      final rel = (ranges.keys.toList()..sort()).first;
      return '$rel@${ranges[rel]!.first.$1}';
    }
    final bins = ((r['relativeBins'] as List?) ?? const []).cast<String>();
    final start = r['startMs'];
    return bins.isEmpty ? 'legacy@$start' : '${bins.first}@t$start';
  }

  Future<Set<RawFileKey>> _deletedBins() async {
    final file = File('$_docs/deleted_bins.json');
    if (!await file.exists()) return const {};
    try {
      return (jsonDecode(await file.readAsString()) as List)
          .whereType<String>()
          .map(RawFileKey.fromRel)
          .whereType<RawFileKey>()
          .toSet();
    } catch (e) {
      Logger.error('LegacyUpdate: deleted_bins.json unreadable ($e)');
      return const {};
    }
  }
}
