// Support for the publication tests: a fake Opus decoder whose samples say which frame
// they are, a world of sealed files on disk, and an oracle that reads the archive back.

import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';

import 'plan_fixtures.dart';

/// The first sample of every decoded frame: silence never starts with it.
const frameMark = 7777;

/// What the fake decoder renders for frame [index] of the file named [tag], decoded as
/// the [count]th packet since the decoder was made.
Int16List fakePcm(int index, int tag, int count) {
  final pcm = Int16List(samplesPerFrame)..fillRange(0, samplesPerFrame, 1000);
  pcm[0] = frameMark;
  pcm[1] = index & 0x7FFF;
  pcm[2] = index >> 15;
  pcm[3] = tag & 0x7FFF;
  pcm[4] = (tag >> 15) & 0x7FFF;
  pcm[5] = tag >> 30;
  pcm[6] = count & 0x7FFF;
  return pcm;
}

/// Decodes the fixture payloads (plan_fixtures.dart): an index with bit 31 set cannot be
/// decoded. Its samples record how many packets it had decoded, so a recording's audio
/// shows whether each file was decoded from its start, in one pass.
class FakeOpus implements FrameDecoder {
  int count = 0;
  static int made = 0;

  /// Throws as a broken decoder does, from this many packets on.
  final int? failAfter;

  FakeOpus({this.failAfter}) {
    made++;
  }

  @override
  Int16List? decode(Uint8List packet) {
    if (failAfter != null && count >= failAfter!) throw StateError('decoder broke');
    final n = count++;
    final data = ByteData.sublistView(packet);
    final index = data.getUint32(0, Endian.little);
    if (index & 0x80000000 != 0) return null;
    return fakePcm(index, data.getUint32(4, Endian.little), n);
  }

  @override
  void dispose() {}
}

/// Writes the WAV it is given as the "M4A" (a copy), or fails.
class FakeEncoder implements AudioEncoder {
  bool fail = false;
  int encoded = 0;

  @override
  Future<void> encode(File wav, File m4a, {bool Function()? isCancelled}) async {
    if (fail) throw StateError('encoder failed');
    await wav.copy(m4a.path);
    encoded++;
  }
}

/// The card a file's bytes and fixture audio make.
FileCard cardOf(Bin b, {int? upTo, bool hasVad = true}) {
  final bytes = upTo == null ? b.bytes : Uint8List.sublistView(b.bytes, 0, upTo);
  final records = parseRecords(bytes);
  final whole = b.file().audio!;
  final n = records.frameCount;
  return FileCard(
    key: b.key,
    indexerVersion: cardIndexerVersion,
    chunks: [(0, bytes.length)],
    records: records,
    decoderId: 'fake',
    vadModelId: hasVad ? 'fake-vad' : FileCard.noVad,
    audio: FrameAudio(
        decoded: Uint8List.fromList(whole.decoded.sublist(0, n)),
        speech: Float32List.fromList(whole.speech.sublist(0, n))),
  );
}

/// Sealed files on disk, as the downloads leave them.
class World {
  final Directory root;
  final RawChunkStore store;
  final Map<RawFileKey, Bin> bins = {};
  final Map<RawFileKey, FileCard> cards = {};
  final Set<RawFileKey> noVad = {};

  World(this.root) : store = RawChunkStore(root.path);

  String get docs => root.path;

