// Equivalence with today (RECORDINGS_PIPELINE_REDESIGN.md §12): the planner against
// VadAudioProcessor on the same bins, recording for recording, discard for discard,
// marker for marker.
//
// The host has no Opus or Silero, so today's processor decodes nothing: in Silero mode
// every frame is non-speech unless a tap or a Priority Recording forces it, and in AAD
// mode every frame is speech. That still exercises every structural rule: gaps, resumes,
// clock jumps, taps and their windows, stop, Priority Recording and its cap, mute,
// silence split, minimum speech, the length cap, session changes and the AAD flood guard.
//
// The generated timelines avoid what changes on purpose (§10), each covered by its own
// rule test in plan_test.dart:
// - a stale Priority Recording closes on stream facts (here: no resume gap of 15 s or
//   more inside a span);
// - the AAD flood guard counts resume events (here: every resume follows at least 60
//   frames);
// - frames after a stop or mute-on are discarded and take time (here: a resume always
//   ends the latch; after-stop and muted-frame discards are not compared);
// - a recording starts at its first frame (here: a tap or priority start is followed by
//   frames, and files start with frames, so the two agree);
// - a session change is a hard boundary (here: sessions are an hour apart);
// - a cap cut's successor starts at its first frame (here: no clock jumps with a cap);
// - the Priority Recording cap counts device time, not the clock (here: no clock set inside
//   a span whose cap can fire);
// - Priority Recording's audio is kept whatever closes it while capture goes on (here: a
//   span still open at the end of a session has 3 s of audio or more);
// - a second mute-on while muted keeps the first (here: none);
// - an orphaned tap no longer ends its window (here: taps are followed by audio).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_fixtures.dart';

const _short = PlanPolicy(
    vadEnabled: true,
    speechThreshold: 0.5,
    silenceSplitMs: 30000,
    minSpeechMs: 3000,
    maxChunkMs: 1 << 62,
    manual: false);
const _capped = PlanPolicy(
    vadEnabled: true, speechThreshold: 0.5, silenceSplitMs: 30000, minSpeechMs: 2000, maxChunkMs: 90000, manual: false);

class _Gen {
  final Random r;
  final bool aad;
  final bool clockJumps;

  /// The priority cap; with 1 minute a span can reach it in a timeline, so taps stay
  /// out of spans (a tap window over the cap is a listed change); 0 and 120 never fire.
  final int capMinutes;
  bool _inPriority = false;
  int _framesSinceResume = 0;

