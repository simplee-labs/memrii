import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recording-mode switch history decides which settings cut which audio.
/// Send a stretch to the wrong entry and it is processed by the mode it was NOT
/// recorded in — auto audio chopped at every AAD wake by manual's
/// `vadSplitSeconds = 0`, or a deliberate manual capture filed as a recoverable
/// ghost row by auto's speech filter.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ModeSettings.fromJson falls back to the live prefs per field, and
    // SharedPreferencesUtil.init touches secure storage on the way up.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  ModeSettings mode({required int splitMs, int minSpeechMs = 0, bool? manual}) => ModeSettings(
        vadEnabled: splitMs > 0,
        speechThreshold: 0.5,
        silenceDurationToSplitMs: splitMs,
        minDurationMs: 0,
        minSpeechMs: minSpeechMs,
        maxChunkMs: 0x7FFFFFFFFFFFFFFF,
        manual: manual,
      );

  /// Use a timerStart above kMinValidEpoch (2000-01-01) for these offsets. Values at or below that boundary are
  /// treated as pre-time-sync bins and read as zero; separate tests cover that case.
  const int base = 1786741941;

  ModeSwitchRecord entry(int at, {int splitMs = 120000}) =>
      ModeSwitchRecord(atUtcSeconds: base + at, settings: mode(splitMs: splitMs));

  group('encode / decode', () {
    test('round-trips a multi-entry history in order', () {
      final history = [entry(100, splitMs: 120000), entry(200, splitMs: 0)];
      final restored = ModeSwitchRecord.decode(ModeSwitchRecord.encode(history));

      expect(restored.map((e) => e.atUtcSeconds), [base + 100, base + 200]);
      expect(restored[0].settings.silenceDurationToSplitMs, 120000);
      expect(restored[1].settings.silenceDurationToSplitMs, 0);
      // The sentinel is the largest int Dart holds; a JSON round trip that
      // widened it to a double would silently disable the max-duration cap.
      expect(restored[0].settings.maxChunkMs, 0x7FFFFFFFFFFFFFFF);
    });

    // The mode LABEL is the one field that must NOT fall back to the live prefs
    // when it is missing. The other six are behaviours, so degrading them to
    // "how the app behaves today" is defensible; this one is a claim about which
    // mode already-recorded audio was captured in, and the live value fabricates
    // it rather than degrading it.
    //
    // The path is not hypothetical. An entry written by a build without the
    // field is re-hydrated on the next decode, and _recordModeSwitch decodes the
    // history BEFORE flipping prefs.manualMode — so a live fallback reads the
    // OUTGOING mode and writes it straight back into an entry from two switches
    // ago, durably relabelling that backlog.
    test('an entry with no stored mode decodes to unknown, never to the live mode', () {
      // Exactly what a pre-feature build wrote: the six numbers, no 'manual'.
      const legacy = '[{"at":$base,"settings":{"vadEnabled":true,"speechThreshold":0.5,'
          '"silenceDurationToSplitMs":120000,"minDurationMs":0,"minSpeechMs":3000,'
          '"maxChunkMs":3600000}}]';

      for (final live in [true, false]) {
        SharedPreferencesUtil().manualMode = live;
        final restored = ModeSwitchRecord.decode(legacy);
        expect(restored.single.settings.manual, isNull,
            reason: 'live manualMode=$live must not leak into an entry that predates the field');
        // The behavioural fields still take the live fallback where absent —
        // this test must not be read as switching that off.
        expect(restored.single.settings.silenceDurationToSplitMs, 120000);
      }
    });

    test('a stored mode round-trips both ways and survives re-encoding', () {
      for (final stored in [true, false]) {
        final history = [
          ModeSwitchRecord(
            atUtcSeconds: base + 10,
            settings: mode(splitMs: stored ? 0 : 120000, manual: stored),
          )
        ];
        // Twice: the history is decoded and re-encoded on every retirement, so a
        // field that survives one trip but not two still corrupts over time.
        final once = ModeSwitchRecord.decode(ModeSwitchRecord.encode(history));
        final twice = ModeSwitchRecord.decode(ModeSwitchRecord.encode(once));
        expect(once.single.settings.manual, stored);
        expect(twice.single.settings.manual, stored);
      }
    });

    test('an empty history encodes to the empty string, not "[]"', () {
      // '' is the pref's "nothing pending" value and the fast path out of the
      // drain; '[]' would parse fine but read as a pending switch at a glance.
      expect(ModeSwitchRecord.encode(const []), '');
      expect(ModeSwitchRecord.decode(''), isEmpty);
    });

    test('unreadable JSON degrades to no history instead of throwing', () {
      // Falling back means every bin uses the current mode — the pre-history
      // behaviour. Throwing would wedge the processing pipeline on every run.
      expect(ModeSwitchRecord.decode('{not json'), isEmpty);
      expect(ModeSwitchRecord.decode('[{"at":1}]'), isEmpty); // no settings key
    });

    test('decode sorts, so a clock that stepped backwards cannot unorder it', () {
      final raw = ModeSwitchRecord.encode([entry(300), entry(100)]);
      expect(ModeSwitchRecord.decode(raw).map((e) => e.atUtcSeconds), [base + 100, base + 300]);
    });

    test('a field missing from an older entry falls back to the live value', () {
      final live = ProcessingSettings.fromPrefs().mode;
      final partial = ModeSettings.fromJson({'silenceDurationToSplitMs': 0});
      expect(partial.silenceDurationToSplitMs, 0, reason: 'the field that IS present wins');
      expect(partial.minSpeechMs, live.minSpeechMs);
      expect(partial.vadEnabled, live.vadEnabled);
    });
  });

  group('append', () {
    test('keeps entries ascending', () {
      var h = ModeSwitchRecord.append(const [], entry(200));
      h = ModeSwitchRecord.append(h, entry(100)); // clock stepped back
      expect(h.map((e) => e.atUtcSeconds), [base + 100, base + 200]);
    });

    test('caps the history by dropping the OLDEST', () {
      var h = <ModeSwitchRecord>[];
      for (int i = 1; i <= ModeSwitchRecord.maxEntries + 3; i++) {
        h = ModeSwitchRecord.append(h, entry(i * 10));
      }
      expect(h.length, ModeSwitchRecord.maxEntries);
      // Newest survive: the dropped span falls to the next entry's settings,
      // degraded for the oldest audio only rather than unbounded growth.
      expect(h.first.atUtcSeconds, base + 40);
      expect(h.last.atUtcSeconds, base + (ModeSwitchRecord.maxEntries + 3) * 10);
    });
  });
}
