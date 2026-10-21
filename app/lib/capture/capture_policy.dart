import 'package:omi/backend/preferences.dart';

/// The two ways memrii records. The mode is a label on the audio; what actually decides
/// how audio is cut is the [CapturePolicy] the mode implies.
enum RecordingMode { manual, automatic }

/// How the continuous audio stream from the capture device becomes recordings — the
/// rules memrii applies, in one value, instead of five loose preferences.
///
/// A policy is **memrii's**, not a destination's. Connectors can neither read nor set
/// one: the only processing-adjacent thing a connector may declare is that it needs Opus
/// frame sidecars kept (`ConnectorCapabilities.needsOpusFrameSidecar`), which changes
/// what the processor keeps beside a recording, never what the device records or where a
/// recording is cut — and never anything on the device. `architecture_boundaries_test`
/// keeps connectors from importing this library.
///
/// Implemented today: the concrete default ([MemriiDefaultCapturePolicy]) for both modes,
/// the single writer of the preferences the processor reads
/// ([SharedPreferencesUtil.applyRecordingModeDefaults]), and the reader that turns them
/// back into a policy for a processing run ([CapturePolicy.effective]). Not implemented:
/// any way for anything but the user's own mode choice to select a different policy.
class CapturePolicy {
  const CapturePolicy({
    required this.mode,
    required this.useOnPhoneVad,
    required this.speechThreshold,
    required this.silenceSplit,
    required this.minSpeech,
    required this.maxRecording,
    required this.prioritySafetyCap,
  });

  final RecordingMode mode;

  /// Run Silero on the phone to separate speech from silence. Off means every captured
  /// frame counts as speech, and recordings are cut only on the device's own activity
  /// timestamps (AAD) and on markers.
  final bool useOnPhoneVad;

  /// Silero's speech-probability cutoff, 0–1. Only meaningful with [useOnPhoneVad].
  final double speechThreshold;

  /// Continuous silence that ends a recording. [Duration.zero] means silence never ends
  /// one — manual mode, where the device's stop marker does.
  final Duration silenceSplit;

  /// Least detected speech a recording must hold to be kept. Zero keeps everything.
  final Duration minSpeech;

  /// A recording longer than this is cut even without silence. Null means no cap.
  final Duration? maxRecording;

  /// Priority Recording (automatic mode's Record Start) force-captures until its stop;
  /// this bounds it if the stop never arrives. Null means no device cap, and the
  /// processor falls back to its own absolute bound.
  final Duration? prioritySafetyCap;

  /// A marker in automatic mode keeps this much audio from the tap, whatever the
  /// activity gate and Silero decide. Fixed: it mirrors the firmware, which holds its
  /// gate open for the same span.
  Duration get markerProtection => const Duration(milliseconds: MemriiDefaultCapturePolicy.markerProtectionMs);

  /// Priority Recording is never cut on silence.
  bool get priorityForcesCapture => true;

  /// The processor's `maxChunkMs` for [maxRecording]: effectively unbounded when there
  /// is no cap, exactly as the processor has always been handed it.
  int get maxRecordingMs => maxRecording == null ? 0x7FFFFFFFFFFFFFFF : maxRecording!.inMilliseconds;

  /// The policy the processor will apply right now: read back from the flat preferences
  /// it reads, which [SharedPreferencesUtil.applyRecordingModeDefaults] writes from a
  /// policy. The mode comes from the label; everything that decides a cut comes from the
  /// flat values, never from the descriptive mode label.
  factory CapturePolicy.effective(SharedPreferencesUtil p) => CapturePolicy(
        mode: p.manualMode ? RecordingMode.manual : RecordingMode.automatic,
        useOnPhoneVad: p.vadEnabled,
        speechThreshold: p.vadSpeechThreshold,
        silenceSplit: Duration(seconds: p.vadSplitSeconds),
        minSpeech: Duration(seconds: p.vadMinSpeechSeconds),
        maxRecording: p.vadMaxConversationMinutes == 0 ? null : Duration(minutes: p.vadMaxConversationMinutes),
        prioritySafetyCap: p.priorityRecordMaxMinutes <= 0 ? null : Duration(minutes: p.priorityRecordMaxMinutes),
      );