  _Gen(int seed, {required this.aad, required this.clockJumps})
      : r = Random(seed),
        capMinutes = [0, 1, 120][Random(seed).nextInt(3)];

  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];

  List<Bin> timeline() {
    final bins = <Bin>[];
    var t = 1789000000000 + r.nextInt(100000) * 1000;
    final sessions = 1 + r.nextInt(2);
    for (var s = 0; s < sessions; s++) {
      _inPriority = false;
      _framesSinceResume = 0;
      Bin? prev;
      final files = 1 + r.nextInt(4);
      for (var f = 0; f < files; f++) {
        var b = prev == null
            ? Bin(t, session: 100 + s, uptimeMs: 10000 + r.nextInt(100000))
            : prev.next(gapMs: pick([0, 0, 15000, 60000, 300000]));
        if (prev != null && b.key.timerStart == prev.key.timerStart) b = prev.next(gapMs: 15000);
        _fill(b, lastOfSession: f == files - 1);
        bins.add(b);
        prev = b;
      }
      t = prev!.clockMs + 3600000;
    }
    return bins;
  }

  void _frames(Bin b) {
    final n = 1 + r.nextInt(r.nextBool() ? 60 : 3000);
    b.frames(n);
    _framesSinceResume += n;
  }

  /// The race frames the Omi writes after a stop or mute-on.
  void _race(Bin b) => b.frames(r.nextInt(3));

  void _resume(Bin b, {bool afterLatch = false}) {
    if (aad && !afterLatch && _framesSinceResume < 60) b.frames(60 - _framesSinceResume);
    final gaps = _inPriority
        ? [300, 2000, 8000]
        : aad
            ? [2000, 5000, 130000, 400000]
            : [2000, 30000, 100000, 115000, 130000, 400000];
    // A clock set moves 30 s or more with no uptime: today's processor and the planner
    // both see that as the clock being set (between 5 and 10 s only the planner does).
    final clockSet = clockJumps && !(_inPriority && capMinutes == 1) && r.nextInt(10) == 0;
    b.resume((clockSet ? pick([30000, 130000, 3600000]) : pick(gaps)) + r.nextInt(999), clockSet: clockSet);
    _framesSinceResume = 0;
  }

  void _fill(Bin b, {required bool lastOfSession}) {
    _frames(b);
    final ops = 2 + r.nextInt(10);
    for (var i = 0; i < ops; i++) {
      final k = r.nextInt(100);
      if (k < 35) {
        _frames(b);
      } else if (k < 60) {
        _frames(b);
        _resume(b);
      } else if (k < 72) {
        _frames(b);
        if (!_inPriority || capMinutes != 1) b.tap();
        _frames(b);
      } else if (k < 80) {
        _frames(b);
        b.stop();
        _inPriority = false;
        _race(b);
        _resume(b, afterLatch: true);
        _frames(b);
      } else if (k < 88) {
        b.priority();
        _inPriority = true;
        _frames(b);
      } else {
        _frames(b);
        b.muteOn();
        _race(b);
        b.muteOff();
        _resume(b, afterLatch: true);
        _frames(b);
      }
    }
    _frames(b);
    if (lastOfSession && _inPriority) b.frames(150);
    // Sometimes a marker ends the file. Not a resume (its gap would be padded twice
    // today), and not a priority start ending a session (today it would carry on into the
    // next session's first recording).
    final k = r.nextInt(100);
    if (k < 15 && (!_inPriority || capMinutes != 1)) {
      b.tap();
    } else if (k < 25 && !lastOfSession) {
      b.priority();
      _inPriority = true;
    }
  }
}

List<Bin> debugTimeline(int seed, {required bool aad, required bool clockJumps}) =>
    _Gen(seed, aad: aad, clockJumps: clockJumps).timeline();

class _Outcome {
  final List<String> recordings;
  final List<String> discards;
  final List<String> markers;
  _Outcome(this.recordings, this.discards, this.markers);
}

String _rangesOf(Map<String, (int, int)> ranges) =>
    (ranges.entries.map((e) => '${e.key}[${e.value.$1},${e.value.$2})').toList()..sort()).join(' ');

/// Today's processor over [bins], as the processing worker drives it, ending as Force does.
int _startOf(ParsedRecords r, RawFileKey key) => r.header?.utcMs ?? key.timerStart * 1000;

/// A file as both pipelines read it: its name and its bytes.
typedef _File = ({RawFileKey key, Uint8List bytes});

List<_File> _filesOf(List<Bin> bins) => [for (final b in bins) (key: b.key, bytes: b.bytes)];

