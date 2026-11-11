// The audio stage of a file's card (RECORDINGS_PIPELINE_REDESIGN.md §2): Opus decoded from
// the file's start with a fresh decoder, and Silero run with fresh state, continuously
// through the file. Per frame: whether it decoded, and the highest speech probability of
// the VAD windows that completed during it, the same window-to-frame rule today's
// processor uses. Nothing is decided here; the planner applies the threshold.
//
// A decoder or model that fails to load, or fails mid-file, fails the card; it never
// yields a card of silence or of all speech. Not switched on yet (see raw_chunks.dart).

import 'dart:typed_data';

import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/utils/logger.dart';
import 'package:opus_dart/opus_dart.dart';

/// Silero's window: 512 samples at 16 kHz (32 ms).
const int vadWindowSamples = 512;

/// Windows sent to the model per call. Any size gives the same probabilities: the model
/// keeps its state between calls of one card.
const int _windowsPerCall = 4096;

/// Decodes one Opus packet to 16 kHz mono PCM.
abstract class FrameDecoder {
  /// The PCM, or null when this packet cannot be decoded (it renders as silence). Throws
  /// when the decoder itself fails, which fails the card: a broken decoder must not
  /// pass for a file of undecodable packets.
  Int16List? decode(Uint8List packet);
  void dispose();
}

/// Speech probabilities for consecutive windows of one file.
abstract class SpeechModel {
  /// Identifies the model, so a card made by another one is rebuilt.
  String get id;

  /// One probability per [vadWindowSamples] window of [samples], in order. [fresh]
  /// starts from cleared state; later calls continue the same stream.
  Future<Float32List> run(Float32List samples, {required bool fresh});
}

/// The card could not be built; it is retried, and repeated failures count against the
/// file like any processing failure.
class CardBuildFailed implements Exception {
  final RawFileKey key;
  final String reason;
  CardBuildFailed(this.key, this.reason);
  @override
  String toString() => 'CardBuildFailed: ${key.rel}: $reason';
}

/// An error's description that does not need libopus loaded: OpusException's own
/// toString asks the library for its message.
String describeDecoderError(Object e) => e is OpusException ? 'OpusException ${e.errorCode}' : '$e';

class CardBuildCancelled implements Exception {
  const CardBuildCancelled();
}

/// Runs the audio stage over [records] of [bytes].
Future<FrameAudio> analyzeAudio(
  RawFileKey key,
  Uint8List bytes,
  ParsedRecords records, {
  required FrameDecoder decoder,
  SpeechModel? model,
  void Function()? onLiveness,
  bool Function()? isCancelled,
}) async {
  final n = records.frameCount;
  final decoded = Uint8List(n);
  final speech = Float32List(n)..fillRange(0, n, -1);
  final window = Float32List(vadWindowSamples);
  var windowFill = 0;
  final windows = <Float32List>[];
  final windowFrames = <int>[];
  var fresh = true;

  Future<void> score() async {
    if (windows.isEmpty) return;
    final samples = Float32List(windows.length * vadWindowSamples);
    for (var w = 0; w < windows.length; w++) {
      samples.setAll(w * vadWindowSamples, windows[w]);
    }
    final Float32List probs;
    try {
      probs = await model!.run(samples, fresh: fresh);
    } catch (e) {
      throw CardBuildFailed(key, 'VAD failed: $e');
    }
    if (probs.length != windows.length) {
      throw CardBuildFailed(key, 'VAD returned ${probs.length} probabilities for ${windows.length} windows');
    }
    for (var w = 0; w < probs.length; w++) {
      // Not a probability (NaN, infinite, out of range): the inference failed.
      if (!(probs[w] >= 0 && probs[w] <= 1)) {
        throw CardBuildFailed(key, 'VAD returned ${probs[w]} for window $w');
      }
    }
    fresh = false;
    for (var w = 0; w < windows.length; w++) {
      final frame = windowFrames[w];
      if (probs[w] > speech[frame]) speech[frame] = probs[w];
    }
    windows.clear();
    windowFrames.clear();
  }

  for (var i = 0; i < n; i++) {
    if (i % 50 == 0) {
      onLiveness?.call();
      if (isCancelled?.call() == true) throw const CardBuildCancelled();
      await Future<void>.delayed(Duration.zero);
    }
    final start = records.frameOffsets[i] + 4;
    final Int16List? pcm;
    try {
      pcm = decoder.decode(Uint8List.sublistView(bytes, start, start + records.frameLengths[i]));
    } catch (e) {
      throw CardBuildFailed(key, 'Opus decoder failed at frame $i: ${describeDecoderError(e)}');
    }
    if (pcm == null || pcm.isEmpty) continue;
    decoded[i] = 1;
    if (model == null) continue;
    for (var s = 0; s < pcm.length; s++) {
      window[windowFill++] = pcm[s] / 32768.0;
      if (windowFill == vadWindowSamples) {
        // A window belongs to the frame during which it completed.
        windows.add(Float32List.fromList(window));
        windowFrames.add(i);
        windowFill = 0;
      }
    }
    if (windows.length >= _windowsPerCall) await score();
  }
  await score();
  return FrameAudio(decoded: decoded, speech: speech);
}