  /// Seals [b]'s bytes up to [upTo] (all of them by default), adding to what is sealed;
  /// complete once every byte is.
  Future<void> arrive(Bin b, {int? upTo, bool hasVad = true}) async {
    bins[b.key] = b;
    if (!hasVad) noVad.add(b.key);
    final end = upTo ?? b.length;
    final sealed = (await store.load(b.key)).length;
    if (end > sealed) {
      final part = store.partFile(b.key, sealed);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List.sublistView(b.bytes, sealed, end), flush: true);
      await store.seal(b.key,
          appendOffset: sealed,
          keepLength: end - sealed,
          provenance: ChunkProvenance.echoed,
          advertisedLength: b.length);
    }
    if (end == b.length) await store.setLifecycle(b.key, SourceLifecycle.complete, advertisedLength: b.length);
    cards[b.key] = cardOf(b, upTo: end, hasVad: hasVad);
  }

  /// Each file's first seal, fixed so that runs compare (sealing records the real time).
  static int sealedAtOf(RawFileKey k) => 1789000000000 + (k.timerStart % 100000) * 1000;

  /// What the planner is given: each file from its card, or, once the gate released it,
  /// from its receipt.
  Future<List<PlanFile>> planFiles() async {
    final ledger = await ledgerOf(docs);
    return [
      for (final k in cards.keys)
        if (ledger[k]?.receipt != null)
          PlanFile.released(ledger[k]!.summary!, firstSealedAtMs: sealedAtOf(k))
        else
          PlanFile(
            key: k,
            records: cards[k]!.records,
            audio: cards[k]!.audio,
            hasVad: cards[k]!.hasVad,
            lifecycle: (await store.load(k)).lifecycle,
            firstSealedAtMs: sealedAtOf(k),
          ),
    ];
  }

  /// Plans everything here and publishes what closes, until nothing more does. Returns
  /// the last plan.
  Future<Plan> drain(
    OwnershipCoordinator c, {
    PlanPolicy policy = autoPolicy,
    List<PlanBoundary> boundaries = const [],
    List<RawFileKey> missing = const [],
    Set<RawFileKey> waived = const {},
    Map<int?, int?> endedSessions = const {},
    PublishSettings settings = const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', opusSidecar: true),
    AudioEncoder? encoder,
    void Function(String point)? jobFault,
    bool Function(List<PlanItem> items)? pick,
  }) async {
    for (var round = 0;; round++) {
      if (round > 200) throw StateError('publication did not settle');
      final files = await planFiles();
      final snap = await c.snapshot(files.map((f) => f.key));
      final p = plan(PlanInput(
        files: files,
        missing: missing,
        waived: waived,
        boundaries: [...boundaries, ...snap.stream.boundaries],
        owned: snap.ownershipFor(files),
        policies: PolicyHistory(policy),
        caps: CapHistory.constant(120),
        endedSessions: endedSessions,
      ));
      if (p.items.isEmpty) return p;
      final report = await PublishJob(
        coordinator: c,
        newDecoder: FakeOpus.new,
        encoder: encoder,
        freeBytes: () async => null,
        faultHook: jobFault,
      ).publish(
        items: pick == null
            ? p.items
            : [
                for (final i in p.items)
                  if (pick([i])) i
              ],
        generation: snap.generation,
        files: {for (final f in files) f.key: f},
        cards: cards,
        settings: settings,
      );
      if (report.stop == PublishStop.failed) throw StateError('publication failed: ${report.error}');
      if (pick != null) return p;
    }
  }
}

/// One frame as the oracle names it: its file's [frameTag] and its index there.
typedef FrameName = (int tag, int index);

/// The archive read back from disk, without the ledger.
class Archive {
  /// Audio file (relative to the documents directory) → the frames heard in it, in order,
  /// with the number of silent samples before each and after the last.
  final Map<String, List<(FrameName, int silenceBefore, int count)>> heard = {};
  final Map<String, int> trailingSilence = {};
  final Map<String, int> samples = {};

  /// Audio file → the packets of its sidecar, as (tag, index, decodable).
  final Map<String, List<(int, int, bool)>> sidecars = {};
  final Map<String, Uint8List> metas = {};
  final List<Map<String, Object?>> edls = [];
  final List<Map<String, Object?>> discards = [];

