// Every frame the Omi recorded ends up in exactly one recording, or in none only because
// the user deleted it (a recording, or a day) — however syncs and processing are
// interrupted on the way (RECORDINGS_PIPELINE_REDESIGN.md I1, I4, §12). This drives the
// app's pipeline (AppPipeline: startup recovery, the pass after a sync, Stop, Force Sync,
// Delete Day; RecordingsManager's delete) through seeded sequences of syncs that bring
// whole and partial files, passes that finish, are stopped, or die at a point a seed
// picks, and deletes; then lets it finish and accounts for every frame.
//
// Provenance comes from the Opus frame sidecar each recording carries: the fixture's
// frames name themselves, so the sidecars say exactly which frames each recording holds.
// The Opus decoder, the speech model and the encoder are fakes; everything else is the
// app's own code, on disk.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/raw/app_pipeline.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:omi/utils/wal_file_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/raw/plan_fixtures.dart';
import 'services/raw/publish_fixtures.dart';

class _Paths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Every window is speech.
class _AllSpeech implements SpeechModel {
  @override
  String get id => 'fake-vad';

  @override
  Future<Float32List> run(Float32List samples, {required bool fresh}) async =>
      Float32List(samples.length ~/ vadWindowSamples)..fillRange(0, samples.length ~/ vadWindowSamples, 0.9);
}

/// How a pass ends.
enum _Ending { finishes, stopped, killed }

