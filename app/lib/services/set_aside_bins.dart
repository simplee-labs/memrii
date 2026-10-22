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

  const SetAsideBin({required this.relBin, required this.build, required this.automatic, required this.atMs});

  /// When the bin's audio starts, from its `<timerStart>_<sessionId>.bin` name. Null
  /// for a pre-time-sync bin, whose key is device uptime rather than a time of day.
  DateTime? get startTime {
    final timerStart = int.tryParse(relBin.split('/').last.split('_').first);
    if (timerStart == null || timerStart < 946684800) return null;
    return DateTime.fromMillisecondsSinceEpoch(timerStart * 1000);
  }

  Map<String, dynamic> toJson() => {'bin': relBin, 'build': build, 'auto': automatic, 'atMs': atMs};

  static SetAsideBin? fromJson(Object? json) {
    if (json is! Map) return null;
    final relBin = json['bin'];
    if (relBin is! String || relBin.isEmpty) return null;
    return SetAsideBin(
      relBin: relBin,
      build: json['build'] is String ? json['build'] as String : '',
      automatic: json['auto'] == true,
      atMs: json['atMs'] is int ? json['atMs'] as int : 0,
    );
  }
}

/// Raw bins that processing failed inside in [strikes] runs in a row. They stay on disk
/// and out of every processing run, so one bad file cannot hold back every recording
/// after it.
///
/// Nothing here moves, renames or deletes a bin unless the user asks. The bin stays at
/// the path every reference names; prune never touches it, because no recording names
/// it. A new app build retries it once, since a file that fails every time most likely
/// needs a code fix. At most one bin is set aside automatically per build: a second
/// failing file means processing itself is broken, not the file, so processing stops
/// there and the recordings page asks instead.
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

  static Set<String> relBins() => list().map((e) => e.relBin).toSet();

  static void _save(List<SetAsideBin> entries) =>
      SharedPreferencesUtil().setAsideBins = entries.isEmpty ? '' : jsonEncode(entries.map((e) => e.toJson()).toList());

  static ({String relBin, int count})? _failure() {
    final raw = SharedPreferencesUtil().processingFailure;
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map;
      final bin = json['bin'];
      final count = json['count'];
      if (bin is! String || count is! int) return null;
      return (relBin: bin, count: count);
    } catch (_) {
      return null;
    }
  }

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

  /// A processing run failed inside [relBin] for a reason other than storage.
  static Future<void> recordFailure(String relBin) async {
    final previous = _failure();
    final count = previous?.relBin == relBin ? previous!.count + 1 : 1;
    if (count < strikes) {
      SharedPreferencesUtil().processingFailure = jsonEncode({'bin': relBin, 'count': count});
      Logger.error('SetAsideBins: processing failed inside $relBin ($count/$strikes runs in a row)');
      return;
    }
    final build = await currentBuild();
    final entries = list();
    if (entries.any((e) => e.relBin == relBin)) return;
    if (entries.any((e) => e.automatic && e.build == build)) {
      SharedPreferencesUtil().processingFailure = jsonEncode({'bin': relBin, 'count': count});
      Logger.error('SetAsideBins: $relBin failed $count runs in a row, and this build already set a file '
          'aside — processing stays stopped here until Try again or Skip');
      return;
    }
    _save([
      ...entries,
      SetAsideBin(relBin: relBin, build: build, automatic: true, atMs: DateTime.now().millisecondsSinceEpoch),
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
  /// automatic cap.
  static Future<void> skip(String relBin) async {
    final entries = list();
    if (!entries.any((e) => e.relBin == relBin)) {
      _save([
        ...entries,
        SetAsideBin(
            relBin: relBin, build: await currentBuild(), automatic: false, atMs: DateTime.now().millisecondsSinceEpoch),
      ]);
    }
    _clearFailureFor(relBin);
  }

  /// Try again: the next processing run decodes [relBin], with a fresh count of
  /// [strikes] failures before it is set aside again.
  static void release(String relBin) {
    final entries = list();
    final kept = entries.where((e) => e.relBin != relBin).toList();
    if (kept.length != entries.length) _save(kept);
    _clearFailureFor(relBin);
  }

  /// Delete, from the recordings page: the raw file goes, and with it the entry.
  static Future<void> delete(String relBin) async {
    final file = await fileFor(relBin);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      Logger.error('SetAsideBins: could not delete $relBin: $e');
      rethrow;
    }
    release(relBin);
  }

  /// Startup: a build other than the one that set a bin aside gets one more try at it.
  static Future<void> releaseAfterUpdate() async {
    final entries = list();
    if (entries.isEmpty) return;
    final build = await currentBuild();
    final kept = entries.where((e) => e.build == build).toList();
    if (kept.length == entries.length) return;
    for (final e in entries.where((e) => e.build != build)) {
      _clearFailureFor(e.relBin);
    }
    _save(kept);
    Logger.info('SetAsideBins: build $build retries ${entries.length - kept.length} set-aside bin(s)');
  }

  static Future<File> fileFor(String relBin) async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/raw_segments/$relBin');
  }
}
