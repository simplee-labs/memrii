import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

PlannedRecording _recording(List<PlanPiece> pieces) => PlannedRecording(
      sessionId: 7,
      closeType: CloseType.force,
      closedAt: const PlanPosition(RawFileKey(0, 7), 0),
      pieces: pieces,
      startMs: 1789100000000,
      startUptimeSeconds: 100,
      derivedTime: false,
      markers: const [],
      durationMs: pieces.fold(0, (n, p) => n + p.durationMs),
      frameCount: pieces.whereType<FramesPiece>().fold(0, (n, p) => n + p.span.length),
      silero: true,
      manual: false,
    );

void main() {
  late Directory root;
  late World world;

  setUp(() {
    root = Directory.systemTemp.createTempSync('render_');
    world = World(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  RecordingRenderer renderer({AudioEncoder? encoder, bool sidecar = true, FakeOpus Function()? decoder}) =>
      RecordingRenderer(
        source: (k) async => RenderSource(await world.store.load(k), world.cards[k]!),
        newDecoder: decoder ?? FakeOpus.new,
        encoder: encoder,
        writeSidecar: sidecar,
      );

  Future<Archive> heard(RenderedRecording r) async {
    // Read it back as the archive would hold it.
    final dir = Directory('${root.path}/recordings/2026-01-01')..createSync(recursive: true);
    r.audio.copySync('${dir.path}/recording_1.${r.extension}');
    if (r.sidecar != null) r.sidecar!.copySync('${dir.path}/recording_fs320_1.bin');
    return Archive.read(root.path);
  }

  test('frames in order, silences as zeros, undecodable frames as 20 ms of silence', () async {
    final a = Bin(1789100000000)
      ..frames(5)
      ..frames(1, decoded: false)
      ..frames(4);
    await world.arrive(a);
    final r = await renderer().render(
        _recording([
          FramesPiece(FrameSpan(a.key, 1, 4)),
          const SilencePiece(1234),
          FramesPiece(FrameSpan(a.key, 4, 10)),
        ]),
        Directory('${root.path}/stage/0'));
    expect(r.totalSamples, 9 * 320 + 1234 * 16);
    expect(r.durationMs, 9 * 20 + 1234);
    final archive = await heard(r);
    final rel = archive.heard.keys.single;
    final t = frameTag(a.key);
    expect(
        [for (final h in archive.heard[rel]!) h.$1], [(t, 1), (t, 2), (t, 3), (t, 4), (t, 6), (t, 7), (t, 8), (t, 9)]);
    // The silence, then frame 5's 20 ms of silence before frame 6.
    expect([for (final h in archive.heard[rel]!) h.$2], [0, 0, 0, 1234 * 16, 320, 0, 0, 0]);
    // Every frame decoded as the packet with its own index since the decoder was made:
    // one pass from the file's start, frame 0 decoded and dropped.
    expect([for (final h in archive.heard[rel]!) h.$3], [1, 2, 3, 4, 6, 7, 8, 9]);
    expect([for (final p in archive.sidecars[rel]!) (p.$2, p.$3)],
        [(1, true), (2, true), (3, true), (4, true), (5, false), (6, true), (7, true), (8, true), (9, true)]);
  });

  test('one pass per file across a job\'s recordings; a fresh one only to go back', () async {
    final a = Bin(1789100000000)..frames(10);
    final b = a.next()..frames(10);
    await world.arrive(a);
    await world.arrive(b);
    final made = <FakeOpus>[];
    final rr = renderer(decoder: () {
      final d = FakeOpus();
      made.add(d);
      return d;
    });
    final r1 = await rr.render(_recording([FramesPiece(FrameSpan(a.key, 2, 4))]), Directory('${root.path}/s/1'));
    final r2 = await rr.render(_recording([FramesPiece(FrameSpan(a.key, 6, 10)), FramesPiece(FrameSpan(b.key, 0, 3))]),
        Directory('${root.path}/s/2'));
    expect(made.length, 2, reason: 'file a continued, file b fresh');
    final back = await rr.render(_recording([FramesPiece(FrameSpan(a.key, 0, 2))]), Directory('${root.path}/s/3'));
    expect(made.length, 3, reason: 'going back in a file starts it again');
    for (final r in [r1, r2, back]) {
      final archive = await heard(r);
      final frames = archive.heard.values.single;
      for (final f in frames) {
        expect(f.$3, f.$1.$2, reason: 'frame ${f.$1} decoded with the state its pass had');
      }
      Directory('${root.path}/recordings').deleteSync(recursive: true);
    }
  });

  test('peaks: the loudest sample in each of 200 stretches', () async {
    final a = Bin(1789100000000)..frames(4);
    await world.arrive(a);
    final r = await renderer().render(
        _recording([const SilencePiece(200), FramesPiece(FrameSpan(a.key, 0, 4))]), Directory('${root.path}/s'));
    expect(r.peaks.length, 200);
    // 3200 samples of silence then 1280 of frames: buckets of 22.4 samples.
    expect(r.peaks.sublist(0, 142).every((p) => p == 0), isTrue);
    expect(r.peaks.sublist(143).every((p) => p >= (1000 / 32768 * 65535).round()), isTrue);
  });

  test('M4A: encoded in staging, the WAV gone; a failing encoder leaves the WAV', () async {
    final a = Bin(1789100000000)..frames(4);
    await world.arrive(a);
    final enc = FakeEncoder();
    final r = await renderer(encoder: enc)
        .render(_recording([FramesPiece(FrameSpan(a.key, 0, 4))]), Directory('${root.path}/m'));
    expect(r.extension, 'm4a');
    expect(r.audio.path, endsWith('audio.m4a'));
    expect(File('${root.path}/m/audio.wav').existsSync(), isFalse);
    enc.fail = true;
    final w = await renderer(encoder: enc)
        .render(_recording([FramesPiece(FrameSpan(a.key, 0, 4))]), Directory('${root.path}/w'));
    expect(w.extension, 'wav');
    expect(w.audio.existsSync(), isTrue);
    expect(File('${root.path}/w/audio.m4a').existsSync(), isFalse);
  });

  test('a decoder that breaks fails the render; the next starts a fresh pass', () async {
    final a = Bin(1789100000000)..frames(10);
    await world.arrive(a);
    var broken = true;
    final rr = renderer(decoder: () => broken ? FakeOpus(failAfter: 3) : FakeOpus());
    await expectLater(rr.render(_recording([FramesPiece(FrameSpan(a.key, 0, 10))]), Directory('${root.path}/f')),
        throwsA(isA<RenderFailed>().having((e) => e.storageFull, 'storageFull', isFalse)));
    broken = false;
    final r = await rr.render(_recording([FramesPiece(FrameSpan(a.key, 5, 8))]), Directory('${root.path}/g'));
    final archive = await heard(r);
    expect([for (final f in archive.heard.values.single) f.$3], [5, 6, 7]);
  });

  test('cancelled inside a long recording', () async {
    final a = Bin(1789100000000)..frames(2000);
    await world.arrive(a);
    var calls = 0;
    final rr = RecordingRenderer(
      source: (k) async => RenderSource(await world.store.load(k), world.cards[k]!),
      newDecoder: FakeOpus.new,
      isCancelled: () => ++calls > 2,
    );
    await expectLater(rr.render(_recording([FramesPiece(FrameSpan(a.key, 0, 2000))]), Directory('${root.path}/c')),
        throwsA(isA<RenderCancelled>()));
  });

  test('a long silence is written in blocks', () async {
    final a = Bin(1789100000000)..frames(1);
    await world.arrive(a);
    // Ten minutes of silence: 19 MB, never one allocation.
    final r = await renderer(sidecar: false).render(
        _recording([FramesPiece(FrameSpan(a.key, 0, 1)), const SilencePiece(600000)]), Directory('${root.path}/l'));
    expect(r.audio.lengthSync(), 44 + (320 + 600000 * 16) * 2);
    final tail = Uint8List(1000);
    final raf = r.audio.openSync()..setPositionSync(r.audio.lengthSync() - 1000);
    raf.readIntoSync(tail);
    raf.closeSync();
    expect(tail.every((b) => b == 0), isTrue);
  });

  test('a packet that decodes to other than 20 ms is padded or cut to it: the timeline stays exact', () async {
    final a = Bin(1789100000000)..frames(3);
    await world.arrive(a);
    var n = 0;
    final rr = RecordingRenderer(
      source: (k) async => RenderSource(await world.store.load(k), world.cards[k]!),
      newDecoder: () => _Sized(() => [160, 640, 320][n++ % 3]),
    );
    final r = await rr.render(_recording([FramesPiece(FrameSpan(a.key, 0, 3))]), Directory('${root.path}/o'));
    expect(r.totalSamples, 960);
    expect(r.audio.lengthSync(), 44 + 960 * 2);
    final pcm = Int16List.sublistView(r.audio.readAsBytesSync(), 44);
    expect(pcm.sublist(0, 160).every((s) => s == 5), isTrue);
    expect(pcm.sublist(160, 320).every((s) => s == 0), isTrue, reason: 'the short one padded with silence');
    expect(pcm.sublist(320, 960).every((s) => s == 5), isTrue, reason: 'the long one cut to 320');
  });

  test('space to render: WAV, M4A beside it, and the sidecar', () {
    final r = _recording([const SilencePiece(1000)]);
    expect(bytesToRender(r, m4a: false, sourceBytes: 99, sidecar: false), 44 + 16000 * 2);
    expect(bytesToRender(r, m4a: false, sourceBytes: 99, sidecar: true), 44 + 16000 * 2 + 99);
    expect(bytesToRender(r, m4a: true, sourceBytes: 99, sidecar: false), greaterThan(44 + 16000 * 2 + 4000));
  });
}

class _Sized implements FrameDecoder {
  final int Function() size;
  _Sized(this.size);
  @override
  Int16List? decode(Uint8List packet) {
    final n = size();
    return Int16List(n)..fillRange(0, n, 5);
  }

  @override
  void dispose() {}
}
