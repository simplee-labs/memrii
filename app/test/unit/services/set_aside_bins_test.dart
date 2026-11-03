import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  var build = '15';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tempDir = Directory.systemTemp.createTempSync('set_aside_bins_test');
    PathProviderPlatform.instance = _MockPathProvider()..tempPath = tempDir.path;
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    build = '15';
    SetAsideBins.currentBuild = () async => build;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> failRuns(String relBin, int runs) async {
    for (var i = 0; i < runs; i++) {
      await SetAsideBins.recordFailure(relBin);
    }
  }

  const bad = '1789551600/1789551600_1.bin';
  const other = '1789552200/1789552200_1.bin';

  test('a bin is set aside only on its third failed run in a row', () async {
    await failRuns(bad, 2);
    expect(SetAsideBins.relBins(), isEmpty);

    await SetAsideBins.recordFailure(bad);
    expect(SetAsideBins.relBins(), {bad});
    expect(SetAsideBins.list().single.automatic, isTrue);
    expect(SetAsideBins.stuckBin(), isNull, reason: 'set aside, so processing moves on');
  });

  test('a different bin failing in between starts the count again', () async {
    await failRuns(bad, 2);
    await SetAsideBins.recordFailure(other);
    await failRuns(bad, 2);
    expect(SetAsideBins.relBins(), isEmpty);
  });

  test('a clean run clears the count only if it decoded the failing bin', () async {
    await failRuns(bad, 2);
    SetAsideBins.recordSuccess([bad]);
    await failRuns(bad, 2);
    expect(SetAsideBins.relBins(), isEmpty, reason: 'it decoded in between, so the count started over');

    SetAsideBins.recordSuccess([other]);
    await SetAsideBins.recordFailure(bad);
    expect(SetAsideBins.relBins(), {bad}, reason: 'a run that never reached it proves nothing');
  });

  test('a second failing file in the same build stops processing instead of being set aside', () async {
    await failRuns(bad, 3);
    await failRuns(other, 3);

    expect(SetAsideBins.relBins(), {bad});
    expect(SetAsideBins.stuckBin(), other, reason: 'the banner asks before skipping a second file');
  });

  test('Skip sets a stuck bin aside without spending the automatic allowance', () async {
    await failRuns(bad, 3);
    await failRuns(other, 3);

    await SetAsideBins.skip(other);
    expect(SetAsideBins.relBins(), {bad, other});
    expect(SetAsideBins.list().firstWhere((e) => e.relBin == other).automatic, isFalse);
    expect(SetAsideBins.stuckBin(), isNull);
  });

  test('Try again takes a bin off the list with a fresh count', () async {
    await failRuns(bad, 3);
    SetAsideBins.release(bad);
    expect(SetAsideBins.relBins(), isEmpty);

    await failRuns(bad, 2);
    expect(SetAsideBins.relBins(), isEmpty, reason: 'three more failures before it is set aside again');
  });

  // The bin stays set aside, and so protected from the prune, until the retry has saved
  // its audio (RecordingsManager.retrySetAsideBin).
  test('a new build owes what an older one set aside one retry, and keeps it set aside meanwhile', () async {
    await failRuns(bad, 3);
    await SetAsideBins.releaseAfterUpdate();
    expect(SetAsideBins.list().single.retryPending, isFalse, reason: 'same build — nothing changed');

    build = '16';
    await SetAsideBins.releaseAfterUpdate();
    expect(SetAsideBins.relBins(), {bad});
    expect(SetAsideBins.list().single.retryPending, isTrue);

    await failRuns(other, 3);
    expect(SetAsideBins.relBins(), {bad, other},
        reason: 'the owed retry is not this build\'s, so it leaves the new build its own allowance');

    await SetAsideBins.retryFailed(bad);
    final retried = SetAsideBins.list().firstWhere((e) => e.relBin == bad);
    expect(retried.retryPending, isFalse, reason: 'not tried again until a newer build');
    expect(retried.build, '16');
  });

  test('where the unsaved audio begins goes with the bin from its failures to its entry', () async {
    await SetAsideBins.recordFailure(bad, startByte: 400, startMs: 1789551900000);
    await SetAsideBins.recordFailure(bad, startByte: 400, startMs: 1789551900000);
    await SetAsideBins.recordFailure(bad, startByte: 520, startMs: 1789551930000);
    final entry = SetAsideBins.entryFor(bad)!;
    expect(entry.startByte, 520, reason: 'the latest failure says');
    expect(entry.startMs, 1789551930000);

    // Through Skip, too, for a bin processing stopped at.
    await failRuns(other, 2);
    await SetAsideBins.recordFailure(other, startByte: 64, startMs: 1789552260000);
    expect(SetAsideBins.stuckBin(), other);
    await SetAsideBins.skip(other);
    expect(SetAsideBins.entryFor(other)!.startByte, 64);

    // And through the stored list.
    expect(SetAsideBin.fromJson(SetAsideBins.entryFor(bad)!.toJson())!.startByte, 520);
  });

  test('the start time comes from a wall-clock bin name, not an uptime one', () {
    expect(
      const SetAsideBin(relBin: bad, build: '', automatic: true, atMs: 0).startTime,
      DateTime.fromMillisecondsSinceEpoch(1789551600 * 1000),
    );
    expect(const SetAsideBin(relBin: 'session_7/600_7.bin', build: '', automatic: true, atMs: 0).startTime, isNull);
  });
}
