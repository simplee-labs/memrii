import 'dart:io';

import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/recording_sidecars.dart';

/// How a recording was captured, as far as a destination may need to know.
enum RecordingCaptureMode { manual, automatic, unknown }

/// A finished recording as the integration layer sees it — the only description of a
/// recording a connector ever receives.
///
/// Built from the recording layer's own model by [IntegrationRecording.fromConversation],
/// it carries what a destination can use: where the audio is and what format it is in,
/// when it started and how long it runs, the markers inside it, and a few facts about how
/// it was made. It carries **nothing** of how the audio got here — no BLE, WAL, raw
/// segment, firmware framing, VAD or clock-anchor state — so a connector has no way to
/// depend on those, and the recording pipeline can change underneath without any
/// connector noticing. `architecture_boundaries_test.dart` holds connectors to that.
///
/// Immutable and cheap: building one does no I/O. The getters that do touch the disk
/// ([audioExists], [audioSizeBytes], [hasOpusFrameSidecar]) say so.
class IntegrationRecording {
  const IntegrationRecording({
    required this.id,
    required this.audioPath,
    required this.startTime,
    required this.duration,
    this.sessionId,
    this.captureMode = RecordingCaptureMode.unknown,
    this.clockCorrected = false,
    this.timeUncertain = false,
    this.audioReleased = false,
    this.markers = const [],
    this.hasPriorityMarker = false,
  });

  /// Stable identity: the upload key stamped into the recording's `.meta` when it was
  /// processed, which a re-file (a corrected start time, a new file name) does not
  /// change. Null only for a recording so old its sidecar carries no key.
  final String? id;

  /// Where the finished audio is on the phone.
  final String audioPath;

  final DateTime startTime;
  final Duration duration;

  /// The device boot the recording came from. Opaque to destinations; present so a
  /// connector can group recordings from one capture session if it needs to.
  final int? sessionId;

  final RecordingCaptureMode captureMode;

  /// The phone corrected the start time the capture device assigned.
  final bool clockCorrected;

  /// The start time could not be established (the device had no clock and no anchor
  /// placed it), so [startTime] is a best guess.
  final bool timeUncertain;

  /// Passthrough already removed this recording's audio from the phone after delivery;
  /// only its metadata remains.
  final bool audioReleased;

  /// Bookmarks the user dropped inside this recording, by wall-clock time.
  final List<DateTime> markers;

  /// Derived from authoritative high-priority marker metadata, independent of capture mode.
  final bool hasPriorityMarker;

  DateTime get endTime => startTime.add(duration);

  /// Lower-case extension of the audio file: `wav`, `m4a` (or `ogg`, from an older build).
  String get audioFormat {
    final name = audioPath.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  File get audioFile => File(audioPath);

  /// Reads the disk.
  bool get audioExists => audioFile.existsSync();

  /// Reads the disk. 0 when the file is missing or unreadable.
  int get audioSizeBytes {
    try {
      return audioFile.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// This recording's Opus frame sidecar (see [RecordingSidecars.opusFramesPathFor]),
  /// whether or not one was written.
  String get opusFrameSidecarPath => opusFrameSidecarPathOf(audioPath);

  /// The Opus frame sidecar path for a recording whose audio is at [audioPath] — for a
  /// connector following a [RecordingMove], which has paths rather than recordings.
  static String opusFrameSidecarPathOf(String audioPath) => RecordingSidecars.opusFramesPathFor(audioPath);

  /// Reads the disk.
  bool get hasOpusFrameSidecar => File(opusFrameSidecarPath).existsSync();

  /// The integration view of [c]. [markers] are the bookmark times that fall inside it,
  /// when the caller knows them; the recording model does not carry them itself.
  factory IntegrationRecording.fromConversation(Conversation c,
      {List<DateTime> markers = const [], bool hasPriorityMarker = false}) {
    return IntegrationRecording(
      id: c.uploadKey,
      audioPath: c.file.path,
      startTime: c.startTime,
      duration: c.duration,
      sessionId: c.sessionId,
      captureMode: switch (c.recordedManual) {
        true => RecordingCaptureMode.manual,
        false => RecordingCaptureMode.automatic,
        null => RecordingCaptureMode.unknown,
      },
      clockCorrected: c.clockCorrected,
      timeUncertain: c.isUnknown,
      audioReleased: c.passthrough,
      markers: List.unmodifiable(markers),
      hasPriorityMarker: hasPriorityMarker,
    );
  }
}