  static Future<Archive> read(String docs) async {
    final a = Archive();
    final root = Directory('$docs/recordings');
    if (!await root.exists()) return a;
    for (final dir in (await root.list().toList()).whereType<Directory>()) {
      final date = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      for (final f in (await dir.list().toList()).whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final rel = 'recordings/$date/$name';
        if (name.endsWith('.wav') || name.endsWith('.m4a')) {
          a._readAudio(rel, await f.readAsBytes());
          final metaFile = File('${f.path.substring(0, f.path.lastIndexOf('.'))}.meta');
          if (await metaFile.exists()) a.metas[rel] = await metaFile.readAsBytes();
          final ms = name.split('.').first.split('_').last;
          final side = File('${dir.path}/recording_fs320_$ms.bin');
          if (await side.exists()) a.sidecars[rel] = _packets(await side.readAsBytes());
        } else if (name.endsWith('.edl')) {
          a.edls.add({...(jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(), '_file': rel});
        } else if (name == 'discards.jsonl') {
          for (final line in (await f.readAsString()).split('\n')) {
            if (line.isNotEmpty) a.discards.add((jsonDecode(line) as Map).cast());
          }
        }
      }
    }
    return a;
  }

  void _readAudio(String rel, Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final pcmBytes = data.getUint32(40, Endian.little);
    if (pcmBytes + 44 != bytes.length || data.getUint32(4, Endian.little) != 36 + pcmBytes) {
      throw StateError('$rel: WAV sizes do not match its ${bytes.length} bytes');
    }
    final n = pcmBytes ~/ 2;
    samples[rel] = n;
    final out = <(FrameName, int, int)>[];
    var silence = 0;
    var s = 0;
    while (s < n) {
      final v = data.getInt16(44 + s * 2, Endian.little);
      if (v == frameMark && s + samplesPerFrame <= n) {
        int at(int i) => data.getInt16(44 + (s + i) * 2, Endian.little);
        final index = at(1) | (at(2) << 15);
        final tag = at(3) | (at(4) << 15) | (at(5) << 30);
        out.add(((tag, index), silence, at(6)));
        silence = 0;
        s += samplesPerFrame;
      } else {
        if (v != 0) throw StateError('$rel: sample $s is $v, neither a frame nor silence');
        silence++;
        s++;
      }
    }
    heard[rel] = out;
    trailingSilence[rel] = silence;
  }

  static List<(int, int, bool)> _packets(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final out = <(int, int, bool)>[];
    for (var at = 0; at < bytes.length;) {
      final len = data.getUint32(at, Endian.little);
      final index = data.getUint32(at + 4, Endian.little);
      out.add((data.getUint32(at + 8, Endian.little), index & 0x7FFFFFFF, index & 0x80000000 == 0));
      at += 4 + len;
    }
    return out;
  }
}

/// Every file and its bytes under [dirs] of [docs], for comparing two runs.
Future<Map<String, String>> treeOf(String docs, List<String> dirs) async {
  final out = <String, String>{};
  for (final d in dirs) {
    final dir = Directory('$docs/$d');
    if (!await dir.exists()) continue;
    await for (final e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final rel = e.path.substring(docs.length + 1).replaceAll('\\', '/');
      out[rel] = base64.encode(await e.readAsBytes());
    }
  }
  return out;
}

/// The ledger's day files, decoded.
Future<Map<RawFileKey, LedgerEntry>> ledgerOf(String docs) async {
  final out = <RawFileKey, LedgerEntry>{};
  final dir = Directory('$docs/ledger');
  if (!await dir.exists()) return out;
  for (final f in (await dir.list().toList()).whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json') || name == 'stream.json') continue;
    final day = LedgerDay.decode(name.substring(0, name.length - 5), await f.readAsString());
    for (final e in day.entries.values) {
      out[e.key] = e;
    }
  }
  return out;
}

/// A crash: the hook throws it at the chosen point, and at every point after, so the
/// crashed process does nothing more.
class Crash implements Exception {
  @override
  String toString() => 'Crash';
}

class CrashAt {
  final int at;
  int seen = 0;
  bool crashed = false;
  final points = <String>[];

  CrashAt(this.at);

  void call(String point) {
    if (crashed) throw Crash();
    points.add(point);
    if (++seen == at) {
      crashed = true;
      throw Crash();
    }
  }
}

const genShort = PlanPolicy(
    vadEnabled: true, speechThreshold: 0.5, silenceSplitMs: 20000, minSpeechMs: 2000, maxChunkMs: 60000, manual: false);
const genPolicies = [genShort, manualPolicy, autoPolicy];

/// Small generated timelines for the publication tests: a few sessions and files, every
/// marker kind, short gaps, some sessions before the clock was set.
class TimelineGen {
  final Random r;
  TimelineGen(int seed) : r = Random(seed);

  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  bool chance(int percent) => r.nextInt(100) < percent;

