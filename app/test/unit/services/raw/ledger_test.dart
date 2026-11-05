import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';

void main() {
  const key = RawFileKey(1789100000, 7);
  const rec = Owner(OwnerKind.recording, '2026-09-11/recording_1');
  const other = Owner(OwnerKind.discard, 'd1');

  group('claims', () {
    test('a claim applied again changes nothing', () {
      final e = LedgerEntry(key)..claim(rec, [(100, 200), (300, 400)], [40]);
      e.claim(rec, [(100, 200), (300, 400)], [40]);
      expect(e.frames, [const OwnedRange(100, 200, rec), const OwnedRange(300, 400, rec)]);
      expect(e.events, {40: rec});
    });

    test('byte-adjacent ranges of one owner are coalesced; a claim over them is still a replay', () {
      final e = LedgerEntry(key)
        ..claim(rec, [(100, 200)], [])
        ..claim(rec, [(200, 300)], []);
      expect(e.frames, [const OwnedRange(100, 300, rec)]);
      e.claim(rec, [(150, 250)], []);
      expect(e.frames, [const OwnedRange(100, 300, rec)]);
    });

    test('another owner\'s frames or marker refuse the whole claim', () {
      final e = LedgerEntry(key)..claim(rec, [(100, 200)], [40]);
      expect(() => e.claim(other, [(500, 600), (150, 160)], []), throwsA(isA<LedgerConflict>()));
      expect(() => e.claim(other, [(500, 600)], [40]), throwsA(isA<LedgerConflict>()));
      expect(() => e.claim(other, [(500, 600), (550, 650)], []), throwsA(isA<LedgerConflict>()));
      expect(e.frames, [const OwnedRange(100, 200, rec)], reason: 'nothing of a refused claim is kept');
      expect(e.events, {40: rec});
    });

    test('ranges of different owners that touch stay apart', () {
      final e = LedgerEntry(key)
        ..claim(rec, [(100, 200)], [])
        ..claim(other, [(200, 300)], []);
      expect(e.frames, [const OwnedRange(100, 200, rec), const OwnedRange(200, 300, other)]);
    });
  });

  test('a day file round-trips, receipt and tombstone included', () {
    final day = LedgerDay('2026-09-11');
    day.entryFor(key)
      ..claim(rec, [(100, 200)], [40])
      ..tombstone = const Tombstone(5, 'deleteDay')
      ..summary =
          const EventSummary(key: key, length: 999, frameCount: 3, firstFrameOffset: 36, events: [], hasVad: true)
      ..receipt = const Receipt(
          length: 999,
          lifecycle: SourceLifecycle.complete,
          advertisedLength: 999,
          firstSealedAtMs: 12,
          provenance: [ChunkProvenance.echoed, ChunkProvenance.uncorrelated]);
    final again = LedgerDay.decode(day.name, day.encode());
    expect(again.encode(), day.encode());
    final e = again.entries[key.rel]!;
    expect(e.tombstone!.reason, 'deleteDay');
    expect(e.receipt!.provenance, [ChunkProvenance.echoed, ChunkProvenance.uncorrelated]);
    expect(e.summary!.length, 999);
  });

  test('the stream file round-trips', () {
    final s = StreamState(
      generation: 3,
      boundaries: [const PlanBoundary(BoundaryKind.force, key, 1234)],
      caps: [(atMs: 1, minutes: 120)],
      setAside: [key],
    );
    final again = StreamState.decode(s.encode());
    expect(again.encode(), s.encode());
    expect(again.boundaries.single.offset, 1234);
  });

  test('day files: the UTC date of the name, or the session before the clock was set', () {
    expect(ledgerDayOf(const RawFileKey(1789100000, 7)), '2026-09-11');
    expect(ledgerDayOf(const RawFileKey(1234, 7)), 'session_7');
  });

  test('saved and loaded through the documents directory', () async {
    final root = Directory.systemTemp.createTempSync('ledger_');
    addTearDown(() => root.deleteSync(recursive: true));
    final ledger = Ledger(root.path);
    final day = await ledger.loadDay(ledgerDayOf(key));
    day.entryFor(key).claim(rec, [(1, 2)], []);
    await ledger.saveDay(day);
    expect((await ledger.entriesFor([key, const RawFileKey(1789100000, 8)])).keys, [key]);
    expect((await ledger.loadStream()).generation, 0);
  });

  group('what the planner sees', () {
    Bin bin() => Bin(1789100000000)
      ..frames(3, p: speech)
      ..tap()
      ..frames(3, p: speech)
      ..muteOn()
      ..frames(2, p: speech);

    test('byte ranges become the frames whose records start in them', () {
      final b = bin();
      final f = b.file();
      final records = parseRecords(b.bytes);
      // Frames 1..4 (a tap between 2 and 3), then frame 7.
      final e = LedgerEntry(f.key)
        ..claim(rec, [byteRangeOf(records, 1, 5), byteRangeOf(records, 7, 8)], [f.events[1].offset]);
      final owned = planOwnershipOf({f.key: e}, [f]);
      expect(owned.frames[f.key], [(1, 5), (7, 8)]);
      expect(owned.events, {EventId(f.key, f.events[1].offset)});
    });

    test('a range ends at its last frame\'s record: the next frame is not in it', () {
      final b = bin();
      final records = parseRecords(b.bytes);
      final (start, end) = byteRangeOf(records, 0, 3);
      expect(start, records.frameOffsets[0]);
      expect(end, records.frameOffsets[2] + 12);
      expect(end, lessThan(records.frameOffsets[3]));
    });

    test('a tombstoned file is owned whole, its markers too', () {
      final f = bin().file();
      final e = LedgerEntry(f.key)..tombstone = const Tombstone(1, 'deleteDay');
      final owned = planOwnershipOf({f.key: e}, [f]);
      expect(owned.frames[f.key], [(0, 8)]);
      expect(owned.events, {for (final m in f.events.skip(1)) EventId(f.key, m.offset)});
    });

    test('adjacent ranges of different owners make one planner range', () {
      final b = bin();
      final f = b.file();
      final records = parseRecords(b.bytes);
      final e = LedgerEntry(f.key)
        ..claim(rec, [byteRangeOf(records, 0, 2)], [])
        ..claim(other, [byteRangeOf(records, 2, 3)], []);
      expect(planOwnershipOf({f.key: e}, [f]).frames[f.key], [(0, 3)]);
    });
  });
}
