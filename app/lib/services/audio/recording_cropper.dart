import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

class CroppedAudio {
  final int samples;
  final int sampleRate;
  final List<int> peaks;

  const CroppedAudio(this.samples, this.sampleRate, this.peaks);

  Duration get duration => Duration(microseconds: samples * Duration.microsecondsPerSecond ~/ sampleRate);
}

/// Creates a playable PCM WAV containing only the selected audio. PCM copying
/// runs in an isolate; compressed sources are decoded by the native audio tool.
class RecordingCropper {
  static const _channel = MethodChannel('me.memrii.app/audioCrop');

  @visibleForTesting
  static String? opusLibraryPathForTest;

  /// Encode the selected PCM, rather than copying the source's untrimmed packets.
  /// Each isolate initializes its own codec; the archive publishes this sidecar
  /// together with the audio only after encoding succeeds.
  static Future<void> writeOpusFrames(File source, File output) async {
    final sourcePath = source.path;
    final outputPath = output.path;
    final libraryPath = opusLibraryPathForTest;
    final token = RootIsolateToken.instance;
    await Isolate.run(() async {
      if (libraryPath != null) {
        // opus_dart exposes a conditional native/web FFI type, as does load().
        final dynamic library = DynamicLibrary.open(libraryPath);
        initOpus(library);
      } else {
        if (token != null) BackgroundIsolateBinaryMessenger.ensureInitialized(token);
        initOpus(await opus_flutter.load());
      }
      final encoder = SimpleOpusEncoder(sampleRate: 16000, channels: 1, application: Application.audio);
      try {
        _writeOpusFrames(sourcePath, outputPath, (frame) => encoder.encode(input: frame));
      } finally {
        encoder.destroy();
      }
    });
  }

  @visibleForTesting
  static void writeOpusFramesWithEncoderForTest(File source, File output, Uint8List Function(Int16List) encode) =>
      _writeOpusFrames(source.path, output.path, encode);

  static void _writeOpusFrames(String source, String output, Uint8List Function(Int16List) encode) {
    final input = File(source).openSync();
    RandomAccessFile? target;
    try {
      final info = _pcmInfo(input);
      if (info.sampleRate != 16000 || info.channels != 1) {
        throw const FormatException('Opus frame sidecars require 16 kHz mono PCM.');
      }
      input.setPositionSync(info.offset);
      target = File(output).openSync(mode: FileMode.write);
      void writeFrame(Int16List frame) {
        final packet = encode(frame);
        if (packet.isEmpty) throw const FormatException('The Opus encoder returned an empty packet.');
        final length = ByteData(4)..setUint32(0, packet.length, Endian.little);
        target!.writeFromSync(length.buffer.asUint8List());
        target.writeFromSync(packet);
      }

      var remaining = info.bytes ~/ 2;
      while (remaining > 0) {
        final count = min(320, remaining);
        final bytes = input.readSync(count * 2);
        if (bytes.length != count * 2) throw const FormatException('The recording is truncated.');
        final data = ByteData.sublistView(bytes);
        final frame = Int16List(320);
        for (var i = 0; i < count; i++) {
          frame[i] = data.getInt16(i * 2, Endian.little);
        }
        writeFrame(frame);
        remaining -= count;
      }
      // Flush codec lookahead so the final selected samples are not lost. The
      // frame padding is silence; it contains no audio outside the crop.
      writeFrame(Int16List(320));
      target.flushSync();
    } finally {
      target?.closeSync();
      input.closeSync();
    }
  }