  /// Small timelines: a few sessions and files, every marker kind, short gaps.
  List<Bin> timeline() {
    final bins = <Bin>[];
    var t = 1789000000000 + r.nextInt(100000) * 1000;
    for (var s = 0; s < 1 + r.nextInt(2); s++) {
      // Before the Omi's clock is set: files named by uptime seconds, no clock anywhere, so
      // recordings are dated by when the phone sealed them (`unknown_` names).
      final preSync = chance(20);
      var uptime = 10000 + r.nextInt(100000);
      Bin fresh(int at, int up) => preSync
          ? Bin(at, session: 100 + s, uptimeMs: up, keySeconds: up ~/ 1000, headerUtcMs: 0)
          : Bin(at, session: 100 + s, uptimeMs: up);
      var b = fresh(t, uptime);
      final files = 1 + r.nextInt(3);
      for (var f = 0; f < files; f++) {
        if (f > 0) {
          final prev = b.key.timerStart;
          final gap = pick([0, 0, 3000, 25000]) + r.nextInt(1000);
          b = fresh(b.clockMs + gap, b.uptimeMs + gap);
          if (b.key.timerStart == prev) b = fresh(b.clockMs + 1000, b.uptimeMs + 1000);
        }
        for (var i = 0; i < 2 + r.nextInt(8); i++) {
          final k = r.nextInt(100);
          if (k < 50) {
            b.frames(1 + r.nextInt(chance(50) ? 20 : 250), p: pick([speech, speech, quiet, -1.0]), decoded: !chance(6));
          } else if (k < 65) {
            b.resume(pick([300, 2000, 16000, 25000, 40000]) + r.nextInt(999),
                clockSet: !preSync && chance(8), clockless: preSync || chance(5));
          } else if (k < 77) {
            b.tap(atMs: preSync || chance(10) ? 0 : null);
          } else if (k < 84) {
            b.stop(atMs: preSync ? 0 : null);
          } else if (k < 90) {
            b.priority(atMs: preSync ? 0 : null);
          } else if (k < 95) {
            b.muteOn(atMs: preSync ? 0 : null);
          } else {
            b.muteOff(atMs: preSync ? 0 : null);
          }
        }
        bins.add(b);
      }
      t = b.clockMs + 600000 + r.nextInt(100000) * 10;
    }
    return bins;
  }

  /// Force at the end of each session, sometimes one inside a file too.
  List<PlanBoundary> forces(List<Bin> bins) => [
        for (var i = 0; i < bins.length; i++) ...[
          if (chance(15))
            PlanBoundary(BoundaryKind.force, bins[i].key,
                pick(bins[i].frameOffsetsWritten.isEmpty ? [0] : bins[i].frameOffsetsWritten)),
          if (i == bins.length - 1 || bins[i + 1].key.sessionId != bins[i].key.sessionId) bins[i].force,
        ]
      ];

  PublishSettings settings() => PublishSettings(
        deviceId: 'AA:BB:CC:DD:EE:FF',
        opusSidecar: true,
        maxItemsPerCommit: 1 + r.nextInt(4),
        maxAudioMsPerCommit: pick([1000, 60000, 1 << 40]),
      );
}

/// Every session but the last has ended, each when the next began (unknown before the
/// Omi's clock was set). [bins] are in the order the Omi wrote them.
Map<int?, int?> endedOf(List<Bin> bins) {
  final firsts = <Bin>[];
  for (final b in bins) {
    if (firsts.isEmpty || firsts.last.key.sessionId != b.key.sessionId) firsts.add(b);
  }
  return {
    for (var i = 0; i + 1 < firsts.length; i++)
      firsts[i].key.sessionId: firsts[i + 1].file().header!.hasClock ? firsts[i + 1].file().header!.utcMs : null
  };
}

/// Drains [w] and fails if that published anything: [World.drain] returns its last plan,
/// which is empty whether or not anything was published before it.
Future<void> expectNothingPublished(World w, OwnershipCoordinator c,
    {List<PlanBoundary> boundaries = const [], String? reason}) async {
  final before = await treeOf(w.docs, ['recordings', 'ledger']);
  await w.drain(c, boundaries: boundaries);
  expect(await treeOf(w.docs, ['recordings', 'ledger']), before, reason: reason);
}
