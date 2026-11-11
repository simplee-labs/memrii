// A publication job (RECORDINGS_PIPELINE_REDESIGN.md §4 and §5 step 4): renders a plan's
// closed items into its staging, oldest first, and hands them to the coordinator several
// per transaction. It holds no state that outlives it: a job that stops, is killed or is
// dropped leaves only staging, which recovery deletes, and the next plan picks up from
// the ledger.
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:io';

import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';
import 'package:omi/utils/logger.dart';

class PublishSettings {
  /// For the meta's upload key.
  final String deviceId;

  /// Encode recordings to M4A in staging (the archive's M4A format).
  final bool m4a;

  /// Keep each recording's Opus frames beside it, while a connector wants them.
  final bool opusSidecar;

  /// A transaction takes at most this many items, or this much rendered audio.
  final int maxItemsPerCommit;
  final int maxAudioMsPerCommit;

  const PublishSettings({
    required this.deviceId,
    this.m4a = false,
    this.opusSidecar = false,
    this.maxItemsPerCommit = 16,
    this.maxAudioMsPerCommit = 60 * 60 * 1000,
  });
}

enum PublishStop {
  /// Everything given was published.
  done,

  /// A transaction was dropped: the ledger moved on since the plan (a user action, a
  /// reset, another job). Plan again.
  stale,

  /// Stopped: nothing more was committed, not even a batch already rendered.
  cancelled,

  /// Not enough space to render the next recording; what was rendered before it is
  /// published.
  storageFull,

  /// Rendering failed (the decoder, or a write); what was rendered before is published.
  failed,
}

class PublishReport {
  final PublishStop stop;

  /// Items published.
  final int published;

  /// For [PublishStop.failed]: the item that failed and why.
  final PlanItem? failedItem;
  final Object? error;

  const PublishReport(this.stop, this.published, {this.failedItem, this.error});
}

/// The byte ranges that own [item]'s frames, per file, sorted and coalesced.
Map<RawFileKey, List<(int, int)>> bytesOf(PlanItem item, Map<RawFileKey, FileCard> cards) {
  final out = <RawFileKey, List<(int, int)>>{};
  for (final span in item.spans) {
    if (span.length == 0) continue;
    final card = cards[span.key];
    if (card == null) throw StateError('${span.key.rel}: no card for frames [${span.first},${span.end})');
    out.putIfAbsent(span.key, () => []).add(byteRangeOf(card.records, span.first, span.end));
  }
  for (final ranges in out.values) {
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = ranges.length - 1; i > 0; i--) {
      if (ranges[i - 1].$2 == ranges[i].$1) {
        ranges[i - 1] = (ranges[i - 1].$1, ranges[i].$2);
        ranges.removeAt(i);
      }
    }
  }
  return out;
}

/// A file's event summary for the ledger, from its card or, for a file without one (set
/// aside before its card was made), from its parse.
EventSummary summaryOf(PlanFile f, FileCard? card) =>
    card?.summary ??
    EventSummary(
      key: f.key,
      length: f.parsedEnd,
      frameCount: f.frameCount,
      firstFrameOffset: f.firstFrameOffset,
      events: f.events,
      hasVad: f.hasVad,
    );

class PublishJob {
  final OwnershipCoordinator coordinator;
  final FrameDecoder Function() newDecoder;

  /// Needed in M4A mode.
  final AudioEncoder? encoder;

  /// Free bytes on the phone, or null when unknown (then nothing is held back).
  final Future<int?> Function() freeBytes;
  final bool Function()? isCancelled;
  final void Function()? onLiveness;

  /// Tests: called after each render, where a crash leaves staging only.
  void Function(String point)? faultHook;

  PublishJob({
    required this.coordinator,
    required this.newDecoder,
    required this.freeBytes,
    this.encoder,
    this.isCancelled,
    this.onLiveness,
    this.faultHook,
  });

