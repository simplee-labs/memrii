import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';

/// A raw bin that processing could not get past.
class SetAsideBin {
  /// Path relative to `raw_segments/`, the identity metas and the WAL use.
  final String relBin;

  /// App build that set it aside. A different build retries it once.
  final String build;

  /// Set aside by the stall breaker rather than by the user's Skip. Only these count
  /// toward the one-per-build cap.
  final bool automatic;

  final int atMs;

  /// Byte offset in the bin where the audio no recording holds begins, from the last
  /// failure inside it; null when that failure could not say. A retry decodes the bin
  /// from here and saves what it finds as recordings of their own.
  final int? startByte;

  /// When the audio at [startByte] was recorded (epoch ms), for the retried recording's
  /// start time; null when [startByte] is the bin's head, which the bin's name dates.
  final int? startMs;

  /// A newer build than [build] is to retry it once, on the next processing run.
  final bool retryPending;

  const SetAsideBin({
    required this.relBin,
    required this.build,
    required this.automatic,
    required this.atMs,
    this.startByte,
    this.startMs,
    this.retryPending = false,
  });

  /// When the bin's audio starts, from its `<timerStart>_<sessionId>.bin` name. Null
  /// for a pre-time-sync bin, whose key is device uptime rather than a time of day.
  DateTime? get startTime {
    final timerStart = int.tryParse(relBin.split('/').last.split('_').first);
    if (timerStart == null || timerStart < 946684800) return null;
    return DateTime.fromMillisecondsSinceEpoch(timerStart * 1000);
  }

  SetAsideBin copyWith({String? build, bool? retryPending}) => SetAsideBin(
        relBin: relBin,
        build: build ?? this.build,
        automatic: automatic,
        atMs: atMs,
        startByte: startByte,
        startMs: startMs,
        retryPending: retryPending ?? this.retryPending,
      );

  Map<String, dynamic> toJson() => {
        'bin': relBin,
        'build': build,
        'auto': automatic,
        'atMs': atMs,
        if (startByte != null) 'startByte': startByte,
        if (startMs != null) 'startMs': startMs,
        if (retryPending) 'retry': true,
      };

  static SetAsideBin? fromJson(Object? json) {
    if (json is! Map) return null;
    final relBin = json['bin'];
    if (relBin is! String || relBin.isEmpty) return null;
    return SetAsideBin(
      relBin: relBin,
      build: json['build'] is String ? json['build'] as String : '',
      automatic: json['auto'] == true,
      atMs: json['atMs'] is int ? json['atMs'] as int : 0,
      startByte: json['startByte'] is int ? json['startByte'] as int : null,
      startMs: json['startMs'] is int ? json['startMs'] as int : null,
      retryPending: json['retry'] == true,
    );
  }
}

/// Raw bins that processing failed inside in [strikes] runs in a row. They stay on disk
/// and out of every processing run, so one bad file cannot hold back every recording
/// after it.
///
/// Nothing here moves, renames or deletes a bin; the user's Delete goes through
/// `RecordingsManager.deleteSetAsideBin`. The bin stays at the path every reference
/// names, and the prune keeps it while it is set aside: a recording saved earlier in the
/// run that failed can name it, although the rest of it was never saved.
///
/// Try again, and the one retry each newer build gives it, run
/// `RecordingsManager.retrySetAsideBin`: the bin is decoded from where its unsaved audio
/// begins ([SetAsideBin.startByte]) and saved as recordings of their own, never joined
/// onto one already saved. It stays set aside until that succeeds.
///
/// At most one bin is set aside automatically per build: a second failing file means
/// processing itself is broken, not the file, so processing stops there and the
/// recordings page asks instead.
///
/// Storage failures never count — they are the phone's state, not the file's (see
/// [SharedPreferencesUtil.processingPausedForStorage]).
class SetAsideBins {
  static const int strikes = 3;

  /// The running app's build number. Overridable because tests have no platform.
  @visibleForTesting
  static Future<String> Function() currentBuild = _platformBuild;

  static Future<String> _platformBuild() async {
    try {
      return (await PackageInfo.fromPlatform()).buildNumber;
    } catch (_) {
      return '';
    }
  }

  static List<SetAsideBin> list() {
    final raw = SharedPreferencesUtil().setAsideBins;
    if (raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map(SetAsideBin.fromJson).whereType<SetAsideBin>().toList();
    } catch (_) {
      return const [];
    }
  }

  static SetAsideBin? entryFor(String relBin) {
    for (final e in list()) {
      if (e.relBin == relBin) return e;
    }
    return null;
  }

  static Set<String> relBins() => list().map((e) => e.relBin).toSet();

  static void _save(List<SetAsideBin> entries) =>
      SharedPreferencesUtil().setAsideBins = entries.isEmpty ? '' : jsonEncode(entries.map((e) => e.toJson()).toList());

