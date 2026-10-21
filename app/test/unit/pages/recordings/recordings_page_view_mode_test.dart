import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/pages/settings/offline_audio_settings_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PageController extends RecordingsController {
  _PageController([List<MarkerConversation> initialMarkers = const [], List<Batch> initialBatches = const []])
      : markers = [...initialMarkers],
        data = initialBatches,
        super(integrations: _emptyIntegrations());

  final List<MarkerConversation> markers;
  final List<Batch> data;
  int refreshCalls = 0;
  bool busy = false;

  @override
  void init() {}

  @override
  bool get isLoading => false;

  @override
  bool get syncServiceBusy => busy;

  @override
  List<Batch> get batches => data;

  @override
  Future<void> startPipeline() async {
    refreshCalls++;
  }

  @override
  List<MarkerConversation> get markerConversations => markers;

  @override
  Future<void> deleteMarkerConversation(MarkerConversation marker) async {
    markers.remove(marker);
    notifyListeners();
  }
}

IntegrationCoordinator _emptyIntegrations() {
  final changes = ValueNotifier(0);
  final service = IntegrationCoordinator(
    connectors: const [],
    prefs: SharedPreferencesUtil(),
    loadRecordings: () async => const IntegrationSnapshot([], []),
    recordingChanges: changes,
    isProcessing: () => false,
    isPipelineIdle: () => true,
    checkOnWifi: () async => false,
  );
  addTearDown(() {
    service.dispose();
    changes.dispose();
  });
  return service;
}

class _PageDevice extends ChangeNotifier implements DeviceProvider {
  @override
  bool isConnected = false;

  @override
  bool isConnecting = false;

  @override
  bool isBluetoothEnabled = true;

  @override
  bool isMuted = false;

  @override
  DateTime? muteSince;

  @override
  bool get isPriorityRecording => false;

  @override
  DateTime? recordingSince;

  @override
  int storageFullPercentage = -1;

  @override
  bool recordingModeMismatch = false;

  @override
  void dismissRecordingModeMismatch() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  Widget page(_PageController controller, _PageDevice device) => ChangeNotifierProvider<DeviceProvider>.value(
        value: device,
        child: MaterialApp(home: RecordingsPage(controller: controller)),
      );

  Conversation recording(int hour, {int day = 26, int seconds = 300, bool unknown = false}) => Conversation(
        file: File('/tmp/${unknown ? 'unknown' : 'recording'}_${day}_$hour.wav'),
        startTime: DateTime(2026, 9, day, hour),
        duration: Duration(seconds: seconds),
      );

  MarkerConversation marker(Conversation c, {int offset = 1}) => MarkerConversation(
        markerTime: c.startTime.add(Duration(seconds: offset)),
        edlFile: File('/tmp/marker_${c.startTime.millisecondsSinceEpoch}_$offset.edl'),
        segment: c.file,
      );

  Batch batch(List<Conversation> recordings, {List<DiscardRecord> discards = const [], List<File> raw = const []}) =>
      Batch(
        date: DateTime(2026, 9, recordings.first.startTime.day),
        dateString: '2026-09-${recordings.first.startTime.day}',
        rawSegments: raw,
        draftRecordings: const [],
        finalizedRecordings: recordings,
        discards: discards,
      );

  List<Conversation> visibleRecordings(WidgetTester tester) =>
      tester.widgetList<ConversationTile>(find.byType(ConversationTile)).map((w) => w.conversation).toList();