  /// Publishes [items] (a plan's closed items, in its order) under [generation], the
  /// ledger generation the plan was made under. [files] and [cards] are what the plan was
  /// made from. [onItem] is told the index of each item once it is rendered (for the
  /// progress shown; its commit may come later).
  Future<PublishReport> publish({
    required List<PlanItem> items,
    required int generation,
    required Map<RawFileKey, PlanFile> files,
    required Map<RawFileKey, FileCard> cards,
    required PublishSettings settings,
    void Function(int index)? onItem,
  }) async {
    if (items.isEmpty) return const PublishReport(PublishStop.done, 0);
    final job = await coordinator.startJob(holds: {
      for (final i in items)
        for (final s in i.spans) s.key
    });
    Logger.debug('PublishJob: ${job.id}: ${describeItems(items)}, under generation $generation');
    try {
      final report = await _publish(job, items, generation, files, cards, settings, onItem);
      final line = 'PublishJob: ${job.id}: ${report.stop.name}, ${report.published} of ${items.length} published'
          '${report.failedItem == null ? '' : '; ${describeItem(report.failedItem!)} failed: ${report.error}'}';
      if (report.stop == PublishStop.failed) {
        Logger.error(line);
      } else {
        Logger.debug(line);
      }
      return report;
    } catch (e) {
      Logger.error('PublishJob: ${job.id}: stopped by $e');
      rethrow;
    }
  }

  Future<PublishReport> _publish(JobHandle job, List<PlanItem> items, int generation, Map<RawFileKey, PlanFile> files,
      Map<RawFileKey, FileCard> cards, PublishSettings settings, void Function(int index)? onItem) async {
    final renderer = RecordingRenderer(
      source: (key) async => RenderSource(await coordinator.store.load(key), cards[key]!),
      newDecoder: newDecoder,
      encoder: settings.m4a ? encoder : null,
      writeSidecar: settings.opusSidecar,
      onLiveness: onLiveness,
      isCancelled: isCancelled,
    );
    var published = 0;
    var batch = <StagedItem>[];
    var batchMs = 0;
    var seq = 0;

    /// Commits [batch]; false when the coordinator dropped it. A job cancelled by the time
    /// its commit has its turn in the queue commits nothing more, however much it has
    /// rendered: the coordinator checks, and the drop ends the job as cancelled.
    Future<bool> flush() async {
      if (batch.isEmpty) return true;
      final keys = {
        for (final s in batch) ...s.bytes.keys,
        for (final s in batch) ...s.item.events.map((e) => e.key),
      };
      final result = await coordinator.commit(CommitRequest(
        job: job,
        generation: generation,
        items: batch,
        summaries: {for (final k in keys) k: summaryOf(files[k]!, cards[k])},
        deviceId: settings.deviceId,
        isCancelled: isCancelled,
      ));
      if (!result.accepted) {
        if (isCancelled?.call() == true) throw const RenderCancelled();
        return false;
      }
      published += batch.length;
      batch = [];
      batchMs = 0;
      return true;
    }

    try {
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (isCancelled?.call() == true) return PublishReport(PublishStop.cancelled, published);
        final bytes = bytesOf(item, cards);
        RenderedRecording? rendered;
        if (item is PlannedRecording) {
          final need = bytesToRender(item,
              m4a: settings.m4a && encoder != null,
              sourceBytes: bytes.values.expand((r) => r).fold(0, (n, r) => n + r.$2 - r.$1),
              sidecar: settings.opusSidecar);
          final free = await freeBytes();
          if (free != null && free - storageHeadroomBytes < need) {
            Logger.debug('PublishJob: $need bytes to render, $free free: waiting for space');
            final ok = await flush();
            return PublishReport(ok ? PublishStop.storageFull : PublishStop.stale, published);
          }
          try {
            rendered = await renderer.render(item, Directory('${job.staging.path}/${seq++}'));
          } on RenderFailed catch (e) {
            final ok = await flush();
            if (!ok) return PublishReport(PublishStop.stale, published);
            return PublishReport(e.storageFull ? PublishStop.storageFull : PublishStop.failed, published,
                failedItem: item, error: e);
          }
          faultHook?.call('rendered');
          batchMs += rendered.durationMs;
        }
        batch.add(StagedItem(item, bytes, rendered));
        onItem?.call(index);
        if (batch.length >= settings.maxItemsPerCommit || batchMs >= settings.maxAudioMsPerCommit) {
          if (!await flush()) return PublishReport(PublishStop.stale, published);
        }
      }
      if (!await flush()) return PublishReport(PublishStop.stale, published);
      return PublishReport(PublishStop.done, published);
    } on RenderCancelled {
      return PublishReport(PublishStop.cancelled, published);
    } finally {
      renderer.dispose();
      await coordinator.finishJob(job);
    }
  }
}
