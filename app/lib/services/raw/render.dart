// Rendering a planned recording into staging (RECORDINGS_PIPELINE_REDESIGN.md §4, step 1
// of publication): its WAV, encoded to M4A when that format is chosen, its waveform peaks
// and, while a connector wants one, its Opus frame sidecar. The meta, the EDLs and the
// names are the coordinator's: a name is reserved only when the transaction is built.
//
// Each source file is decoded from its start with a fresh decoder, in one continuous pass
// carried across the recordings of a job, so every frame decodes with exactly the state
// the card's pass had. Memory is bounded at any length: one raw file at a time, silence
// written in blocks, every write awaited, and the peaks kept per bucket.
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:io';
import 'dart:typed_data';

import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/utils/logger.dart';

const int renderSampleRate = 16000;

/// A 20 ms Opus frame at 16 kHz.
const int samplesPerFrame = 320;

/// The meta's waveform: this many peaks across the recording.
const int waveformBuckets = 200;

/// Left free on the phone beyond what a render needs (today's processing headroom).
const int storageHeadroomBytes = 200 * 1024 * 1024;

/// M4A at 32 kbps: an eighth of 16 kHz 16-bit PCM.
const int _m4aShrink = 8;

const int _writeBlock = 64 * 1024;

/// ENOSPC, or EDQUOT where a quota applies: the Linux codes Android reports (the rule
/// the processor it replaced used).
bool isStorageFullError(Object e) {
  if (e is RenderFailed) return e.storageFull;
  if (e is! FileSystemException) return false;
  final code = e.osError?.errorCode;
  return code == 28 || code == 122;
}

/// The render could not be finished. Nothing it staged is published.
class RenderFailed implements Exception {
  final Object cause;
  final bool storageFull;
  RenderFailed(this.cause, {required this.storageFull});
  @override
  String toString() => 'RenderFailed(${storageFull ? 'storage full' : 'failed'}): $cause';
}

class RenderCancelled implements Exception {
  const RenderCancelled();
}

/// Encodes a staged WAV into M4A.
abstract class AudioEncoder {
  /// Encodes [wav] into [m4a]. Throws on failure, leaving nothing at [m4a]; throws
  /// [RenderCancelled] when [isCancelled] turns true.
  Future<void> encode(File wav, File m4a, {bool Function()? isCancelled});
}

/// The app's AAC encoder, through its platform channel (main isolate only).
class AacAudioEncoder implements AudioEncoder {
  @override
  Future<void> encode(File wav, File m4a, {bool Function()? isCancelled}) async {
    String? session;
    final raf = await wav.open();
    try {
      final header = await raf.read(44);
      final rate = ByteData.sublistView(header).getUint32(24, Endian.little);
      session = await AacEncoder.startEncoder(rate, m4a.path);
      // The chunk size the processor always fed the encoder, which caps an input buffer.
      const chunk = 4096;
      while (true) {
        if (isCancelled?.call() == true) throw const RenderCancelled();
        final bytes = await raf.read(chunk);
        if (bytes.isEmpty) break;
        await AacEncoder.encodeBuffer(session, bytes);
      }
      final finishing = session;
      session = null;
      await AacEncoder.finishEncoder(finishing);
    } catch (_) {
      if (session != null) {
        try {
          await AacEncoder.finishEncoder(session);
        } catch (_) {}
      }
      // Finishing a failed session still writes a valid file of what it had: never leave it.
      try {
        if (await m4a.exists()) await m4a.delete();
      } catch (_) {}
      rethrow;
    } finally {
      await raf.close();
    }
  }
}

/// A recording rendered into staging, not yet published.
class RenderedRecording {
  final File audio;

  /// `wav` or `m4a`.
  final String extension;
  final int totalSamples;

  /// [waveformBuckets] peaks, each the largest |sample| in its stretch, scaled to 0–65535.
  final Uint16List peaks;
  final File? sidecar;

  const RenderedRecording({
    required this.audio,
    required this.extension,
    required this.totalSamples,
    required this.peaks,
    required this.sidecar,
  });

  int get durationMs => totalSamples * 1000 ~/ renderSampleRate;
}

/// How many samples [r] renders to: 320 for every frame, decodable or not, and its
/// silences at 16 per ms.
int samplesOf(PlannedRecording r) {
  var n = 0;
  for (final p in r.pieces) {
    n += switch (p) {
      FramesPiece(:final span) => span.length * samplesPerFrame,
      SilencePiece(:final ms) => ms * (renderSampleRate ~/ 1000),
    };
  }
  return n;
}

