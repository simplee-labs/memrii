import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:opus_dart/opus_dart.dart';

const _samplesPerFrame = 320;

/// Sample [s] of the PCM a packet decodes to: its first byte × 100, plus [s], so every
/// sample differs from its neighbours and each frame's samples are recognisable. A first
/// byte of 0xEE is a packet that cannot be decoded.
int _sampleOf(int first, int s) => first * 100 + s;

class _Decoder implements FrameDecoder {
  bool disposed = false;

  /// Fails as a broken decoder does, from this frame on, by throwing [failure].
  int? brokenFrom;
  Object failure = StateError('decoder state corrupted');
  int _frame = 0;

  @override
  Int16List? decode(Uint8List packet) {
    if (brokenFrom != null && _frame >= brokenFrom!) throw failure;
    _frame++;
    if (packet[0] == 0xEE) return null;
    return Int16List.fromList([for (var s = 0; s < _samplesPerFrame; s++) _sampleOf(packet[0], s)]);
  }

  @override
  void dispose() => disposed = true;
}

/// A model with state: each window's probability depends on its samples, in order, and on
/// every window before it since the last fresh start, as an LSTM's does. The state takes
/// in one sample at a time, so the same samples in another order score differently.
int _step(int state, int sample) => (state * 31 + sample) % 1000003;
double _probability(int state) => (state % 1000) / 1000;

class _Model implements SpeechModel {
  final calls = <(bool fresh, int windows)>[];
  int _state = 0;
  Object? failWith;
  int extra = 0;

  /// Replaces window [poisonAt]'s answer.
  int? poisonAt;
  double poison = double.nan;

  @override
  String get id => 'fake-vad';

  @override
  Future<Float32List> run(Float32List samples, {required bool fresh}) async {
    if (failWith != null) throw failWith!;
    final n = samples.length ~/ vadWindowSamples;
    calls.add((fresh, n));
    if (fresh) _state = 0;
    final out = Float32List(n + extra);
    for (var w = 0; w < n; w++) {
      for (var s = 0; s < vadWindowSamples; s++) {
        _state = _step(_state, (samples[w * vadWindowSamples + s] * 32768).round());
      }
      out[w] = _probability(_state);
    }
    if (poisonAt != null && poisonAt! < n) out[poisonAt!] = poison;
    return out;
  }
}

