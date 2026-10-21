import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/capture/capture_policy.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pre-policy implementation of applyRecordingModeDefaults, kept verbatim as the
/// oracle: the policy must write exactly what this wrote, for every input.
void _legacyApplyRecordingModeDefaults(SharedPreferencesUtil p, bool manual) {
  if (manual) {
    p.vadEnabled = false;
    p.vadSpeechThreshold = 0.5;
    p.vadMinSpeechSeconds = 0;
    p.vadSplitSeconds = 0;
    p.vadMaxConversationMinutes = p.manualModeVadMaxConversationMinutes;
  } else {
    p.vadEnabled = p.autoModeVadEnabled;
    p.vadSpeechThreshold = p.autoModeVadSpeechThreshold;
    p.vadMinSpeechSeconds = p.autoModeVadMinSpeechSeconds;
    p.vadSplitSeconds = p.autoModeVadSplitSeconds;
    p.vadMaxConversationMinutes = p.autoModeVadMaxConversationMinutes;
  }
}

/// The five flat prefs the processor reads.
List<Object> _flat(SharedPreferencesUtil p) =>
    [p.vadEnabled, p.vadSpeechThreshold, p.vadMinSpeechSeconds, p.vadSplitSeconds, p.vadMaxConversationMinutes];

void main() {
  late SharedPreferencesUtil prefs;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
  });

  group('the mode writer matches the implementation it replaced', () {
    // Each case: the per-mode snapshots a user might hold.
    final snapshots = <String, void Function(SharedPreferencesUtil)>{
      'fresh install': (_) {},
      'auto with Silero, strict, capped': (p) {
        p.autoModeVadEnabled = true;
        p.autoModeVadSpeechThreshold = 0.65;
        p.autoModeVadMinSpeechSeconds = 10;
        p.autoModeVadSplitSeconds = 300;
        p.autoModeVadMaxConversationMinutes = 90;
      },
      'manual with a cap': (p) => p.manualModeVadMaxConversationMinutes = 45,
      'everything at zero': (p) {
        p.autoModeVadMinSpeechSeconds = 0;
        p.autoModeVadSplitSeconds = 0;
        p.autoModeVadMaxConversationMinutes = 0;
        p.manualModeVadMaxConversationMinutes = 0;
      },
    };

    for (final entry in snapshots.entries) {
      for (final manual in [true, false]) {
        test('${entry.key}, ${manual ? 'manual' : 'auto'}', () {
          entry.value(prefs);
          _legacyApplyRecordingModeDefaults(prefs, manual);
          final expected = _flat(prefs);

          // Scramble the flat prefs so the policy has to write every one of them.
          prefs.vadEnabled = !prefs.vadEnabled;
          prefs.vadSpeechThreshold = 0.99;
          prefs.vadMinSpeechSeconds = 777;
          prefs.vadSplitSeconds = 777;
          prefs.vadMaxConversationMinutes = 777;

          prefs.applyRecordingModeDefaults(manual);
          expect(_flat(prefs), expected);
        });
      }
    }
  });

  group('ProcessingSettings.fromPrefs reads the effective policy exactly as before', () {
    for (final (split, minSpeech, cap) in [(120, 3, 0), (0, 0, 60), (300, 10, 1)]) {
      test('split=$split minSpeech=$minSpeech cap=$cap', () {
        prefs.vadEnabled = true;
        prefs.vadSpeechThreshold = 0.3;
        prefs.vadSplitSeconds = split;
        prefs.vadMinSpeechSeconds = minSpeech;
        prefs.vadMaxConversationMinutes = cap;
        prefs.filterMinDurationSeconds = 7;
        prefs.priorityRecordMaxMinutes = 0;

        final s = ProcessingSettings.fromPrefs();
        expect(s.vadEnabled, true);
        expect(s.speechThreshold, 0.3);
        expect(s.silenceDurationToSplitMs, split * 1000);
        expect(s.minSpeechMs, minSpeech * 1000);
        expect(s.maxChunkMs, cap == 0 ? 0x7FFFFFFFFFFFFFFF : cap * 60 * 1000);
        expect(s.minDurationMs, 7000);
        expect(s.priorityRecordCapMinutes, 0, reason: 'raw minutes, 0 included');
        expect(s.manual, prefs.manualMode);
      });
    }
  });

  group('MemriiDefaultCapturePolicy', () {
    test('manual never filters and never cuts on silence', () {
      final m = MemriiDefaultCapturePolicy.manual();
      expect(m.useOnPhoneVad, isFalse);
      expect(m.silenceSplit, Duration.zero);
      expect(m.minSpeech, Duration.zero);
      expect(m.maxRecording, isNull);
      expect(m.priorityForcesCapture, isTrue);
    });

    test('automatic defaults are a fresh install\'s', () {
      final a = MemriiDefaultCapturePolicy.forMode(RecordingMode.automatic, prefs);
      expect(a.useOnPhoneVad, isFalse, reason: 'firmware activity detection by default; Silero is opt-in');
      expect(a.silenceSplit, const Duration(minutes: 2));
      expect(a.minSpeech, const Duration(seconds: 3));
      expect(a.maxRecording, isNull);
      expect(a.prioritySafetyCap, const Duration(hours: 2));
    });

    test('a round trip through manual restores the automatic snapshot', () {
      prefs.autoModeVadSplitSeconds = 45;
      prefs.applyRecordingModeDefaults(false);
      prefs.applyRecordingModeDefaults(true);
      expect(prefs.vadSplitSeconds, 0);
      prefs.applyRecordingModeDefaults(false);
      expect(prefs.vadSplitSeconds, 45);
    });

    // These two mirror firmware constants; drifting from them breaks marker capture and
    // inter-file stitching. Read the firmware's own source so a change on either side
    // fails here rather than on a device.
    test('the marker window equals the firmware FORCE_WAKE_HOLD_MS', () {
      final aad = File('../omi/firmware/omi/src/aad.c').readAsStringSync();
      final fw = int.parse(RegExp(r'#define\s+FORCE_WAKE_HOLD_MS\s+(\d+)').firstMatch(aad)!.group(1)!);
      expect(MemriiDefaultCapturePolicy.markerProtectionMs, fw);
      expect(MemriiDefaultCapturePolicy.manual().markerProtection.inMilliseconds, fw);
    });

    test('the activity hold equals the firmware CONFIG_OMI_VAD_HOLD_MS', () {
      final conf = File('../omi/firmware/omi/omi.conf').readAsStringSync();
      final fw = int.parse(RegExp(r'^CONFIG_OMI_VAD_HOLD_MS=(\d+)', multiLine: true).firstMatch(conf)!.group(1)!);
      expect(MemriiDefaultCapturePolicy.firmwareActivityHoldMs, fw);
    });
  });
}