  static Future<CroppedAudio> crop(File source, File output, Duration start, Duration end) async {
    if (start.isNegative || end <= start) throw ArgumentError('Choose a non-empty crop range.');
    if (source.path.toLowerCase().endsWith('.wav')) {
      return Isolate.run(() => _copyPcm(source.path, output.path, start, end));
    }

    try {
      await _channel.invokeMethod<void>('crop', {
        'sourcePath': source.path,
        'outputPath': output.path,
        'startUs': start.inMicroseconds,
        'endUs': end.inMicroseconds,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? 'Could not crop the recording.', source.path);
    }
    // Read the decoded result rather than trusting the requested duration.
    return Isolate.run(() => _scanPcm(output.path));
  }

  static ({int offset, int bytes, int sampleRate, int channels}) _pcmInfo(RandomAccessFile file) {
    final header = file.readSync(12);
    if (header.length != 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Not a WAV recording.');
    }
    int? sampleRate;
    int? channels;
    final length = file.lengthSync();
    while (file.positionSync() + 8 <= length) {
      final chunk = file.readSync(8);
      final kind = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      final offset = file.positionSync();
      if (kind == 'fmt ' && size >= 16) {
        final format = ByteData.sublistView(file.readSync(16));
        if (format.getUint16(0, Endian.little) != 1 || format.getUint16(14, Endian.little) != 16) {
          throw const FormatException('Only 16-bit PCM WAV recordings can be cropped.');
        }
        channels = format.getUint16(2, Endian.little);
        sampleRate = format.getUint32(4, Endian.little);
      } else if (kind == 'data' && sampleRate != null && channels != null && sampleRate > 0 && channels > 0) {
        return (offset: offset, bytes: min(size, length - offset), sampleRate: sampleRate, channels: channels);
      }
      file.setPositionSync(offset + size + size % 2);
    }
    throw const FormatException('The recording has no PCM audio.');
  }

  static CroppedAudio _copyPcm(String source, String output, Duration start, Duration end) {
    final input = File(source).openSync();
    RandomAccessFile? target;
    try {
      final info = _pcmInfo(input);
      final frames = info.bytes ~/ (info.channels * 2);
      final startFrame = start.inMicroseconds * info.sampleRate ~/ Duration.microsecondsPerSecond;
      final endFrame = min(frames, end.inMicroseconds * info.sampleRate ~/ Duration.microsecondsPerSecond);
      // Allow sub-millisecond rounding in metadata, but reject a genuinely invalid end.
      if (startFrame >= endFrame || end.inMilliseconds > frames * 1000 ~/ info.sampleRate + 1) {
        throw ArgumentError('The crop range exceeds the recording.');
      }
      final count = endFrame - startFrame;
      target = File(output).openSync(mode: FileMode.write);
      target.writeFromSync(_wavHeader(count * info.channels * 2, info.sampleRate, info.channels));
      input.setPositionSync(info.offset + startFrame * info.channels * 2);
      final peaks = _consumePcm(input, count, info.channels, target: target);
      target.flushSync();
      return CroppedAudio(count, info.sampleRate, peaks);
    } finally {
      target?.closeSync();
      input.closeSync();
    }
  }

  static CroppedAudio _scanPcm(String path) {
    final input = File(path).openSync();
    try {
      final info = _pcmInfo(input);
      final frames = info.bytes ~/ (info.channels * 2);
      if (frames == 0) throw const FormatException('The cropped recording is empty.');
      input.setPositionSync(info.offset);
      return CroppedAudio(frames, info.sampleRate, _consumePcm(input, frames, info.channels));
    } finally {
      input.closeSync();
    }
  }

  static List<int> _consumePcm(RandomAccessFile input, int frames, int channels, {RandomAccessFile? target}) {
    final peaks = List<int>.filled(200, 0);
    var consumed = 0;
    while (consumed < frames) {
      final count = min(16384, frames - consumed);
      final bytes = input.readSync(count * channels * 2);
      if (bytes.length != count * channels * 2) throw const FormatException('The recording is truncated.');
      target?.writeFromSync(bytes);
      final data = ByteData.sublistView(bytes);
      for (var frame = 0; frame < count; frame++) {
        final bucket = (consumed + frame) * peaks.length ~/ frames;
        for (var channel = 0; channel < channels; channel++) {
          final peak = data.getInt16((frame * channels + channel) * 2, Endian.little).abs();
          if (peak > peaks[bucket]) peaks[bucket] = peak;
        }
      }
      consumed += count;
    }
    return peaks.map((peak) => min(65535, peak * 2)).toList();
  }

  static Uint8List _wavHeader(int bytes, int sampleRate, int channels) {
    final data = ByteData(44);
    final header = data.buffer.asUint8List();
    header.setRange(0, 4, 'RIFF'.codeUnits);
    data.setUint32(4, 36 + bytes, Endian.little);
    header.setRange(8, 16, 'WAVEfmt '.codeUnits);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * channels * 2, Endian.little);
    data.setUint16(32, channels * 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    header.setRange(36, 40, 'data'.codeUnits);
    data.setUint32(40, bytes, Endian.little);
    return header;
  }
}