typedef _Frame = (int tag, int index);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('recordings_invariants_');
    PathProviderPlatform.instance = _Paths(root.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    await WalFileManager.init();
    final prefs = SharedPreferencesUtil();
    prefs.vadEnabled = false; // every frame is speech: nothing is dropped as silence or noise
    prefs.vadSplitSeconds = 120;
    prefs.vadMaxConversationMinutes = 1; // recordings close mid-file, in every pass
    prefs.filterMinDurationSeconds = 0;
    prefs.omiEnabled = true; // the Opus frame sidecar: the provenance this test reads
    prefs.audioSaveFormat = 'wav';
    RecordingsManager.freeDiskBytes = () async => null;
    SetAsideBins.currentBuild = () async => '26';
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The app as a fresh process finds it: startup recovery first.
  Future<AppPipeline> launch() async {
    final app = AppPipeline.forTest()
      ..engines = (decoderId: 'fake', newDecoder: FakeOpus.new, model: _AllSpeech(), encoder: FakeEncoder());
    await app.start();
    return app;
  }

  /// Each recording's frames, from its sidecar.
  Future<Map<String, List<_Frame>>> recordings() async => {
        for (final e in (await Archive.read(root.path)).sidecars.entries)
          e.key: [for (final (tag, index, _) in e.value) (tag, index)]
      };

  /// Each discarded clip's frames, from its byte ranges and where the fixture wrote each
  /// frame; with the day folder it is listed under.
  Future<List<({String date, Set<_Frame> frames})>> discards(AppPipeline app, List<Bin> bins) async {
    final out = <({String date, Set<_Frame> frames})>[];
    final dir = Directory('${root.path}/recordings');
    if (!dir.existsSync()) return out;
    for (final day in dir.listSync().whereType<Directory>()) {
      for (final d in await app.coordinator.readDiscardLines(p.basename(day.path))) {
        final frames = <_Frame>{};
        for (final MapEntry(key: rel, value: list) in ((d['binRanges'] as Map?) ?? const {}).entries) {
          final b = bins.firstWhere((b) => b.key.rel == rel);
          for (final pair in (list as List).cast<List<Object?>>()) {
            for (var i = 0; i < b.frameCount; i++) {
              final o = b.frameOffsetsWritten[i];
              if (o >= (pair[0]! as int) && o < (pair[1]! as int)) frames.add((frameTag(b.key), i));
            }
          }
        }
        out.add((date: p.basename(day.path), frames: frames));
      }
    }
    return out;
  }

  Future<void> runScenario(int seed) async {
    final rnd = Random(seed);
    final log = <String>[];
    final world = World(root);
    var app = await launch();

    // What the Omi recorded: one boot, a few files, sometimes a pause long enough to split.
    final bins = <Bin>[];
    var next = Bin(DateTime(2026, 9, 11, 10).millisecondsSinceEpoch, session: 1);
    for (var i = 0, n = 3 + rnd.nextInt(4); i < n; i++) {
      next.frames(1500 + rnd.nextInt(3000), p: speech);
      bins.add(next);
      next = next.next(gapMs: 1000 + (rnd.nextInt(4) == 0 ? 180000 : 0));
    }
    final recorded = {
      for (final b in bins)
        for (var i = 0; i < b.frameCount; i++) (frameTag(b.key), i)
    };
    final deleted = <_Frame>{};

    /// One pass after a sync, ended as [ending] at its [at]th step.
    Future<void> pass(_Ending ending, int at, {bool force = false}) async {
      var steps = 0;
      if (ending == _Ending.killed) app.coordinator.faultHook = CrashAt(at).call;
      try {
        await app.runPass(
            force: force,
            onProgress: (_) {
              if (ending == _Ending.stopped && ++steps == at) app.cancel();
            });
      } on Crash {
        // The process died: the next launch recovers from what is on disk.
      }
      if (ending == _Ending.killed) app = await launch();
    }

    Bin? partial;
    var index = 0;
    while (index < bins.length || partial != null) {
      // A sync finishes the file it left half-downloaded, then brings one or two more,
      // sometimes leaving the last of them half-downloaded.
      if (partial != null) {
        await world.arrive(partial);
        log.add('rest of ${partial.key.rel}');
        partial = null;
      }
      for (var k = 0, n = min(1 + rnd.nextInt(2), bins.length - index); k < n; k++) {
        final b = bins[index++];
        if (k == n - 1 && rnd.nextInt(4) == 0) {
          final upTo = 36 + rnd.nextInt(b.length - 36);
          await world.arrive(b, upTo: upTo);
          partial = b;
          log.add('file ${b.key.rel}: $upTo of ${b.length} bytes');
        } else {
          await world.arrive(b);
          log.add('file ${b.key.rel}: ${b.frameCount} frames');
        }
      }
      final roll = rnd.nextInt(10);
      final ending = roll < 4 ? _Ending.finishes : (roll < 6 ? _Ending.stopped : _Ending.killed);
      final at = 1 + rnd.nextInt(8);
      final force = rnd.nextInt(6) == 0;
      log.add('pass${force ? ' (Force Sync)' : ''}: ${ending.name}${ending == _Ending.finishes ? '' : ' at step $at'}');
      await pass(ending, at, force: force);

      // Sometimes the user deletes a recording, or the day.
      final action = rnd.nextInt(10);
      if (action < 2) {
        final saved = (await recordings()).entries.toList();
        if (saved.isNotEmpty) {
          final victim = saved[rnd.nextInt(saved.length)];
          deleted.addAll(victim.value);
          log.add('delete ${victim.key} (${victim.value.length} frames)');
          await RecordingsManager.deleteConversations([Conversation.fromFile(File('${root.path}/${victim.key}'))]);
        }
      } else if (action == 2) {
        final dates = {for (final rel in (await recordings()).keys) rel.split('/')[1]};
        if (dates.isNotEmpty) {
          final date = dates.elementAt(rnd.nextInt(dates.length));
          for (final e in (await recordings()).entries) {
            if (e.key.split('/')[1] == date) deleted.addAll(e.value);
          }
          for (final d in await discards(app, bins)) {
            if (d.date == date) deleted.addAll(d.frames);
          }
          log.add('Delete Day $date');
          await app.deleteDay(date);
        }
      }
    }

    // Then nothing more goes wrong: Force Sync, and passes until nothing is left to do.
    await pass(_Ending.finishes, 0, force: true);
    await pass(_Ending.finishes, 0);

    final held = <_Frame, List<String>>{};
    for (final e in (await recordings()).entries) {
      for (final f in e.value) {
        (held[f] ??= []).add(e.key);
      }
    }
    final clips = await discards(app, bins);
    final discarded = {for (final d in clips) ...d.frames};
    final lost = recorded.where((f) => !held.containsKey(f) && !discarded.contains(f) && !deleted.contains(f));
    final twice = held.entries.where((e) => e.value.length > 1 || discarded.contains(e.key));
    final resurrected = deleted.where((f) => held.containsKey(f) || discarded.contains(f));
    final unknown = held.keys.where((f) => !recorded.contains(f));
    final why = 'seed $seed:\n  ${log.join('\n  ')}\n'
        'recordings: ${(await recordings()).map((k, v) => MapEntry(k, v.length))}';

    expect(
      (lost: lost.length, twice: twice.length, resurrected: resurrected.length, unknown: unknown.length),
      (lost: 0, twice: 0, resurrected: 0, unknown: 0),
      reason: 'lost ${lost.take(3)}; twice ${twice.take(3)}; deleted but back ${resurrected.take(3)}\n$why',
    );
    expect(app.coordinator.journalFile.existsSync(), isFalse, reason: 'a journal is left\n$why');
    // With every frame saved or deleted for good, no raw file is left on the phone.
    if (clips.isEmpty) {
      for (final b in bins) {
        expect((await app.coordinator.store.load(b.key)).chunks, isEmpty,
            reason: '${b.key.rel} was not released\n$why');
      }
    }
  }

  for (var seed = 1; seed <= 24; seed++) {
    test('every frame lands exactly once, however passes are interrupted (seed $seed)', () => runScenario(seed),
        timeout: const Timeout(Duration(minutes: 2)));
  }
}