void main() {
  late Directory root;
  late RawChunkStore store;
  const key = RawFileKey(1789100000, 7);

  setUp(() {
    root = Directory.systemTemp.createTempSync('card_audio_');
    store = RawChunkStore(root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A bin of frames whose first payload bytes are [firsts].
  Future<void> writeBin(List<int> firsts, {RawFileKey k = key}) async {
    final b = BytesBuilder();
    for (final f in firsts) {
      b.add((ByteData(4)..setUint32(0, 8, Endian.little)).buffer.asUint8List());
      b.add([f, 0, 0, 0, 0, 0, 0, 0]);
    }
    final file = File('${root.path}/raw_segments/${k.rel}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(b.toBytes());
  }

  /// The rule written out independently: decoded frames' samples in order, cut into
  /// 512-sample windows; the model's state runs through them from zero; window g belongs
  /// to the frame holding its last sample.
  List<double> expectedSpeech(List<int> firsts) {
    final speech = List<double>.filled(firsts.length, -1);
    final samples = <int>[];
    final frameOfSample = <int>[];
    for (var i = 0; i < firsts.length; i++) {
      if (firsts[i] == 0xEE) continue;
      for (var s = 0; s < _samplesPerFrame; s++) {
        samples.add(_sampleOf(firsts[i], s));
        frameOfSample.add(i);
      }
    }
    var state = 0;
    for (var g = 0; (g + 1) * vadWindowSamples <= samples.length; g++) {
      for (final sample in samples.sublist(g * vadWindowSamples, (g + 1) * vadWindowSamples)) {
        state = _step(state, sample);
      }
      final frame = frameOfSample[(g + 1) * vadWindowSamples - 1];
      final p = _probability(state);
      if (p > speech[frame]) speech[frame] = p;
    }
    return speech;
  }

  void expectSpeech(FileCard card, List<int> firsts, {int from = 0}) {
    final expected = expectedSpeech(firsts);
    for (var i = from; i < firsts.length; i++) {
      expect(card.audio.speech[i], closeTo(expected[i], 1e-6), reason: 'frame $i');
    }
  }

  CardBuilder builder({_Model? model, _Decoder? decoder, void Function()? onBuild, bool Function()? cancelled}) =>
      CardBuilder(
        store: store,
        decoderId: 'fake-opus',
        newDecoder: () {
          onBuild?.call();
          return decoder ?? _Decoder();
        },
        model: model,
        isCancelled: cancelled,
      );

  test('each window, scored from its own samples in order, belongs to the frame it completed in', () async {
    final firsts = List.generate(100, (i) => 1 + i % 50);
    await writeBin(firsts);
    final card = await builder(model: _Model()).current(key);
    expect(card.audio.decoded, everyElement(1));
    expectSpeech(card, firsts);
    expect(card.audio.speech.where((p) => p < 0), isNotEmpty, reason: 'some frames complete no window');
  });

  test('a packet that cannot be decoded adds no samples and is marked undecoded', () async {
    final firsts = [1, 2, 0xEE, 3, 0xEE, 4, 5, 6, 7, 8, 9, 10];
    await writeBin(firsts);
    final card = await builder(model: _Model()).current(key);
    expect(card.audio.decoded, [1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1]);
    expectSpeech(card, firsts);
  });

  test('a decoder that fails mid-file fails the card, rather than passing for undecodable packets', () async {
    await writeBin(List.filled(10, 1));
    final decoder = _Decoder()..brokenFrom = 1;
    await expectLater(builder(model: _Model(), decoder: decoder).current(key), throwsA(isA<CardBuildFailed>()));
    expect(decoder.disposed, isTrue);
    expect(await loadCard(store, key), isNull, reason: 'no card is saved');
  });

  test("an Opus error mid-file fails the card, and its message does not need libopus loaded", () async {
    // libopus is not loaded on the host, so OpusException's own toString would throw here.
    await writeBin(List.filled(10, 1));
    final decoder = _Decoder()
      ..brokenFrom = 4
      ..failure = const OpusException(-3);
    await expectLater(
        builder(model: _Model(), decoder: decoder).current(key),
        throwsA(isA<CardBuildFailed>()
            .having((e) => e.reason, 'reason', 'Opus decoder failed at frame 4: OpusException -3')));
    expect(decoder.disposed, isTrue);
    expect(await loadCard(store, key), isNull, reason: 'no card is saved');
  });

  test('the model starts fresh once per file and its state runs on across calls', () async {
    final firsts = List.generate(7000, (i) => 1 + i % 50); // 4375 windows: two calls
    await writeBin(firsts);
    final model = _Model();
    final card = await builder(model: model).current(key);
    expect(model.calls, [(true, 4096), (false, 279)]);
    expectSpeech(card, firsts, from: 6500);
  });

  test('without a VAD model every frame is still decoded, and the card says so', () async {
    await writeBin([1, 2, 3]);
    final card = await builder().current(key);
    expect(card.vadModelId, FileCard.noVad);
    expect(card.hasVad, isFalse);
    expect(card.audio.decoded, [1, 1, 1]);
    expect(card.audio.speech, everyElement(-1));
  });

  test('a VAD failure fails the card rather than guessing', () async {
    await writeBin(List.filled(10, 1));
    final model = _Model()..failWith = Exception('ORT gone');
    final decoder = _Decoder();
    await expectLater(builder(model: model, decoder: decoder).current(key), throwsA(isA<CardBuildFailed>()));
    expect(decoder.disposed, isTrue);
    expect(await loadCard(store, key), isNull, reason: 'no card is saved');
  });

  test('a VAD answer of the wrong size fails the card', () async {
    await writeBin(List.filled(10, 1));
    await expectLater(builder(model: _Model()..extra = 1).current(key), throwsA(isA<CardBuildFailed>()));
  });

  for (final (name, value) in [
    ('NaN', double.nan),
    ('infinity', double.infinity),
    ('below 0', -0.01),
    ('above 1', 1.01)
  ]) {
    test('a VAD answer that is not a probability ($name) fails the card', () async {
      await writeBin(List.filled(10, 1));
      await expectLater(
          builder(
                  model: _Model()
                    ..poisonAt = 2
                    ..poison = value)
              .current(key),
          throwsA(isA<CardBuildFailed>()));
      expect(await loadCard(store, key), isNull);
    });
  }

  test('a decoder that cannot load fails the card', () async {
    await writeBin([1]);
    final b = CardBuilder(
        store: store, decoderId: 'fake-opus', newDecoder: () => throw StateError('no libopus'), model: _Model());
    await expectLater(b.current(key), throwsA(isA<CardBuildFailed>()));
  });

  test('a cancelled build stops and saves nothing', () async {
    await writeBin(List.filled(200, 1));
    await expectLater(builder(model: _Model(), cancelled: () => true).current(key), throwsA(isA<CardBuildCancelled>()));
    expect(await loadCard(store, key), isNull);
  });

  test('a saved card is reused until its file grows or another model would make it', () async {
    await writeBin([1, 2, 3]);
    var builds = 0;
    void count() => builds++;
    await builder(model: _Model(), onBuild: count).current(key);
    await builder(model: _Model(), onBuild: count).current(key);
    expect(builds, 1, reason: 'a fresh decoder per build, and no build for a current card');
    await builder(onBuild: count).current(key);
    expect(builds, 2, reason: 'a card made with VAD does not serve a device without it');

    // The file grows by a sealed continuation.
    final part = store.partFile(key, 36);
    await part.parent.create(recursive: true);
    await part
        .writeAsBytes([...(ByteData(4)..setUint32(0, 8, Endian.little)).buffer.asUint8List(), 9, 0, 0, 0, 0, 0, 0, 0]);
    await store.seal(key, appendOffset: 36, keepLength: 12, provenance: ChunkProvenance.echoed);
    final grown = await builder(onBuild: count).current(key);
    expect(builds, 3);
    expect(grown.records.frameCount, 4);
    expect(grown.chunks, [(0, 36), (36, 12)]);
  });

  test('a card from an older indexer is rebuilt', () async {
    await writeBin([1, 2, 3]);
    var builds = 0;
    final current = await builder(onBuild: () => builds++).current(key);
    await saveCard(
        store,
        FileCard(
          key: current.key,
          indexerVersion: cardIndexerVersion - 1,
          chunks: current.chunks,
          records: current.records,
          decoderId: current.decoderId,
          vadModelId: current.vadModelId,
          audio: current.audio,
        ));
    final rebuilt = await builder(onBuild: () => builds++).current(key);
    expect(builds, 2);
    expect(rebuilt.indexerVersion, cardIndexerVersion);
  });

  test("another file's card under this file's name is never used", () async {
    const other = RawFileKey(1789100600, 7);
    await writeBin([1, 2, 3]);
    await writeBin([4, 5, 6], k: other); // the same chunk sizes, other bytes
    await builder().current(other);
    await cardFileFor(store, key).parent.create(recursive: true);
    await cardFileFor(store, other).copy(cardFileFor(store, key).path);
    expect(await loadCard(store, key), isNull);
    var builds = 0;
    final card = await builder(onBuild: () => builds++).current(key);
    expect(builds, 1);
    expect(card.key, key);
  });

  group('the Opus adapter', () {
    test('a packet libopus calls invalid is undecodable; any other error is the decoder failing', () {
      expect(OpusFrameDecoder.invalidPacket, -4, reason: "libopus's OPUS_INVALID_PACKET");
      expect(OpusFrameDecoder.decodeOrNull(() => throw const OpusException(-4)), isNull);
      expect(() => OpusFrameDecoder.decodeOrNull(() => throw const OpusException(-3)), throwsA(isA<OpusException>()));
      expect(() => OpusFrameDecoder.decodeOrNull(() => throw StateError('destroyed')), throwsStateError);
      expect(OpusFrameDecoder.decodeOrNull(() => Int16List(3)), hasLength(3));
      expect(describeDecoderError(const OpusException(-3)), 'OpusException -3');
    });
  });

  group('the versions a card names', () {
    test('the decoder id matches every opus package pubspec.lock resolves, native providers included', () {
      final lines = File('pubspec.lock').readAsLinesSync();
      // A package's block: its "  name:" line and the more-indented lines under it.
      List<String> block(String name) {
        final start = lines.indexOf('  $name:');
        final end = lines.indexWhere((l) => l.startsWith('  ') && !l.startsWith('   '), start + 1);
        return lines.sublist(start, end < 0 ? lines.length : end);
      }

      String field(String package, String name) =>
          block(package).firstWhere((l) => l.trim().startsWith('$name:')).split(':').last.trim().replaceAll('"', '');
      String pinned(String package) =>
          '$package ${field(package, 'version')} ${field(package, 'resolved-ref').substring(0, 8)}';
      expect(
          OpusFrameDecoder.id,
          '${pinned('opus_dart')} / opus_flutter ${field('opus_flutter', 'version')} / '
          '${pinned('opus_flutter_android')} / ${pinned('opus_flutter_ios')}, 16000 Hz mono');
    });

    test('the VAD model id names the bundled asset\'s exact bytes', () {
      final digest = sha256.convert(File('assets/models/silero_vad.onnx').readAsBytesSync()).toString();
      expect(SileroBatchModel.assetSha256, digest);
      expect(SileroBatchModel.modelId, contains(digest));
    });
  });
}
