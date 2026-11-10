// The gate (RECORDINGS_PIPELINE_REDESIGN.md §6): the one way a raw file leaves the phone.
//
// A logical file's chunks, manifest and card are deleted only when it is in a terminal
// state (nothing more of it will come), it is not set aside, no live job reads it, and
// either it is tombstoned or every frame and every tap and Priority Recording start in
// it is owned by something other than a discard: a discard's audio stays recoverable
// until it is deleted, recovered or expires (§7), each of which hands it to another
// owner. Its ledger entry then keeps a receipt and its event summary, so the event layer
// never depends on files that are gone; the receipt is written before the chunks go.
//
// Not switched on yet (see raw_chunks.dart).

import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/raw_chunks.dart';

class RawBinGate {
  final OwnershipCoordinator coordinator;

  RawBinGate(this.coordinator);

  RawChunkStore get _store => coordinator.store;

  /// Releases each of [candidates] (every logical file on the phone by default) that may
  /// go, one transaction each. Returns those released.
  Future<Set<RawFileKey>> release({Iterable<RawFileKey>? candidates}) async {
    final keys = candidates ?? await _store.listKeys();
    final released = <RawFileKey>{};
    for (final key in keys) {
      final done = await coordinator.transact('gate', () async {
        final ops = await _releaseOps(key);
        return (ops, ops.isNotEmpty);
      });
      if (done) released.add(key);
    }
    return released;
  }

  /// Why [key] may not go now, or null. In the queue.
  Future<String?> blocked(RawFileKey key) async => (await _assess(key)).$1;

  Future<List<JournalOp>> _releaseOps(RawFileKey key) async {
    var (why, file, records, entry) = await _assess(key);
    if (why != null) return const [];
    if (entry?.receipt != null) {
      // Released before; these chunks are a copy that came back. The receipt stands.
      return [DeleteRawOp(key)];
    }
    final card = await _currentCard(file!);
    records ??= card?.records ?? parseRecords(await file.read(0, file.length));
    final summary = card?.summary ??
        EventSummary(
          key: key,
          length: records.length,
          frameCount: records.frameCount,
          firstFrameOffset: records.frameCount == 0 ? null : records.frameOffsets[0],
          events: records.events,
          hasVad: entry?.summary?.hasVad ?? true,
        );
    final receipt = Receipt(
      length: file.length,
      lifecycle: file.lifecycle,
      advertisedLength: file.advertisedLength,
      firstSealedAtMs: file.firstSealedAtMs,
      provenance: [for (final c in file.chunks) c.provenance],
    );
    // The receipt first: the event layer must never lose a file's markers.
    return [ReceiptOp(receipt, summary), DeleteRawOp(key)];
  }

  Future<(String?, LogicalRawFile?, ParsedRecords?, LedgerEntry?)> _assess(RawFileKey key) async {
    final file = await _store.load(key);
    if (file.chunks.isEmpty) return ('nothing on the phone', null, null, null);
    final entry = (await coordinator.ledger.entriesFor([key]))[key];
    if (!file.lifecycle.isTerminal) return ('still receiving', file, null, entry);
    if ((await coordinator.ledger.loadStream()).setAside.contains(key)) return ('set aside', file, null, entry);
    if (coordinator.heldByJobs.contains(key)) return ('a job reads it', file, null, entry);
    if (entry?.receipt != null || entry?.tombstone != null) return (null, file, null, entry);
    final records = (await _currentCard(file))?.records ?? parseRecords(await file.read(0, file.length));
    final owned = [
      for (final r in entry?.frames ?? const <OwnedRange>[])
        if (r.owner.kind != OwnerKind.discard) r
    ];
    var at = 0;
    for (var i = 0; i < records.frameCount; i++) {
      final o = records.frameOffsets[i];
      while (at < owned.length && owned[at].end <= o) {
        at++;
      }
      if (at == owned.length || owned[at].start > o) return ('frame $i is not owned for good', file, records, entry);
    }
    for (final e in records.events) {
      if (e.kind != CardEventKind.tap && e.kind != CardEventKind.priorityStart) continue;
      if (!(entry?.events.containsKey(e.offset) ?? false)) {
        return ('marker @${e.offset} is not owned', file, records, entry);
      }
    }
    return (null, file, records, entry);
  }

  /// The file's card, if it describes these chunks.
  Future<FileCard?> _currentCard(LogicalRawFile file) async {
    final card = await loadCard(_store, file.key);
    if (card == null) return null;
    final chunks = [for (final c in file.chunks) (c.offset, c.length)];
    if (card.chunks.length != chunks.length) return null;
    for (var i = 0; i < chunks.length; i++) {
      if (card.chunks[i] != chunks[i]) return null;
    }
    return card;
  }
}