/// The staging space rendering [r] needs at its peak: the WAV and, in M4A mode, the M4A
/// beside it before the WAV goes; and the sidecar, which is never larger than the source
/// bytes its frames occupy ([sourceBytes]).
int bytesToRender(PlannedRecording r, {required bool m4a, required int sourceBytes, required bool sidecar}) {
  final wav = 44 + samplesOf(r) * 2;
  return wav + (m4a ? wav ~/ _m4aShrink + _writeBlock : 0) + (sidecar ? sourceBytes : 0);
}

/// A file the renderer reads: its sealed bytes and the card that indexes them.
class RenderSource {
  final LogicalRawFile file;
  final FileCard card;
  const RenderSource(this.file, this.card);
}

/// Renders the recordings of one job, in order.
class RecordingRenderer {
  final Future<RenderSource> Function(RawFileKey key) source;
  final FrameDecoder Function() newDecoder;

  /// Null in WAV mode; in M4A mode, an encoder that fails leaves the recording a WAV.
  final AudioEncoder? encoder;
  final bool writeSidecar;
  final void Function()? onLiveness;
  final bool Function()? isCancelled;

  RecordingRenderer({
    required this.source,
    required this.newDecoder,
    this.encoder,
    this.writeSidecar = false,
    this.onLiveness,
    this.isCancelled,
  });

  // One continuous decoding pass per file, carried across this job's recordings.
  RawFileKey? _key;
  FrameDecoder? _decoder;
  Uint8List? _bytes;
  ParsedRecords? _records;
  int _next = 0;

  void dispose() {
    _decoder?.dispose();
    _decoder = null;
    _bytes = null;
    _records = null;
    _key = null;
  }

  /// Renders [r] into [dir] as `audio.wav` (or `audio.m4a`) and `frames.bin`.
  Future<RenderedRecording> render(PlannedRecording r, Directory dir) async {
    try {
      return await _render(r, dir);
    } catch (e) {
      dispose(); // the pass may be anywhere: the next render starts fresh
      if (e is RenderCancelled || e is RenderFailed) rethrow;
      throw RenderFailed(e, storageFull: isStorageFullError(e));
    }
  }

  Future<RenderedRecording> _render(PlannedRecording r, Directory dir) async {
    await dir.create(recursive: true);
    final total = samplesOf(r);
    final wav = File('${dir.path}/audio.wav');
    final out = _BlockWriter(await wav.open(mode: FileMode.write));
    final side = writeSidecar ? _BlockWriter(await File('${dir.path}/frames.bin').open(mode: FileMode.write)) : null;
    final peaks = _Peaks(total);
    var odd = 0;
    try {
      await out.add(_wavHeader(total * 2));
      final zeros = Int16List(samplesPerFrame);
      var count = 0;
      for (final piece in r.pieces) {
        switch (piece) {
          case SilencePiece(:final ms):
            final n = ms * (renderSampleRate ~/ 1000);
            await out.addZeros(n * 2);
            peaks.skip(n);
          case FramesPiece(:final span):
            await _seek(span.key, span.first);
            final records = _records!;
            final bytes = _bytes!;
            for (var i = span.first; i < span.end; i++) {
              if (++count % 500 == 0) {
                onLiveness?.call();
                if (isCancelled?.call() == true) throw const RenderCancelled();
                await Future<void>.delayed(Duration.zero);
              }
              final at = records.frameOffsets[i];
              final length = records.frameLengths[i];
              final packet = Uint8List.sublistView(bytes, at + 4, at + 4 + length);
              var pcm = _decode(span.key, i, packet) ?? zeros;
              if (pcm.length != samplesPerFrame) {
                // The Omi writes 20 ms frames only; keep the timeline exact regardless.
                odd++;
                pcm = Int16List(samplesPerFrame)..setRange(0, _min(pcm.length, samplesPerFrame), pcm);
              }
              peaks.add(pcm);
              await out.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
              await side?.add(Uint8List.sublistView(bytes, at, at + 4 + length));
            }
            _next = span.end;
        }
      }
      await out.close();
      await side?.close();
    } catch (_) {
      await out.abandon();
      await side?.abandon();
      rethrow;
    }
    if (odd > 0) Logger.error('RecordingRenderer: $odd frame(s) did not decode to 20 ms; padded or cut to it');

    var audio = wav;
    var extension = 'wav';
    final enc = encoder;
    if (enc != null) {
      final m4a = File('${dir.path}/audio.m4a');
      try {
        await enc.encode(wav, m4a, isCancelled: isCancelled);
        await wav.delete();
        audio = m4a;
        extension = 'm4a';
      } on RenderCancelled {
        rethrow;
      } catch (e) {
        if (isStorageFullError(e)) rethrow;
        // A recording is never lost to the encoder: it is published as the WAV it is.
        Logger.error('RecordingRenderer: M4A encoding failed ($e); publishing WAV');
        try {
          if (await m4a.exists()) await m4a.delete();
        } catch (_) {}
      }
    }
    return RenderedRecording(
      audio: audio,
      extension: extension,
      totalSamples: total,
      peaks: peaks.result(),
      sidecar: writeSidecar ? File('${dir.path}/frames.bin') : null,
    );
  }

