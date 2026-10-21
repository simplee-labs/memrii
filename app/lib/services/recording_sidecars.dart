import 'package:omi/models/recordings/recording_filename.dart';

/// Names of the files the recording layer keeps beside a finished recording's audio.
///
/// Only the Opus frame sidecar lives here so far — the one sidecar a connector reads — and
/// every path to it goes through this, so the writer (the processor), the movers (re-file,
/// stitch, delete in `RecordingsManager`) and the reader (the Omi Cloud connector) cannot
/// drift apart.
class RecordingSidecars {
  RecordingSidecars._();

  /// The recording's **Opus frame sidecar**: `recording_fs320_<ts>.bin` beside the audio,
  /// holding 20 ms Opus packets, each as a 4-byte little-endian length followed
  /// by the packet. Originals retain device packets; crop copies encode only
  /// their selected PCM. Both write this file while an enabled connector asks
  /// for one (`ConnectorCapabilities.needsOpusFrameSidecar` — today, Omi Cloud).
  ///
  /// The name is a compatibility contract, not branding. Omi Cloud's delivery state is
  /// keyed by this exact path in preferences already on phones, and its server reads the
  /// 320-sample frame size out of the `fs320` in the name; neither may change with the
  /// product name.
  ///
  /// Separators are normalised to '/', so a path built by hand and one read back from a
  /// directory listing agree even where the platform lists with '\' (Android never does).
  ///
  /// Crop copies retain their own suffix so they never share the original's frames.
  /// Ordinary recordings keep the historical name, including delivery-state keys.
  static String opusFramesPathFor(String audioPath) {
    final path = audioPath.replaceAll('\\', '/');
    final ts = RecordingFilename.timestamp(path) ?? RecordingFilename.stem(path).split('_').last;
    final suffix = RecordingFilename.cropSuffix(path);
    final slash = path.lastIndexOf('/');
    return slash < 0 ? 'recording_fs320_$ts$suffix.bin' : '${path.substring(0, slash)}/recording_fs320_$ts$suffix.bin';
  }

  /// [opusFramesPathFor] for a recording that is being written: [dateFolderPath] is the
  /// folder it goes in, [startMs] its start as the audio file will be named.
  static String opusFramesPathIn(String dateFolderPath, int startMs) => '$dateFolderPath/recording_fs320_$startMs.bin';
}
