import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/raw_chunks.dart';

/// Writes records the way the firmware does: little-endian words, frames padded to 4.
class _Bin {
  final _b = BytesBuilder();
  int get length => _b.length;

  void word(int w) => _b.add((ByteData(4)..setUint32(0, w, Endian.little)).buffer.asUint8List());

  void header({int utcMs = 1789100000000, int uptimeMs = 5000, int imu = 77, int session = 7}) {
    final d = ByteData(36)
      ..setUint32(0, 0xFFFFFFFB, Endian.little)
      ..setUint32(4, 28, Endian.little)
      ..setUint64(8, utcMs, Endian.little)
      ..setUint64(16, uptimeMs, Endian.little)
      ..setUint32(24, imu, Endian.little)
      ..setUint32(28, session, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void frame(int payloadLength, {int fill = 1}) {
    word(payloadLength);
    _b.add(List.filled(payloadLength, fill));
    _b.add(List.filled(((payloadLength + 3) & ~3) - payloadLength, 0));
  }

  void marker(int tag, {int utcMs = 1789100001000, int uptimeMs = 6000, int session = 7}) {
    final d = ByteData(20)
      ..setUint32(0, tag, Endian.little)
      ..setUint64(4, utcMs, Endian.little)
      ..setUint32(12, uptimeMs, Endian.little)
      ..setUint32(16, session, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void resume({int utcSeconds = 1789100002, int uptimeMs = 7000}) {
    final d = ByteData(20)
      ..setUint32(0, 0xFFFFFFFD, Endian.little)
      ..setUint32(4, utcSeconds, Endian.little)
      ..setUint32(8, uptimeMs, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  Uint8List bytes() => _b.toBytes();
}

void main() {
  group('parse', () {
    test('frames, padding and every marker kind, each at its own offset', () {
      final bin = _Bin()
        ..header()
        ..frame(71)
        ..marker(0xFFFFFFFE)
        ..frame(105)
        ..word(0)
        ..word(0xFFFFFFFF)
        ..resume()
        ..marker(0xFFFFFFFC)
        ..marker(0xFFFFFFF8)
        ..marker(0xFFFFFFFA)
        ..marker(0xFFFFFFF9)
        ..frame(1);
      final r = parseRecords(bin.bytes());
      expect(r.stop, ParseStop.none);
      expect(r.parsedEnd, r.length);
      expect(r.frameOffsets, [36, 132, 352]);
      expect(r.frameLengths, [71, 105, 1]);
      expect(r.events.map((e) => (e.kind, e.offset, e.frameIndex)), [
        (CardEventKind.header, 0, 0),
        (CardEventKind.tap, 112, 1),
        (CardEventKind.resume, 252, 2),
        (CardEventKind.stop, 272, 2),
        (CardEventKind.priorityStart, 292, 2),
        (CardEventKind.muteOn, 312, 2),
        (CardEventKind.muteOff, 332, 2),
      ]);
      final header = r.header!;
      expect((header.utcMs, header.uptimeMs, header.imuTicks, header.sessionId), (1789100000000, 5000, 77, 7));
      final tap = r.events[1];
      expect((tap.utcMs, tap.uptimeMs, tap.sessionId), (1789100001000, 6000, 7));
      final resume = r.events[2];
      expect((resume.utcMs, resume.uptimeMs, resume.sessionId), (1789100002000, 7000, null));
    });

    test('a record is counted only when it is all there, padding included', () {
      final bin = _Bin()
        ..header()
        ..frame(5); // 4 + 8 bytes
      final whole = bin.bytes();
      for (var cut = 36; cut < whole.length; cut++) {
        final r = parseRecords(Uint8List.sublistView(whole, 0, cut));
        expect(r.frameCount, 0, reason: 'cut at $cut');
        expect(r.parsedEnd, 36, reason: 'cut at $cut');
        expect(r.stop, cut == 36 ? ParseStop.none : ParseStop.incomplete, reason: 'cut at $cut');
      }
      expect(parseRecords(whole).frameCount, 1);
    });

    test('a marker cut short has no effect: neither its event nor what follows', () {
      final bin = _Bin()
        ..header()
        ..resume();
      final whole = bin.bytes();
      for (var cut = 37; cut < whole.length; cut++) {
        final r = parseRecords(Uint8List.sublistView(whole, 0, cut));
        expect(r.events.map((e) => e.kind), [CardEventKind.header], reason: 'cut at $cut');
      }
    });

    test('a word that is neither a marker nor a possible frame stops the walk there', () {
      final bin = _Bin()
        ..header()
        ..frame(10)
        ..word(maxFramePayload + 1)
        ..frame(10);
      final r = parseRecords(bin.bytes());
      expect(r.stop, ParseStop.unknownRecord);
      expect(r.parsedEnd, 36 + 16);
      expect(r.frameCount, 1);
    });

    test('a header later in the file is an event, not the one that dates it', () {
      final bin = _Bin()
        ..frame(4)
        ..header(utcMs: 1789100009000);
      final r = parseRecords(bin.bytes());
      expect(r.header, isNull);
      expect(r.events.single.kind, CardEventKind.header);
    });
  });

  group('how a file ends', () {
    Uint8List cutFrame() {
      final bin = _Bin()
        ..header()
        ..frame(10)
        ..frame(100);
      final whole = bin.bytes();
      return Uint8List.sublistView(whole, 0, whole.length - 30);
    }

    test('a cut last record waits while the file is receiving, and is a cut tail once it is complete', () {
      final r = parseRecords(cutFrame());
      expect(r.endFor(SourceLifecycle.receiving), FileEnd.awaitingBytes);
      expect(r.endFor(SourceLifecycle.complete), FileEnd.cutTail);
      expect(r.endFor(SourceLifecycle.sourceGone), FileEnd.cutTail);
    });

    test('more than a record left unreadable in a complete file is damage', () {
      final bin = _Bin()
        ..header()
        ..word(5000);
      for (var i = 0; i < 400; i++) {
        bin.word(0x01010101);
      }
      final r = parseRecords(bin.bytes());
      expect(r.endFor(SourceLifecycle.complete), FileEnd.damaged);
      expect(r.endFor(SourceLifecycle.receiving), FileEnd.damaged, reason: 'no later byte makes it readable');
    });

    test('a file read to its end is clean', () {
      final bin = _Bin()
        ..header()
        ..frame(10);
      expect(parseRecords(bin.bytes()).endFor(SourceLifecycle.receiving), FileEnd.clean);
    });
  });

  group('real firmware bins', () {
    Uint8List fixture(String name) => File('test/fixtures/bins/$name').readAsBytesSync();

    test('the 476-byte bin: header, four frames, a resume, and block padding', () {
      final r = parseRecords(fixture('1787938578_4261367757.bin'));
      expect(r.stop, ParseStop.none);
      expect(r.parsedEnd, 476);
      expect(r.frameOffsets, [36, 132, 244, 340]);
      expect(r.frameLengths, [71, 105, 90, 91]);
      expect(r.events.map((e) => (e.kind, e.offset, e.frameIndex)), [
        (CardEventKind.header, 0, 0),
        (CardEventKind.resume, 112, 1),
      ]);
      expect(r.header!.sessionId, 4261367757);
      expect(r.header!.utcMs, 1787938578557);
      expect(r.events[1].hasClock, isTrue);
    });

    test('the 36-byte rotation: a header and nothing else', () {
      final r = parseRecords(fixture('1788031307_1193025564.bin'));
      expect(r.frameCount, 0);
      expect(r.events.single.kind, CardEventKind.header);
      expect(r.endFor(SourceLifecycle.complete), FileEnd.clean);
    });
  });

  group('persistence', () {
    late Directory root;
    late RawChunkStore store;
    const key = RawFileKey(1789100000, 7);

    setUp(() {
      root = Directory.systemTemp.createTempSync('card_');
      store = RawChunkStore(root.path);
    });
    tearDown(() => root.deleteSync(recursive: true));

    FileCard card() {
      final bin = _Bin()
        ..header()
        ..frame(3)
        ..marker(0xFFFFFFFE)
        ..frame(7);
      final r = parseRecords(bin.bytes());
      return FileCard(
        key: key,
        indexerVersion: cardIndexerVersion,
        chunks: [(0, r.length)],
        records: r,
        decoderId: 'dec',
        vadModelId: 'vad',
        audio: FrameAudio(decoded: Uint8List.fromList([1, 0]), speech: Float32List.fromList([0.25, -1])),
      );
    }

    test('a card survives a round trip exactly', () async {
      final original = card();
      await saveCard(store, original);
      final loaded = (await loadCard(store, key))!;
      expect(loaded.key, key);
      expect(loaded.chunks, original.chunks);
      expect(loaded.records.frameOffsets, original.records.frameOffsets);
      expect(loaded.records.frameLengths, original.records.frameLengths);
      expect(loaded.records.events, original.records.events);
      expect((loaded.records.parsedEnd, loaded.records.length, loaded.records.stop),
          (original.records.parsedEnd, original.records.length, original.records.stop));
      expect(loaded.audio.decoded, [1, 0]);
      expect(loaded.audio.speech, [0.25, -1]);
      expect((loaded.decoderId, loaded.vadModelId), ('dec', 'vad'));
    });

    test('a damaged card reads as missing, to be rebuilt', () async {
      await saveCard(store, card());
      final file = cardFileFor(store, key);
      await file.writeAsBytes((await file.readAsBytes()).sublist(0, 30));
      expect(await loadCard(store, key), isNull);
    });

    test('a card is stale once its file has another chunk, or another version made it', () async {
      final c = card();
      LogicalRawFile file(List<RawChunk> chunks) => LogicalRawFile(
          key: key,
          chunks: chunks,
          lifecycle: SourceLifecycle.receiving,
          advertisedLength: null,
          firstSealedAtMs: null,
          hasManifest: true);
      final same = file([RawChunk(offset: 0, length: c.records.length, provenance: ChunkProvenance.echoed, path: 'x')]);
      expect(c.isCurrentFor(same, decoderId: 'dec', vadModelId: 'vad'), isTrue);
      expect(c.isCurrentFor(same, decoderId: 'dec', vadModelId: 'other'), isFalse);
      final otherFile = LogicalRawFile(
          key: const RawFileKey(1789100600, 7),
          chunks: same.chunks,
          lifecycle: SourceLifecycle.receiving,
          advertisedLength: null,
          firstSealedAtMs: null,
          hasManifest: true);
      expect(c.isCurrentFor(otherFile, decoderId: 'dec', vadModelId: 'vad'), isFalse, reason: "another file's card");
      expect(c.isCurrentFor(same, decoderId: 'other', vadModelId: 'vad'), isFalse);
      final grown = file([
        RawChunk(offset: 0, length: c.records.length, provenance: ChunkProvenance.echoed, path: 'x'),
        RawChunk(offset: c.records.length, length: 8, provenance: ChunkProvenance.echoed, path: 'y'),
      ]);
      expect(c.isCurrentFor(grown, decoderId: 'dec', vadModelId: 'vad'), isFalse);
    });

    test('the event summary keeps every marker and survives JSON', () {
      final s = card().summary;
      final back = EventSummary.fromJson(s.toJson());
      expect(back.key, key);
      expect(back.frameCount, 2);
      expect(back.events, s.events);
      expect(back.events.map((e) => e.kind), [CardEventKind.header, CardEventKind.tap]);
    });
  });
}
