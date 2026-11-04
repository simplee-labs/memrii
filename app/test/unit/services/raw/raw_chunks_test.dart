import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/raw_chunks.dart';

void main() {
  late Directory root;
  late RawChunkStore store;
  const key = RawFileKey(1789100000, 7);

  setUp(() {
    root = Directory.systemTemp.createTempSync('raw_chunks_');
    store = RawChunkStore(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Uint8List bytes(int from, int to) => Uint8List.fromList([for (var i = from; i < to; i++) i % 251]);

  /// What a native transfer leaves: a part holding [content].
  Future<void> writePart(RawFileKey k, int appendOffset, List<int> content) async {
    final part = store.partFile(k, appendOffset);
    await part.parent.create(recursive: true);
    await part.writeAsBytes(content, flush: true);
  }

  File manifestOf(RawFileKey k) => File('${store.folderOf(k).path}/${k.manifestName}');

  group('layout', () {
    test('the first chunk keeps today\'s bin path; continuations are named by offset', () {
      expect(key.rel, '1789100000/1789100000_7.bin');
      expect(key.chunkName(4096), '1789100000_7@4096.bin');
      expect(key.partName(0), '1789100000_7.bin.partial');
      expect(const RawFileKey(1234, 3).rel, 'session_3/1234_3.bin');
    });
  });

  group('load', () {
    test('a file never downloaded is empty', () async {
      final file = await store.load(key);
      expect(file.length, 0);
      expect(file.hasManifest, isFalse);
    });

    test('a bin from before this format is one imported chunk', () async {
      final bin = File('${root.path}/raw_segments/${key.rel}');
      await bin.parent.create(recursive: true);
      await bin.writeAsBytes(bytes(0, 100));
      final file = await store.load(key);
      expect(file.hasManifest, isFalse);
      expect(file.chunks.single.provenance, ChunkProvenance.imported);
      expect(await file.read(0, 100), bytes(0, 100));
    });

    test('a continuation after an imported bin keeps the bin as its first chunk', () async {
      final bin = File('${root.path}/raw_segments/${key.rel}');
      await bin.parent.create(recursive: true);
      await bin.writeAsBytes(bytes(0, 4));
      await writePart(key, 4, bytes(4, 10));
      await store.seal(key, appendOffset: 4, keepLength: 6, provenance: ChunkProvenance.echoed);
      final file = await store.load(key);
      expect(file.hasManifest, isTrue);
      expect(file.chunks.map((c) => (c.offset, c.length, c.provenance)), [
        (0, 4, ChunkProvenance.imported),
        (4, 6, ChunkProvenance.echoed),
      ]);
      expect(await file.read(0, 10), bytes(0, 10));
    });

    test('recording a lifecycle for an imported bin keeps the bin', () async {
      final bin = File('${root.path}/raw_segments/${key.rel}');
      await bin.parent.create(recursive: true);
      await bin.writeAsBytes(bytes(0, 4));
      await store.setLifecycle(key, SourceLifecycle.receiving, advertisedLength: 8);
      final file = await store.load(key);
      expect(file.length, 4);
      expect(file.chunks.single.provenance, ChunkProvenance.imported);
      expect(file.advertisedLength, 8);
    });

    test('a chunk whose length differs from its manifest entry is reported, not read', () async {
      await writePart(key, 0, bytes(0, 50));
      await store.seal(key, appendOffset: 0, keepLength: 50, provenance: ChunkProvenance.echoed);
      final chunk = File('${root.path}/raw_segments/${key.rel}');
      await chunk.writeAsBytes(bytes(0, 40));
      expect(() => store.load(key), throwsA(isA<RawFileInconsistent>()));
    });
  });

  group('seal', () {
    test('a part becomes a chunk, listed with its provenance and the advertised length', () async {
      await writePart(key, 0, bytes(0, 64));
      final chunk = await store.seal(key,
          appendOffset: 0, keepLength: 64, provenance: ChunkProvenance.echoed, advertisedLength: 200);
      expect(chunk!.length, 64);
      expect(await store.partFile(key, 0).exists(), isFalse);
      final file = await store.load(key);
      expect(file.hasManifest, isTrue);
      expect(file.length, 64);
      expect(file.chunks.single.provenance, ChunkProvenance.echoed);
      expect(file.advertisedLength, 200);
      expect(file.firstSealedAtMs, isNotNull);
      expect(file.lifecycle, SourceLifecycle.receiving);
    });

    test('bytes past the accepted length are cut off before sealing', () async {
      await writePart(key, 0, bytes(0, 64));
      await store.seal(key, appendOffset: 0, keepLength: 40, provenance: ChunkProvenance.echoed);
      final file = await store.load(key);
      expect(file.length, 40);
      expect(await file.read(0, 40), bytes(0, 40));
    });

    test('a part that accepted nothing is deleted and seals no chunk', () async {
      await writePart(key, 0, bytes(0, 10));
      expect(await store.seal(key, appendOffset: 0, keepLength: 0, provenance: ChunkProvenance.echoed), isNull);
      expect(await store.partFile(key, 0).exists(), isFalse);
      expect((await store.load(key)).length, 0);
    });

    test('a continuation is read as one logical file with the chunks before it', () async {
      await writePart(key, 0, bytes(0, 100));
      await store.seal(key, appendOffset: 0, keepLength: 100, provenance: ChunkProvenance.echoed);
      await writePart(key, 100, bytes(100, 180));
      await store.seal(key, appendOffset: 100, keepLength: 80, provenance: ChunkProvenance.uncorrelated);
      final file = await store.load(key);
      expect(file.chunks.map((c) => (c.offset, c.length, c.provenance)), [
        (0, 100, ChunkProvenance.echoed),
        (100, 80, ChunkProvenance.uncorrelated),
      ]);
      expect(await file.read(90, 110), bytes(90, 110));
      expect(await file.read(0, 180), bytes(0, 180));
      expect(() => file.read(170, 181), throwsRangeError);
    });

    test('the first seal time is kept by later seals', () async {
      await writePart(key, 0, bytes(0, 10));
      await store.seal(key, appendOffset: 0, keepLength: 10, provenance: ChunkProvenance.echoed);
      final first = (await store.load(key)).firstSealedAtMs;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await writePart(key, 10, bytes(10, 20));
      await store.seal(key, appendOffset: 10, keepLength: 10, provenance: ChunkProvenance.echoed);
      expect((await store.load(key)).firstSealedAtMs, first);
    });

    test('a part that does not start where the sealed chunks end is refused and left alone', () async {
      await writePart(key, 0, bytes(0, 10));
      await store.seal(key, appendOffset: 0, keepLength: 10, provenance: ChunkProvenance.echoed);
      await writePart(key, 12, bytes(12, 20));
      expect(() => store.seal(key, appendOffset: 12, keepLength: 8, provenance: ChunkProvenance.echoed),
          throwsA(isA<RawFileInconsistent>()));
      expect(await store.partFile(key, 12).length(), 8);
    });

    test('concurrent seals of one file are serialized', () async {
      await writePart(key, 0, bytes(0, 10));
      final first = store.seal(key, appendOffset: 0, keepLength: 10, provenance: ChunkProvenance.echoed);
      final lifecycle = store.setLifecycle(key, SourceLifecycle.receiving, advertisedLength: 30);
      await Future.wait([first, lifecycle]);
      final file = await store.load(key);
      expect(file.length, 10);
      expect(file.advertisedLength, 30);
    });
  });

  group('lifecycle', () {
    test('complete needs every advertised byte sealed', () async {
      expect(() => store.setLifecycle(key, SourceLifecycle.complete, advertisedLength: 50),
          throwsA(isA<RawFileInconsistent>()));
      await writePart(key, 0, bytes(0, 30));
      await store.seal(key, appendOffset: 0, keepLength: 30, provenance: ChunkProvenance.echoed, advertisedLength: 50);
      expect(() => store.setLifecycle(key, SourceLifecycle.complete), throwsA(isA<RawFileInconsistent>()));
      expect((await store.load(key)).lifecycle, SourceLifecycle.receiving);
    });

    test('a terminal state is kept and cannot be undone', () async {
      await writePart(key, 0, bytes(0, 50));
      await store.seal(key, appendOffset: 0, keepLength: 50, provenance: ChunkProvenance.echoed);
      await store.setLifecycle(key, SourceLifecycle.complete, advertisedLength: 50);
      expect((await store.load(key)).lifecycle, SourceLifecycle.complete);
      expect(() => store.setLifecycle(key, SourceLifecycle.receiving), throwsA(isA<RawFileInconsistent>()));
      expect(() => store.setLifecycle(key, SourceLifecycle.sourceGone), throwsA(isA<RawFileInconsistent>()));
    });
  });

  group('recover', () {
    test('a seal interrupted between listing and renaming is finished as listed', () async {
      await writePart(key, 0, bytes(0, 30));
      await store.seal(key, appendOffset: 0, keepLength: 30, provenance: ChunkProvenance.echoed);
      // The crash: listed in the manifest, still under its part name.
      await File('${root.path}/raw_segments/${key.rel}').rename(store.partFile(key, 0).path);
      expect((await store.load(key)).length, 0, reason: 'the file ends before a chunk still being sealed');

      expect(await store.recover(persistedEnd: (_) => null), {key});
      final file = await store.load(key);
      expect(file.length, 30);
      expect(file.chunks.single.provenance, ChunkProvenance.echoed);
      expect(await file.read(0, 30), bytes(0, 30));
    });

    test('a stray part at an offset already sealed never replaces the chunk', () async {
      await writePart(key, 0, [1, 2, 3, 4]);
      await store.seal(key, appendOffset: 0, keepLength: 4, provenance: ChunkProvenance.echoed);
      // A second transfer that started from the same sealed length, and could not seal.
      await writePart(key, 0, [9, 8, 7, 6]);
      await store.recover(persistedEnd: (_) => 4);
      expect(await (await store.load(key)).read(0, 4), [1, 2, 3, 4]);
      expect(await store.partFile(key, 0).exists(), isFalse);
      expect(await File('${store.partFile(key, 0).path}.conflict').readAsBytes(), [9, 8, 7, 6]);
    });

    test('a stray part the sealed chunk already holds is simply removed', () async {
      await writePart(key, 0, [1, 2, 3, 4]);
      await store.seal(key, appendOffset: 0, keepLength: 4, provenance: ChunkProvenance.echoed);
      await writePart(key, 0, [1, 2, 3]);
      await store.recover(persistedEnd: (_) => 3);
      expect(await store.partFile(key, 0).exists(), isFalse);
      expect(await File('${store.partFile(key, 0).path}.conflict').exists(), isFalse);
      expect(await (await store.load(key)).read(0, 4), [1, 2, 3, 4]);
    });

    test('a stray part longer than the sealed chunk keeps the bytes only it holds', () async {
      await writePart(key, 0, [1, 2, 3, 4]);
      await store.seal(key, appendOffset: 0, keepLength: 4, provenance: ChunkProvenance.echoed);
      await writePart(key, 0, [1, 2, 3, 4, 5]);
      await store.recover(persistedEnd: (_) => 5);
      expect(await File('${store.partFile(key, 0).path}.conflict').readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await (await store.load(key)).read(0, 4), [1, 2, 3, 4]);
    });

    test('a second conflict at the same offset never replaces the first', () async {
      await writePart(key, 0, [1, 2, 3, 4]);
      await store.seal(key, appendOffset: 0, keepLength: 4, provenance: ChunkProvenance.echoed);
      final conflict = '${store.partFile(key, 0).path}.conflict';
      await writePart(key, 0, [9, 8, 7, 6]);
      await store.recover(persistedEnd: (_) => 4);
      await writePart(key, 0, [6, 7, 8, 9]);
      await store.recover(persistedEnd: (_) => 4);
      expect(await File(conflict).readAsBytes(), [9, 8, 7, 6]);
      expect(await File('$conflict.1').readAsBytes(), [6, 7, 8, 9]);
      // A copy of an earlier conflict adds nothing, and the earlier ones stay as they were.
      await writePart(key, 0, [6, 7, 8, 9]);
      await store.recover(persistedEnd: (_) => 4);
      expect(await store.partFile(key, 0).exists(), isFalse);
      expect(await File('$conflict.2').exists(), isFalse);
      expect(await File(conflict).readAsBytes(), [9, 8, 7, 6]);
      expect(await File('$conflict.1').readAsBytes(), [6, 7, 8, 9]);
    });

    test('a part that does not start where the sealed chunks end is set aside, not sealed', () async {
      await writePart(key, 0, bytes(0, 10));
      await store.seal(key, appendOffset: 0, keepLength: 10, provenance: ChunkProvenance.echoed);
      await writePart(key, 12, bytes(12, 20));
      await store.recover(persistedEnd: (_) => 20);
      expect((await store.load(key)).length, 10);
      expect(await File('${store.partFile(key, 12).path}.conflict').exists(), isTrue);
    });

    test('a part a crash left behind keeps only the bytes before the saved progress', () async {
      await writePart(key, 0, bytes(0, 40));
      await store.seal(key, appendOffset: 0, keepLength: 40, provenance: ChunkProvenance.echoed);
      await writePart(key, 40, bytes(40, 100));
      await store.recover(persistedEnd: (k) => k == key ? 70 : null);
      final file = await store.load(key);
      expect(file.length, 70);
      expect(file.chunks.last.provenance, ChunkProvenance.uncorrelated);
      expect(await file.read(0, 70), bytes(0, 70));
    });

    test('with no saved progress a leftover part keeps nothing', () async {
      await writePart(key, 0, bytes(0, 40));
      await store.recover(persistedEnd: (_) => null);
      expect(await store.partFile(key, 0).exists(), isFalse);
      expect((await store.load(key)).length, 0);
    });

    test('a pre-time-sync file in its session folder is recovered under its own key', () async {
      const early = RawFileKey(1234, 3);
      await writePart(early, 0, bytes(0, 20));
      await store.recover(persistedEnd: (k) => k == early ? 20 : null);
      expect((await store.load(early)).length, 20);
    });
  });

  test('the manifest is plain JSON others can read', () async {
    await writePart(key, 0, bytes(0, 5));
    await store.seal(key, appendOffset: 0, keepLength: 5, provenance: ChunkProvenance.imported, advertisedLength: 9);
    final json = jsonDecode(await manifestOf(key).readAsString()) as Map<String, dynamic>;
    expect(json['v'], 1);
    expect(json['chunks'], [
      {'offset': 0, 'length': 5, 'provenance': 'imported'}
    ]);
    expect(json['advertisedLength'], 9);
  });
}