  /// Writes the flat preferences the processor reads. The only writer of all five: two
  /// writers is how a label and its values drift apart.
  void writeProcessingPrefs(SharedPreferencesUtil p) {
    p.vadEnabled = useOnPhoneVad;
    p.vadSpeechThreshold = speechThreshold;
    p.vadMinSpeechSeconds = minSpeech.inSeconds;
    p.vadSplitSeconds = silenceSplit.inSeconds;
    p.vadMaxConversationMinutes = maxRecording?.inMinutes ?? 0;
  }
}

/// memrii's default capture behaviour, and the constants it shares with the firmware.
class MemriiDefaultCapturePolicy {
  MemriiDefaultCapturePolicy._();

  /// Mirrors `FORCE_WAKE_HOLD_MS` in `omi/firmware/omi/src/aad.c`: after a marker the
  /// firmware forces its gate open this long, and the processor forces the same span
  /// through as speech. **Must equal the firmware value**, or the app's protection
  /// window stops lining up with the audio the firmware actually kept.
  static const int markerProtectionMs = 50000;

  /// Mirrors `CONFIG_OMI_VAD_HOLD_MS` in `omi/firmware/omi/omi.conf`: the firmware keeps
  /// emitting audio this long after the last voice frame, so a gap the app sees is that
  /// much shorter than the silence the user heard.
  static const int firmwareActivityHoldMs = 10000;

  /// Manual mode: nothing is filtered and silence never cuts — the device's Record
  /// Start/Stop markers are the boundaries. The one user setting is the length cap.
  static CapturePolicy manual({int maxRecordingMinutes = 0, int prioritySafetyCapMinutes = 120}) => CapturePolicy(
        mode: RecordingMode.manual,
        useOnPhoneVad: false,
        speechThreshold: 0.5,
        silenceSplit: Duration.zero,
        minSpeech: Duration.zero,
        maxRecording: maxRecordingMinutes == 0 ? null : Duration(minutes: maxRecordingMinutes),
        prioritySafetyCap: prioritySafetyCapMinutes <= 0 ? null : Duration(minutes: prioritySafetyCapMinutes),
      );

  /// Automatic mode, from the user's own automatic-mode settings. The defaults here are
  /// the defaults a fresh install has: firmware activity detection only (no Silero), a
  /// two-minute silence split, three seconds of speech to keep a recording, no cap.
  static CapturePolicy automatic({
    bool useOnPhoneVad = false,
    double speechThreshold = 0.5,
    int silenceSplitSeconds = 120,
    int minSpeechSeconds = 3,
    int maxRecordingMinutes = 0,
    int prioritySafetyCapMinutes = 120,
  }) =>
      CapturePolicy(
        mode: RecordingMode.automatic,
        useOnPhoneVad: useOnPhoneVad,
        speechThreshold: speechThreshold,
        silenceSplit: Duration(seconds: silenceSplitSeconds),
        minSpeech: Duration(seconds: minSpeechSeconds),
        maxRecording: maxRecordingMinutes == 0 ? null : Duration(minutes: maxRecordingMinutes),
        prioritySafetyCap: prioritySafetyCapMinutes <= 0 ? null : Duration(minutes: prioritySafetyCapMinutes),
      );

  /// The policy [mode] implies for this user: manual's fixed rules with its own cap, or
  /// automatic from the per-mode snapshot a round trip through manual preserves.
  static CapturePolicy forMode(RecordingMode mode, SharedPreferencesUtil p) => switch (mode) {
        RecordingMode.manual => manual(
            maxRecordingMinutes: p.manualModeVadMaxConversationMinutes,
            prioritySafetyCapMinutes: p.priorityRecordMaxMinutes,
          ),
        RecordingMode.automatic => automatic(
            useOnPhoneVad: p.autoModeVadEnabled,
            speechThreshold: p.autoModeVadSpeechThreshold,
            silenceSplitSeconds: p.autoModeVadSplitSeconds,
            minSpeechSeconds: p.autoModeVadMinSpeechSeconds,
            maxRecordingMinutes: p.autoModeVadMaxConversationMinutes,
            prioritySafetyCapMinutes: p.priorityRecordMaxMinutes,
          ),
      };
}