Future<_Outcome> _today(List<_File> bins, PlanPolicy policy, {required bool aad, required int capMinutes}) async {
  final dir = Directory.systemTemp.createTempSync('plan_eq_');
  try {
    final records = <String, ParsedRecords>{};
    final saved = <String>[];
    VadAudioProcessor.debugOnSave = (refs, start) {
      final pieces = <String>[];
      String? stem;
      var first = 0;
      var end = 0;
      void flush() {
        if (stem != null) pieces.add('$stem[$first,$end)');
        stem = null;
      }

      for (final ref in refs) {
        if (ref is Duration) {
          flush();
          pieces.add('silence(${ref.inMilliseconds}ms)');
          continue;
        }
        final f = ref as FrameRef;
        final s = f.segmentFile.uri.pathSegments.last.split('.').first;
        final index = records[s]!.frameOffsets.indexOf(f.byteOffset);
        if (stem == s && end == index) {
          end++;
        } else {
          flush();
          stem = s;
          first = index;
          end = index + 1;
        }
      }
      flush();
      saved.add('${start.millisecondsSinceEpoch} ${pieces.join(' ')}');
    };
    final processor = VadAudioProcessor.fromSettings(
      settings: ProcessingSettings(
        vadEnabled: policy.vadEnabled,
        speechThreshold: policy.speechThreshold,
        silenceDurationToSplitMs: policy.silenceSplitMs,
        minDurationMs: 0,
        minSpeechMs: policy.minSpeechMs,
        maxChunkMs: policy.maxChunkMs,
        deviceId: 'equivalence',
        audioSaveFormat: 'wav',
        writeOpusFrameSidecar: false,
        priorityRecordCapMinutes: capMinutes,
        manual: policy.manual,
      ),
      outputDir: dir.path,
      session: aad
          ? null
          : OrtSession.fromMap({'sessionId': 'host-test-fake', 'inputNames': <String>[], 'outputNames': <String>[]}),
    );
    final ordered = [...bins]..sort((a, b) => a.key.timerStart.compareTo(b.key.timerStart));
    for (final b in ordered) {
      final file = File('${dir.path}/${b.key.stem}.bin');
      await file.writeAsBytes(b.bytes);
      records[b.key.stem] = parseRecords(b.bytes);
      await processor.processSegmentFile(
          file, DateTime.fromMillisecondsSinceEpoch(b.key.timerStart * 1000, isUtc: true),
          sessionId: b.key.sessionId);
    }
    await processor.flushRemaining();

    final discards = <String>[];
    for (final d in processor.consumePendingDiscards()) {
      final ranges = <String, (int, int)>{};
      for (final e in ((d['binRanges'] as Map?) ?? const {}).entries) {
        final r = (e.value as List).cast<int>();
        ranges[(e.key as String).split('/').last.split('.').first] = (r[0], r[1]);
      }
      discards.add('${d['reason']} ${d['startMs']}-${d['endMs']} ${d['audioMs'] ?? 0} ${_rangesOf(ranges)}');
    }
    final markers = [
      for (final m in processor.consumePendingEdlData())
        '${(m['filename'] as String).replaceAll(RegExp(r'^recording_|\.wav$'), '')}|${m['markerMs']}|'
            '${m['offsetMs']}|${m['isHighPriority']}'
    ];
    return _Outcome(saved..sort(), discards..sort(), markers..sort());
  } finally {
    VadAudioProcessor.debugOnSave = null;
    dir.deleteSync(recursive: true);
  }
}

