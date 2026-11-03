import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/recordings_banners.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PriorityRecordingBanner with a known start', () {
    // The timed branch reads the 24-hour preference, so it needs real prefs.
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        return null;
      });
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    final since = DateTime.utc(2026, 9, 14, 16, 43);

    testWidgets('shows the start in 12-hour form by default', (tester) async {
      SharedPreferencesUtil().use24HourTime = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PriorityRecordingBanner(active: true, since: since))));
      expect(find.text('Priority Recording since ${DateFormat('h:mm a').format(since.toLocal())}'), findsOneWidget);
    });

    testWidgets('follows the 24-hour preference, like the mute banner', (tester) async {
      SharedPreferencesUtil().use24HourTime = true;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PriorityRecordingBanner(active: true, since: since))));
      expect(find.text('Priority Recording since ${DateFormat('HH:mm').format(since.toLocal())}'), findsOneWidget);
    });
  });

  testWidgets('StuckRecordingBanner is empty with nothing stuck', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StuckRecordingBanner(stuckFiles: 0))));
    expect(find.textContaining('download'), findsNothing);
  });

  testWidgets('StuckRecordingBanner says how much more the Omi can record before it overwrites', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: StuckRecordingBanner(stuckFiles: 1, overwriteMinutes: 3 * 24 * 60 + 5))));
    expect(
        find.text('A recording won\'t download from your Omi. It stays there and is tried every sync. '
            'The Omi will overwrite it after about 3 days of recording.'),
        findsOneWidget);
  });

  testWidgets('StuckRecordingBanner makes no claim when the Omi cannot say', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StuckRecordingBanner(stuckFiles: 2))));
    expect(find.text('2 recordings won\'t download from your Omi. They stay there and are tried every sync.'),
        findsOneWidget);
  });

  test('recording time reads in the largest whole unit', () {
    expect(StuckRecordingBanner.recordingTime(0), '1 minute');
    expect(StuckRecordingBanner.recordingTime(59), '59 minutes');
    expect(StuckRecordingBanner.recordingTime(60), '1 hour');
    expect(StuckRecordingBanner.recordingTime(47 * 60 + 59), '47 hours');
    expect(StuckRecordingBanner.recordingTime(48 * 60), '2 days');
  });

  testWidgets('VadFallbackBanner is empty when inactive', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VadFallbackBanner(active: false))));
    expect(find.textContaining('Voice detection unavailable'), findsNothing);
  });

  testWidgets('VadFallbackBanner surfaces the AAD-fallback warning when active', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VadFallbackBanner(active: true))));
    expect(find.textContaining('Voice detection unavailable'), findsOneWidget);
  });

  testWidgets('PriorityRecordingBanner is empty when no Priority Recording is live', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PriorityRecordingBanner(active: false))));
    expect(find.textContaining('Priority Recording'), findsNothing);
  });

  testWidgets('PriorityRecordingBanner shows while one is live, timeless when the start is unknown', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PriorityRecordingBanner(active: true))));
    expect(find.text('Priority Recording in progress'), findsOneWidget);
  });
}