  static ({String relBin, int count, int? startByte, int? startMs})? _failure() {
    final raw = SharedPreferencesUtil().processingFailure;
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map;
      final bin = json['bin'];
      final count = json['count'];
      if (bin is! String || count is! int) return null;
      final startByte = json['startByte'];
      final startMs = json['startMs'];
      return (
        relBin: bin,
        count: count,
        startByte: startByte is int ? startByte : null,
        startMs: startMs is int ? startMs : null,
      );
    } catch (_) {
      return null;
    }
  }

  static void _saveFailure(String relBin, int count, int? startByte, int? startMs) =>
      SharedPreferencesUtil().processingFailure = jsonEncode({
        'bin': relBin,
        'count': count,
        if (startByte != null) 'startByte': startByte,
        if (startMs != null) 'startMs': startMs,
      });

  static void _clearFailureFor(String relBin) {
    if (_failure()?.relBin == relBin) SharedPreferencesUtil().processingFailure = '';
  }

  /// The bin processing keeps failing inside and could not set aside on its own
  /// (the per-build cap was already spent), or null. The recordings page offers
  /// Try again and Skip for it.
  static String? stuckBin() {
    final failure = _failure();
    if (failure == null || failure.count < strikes) return null;
    return relBins().contains(failure.relBin) ? null : failure.relBin;
  }

  /// A processing run failed inside [relBin] for a reason other than storage. [startByte]
  /// and [startMs] say where in it the audio no recording holds begins (see
  /// [SetAsideBin.startByte]); the latest failure's are kept.
  static Future<void> recordFailure(String relBin, {int? startByte, int? startMs}) async {
    final previous = _failure();
    final count = previous?.relBin == relBin ? previous!.count + 1 : 1;
    if (count < strikes) {
      _saveFailure(relBin, count, startByte, startMs);
      Logger.error('SetAsideBins: processing failed inside $relBin ($count/$strikes runs in a row)');
      return;
    }
    final build = await currentBuild();
    final entries = list();
    if (entries.any((e) => e.relBin == relBin)) return;
    if (entries.any((e) => e.automatic && e.build == build)) {
      _saveFailure(relBin, count, startByte, startMs);
      Logger.error('SetAsideBins: $relBin failed $count runs in a row, and this build already set a file '
          'aside — processing stays stopped here until Try again or Skip');
      return;
    }
    _save([
      ...entries,
      SetAsideBin(
        relBin: relBin,
        build: build,
        automatic: true,
        atMs: DateTime.now().millisecondsSinceEpoch,
        startByte: startByte,
        startMs: startMs,
      ),
    ]);
    SharedPreferencesUtil().processingFailure = '';
    Logger.error('SetAsideBins: set $relBin aside after $count failed runs — kept on disk, skipped by processing');
  }

  /// A run finished cleanly over [relBins]: if the bin that kept failing was among
  /// them, it no longer fails.
  static void recordSuccess(Iterable<String> relBins) {
    final failure = _failure();
    if (failure != null && relBins.contains(failure.relBin)) SharedPreferencesUtil().processingFailure = '';
  }

  /// Skip, from the recordings page: set [relBin] aside without spending the
  /// automatic cap. Where its unsaved audio begins comes from its last failure.
  static Future<void> skip(String relBin) async {
    final entries = list();
    if (!entries.any((e) => e.relBin == relBin)) {
      final failure = _failure();
      final own = failure?.relBin == relBin ? failure : null;
      _save([
        ...entries,
        SetAsideBin(
          relBin: relBin,
          build: await currentBuild(),
          automatic: false,
          atMs: DateTime.now().millisecondsSinceEpoch,
          startByte: own?.startByte,
          startMs: own?.startMs,
        ),
      ]);
    }
    _clearFailureFor(relBin);
  }

  /// Takes [relBin] out of the set-aside list, with its failure count. For a bin still
  /// stuck (never set aside), the next run decodes it again, with a fresh count of
  /// [strikes] failures; a set-aside bin is released only once
  /// `RecordingsManager.retrySetAsideBin` has saved its audio, or when it is deleted.
  static void release(String relBin) {
    final entries = list();
    final kept = entries.where((e) => e.relBin != relBin).toList();
    if (kept.length != entries.length) _save(kept);
    _clearFailureFor(relBin);
  }

  /// A retry of [relBin] failed: it stays set aside, now on this build's account, so
  /// it is not retried again until a newer one.
  static Future<void> retryFailed(String relBin) async {
    final build = await currentBuild();
    _save([for (final e in list()) e.relBin == relBin ? e.copyWith(build: build, retryPending: false) : e]);
    _clearFailureFor(relBin);
  }

  /// Startup: a build other than the one that set a bin aside gets one more try at it,
  /// on the next processing run (see `RecordingsManager.retryPendingSetAsideBins`). The
  /// bin stays set aside, and protected, until that try saves its audio.
  static Future<void> releaseAfterUpdate() async {
    final entries = list();
    if (entries.isEmpty) return;
    final build = await currentBuild();
    final due = entries.where((e) => e.build != build && !e.retryPending).toList();
    if (due.isEmpty) return;
    for (final e in due) {
      _clearFailureFor(e.relBin);
    }
    _save([for (final e in entries) due.contains(e) ? e.copyWith(retryPending: true) : e]);
    Logger.info('SetAsideBins: build $build retries ${due.length} set-aside bin(s) on the next processing run');
  }

  static Future<File> fileFor(String relBin) async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/raw_segments/$relBin');
  }
}