/// The planner over the same bins, with Force at the end.
_Outcome _planned(List<_File> bins, PlanPolicy policy, {required bool aad, required int capMinutes}) {
  // No decoder on the host: no frame completes a VAD window, as for today's processor.
  final files = [
    for (final b in bins)
      () {
        final records = parseRecords(b.bytes);
        final n = records.frameCount;
        return PlanFile(
          key: b.key,
          records: records,
          audio: FrameAudio(decoded: Uint8List(n), speech: Float32List(n)..fillRange(0, n, -1)),
          hasVad: !aad,
          lifecycle: SourceLifecycle.complete,
        );
      }()
  ];
  final records = {for (final b in bins) b.key: parseRecords(b.bytes)};
  final last = files.reduce((a, b) => compareKeys(a.key, b.key) >= 0 ? a : b);
  final p = planOf(files,
      policy: policy,
      endedSessions: endedSessionsOf(bins.map((b) => (key: b.key, startMs: _startOf(records[b.key]!, b.key)))),
      boundaries: [PlanBoundary(BoundaryKind.force, last.key, last.parsedEnd)],
      capMinutes: capMinutes);
  final recordings = <String>[];
  final discards = <String>[];
  final markers = <String>[];
  for (final item in p.items) {
    switch (item) {
      case PlannedRecording r:
        recordings.add('${r.startMs} ${r.pieces.join(' ')}');
        for (final m in r.markers) {
          markers.add('${r.startMs}|${m.markerMs}|${m.offsetMs}|${m.highPriority}');
        }
      case PlannedDiscard d:
        for (final m in d.orphans) {
          markers.add('|${m.markerMs}|0|${m.highPriority}');
        }
        // Frames after a stop or mute-on are discards today's processor drops (§10); a
        // muted interval is compared without them.
        if (d.kind == DiscardKind.afterStop || (d.kind == DiscardKind.muted && d.muteOn == null)) continue;
        if (d.kind == DiscardKind.muted) {
          discards.add('muted ${d.startMs}-${d.endMs} 0 ');
          continue;
        }
        final ranges = <String, (int, int)>{};
        for (final s in d.spans) {
          final rec = records[s.key]!;
          final start = rec.frameOffsets[s.first];
          final end = rec.frameOffsets[s.end - 1] + 4 + ((rec.frameLengths[s.end - 1] + 3) & ~3);
          final had = ranges[s.key.stem];
          ranges[s.key.stem] = had == null ? (start, end) : (min(had.$1, start), max(had.$2, end));
        }
        discards.add('${d.kind.reason} ${d.startMs}-${d.endMs} ${d.audioMs} ${_rangesOf(ranges)}');
      case PlannedOrphans o:
        for (final m in o.markers) {
          markers.add('|${m.markerMs}|0|${m.highPriority}');
        }
    }
  }
  return _Outcome(recordings..sort(), discards..sort(), markers..sort());
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_onnxruntime'), (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    // Today's processor logs every step; thousands of lines per timeline.
    Logger.instance.talker.disable();
  });
  tearDown(() => Logger.instance.talker.enable());

  // 25 per mode here; 200 per mode passed when the planner was built (§14).
  const perMode = 25;
  final modes = <(String, PlanPolicy, bool)>[
    ('Silero, 120 s split', autoPolicy, false),
    ('Silero, 30 s split', _short, false),
    ('Silero, 90 s cap', _capped, false),
    ('AAD (no Silero)', autoPolicy, true),
    ('manual', manualPolicy, true),
  ];
  test('the real firmware fixtures: the plan is what today\'s processor makes', () async {
    final fixtures = <_File>[
      for (final name in ['1787938578_4261367757', '1788031307_1193025564'])
        (
          key: RawFileKey(int.parse(name.split('_')[0]), int.parse(name.split('_')[1])),
          bytes: File('test/fixtures/bins/$name.bin').readAsBytesSync(),
        )
    ];
    for (final (name, policy, aad) in modes) {
      final today = await _today(fixtures, policy, aad: aad, capMinutes: 120);
      final planned = _planned(fixtures, policy, aad: aad, capMinutes: 120);
      expect(planned.recordings, today.recordings, reason: name);
      expect(planned.discards, today.discards, reason: name);
      expect(planned.markers, today.markers, reason: name);
      if (aad) expect(today.recordings, isNotEmpty, reason: '$name: the four frames are a recording');
    }
  });

  for (final (name, policy, aad) in modes) {
    test('$name: the plan is what today\'s processor makes', () async {
      var recordings = 0;
      var discards = 0;
      var markers = 0;
      for (var seed = 0; seed < perMode; seed++) {
        final g = _Gen(seed * 7 + name.length, aad: aad, clockJumps: policy.maxChunkMs > 1 << 40);
        final bins = g.timeline();
        final capMinutes = g.capMinutes;
        final today = await _today(_filesOf(bins), policy, aad: aad, capMinutes: capMinutes);
        final planned = _planned(_filesOf(bins), policy, aad: aad, capMinutes: capMinutes);
        expect(planned.recordings, today.recordings, reason: '$name seed $seed: recordings');
        expect(planned.discards, today.discards, reason: '$name seed $seed: discards');
        expect(planned.markers, today.markers, reason: '$name seed $seed: markers');
        recordings += today.recordings.length;
        discards += today.discards.length;
        markers += today.markers.length;
      }
      // The comparison has something to compare.
      expect(recordings, greaterThan(perMode));
      if (!aad) expect(discards, greaterThan(perMode));
      expect(markers, greaterThan(perMode));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