  testWidgets('mode icons, tooltips and accessibility labels match existing saved values', (tester) async {
    final semantics = tester.ensureSemantics();
    final prefs = SharedPreferencesUtil();
    await tester.pumpWidget(page(_PageController(), _PageDevice()));
    expect(find.byTooltip('Session mode'), findsOneWidget);
    expect(tester.getSemantics(find.byTooltip('Session mode')).getSemanticsData().tooltip, 'Session mode');
    final sessionIcon = tester.widget<FaIcon>(find.descendant(
      of: find.byTooltip('Session mode'),
      matching: find.byType(FaIcon),
    ));
    expect(sessionIcon.icon, FontAwesomeIcons.handPointer);
    expect(sessionIcon.size, 20);
    expect(sessionIcon.color, Colors.grey.shade300);
    prefs.manualMode = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(_PageController(), _PageDevice()));
    expect(find.byTooltip('Ambient mode'), findsOneWidget);
    expect(tester.getSemantics(find.byTooltip('Ambient mode')).getSemanticsData().tooltip, 'Ambient mode');
    final ambientIcon = tester.widget<FaIcon>(find.descendant(
      of: find.byTooltip('Ambient mode'),
      matching: find.byType(FaIcon),
    ));
    expect(ambientIcon.icon, FontAwesomeIcons.earListen);
    expect(ambientIcon.size, 20);
    expect(ambientIcon.color, Colors.deepPurpleAccent);
    semantics.dispose();
  });

  testWidgets('recording settings mode copy respects configurable actions', (tester) async {
    final device = _PageDevice()..isConnected = true;
    await tester.pumpWidget(ChangeNotifierProvider<DeviceProvider>.value(
      value: device,
      child: const MaterialApp(home: OfflineAudioSettingsPage()),
    ));
    expect(find.text('Ambient mode'), findsOneWidget);
    expect(find.textContaining('Session mode: start and stop recording using your configured button actions.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    expect(find.textContaining('Ambient mode: hands-free recording with device activity detection.'), findsOneWidget);
    expect(find.textContaining('Use your configured Marker action'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty Markers view can be selected and restored after reopening', (tester) async {
    final prefs = SharedPreferencesUtil();
    final device = _PageDevice();
    await tester.pumpWidget(page(_PageController(), device));

    expect(find.byTooltip('Toggle markers only'), findsOneWidget);
    expect(find.byTooltip('Hide ghosts'), findsOneWidget);
    expect(find.textContaining('No conversations found.'), findsOneWidget);

    await tester.tap(find.byTooltip('Toggle markers only'));
    await tester.pump();
    expect(find.textContaining('No marked recordings yet.'), findsOneWidget);
    expect(prefs.showMarkersOnly, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(_PageController(), device));
    expect(find.textContaining('No marked recordings yet.'), findsOneWidget);
    expect(find.byTooltip('Toggle markers only'), findsOneWidget);
  });

  testWidgets('deleting the last marker keeps both saved view settings', (tester) async {
    final prefs = SharedPreferencesUtil()..showMarkersOnly = true;
    final rec = recording(12);
    final mc = marker(rec);
    final controller = _PageController([
      mc
    ], [
      batch([rec])
    ]);
    final device = _PageDevice();
    await tester.pumpWidget(page(controller, device));

    await tester.tap(find.byTooltip('Hide ghosts'));
    await tester.pump();
    expect(find.byTooltip('Show ghosts'), findsOneWidget);
    expect(prefs.hideGhosts, isTrue);

    expect(visibleRecordings(tester), [rec]);
    await tester.longPress(find.text('Marker at ${mc.markerTimeLabel}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(controller.markers, isEmpty);
    expect(find.byType(ConversationTile), findsNothing);
    expect(find.byType(BatchCard), findsNothing);
    expect(find.textContaining('No marked recordings yet.'), findsOneWidget);
    expect(prefs.showMarkersOnly, isTrue);
    expect(prefs.hideGhosts, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(_PageController(), device));
    expect(find.textContaining('No marked recordings yet.'), findsOneWidget);
    expect(find.byTooltip('Show ghosts'), findsOneWidget);
  });

  group('Marker View uses the normal recording list', () {
    Future<void> pumpListPage(WidgetTester tester, _PageController controller) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(page(controller, _PageDevice()));
    }

    testWidgets('OFF shows normal rows; ON filters without duplicating rows; OFF restores them', (tester) async {
      final older = recording(8);
      final newer = recording(9);
      final unmarked = recording(10, day: 27);
      final controller = _PageController(
        [marker(older), marker(newer), marker(newer, offset: 2)],
        [
          batch([unmarked]),
          batch([older, newer])
        ],
      );
      await pumpListPage(tester, controller);
      expect(visibleRecordings(tester), [unmarked, newer, older]);
      final scrollController = tester.widget<ListView>(find.byType(ListView)).controller;

      await tester.tap(find.byTooltip('Toggle markers only'));
      await tester.pump();
      expect(visibleRecordings(tester), [newer, older]);
      expect(find.byType(BatchCard), findsOneWidget);
      expect(find.text('2026-09-27'), findsNothing);
      expect(find.text('2026-09-26'), findsOneWidget);
      expect(tester.widget<ListView>(find.byType(ListView)).controller, same(scrollController));

      await tester.tap(find.byTooltip('Toggle markers only'));
      await tester.pump();
      expect(visibleRecordings(tester), [unmarked, newer, older]);
      expect(SharedPreferencesUtil().showMarkersOnly, isFalse);
    });

    testWidgets('controller marker updates add and remove membership without toggling the view', (tester) async {
      SharedPreferencesUtil().showMarkersOnly = true;
      final rec = recording(12);
      final first = marker(rec);
      final second = marker(rec, offset: 2);
      final controller = _PageController([], [
        batch([rec])
      ]);
      await pumpListPage(tester, controller);
      expect(find.textContaining('No marked recordings yet.'), findsOneWidget);

      controller.markers.addAll([first, second]);
      controller.notifyListeners();
      await tester.pump();
      expect(visibleRecordings(tester), [rec]);
      await controller.deleteMarkerConversation(first);
      await tester.pump();
      expect(visibleRecordings(tester), [rec]);
      await controller.deleteMarkerConversation(second);
      await tester.pump();
      expect(find.byType(ConversationTile), findsNothing);
      expect(find.textContaining('No marked recordings yet.'), findsOneWidget);

      await tester.tap(find.byTooltip('Toggle markers only'));
      await tester.pump();
      expect(visibleRecordings(tester), [rec]);
    });

    testWidgets('a cross-midnight marker keeps the recording in its normal date section', (tester) async {
      SharedPreferencesUtil().showMarkersOnly = true;
      final rec = recording(23, seconds: 7200);
      final mc = marker(rec, offset: 3600);
      expect(mc.markerTime.day, 27);
      await pumpListPage(
          tester,
          _PageController([
            mc
          ], [
            batch([rec])
          ]));
      expect(visibleRecordings(tester), [rec]);
      expect(find.text('2026-09-26'), findsOneWidget);
      expect(find.text('2026-09-27'), findsNothing);
    });

    testWidgets('Marker and Ghost View compose and keep independent saved preferences', (tester) async {
      final marked = recording(12);
      final unmarked = recording(10);
      final ghost = DiscardRecord(
        startTime: DateTime(2026, 9, 26, 9),
        endTime: DateTime(2026, 9, 26, 9, 1),
        reason: 'muted',
        maxVoiceProb: 0,
        relativeBins: const [],
        sourceJsonl: File('/tmp/discards.jsonl'),
      );
      final controller = _PageController([
        marker(marked)
      ], [
        batch([marked, unmarked], discards: [ghost])
      ]);
      await pumpListPage(tester, controller);
      expect(find.byType(GhostRow), findsOneWidget);

      await tester.tap(find.byTooltip('Toggle markers only'));
      await tester.pump();
      expect(visibleRecordings(tester), [marked]);
      expect(find.byType(GhostRow), findsNothing);
      await tester.tap(find.byTooltip('Hide ghosts'));
      await tester.pump();
      expect(visibleRecordings(tester), [marked]);
      expect(find.byType(GhostRow), findsNothing);

      await tester.tap(find.byTooltip('Toggle markers only'));
      await tester.pump();
      expect(visibleRecordings(tester), [marked, unmarked]);
      expect(find.byType(GhostRow), findsNothing);
      expect(SharedPreferencesUtil().hideGhosts, isTrue);
      await tester.tap(find.byTooltip('Show ghosts'));
      await tester.pump();
      expect(find.byType(GhostRow), findsOneWidget);
    });

    testWidgets('duration tabs remain usable and intersect Marker View', (tester) async {
      SharedPreferencesUtil()
        ..showMarkersOnly = true
        ..filterMinDurationSeconds = 60;
      final long = recording(8);
      final short = recording(9, seconds: 10);
      final unmarked = recording(10, seconds: 10);
      final controller = _PageController([
        marker(long),
        marker(short)
      ], [
        batch([long, short, unmarked])
      ]);
      await pumpListPage(tester, controller);
      expect(visibleRecordings(tester), [long]);

      await tester.tap(find.byTooltip('Filter recordings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden').last);
      await tester.pumpAndSettle();
      expect(visibleRecordings(tester), [short]);
      await tester.tap(find.byTooltip('Filter recordings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All').last);
      await tester.pumpAndSettle();
      expect(visibleRecordings(tester), [short, long]);
    });

    testWidgets('unattached markers and raw audio do not create marker-only cards', (tester) async {
      SharedPreferencesUtil().showMarkersOnly = true;
      final unmarked = recording(12);
      final pending = MarkerConversation(markerTime: unmarked.startTime, edlFile: File('/tmp/pending.edl'));
      final controller = _PageController([
        pending
      ], [
        batch([unmarked], raw: [File('/tmp/raw.bin')])
      ]);
      await pumpListPage(tester, controller);
      expect(find.byType(BatchCard), findsNothing);
      expect(find.byType(ConversationTile), findsNothing);
      expect(find.textContaining('No marked recordings yet.'), findsOneWidget);
      expect(tester.widget<ListView>(find.byType(ListView)).physics, isA<AlwaysScrollableScrollPhysics>());
    });

    testWidgets('Unorganized recordings use the same marker predicate', (tester) async {
      SharedPreferencesUtil().showMarkersOnly = true;
      final marked = recording(12, unknown: true);
      final unmarked = recording(10, unknown: true);
      final controller = _PageController([
        marker(marked)
      ], [
        batch([marked, unmarked])
      ]);
      await pumpListPage(tester, controller);
      expect(visibleRecordings(tester), [marked]);
      expect(find.textContaining('1 recording with unknown timestamps'), findsOneWidget);
    });

    testWidgets('Select all only selects visible marked recording rows', (tester) async {
      SharedPreferencesUtil().showMarkersOnly = true;
      final marked = recording(12);
      final unmarked = recording(10);
      final controller = _PageController([
        marker(marked)
      ], [
        batch([marked, unmarked])
      ]);
      await pumpListPage(tester, controller);
      await tester.longPress(find.text(marked.timeRangeLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all'));
      await tester.pump();
      final tiles = tester.widgetList<ConversationTile>(find.byType(ConversationTile)).toList();
      expect(tiles.map((t) => t.conversation), [marked]);
      expect(tiles.single.selected, isTrue);
      expect(find.text('1'), findsOneWidget);
    });

    for (final empty in [false, true]) {
      testWidgets('pull-to-refresh uses the normal pipeline with Marker View ON (empty=$empty)', (tester) async {
        final rec = recording(12);
        final controller = _PageController(empty ? [] : [marker(rec)], [
          batch([rec])
        ]);
        await pumpListPage(tester, controller);

        Future<void> refresh() async {
          await tester.drag(find.byType(ListView), const Offset(0, 500));
          await tester.pumpAndSettle();
        }

        await refresh();
        expect(controller.refreshCalls, 1);
        await tester.tap(find.byTooltip('Toggle markers only'));
        await tester.pump();
        await refresh();
        expect(controller.refreshCalls, 2);
        controller.busy = true;
        await refresh();
        expect(controller.refreshCalls, 2);
        expect(find.text('Sync already in progress'), findsOneWidget);
      });
    }
  });
}