  /// Positions the pass at frame [first] of [key]: a fresh decoder from the file's start
  /// unless the pass is already in that file at or before it, then every frame before it
  /// decoded and dropped.
  Future<void> _seek(RawFileKey key, int first) async {
    if (_key != key || _next > first) {
      dispose();
      final s = await source(key);
      if (s.card.key != key) throw StateError('${key.rel}: the card names ${s.card.key.rel}');
      _bytes = await s.file.read(0, s.card.records.parsedEnd);
      _records = s.card.records;
      try {
        _decoder = newDecoder();
      } catch (e) {
        throw RenderFailed('Opus decoder failed to load: $e', storageFull: false);
      }
      _key = key;
      _next = 0;
    }
    final records = _records!;
    final bytes = _bytes!;
    for (var i = _next; i < first; i++) {
      if (i % 500 == 0) {
        onLiveness?.call();
        if (isCancelled?.call() == true) throw const RenderCancelled();
        await Future<void>.delayed(Duration.zero);
      }
      final at = records.frameOffsets[i];
      _decode(key, i, Uint8List.sublistView(bytes, at + 4, at + 4 + records.frameLengths[i]));
    }
    _next = first;
  }

  Int16List? _decode(RawFileKey key, int frame, Uint8List packet) {
    try {
      final pcm = _decoder!.decode(packet);
      return pcm == null || pcm.isEmpty ? null : pcm;
    } catch (e) {
      throw RenderFailed('${key.rel}: Opus decoder failed at frame $frame: ${describeDecoderError(e)}',
          storageFull: false);
    }
  }
}

int _min(int a, int b) => a < b ? a : b;

/// Writes through a fixed block, awaiting every write: memory stays bounded however long
/// the recording or its silences.
class _BlockWriter {
  final RandomAccessFile _raf;
  final Uint8List _block = Uint8List(_writeBlock);
  int _fill = 0;

  _BlockWriter(this._raf);

  Future<void> add(Uint8List bytes) async {
    var from = 0;
    while (from < bytes.length) {
      final n = _min(bytes.length - from, _writeBlock - _fill);
      _block.setRange(_fill, _fill + n, bytes, from);
      _fill += n;
      from += n;
      if (_fill == _writeBlock) await _flush();
    }
  }

  Future<void> addZeros(int count) async {
    while (count > 0) {
      final n = _min(count, _writeBlock - _fill);
      _block.fillRange(_fill, _fill + n, 0);
      _fill += n;
      count -= n;
      if (_fill == _writeBlock) await _flush();
    }
  }

  Future<void> _flush() async {
    if (_fill == 0) return;
    await _raf.writeFrom(_block, 0, _fill);
    _fill = 0;
  }

  Future<void> close() async {
    await _flush();
    await _raf.flush();
    await _raf.close();
  }

  Future<void> abandon() async {
    try {
      await _raf.close();
    } catch (_) {}
  }
}

/// The largest |sample| in each of [waveformBuckets] equal stretches of a recording whose
/// length is known before it is written.
class _Peaks {
  final int total;
  final Int32List _max = Int32List(waveformBuckets);
  int _sample = 0;
  int _bucket = 0;
  int _bucketEnd;

  _Peaks(this.total) : _bucketEnd = _endOf(0, total);

  /// Sample s is in bucket s × buckets ÷ total (rounded down).
  static int _endOf(int bucket, int total) => ((bucket + 1) * total + waveformBuckets - 1) ~/ waveformBuckets;

  void skip(int n) => _sample += n;

  void add(Int16List pcm) {
    for (var i = 0; i < pcm.length; i++, _sample++) {
      while (_sample >= _bucketEnd && _bucket < waveformBuckets - 1) {
        _bucket++;
        _bucketEnd = _endOf(_bucket, total);
      }
      final v = pcm[i] < 0 ? -pcm[i] : pcm[i];
      if (v > _max[_bucket]) _max[_bucket] = v;
    }
  }

  Uint16List result() {
    final out = Uint16List(waveformBuckets);
    for (var b = 0; b < waveformBuckets; b++) {
      final v = (_max[b] / 32768.0 * 65535.0).round();
      out[b] = v > 65535 ? 65535 : v;
    }
    return out;
  }
}

Uint8List _wavHeader(int pcmBytes) {
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcmBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, renderSampleRate, Endian.little);
  h.setUint32(28, renderSampleRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcmBytes, Endian.little);
  return h.buffer.asUint8List();
}