/// A file's card, built when missing or stale.
abstract class CardSource {
  Future<FileCard> current(RawFileKey key);
}

/// Builds and keeps the cards of a store's files.
class CardBuilder implements CardSource {
  final RawChunkStore store;
  final String decoderId;
  final FrameDecoder Function() newDecoder;

  /// Null on a device set to run without Silero: its cards say so, and the planner uses
  /// the AAD rules. Never null because a model failed to load: that fails the card.
  final SpeechModel? model;

  final void Function()? onLiveness;
  final bool Function()? isCancelled;

  CardBuilder({
    required this.store,
    required this.decoderId,
    required this.newDecoder,
    required this.model,
    this.onLiveness,
    this.isCancelled,
  });

  String get vadModelId => model?.id ?? FileCard.noVad;

  /// The file's card: the saved one if it still describes the file, else a new one.
  @override
  Future<FileCard> current(RawFileKey key) async {
    final file = await store.load(key);
    final saved = await loadCard(store, key);
    if (saved != null && saved.isCurrentFor(file, decoderId: decoderId, vadModelId: vadModelId)) return saved;
    final watch = Stopwatch()..start();
    final FileCard card;
    try {
      card = await _build(file);
    } on CardBuildCancelled {
      rethrow;
    } catch (e) {
      Logger.error('CardBuilder: ${key.rel}: no card: $e');
      rethrow;
    }
    await saveCard(store, card);
    final undecodable = card.audio.decoded.where((d) => d == 0).length;
    Logger.debug('CardBuilder: ${key.rel}: card ${saved == null ? 'made' : 'remade'}, ${file.length} bytes in '
        '${file.chunks.length} chunk(s), ${card.records.frameCount} frames'
        '${undecodable == 0 ? '' : ', $undecodable undecodable'}${card.hasVad ? '' : ', no VAD'}, '
        'ends ${card.records.endFor(file.lifecycle).name}, ${watch.elapsedMilliseconds} ms');
    return card;
  }

  Future<FileCard> _build(LogicalRawFile file) async {
    final bytes = await file.read(0, file.length);
    final records = parseRecords(bytes);
    final FrameDecoder decoder;
    try {
      decoder = newDecoder();
    } catch (e) {
      throw CardBuildFailed(file.key, 'Opus decoder failed to load: $e');
    }
    try {
      final audio = await analyzeAudio(file.key, bytes, records,
          decoder: decoder, model: model, onLiveness: onLiveness, isCancelled: isCancelled);
      return FileCard(
        key: file.key,
        indexerVersion: cardIndexerVersion,
        chunks: [for (final c in file.chunks) (c.offset, c.length)],
        records: records,
        decoderId: decoderId,
        vadModelId: vadModelId,
        audio: audio,
      );
    } finally {
      decoder.dispose();
    }
  }
}

/// The app's Opus decoder: libopus through opus_dart, 16 kHz mono.
class OpusFrameDecoder implements FrameDecoder {
  /// The decoder the card was made with, down to the native libopus providers; pinned
  /// against pubspec.lock by a test.
  static const id = 'opus_dart 3.0.1 e2202b0f / opus_flutter 3.0.3 / opus_flutter_android 3.0.1 c3e51180 / '
      'opus_flutter_ios 3.0.0 04696ff9, 16000 Hz mono';

  /// libopus's OPUS_INVALID_PACKET: this packet is corrupt. Any other error is the
  /// decoder's own.
  static const invalidPacket = -4;

  final SimpleOpusDecoder _decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

  @override
  Int16List? decode(Uint8List packet) => decodeOrNull(() => _decoder.decode(input: packet));

  /// Runs [decode], answering null for a packet libopus reports as invalid and letting
  /// every other failure through.
  static Int16List? decodeOrNull(Int16List Function() decode) {
    try {
      return decode();
    } on OpusException catch (e) {
      if (e.errorCode == invalidPacket) return null;
      rethrow;
    }
  }

  @override
  void dispose() => _decoder.destroy();
}

/// Silero through the native batch runner, which keeps its state between calls.
class SileroBatchModel implements SpeechModel {
  /// The model the card was made with; pinned against the asset's SHA-256 by a test.
  static const assetSha256 = '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3';
  static const modelId = 'silero_vad.onnx v6.2.1 sha256:$assetSha256';

  final VadBatchRunnerChannel runner;

  SileroBatchModel(this.runner);

  @override
  String get id => modelId;

  @override
  Future<Float32List> run(Float32List samples, {required bool fresh}) {
    if (!runner.available) throw StateError('the VAD batch runner is not available');
    return runner.runVadBatch(samples, resetStateFirst: fresh);
  }
}
