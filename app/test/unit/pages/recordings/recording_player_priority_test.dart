import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'package:omi/pages/recordings/marker_conversation_player_page.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PriorityController extends RecordingsController {
  _PriorityController(this.conversation, {this.priority = false});

  Conversation conversation;
  bool inLibrary = true;
  bool priority;
  bool failUpdate = false;
  Completer<void>? updateGate;
  final updates = <bool>[];
  final priorityTargets = <Conversation>[];
  final crops = <(Duration, Duration)>[];
  final cropTargets = <Conversation>[];
  bool failCrop = false;
  Completer<void>? cropGate;
  Conversation? savedCrop;
  final extraMarkers = <MarkerConversation>[];

  @override
  List<Batch> get batches => [
        Batch(
          dateString: '2026-10-11',
          date: conversation.startTime,
          rawSegments: const [],
          draftRecordings: const [],
          finalizedRecordings: [if (inLibrary) conversation, if (savedCrop != null) savedCrop!],
        ),
      ];

  @override
  List<MarkerConversation> get markerConversations => [
        ...extraMarkers,
        if (priority)
          MarkerConversation(
            markerTime: conversation.startTime,
            edlFile: File('${conversation.file.path}.edl'),
            segment: conversation.file,
            isHighPriority: true,
          ),
        if (savedCrop != null)
          MarkerConversation(
            markerTime: savedCrop!.startTime,
            edlFile: File('${savedCrop!.file.path}.edl'),
            segment: savedCrop!.file,
            isHighPriority: true,
          ),
      ];

  @override
  List<IntegrationStatus> integrationStatuses(Conversation c) => [];

  @override
  Future<Conversation> resolveConversation(Conversation original) async =>
      currentConversation(original) ?? (throw const FileSystemException('Recording is no longer available'));

  @override
  Future<void> setConversationPriority(Conversation c, bool value) async {
    updates.add(value);
    priorityTargets.add(c);
    await updateGate?.future;
    if (failUpdate) throw const FileSystemException('Could not save priority');
    priority = value;
    notifyListeners();
  }

  @override
  Future<Conversation> saveCroppedConversation(Conversation c, Duration start, Duration end) async {
    crops.add((start, end));
    await cropGate?.future;
    if (failCrop) throw const FileSystemException('Could not save crop');
    c = await resolveConversation(c);
    cropTargets.add(c);
    return savedCrop = Conversation(
      file: c.file.copySync('${c.file.path}_cropped.wav'),
      startTime: c.startTime.add(start),
      duration: end - start,
      uploadKey: 'cropped-copy',
      isCropped: true,
    );
  }
}

void main() {
  late Directory folder;
  late Conversation conversation;
  final audioChannels = <String>[];
  final playerCalls = <MethodCall>[];
  final audioEvents = <String>[];
  final audioDurations = <String, int>{};
  var failAudioLoad = false;

  void emitPlayback(String events, {int position = 0, bool completed = false}) {
    final duration = audioDurations[events] ?? 10000000;
    ui.channelBuffers.push(
      events,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'processingState': completed ? 4 : 3,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'updatePosition': position,
        'bufferedPosition': duration,
        'duration': duration,
        'currentIndex': 0,
      }),
      (_) {},
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    failAudioLoad = false;
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    await SharedPreferencesUtil.init();

    folder = Directory.systemTemp.createTempSync('recording_priority_player');
    final start = DateTime(2026, 10, 11, 12);
    final file = File('${folder.path}/recording_${start.millisecondsSinceEpoch}.wav')
      ..writeAsBytesSync(Uint8List(44 + 320000));
    conversation = Conversation.fromFile(file);

    messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (call) async {
      if (call.method == 'init') {
        final id = (call.arguments as Map)['id'];
        final methods = 'com.ryanheise.just_audio.methods.$id';
        final events = 'com.ryanheise.just_audio.events.$id';
        final data = 'com.ryanheise.just_audio.data.$id';
        audioChannels.addAll([methods, events, data]);
        audioEvents.add(events);
        messenger.setMockMethodCallHandler(MethodChannel(events), (_) async => null);
        messenger.setMockMethodCallHandler(MethodChannel(data), (_) async => null);
        messenger.setMockMethodCallHandler(MethodChannel(methods), (playerCall) async {
          playerCalls.add(playerCall);
          if (playerCall.method == 'load') {
            if (failAudioLoad) throw PlatformException(code: '1', message: 'Preview load failed');
            final source = (playerCall.arguments as Map)['audioSource'] as Map;
            audioDurations[events] =
                source['type'] == 'clipping' ? (source['end'] as int) - (source['start'] as int) : 10000000;
            emitPlayback(events);
            return {'duration': audioDurations[events]};
          }
          if (playerCall.method == 'seek') {
            emitPlayback(events, position: (playerCall.arguments as Map)['position'] as int);
          }
          return <String, dynamic>{};
        });
      }
      return <String, dynamic>{};
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    audioChannels.clear();
    playerCalls.clear();
    audioEvents.clear();
    audioDurations.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
    folder.deleteSync(recursive: true);
  });

  Future<void> openPlayer(WidgetTester tester, _PriorityController controller) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: ConversationPlayerPage(conversation: conversation, controller: controller),
      ));
      // Allow the real file read used by waveform loading to finish outside the fake clock.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      controller.dispose();
    });
  }

  Future<void> settleAudio(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump();
        if (attempt >= 5 && find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> openCropPlayer(WidgetTester tester, {bool marker = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _PriorityController(conversation);
    await tester.pumpWidget(MaterialApp(
      home: marker
          ? MarkerConversationPlayerPage(
              markerConversation: MarkerConversation(
                markerTime: conversation.startTime.add(const Duration(seconds: 5)),
                segment: conversation.file,
                edlFile: File('${folder.path}/marker.edl'),
                markerOffsetMs: 5000,
                cropStartMs: 2000,
                cropEndMs: 8000,
                userSaved: true,
              ),
              controller: controller,
            )
          : MarkerConversationPlayerPage.forRecording(conversation: conversation, controller: controller),
    ));
    await settleAudio(tester);
    if (marker) {
      await tester.tap(find.byTooltip('Edit crop'));
      await tester.pumpAndSettle();
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      controller.dispose();
    });
  }

  Map getLastLoadedSource() => playerCalls.lastWhere((call) => call.method == 'load').arguments['audioSource'] as Map;
  int getLastSeekPosition() => playerCalls.lastWhere((call) => call.method == 'seek').arguments['position'] as int;

  Future<void> closeCropPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // just_audio cancels its position timer on the first tick after disposal.
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('crop Play starts at the crop start, clips the end and stops on completion', (tester) async {
    await openCropPlayer(tester, marker: true);
    final source = getLastLoadedSource();
    expect(source['type'], 'clipping');
    expect(source['start'], 2000000);
    expect(source['end'], 8000000);
    expect(getLastSeekPosition(), 3000000, reason: 'the marker begins at absolute 5 seconds');
    expect(find.text('00:10'), findsOneWidget, reason: 'the timeline retains the full recording duration');

    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastSeekPosition(), 0, reason: 'Play restarts at absolute crop start, not the marker');
    expect(playerCalls.lastWhere((call) => call.method == 'play').method, 'play');
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.text('00:02'), findsOneWidget);

    emitPlayback(audioEvents.single, position: 3000000);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('00:05'), findsOneWidget, reason: 'relative audio positions map back to the full timeline');
    await tester.tap(find.byTooltip('Seek backward 30 seconds'));
    await settleAudio(tester);
    expect(getLastSeekPosition(), 0);
    await tester.tap(find.byTooltip('Seek forward 30 seconds'));
    await settleAudio(tester);
    expect(getLastSeekPosition(), 6000000, reason: 'seeking cannot leave the native crop');

    emitPlayback(audioEvents.single, position: 6000000, completed: true);
    await settleAudio(tester);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.text('00:08'), findsOneWidget);
    expect(playerCalls.last.method, 'pause');
    final playCount = playerCalls.where((call) => call.method == 'play').length;
    await tester.tap(find.byTooltip('Seek backward 30 seconds'));
    await settleAudio(tester);
    expect(playerCalls.where((call) => call.method == 'play').length, playCount,
        reason: 'seeking after completion must not resume automatically');
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastSeekPosition(), 0);
    expect(tester.takeException(), isNull);
    await closeCropPlayer(tester);
  });

  testWidgets('changing either crop boundary pauses and the next Play uses the updated selection', (tester) async {
    await openCropPlayer(tester);
    await tester.tap(find.byKey(const ValueKey('crop-start-increase')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('crop-end-decrease')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastLoadedSource()['start'], 1000000);
    expect(getLastLoadedSource()['end'], 9000000);
    expect(getLastSeekPosition(), 0);
    emitPlayback(audioEvents.single, position: 2000000);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Pause'));
    await settleAudio(tester);
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastSeekPosition(), 0, reason: 'replaying a paused crop begins at crop start');

    await tester.tap(find.byKey(const ValueKey('crop-start-increase')));
    await settleAudio(tester);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(playerCalls.last.method, 'pause');
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastLoadedSource()['start'], 2000000);
    expect(getLastLoadedSource()['end'], 9000000);
    await tester.tap(find.byKey(const ValueKey('crop-end-decrease')));
    await settleAudio(tester);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(playerCalls.last.method, 'pause');
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastLoadedSource()['start'], 2000000);
    expect(getLastLoadedSource()['end'], 8000000);
    expect(getLastSeekPosition(), 0);
    expect(tester.takeException(), isNull);
    await closeCropPlayer(tester);
  });

  testWidgets('a failed preview load stays editable and Play can retry', (tester) async {
    await openCropPlayer(tester);
    await tester.tap(find.byKey(const ValueKey('crop-start-increase')));
    await tester.pumpAndSettle();
    failAudioLoad = true;
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(playerCalls.where((call) => call.method == 'play'), isEmpty);
    expect(find.text('Could not play the crop preview. Please try again.'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('crop-end-decrease'))).onPressed, isNotNull);
    failAudioLoad = false;
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    expect(getLastLoadedSource()['start'], 1000000);
    expect(getLastLoadedSource()['end'], 10000000);
    expect(getLastSeekPosition(), 0);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closeCropPlayer(tester);
  });

  testWidgets('priority toggle is adjacent to delete and enabling needs no confirmation', (tester) async {
    final controller = _PriorityController(conversation);
    await openPlayer(tester, controller);
    final actions = tester.widget<AppBar>(find.byType(AppBar)).actions!;
    final deleteIndex = actions.indexWhere((w) => w is IconButton && w.tooltip == 'Delete conversation');
    expect(actions[deleteIndex - 1], isA<ListenableBuilder>());
    expect(find.byTooltip('Mark as priority'), findsOneWidget);

    await tester.tap(find.byTooltip('Mark as priority'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.updates, [true]);
    final icon = tester.widget<FaIcon>(find.descendant(
      of: find.byTooltip('Remove priority'),
      matching: find.byType(FaIcon),
    ));
    expect(icon.icon, FontAwesomeIcons.solidBookmark);
    expect(icon.color, Colors.red);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removal matches deletion styling and Cancel preserves priority', (tester) async {
    final controller = _PriorityController(conversation, priority: true);
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    final deletion = tester.widget<AlertDialog>(find.byType(AlertDialog));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Remove priority'));
    await tester.pumpAndSettle();
    final removal = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(removal.backgroundColor, deletion.backgroundColor);
    expect((removal.title! as Text).style, (deletion.title! as Text).style);
    expect((removal.content! as Text).style, (deletion.content! as Text).style);
    expect(controller.updates, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.priority, isTrue);
    expect(controller.updates, isEmpty);
    expect(find.byTooltip('Remove priority'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('priority follows a recording moved while its player remains open', (tester) async {
    conversation = Conversation(
      file: conversation.file,
      startTime: conversation.startTime,
      duration: conversation.duration,
      uploadKey: 'stable-recording-id',
    );
    final controller = _PriorityController(conversation, priority: true);
    await openPlayer(tester, controller);
    final original = conversation;
    final corrected = original.startTime.add(const Duration(days: 1));
    final moved = original.file.renameSync('${folder.path}/recording_${corrected.millisecondsSinceEpoch}.wav');
    controller.conversation = Conversation(
      file: moved,
      startTime: corrected,
      duration: original.duration,
      uploadKey: original.uploadKey,
    );
    controller.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byTooltip('Remove priority'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove priority'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Remove priority'));
    await tester.pumpAndSettle();
    expect(controller.updates, [false]);
    expect(controller.priorityTargets.single.file.path, moved.path);
    expect(find.byTooltip('Mark as priority'), findsOneWidget);

    await tester.tap(find.byTooltip('Mark as priority'));
    await tester.pumpAndSettle();
    expect(controller.updates, [false, true]);
    expect(controller.priorityTargets.last.file.path, moved.path);
    expect(tester.takeException(), isNull);
  });

  testWidgets('priority is disabled when the open recording is removed from the library', (tester) async {
    final controller = _PriorityController(conversation);
    await openPlayer(tester, controller);
    controller.inLibrary = false;
    controller.notifyListeners();
    await tester.pumpAndSettle();
    final button = find.ancestor(of: find.byTooltip('Mark as priority'), matching: find.byType(IconButton));
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    await tester.tap(find.byTooltip('Mark as priority'));
    await tester.pumpAndSettle();
    expect(controller.updates, isEmpty);
  });

  testWidgets('dismissing confirmation preserves priority and confirming removes it', (tester) async {
    final controller = _PriorityController(conversation, priority: true);
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Remove priority'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(controller.updates, isEmpty);
    expect(controller.priority, isTrue);

    await tester.tap(find.byTooltip('Remove priority'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove priority'));
    await tester.pumpAndSettle();
    expect(controller.updates, [false]);
    expect(controller.priority, isFalse);
    expect(find.byTooltip('Mark as priority'), findsOneWidget);
    expect(find.byType(ConversationPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a crop from a moved player uses the current audio path', (tester) async {
    conversation = Conversation(
      file: conversation.file,
      startTime: conversation.startTime,
      duration: conversation.duration,
      uploadKey: 'stable-recording-id',
    );
    final controller = _PriorityController(conversation);
    await openPlayer(tester, controller);
    final original = conversation;
    final corrected = original.startTime.add(const Duration(days: 1));
    final moved = original.file.renameSync('${folder.path}/recording_${corrected.millisecondsSinceEpoch}.wav');
    controller.conversation = Conversation(
      file: moved,
      startTime: corrected,
      duration: original.duration,
      uploadKey: original.uploadKey,
    );
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Crop recording'));
    await settleAudio(tester);
    final editor = tester.widget<MarkerConversationPlayerPage>(find.byType(MarkerConversationPlayerPage));
    expect(editor.conversation!.file.path, moved.path);
    final source = getLastLoadedSource();
    expect((source['child'] as Map)['uri'], moved.uri.toString());
    await tester.tap(find.byTooltip('Save cropped copy'));
    await settleAudio(tester);
    expect(controller.cropTargets.single.file.path, moved.path);
    expect(controller.savedCrop!.startTime, corrected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open crop can reload its preview and save after its source moves', (tester) async {
    conversation = Conversation(
      file: conversation.file,
      startTime: conversation.startTime,
      duration: conversation.duration,
      uploadKey: 'stable-recording-id',
    );
    final controller = _PriorityController(conversation);
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Crop recording'));
    await settleAudio(tester);
    final original = conversation;
    final corrected = original.startTime.add(const Duration(days: 1));
    final moved = original.file.renameSync('${folder.path}/recording_${corrected.millisecondsSinceEpoch}.wav');
    controller.conversation = Conversation(
      file: moved,
      startTime: corrected,
      duration: original.duration,
      uploadKey: original.uploadKey,
    );
    controller.notifyListeners();
    await tester.tap(find.byKey(const ValueKey('crop-start-increase')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play'));
    await settleAudio(tester);
    final source = getLastLoadedSource();
    expect((source['child'] as Map)['uri'], moved.uri.toString());
    expect(source['start'], 1000000);
    await tester.tap(find.byTooltip('Save cropped copy'));
    await settleAudio(tester);
    expect(controller.cropTargets.single.file.path, moved.path);
    expect(controller.savedCrop!.startTime, corrected.add(const Duration(seconds: 1)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending and failed writes keep the toggle consistent', (tester) async {
    final controller = _PriorityController(conversation)
      ..failUpdate = true
      ..updateGate = Completer<void>();
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Mark as priority'));
    await tester.pump();
    final toggle = find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Mark as priority');
    expect(tester.widget<IconButton>(toggle).onPressed, isNull);
    controller.updateGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.priority, isFalse);
    expect(controller.updates, [true]);
    expect(find.text('Failed to update recording priority.'), findsOneWidget);
    expect(tester.widget<IconButton>(toggle).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final priority in [false, true]) {
    testWidgets('recording crop is available and saved copy can be opened (priority=$priority)', (tester) async {
      final controller = _PriorityController(conversation, priority: priority);
      await openPlayer(tester, controller);
      await tester.tap(find.byTooltip('Crop recording'));
      await settleAudio(tester);
      expect(find.text('Crop recording'), findsOneWidget);
      expect(find.byType(MarkerConversationPlayerPage), findsOneWidget);
      expect(find.byTooltip('Delete marker'), findsNothing);
      await tester.tap(find.byTooltip('Save cropped copy'));
      await tester.pumpAndSettle();
      expect(controller.crops, [(Duration.zero, const Duration(seconds: 10))]);
      expect(controller.savedCrop?.isCropped, isTrue);
      final message = tester.widget<Text>(find.text('Cropped copy saved to Conversations'));
      expect(message.style?.color, Colors.white);
      final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackbar.backgroundColor, const Color(0xFF303030));
      await tester.tap(find.text('Open'));
      await settleAudio(tester);
      expect(tester.widget<ConversationPlayerPage>(find.byType(ConversationPlayerPage)).conversation,
          same(controller.savedCrop));
      expect(find.byTooltip('Remove priority'), findsOneWidget);
      expect(controller.priority, priority, reason: 'saving a priority copy must not change the source status');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('marker crop preserves its selected range when editing again and saves actual copy', (tester) async {
    final controller = _PriorityController(conversation);
    final edl = File('${folder.path}/marker.edl')..writeAsStringSync('{}');
    final marker = MarkerConversation(
      markerTime: conversation.startTime.add(const Duration(seconds: 5)),
      segment: conversation.file,
      edlFile: edl,
      markerOffsetMs: 5000,
      cropStartMs: 2000,
      cropEndMs: 8000,
      userSaved: true,
    );
    await tester.pumpWidget(MaterialApp(
        home: MarkerConversationPlayerPage(
      markerConversation: marker,
      controller: controller,
    )));
    await settleAudio(tester);
    await tester.tap(find.byTooltip('Edit crop'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('recording-crop-waveform')));
    await tester.dragFrom(rect.topLeft + Offset(rect.width * 0.2, rect.height / 2), Offset(rect.width * 0.1, 0));
    await tester.pump();
    await tester.dragFrom(rect.topLeft + Offset(rect.width * 0.8, rect.height / 2), Offset(-rect.width * 0.1, 0));
    await tester.pump();
    await tester.tap(find.byTooltip('Save cropped copy'));
    await settleAudio(tester);
    expect(controller.crops.single.$1.inMilliseconds, greaterThan(2000));
    expect(controller.crops.single.$2.inMilliseconds, lessThan(8000));
    expect(controller.crops.single.$2.inMilliseconds, greaterThan(6000));
    expect(find.text('Cropped copy saved to Conversations'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit crop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save cropped copy'));
    await settleAudio(tester);
    expect(controller.crops[1], controller.crops[0], reason: 'entering crop mode must not reset the selected range');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
    controller.dispose();
  });

  testWidgets('an open marker crop remembers its range on the migrated EDL', (tester) async {
    final original = conversation;
    final controller = _PriorityController(original);
    final edl = File('${folder.path}/marker_${original.startTime.millisecondsSinceEpoch + 5000}.edl')
      ..writeAsStringSync('{}');
    final marker = MarkerConversation(
      markerTime: original.startTime.add(const Duration(seconds: 5)),
      segment: original.file,
      edlFile: edl,
      markerOffsetMs: 5000,
      cropStartMs: 2000,
      cropEndMs: 8000,
      userSaved: true,
    );
    await tester.pumpWidget(
        MaterialApp(home: MarkerConversationPlayerPage(markerConversation: marker, controller: controller)));
    await settleAudio(tester);
    await tester.tap(find.byTooltip('Edit crop'));
    await tester.pumpAndSettle();

    final corrected = original.startTime.add(const Duration(days: 1));
    final moved = original.file.renameSync('${folder.path}/recording_${corrected.millisecondsSinceEpoch}.wav');
    controller.conversation = Conversation(
      file: moved,
      startTime: corrected,
      duration: original.duration,
      uploadKey: original.uploadKey,
    );
    final movedEdl = edl.renameSync('${folder.path}/marker_${corrected.millisecondsSinceEpoch + 5000}.edl');
    controller.extraMarkers.add(MarkerConversation(
      markerTime: corrected.add(const Duration(seconds: 5)),
      segment: moved,
      edlFile: movedEdl,
      markerOffsetMs: 5000,
      cropStartMs: 2000,
      cropEndMs: 8000,
      userSaved: true,
    ));
    controller.notifyListeners();
    await tester.tap(find.byTooltip('Save cropped copy'));
    await settleAudio(tester);
    expect(find.text('Cropped copy saved to Conversations'), findsOneWidget);
    expect(controller.savedCrop!.startTime, corrected.add(const Duration(seconds: 2)));
    expect(edl.existsSync(), isFalse);
    final data = jsonDecode(movedEdl.readAsStringSync()) as Map<String, dynamic>;
    expect(data['segmentFilename'], moved.uri.pathSegments.last);
    expect(data['markerTimestampMs'], corrected.millisecondsSinceEpoch + 5000);
    expect(data['cropStartMs'], 2000);
    expect(data['cropEndMs'], 8000);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
    controller.dispose();
  });

  testWidgets('crop editor fits a phone and both full-range grips stay reachable', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _PriorityController(conversation);
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Crop recording'));
    await settleAudio(tester);
    for (final name in ['crop-start-handle', 'crop-end-handle']) {
      final grip = tester.getRect(find.byKey(ValueKey(name)));
      expect(grip.width, 48);
      expect(grip.left, greaterThanOrEqualTo(0));
      expect(grip.right, lessThanOrEqualTo(390));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed crop write stays editable and never claims it was saved', (tester) async {
    final controller = _PriorityController(conversation)
      ..failCrop = true
      ..cropGate = Completer<void>();
    await openPlayer(tester, controller);
    await tester.tap(find.byTooltip('Crop recording'));
    await settleAudio(tester);
    await tester.tap(find.byTooltip('Save cropped copy'));
    await tester.pump();
    final save = find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Save cropped copy');
    expect(tester.widget<IconButton>(save).onPressed, isNull);
    controller.cropGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cropped copy saved to Conversations'), findsNothing);
    expect(find.text('Could not save the cropped recording. Please try again.'), findsOneWidget);
    expect(tester.widget<IconButton>(save).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
