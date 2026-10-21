import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/ui_lifecycle.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_entitlement_service.dart';
import '../pages/recordings/folder_export_integration_test.dart' show FakeFolder;
import '../pages/recordings/integration_upload_manager_test.dart' show FakeIntegration;

class _IdleSync implements SDCardWalSync {
  IWalSyncProgressListener? listener;
  @override
  bool get isSyncing => false;
  @override
  Future<Set<String>> incompleteBinRelPaths() async => {};
  @override
  void setGlobalProgressListener(IWalSyncProgressListener? value) => listener = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClockedOmiConnector extends OmiCloudConnector {
  _ClockedOmiConnector(this._prefs, this._now) : super(_prefs);
  final SharedPreferencesUtil _prefs;
  final DateTime Function() _now;

  @override
  DateTime? backingOffUntil(IntegrationRecording recording) {
    final until = _prefs.getOmiBackoffUntil(recording.opusFrameSidecarPath);
    return until > _now().millisecondsSinceEpoch ? DateTime.fromMillisecondsSinceEpoch(until) : null;
  }
}

class _LifecycleConnector extends FakeIntegration {
  _LifecycleConnector({this.startup}) : super('Lifecycle');
  final Future<void>? startup;
  int opens = 0;
  int starts = 0;
  bool initialized = false;
  Future<void> Function()? onOpen;
  @override
  Future<void> onServicesStarted() async {
    starts++;
    if (startup != null) await startup;
    initialized = true;
  }

  @override
  Future<void> onAppOpened() async {
    expect(initialized, isTrue);
    opens++;
    await onOpen?.call();
  }
}

class _CheckpointConnector extends FakeIntegration {
  _CheckpointConnector() : super('Cloud', autoUpload: true) {
    enabledByDefault = true;
  }
  final entered = Completer<void>();
  final release = Completer<void>();
  bool? cancelled;
  @override
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled}) async {
    grants.add(upload);
    entered.complete();
    await release.future;
    cancelled = isCancelled?.call() ?? false;
    if (!cancelled!) deliver(upload.recording);
  }
}

void main() {
  late SharedPreferencesUtil prefs;
  late TestEntitlementService entitlements;
  late Directory temp;
  late ValueNotifier<int> changes;
  late List<Conversation> recordings;
  late List<MarkerConversation> markers;
  var unsettled = false;
  final at = DateTime(2026, 9, 1);
  final secure = <String, String>{};

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        if (call.method == 'write') secure[args['key'] as String] = args['value'] as String;
        if (call.method == 'read') return secure[args['key'] as String];
        return null;
      },
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    entitlements = TestEntitlementService(isPro: true);
    temp = Directory.systemTemp.createTempSync('integration_lifecycle');
    changes = ValueNotifier(0);
    recordings = [];
    markers = [];
    unsettled = false;
    FolderExportConnector.resetForTest();
  });

  tearDown(() {
    FolderExportConnector.resetForTest();
    changes.dispose();
    temp.deleteSync(recursive: true);
  });

  Conversation recording(String id, {DateTime? start}) => Conversation(
        file: File('${temp.path}/recording_$id.wav')..writeAsBytesSync(List.filled(100, 7)),
        startTime: start ?? at,
        duration: const Duration(minutes: 2),
        uploadKey: id,
      );
  IntegrationSnapshot snapshot() => IntegrationSnapshot([
        Batch(
            date: at,
            dateString: '2026-09-01',
            rawSegments: const [],
            draftRecordings: const [],
            finalizedRecordings: [...recordings]),
      ], [
        ...markers
      ]);

  IntegrationCoordinator service(
    List<Connector> connectors, {
    Future<IntegrationSnapshot> Function()? load,
    Future<bool> Function()? wifi,
    Stream<Object?>? networkChanges,
    Listenable? recordingChanges,
    bool Function()? processing,
    void Function(String)? acquire,
    void Function(String)? release,
    DateTime Function()? now,
    Duration pollInterval = const Duration(milliseconds: 20),
  }) {
    final result = IntegrationCoordinator(
      connectors: connectors,
      prefs: prefs,
      automation: AutomationPolicy(prefs, entitlements: entitlements),
      loadRecordings: load ?? () async => snapshot(),
      recordingChanges: recordingChanges ?? changes,
      isProcessing: processing ?? () => unsettled,
      isPipelineIdle: () => true,
      checkOnWifi: wifi ?? () async => true,
      connectivityChanges: networkChanges,
      acquireWake: acquire,
      releaseWake: release,
      convertToPassthrough: (_) async {},
      pollInterval: pollInterval,
      now: now,
    );
    addTearDown(result.dispose);
    return result;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));
  MockClient transport({void Function(http.Request)? onRequest}) => MockClient((request) async {
        onRequest?.call(request);
        if (request.url.host == 'public.heypocketai.com') {
          return http.Response(
              jsonEncode({
                'data': {'upload_url': 'https://upload.example/audio'}
              }),
              200);
        }
        return http.Response('{"status":"completed"}', 200);
      });

  Future<HeyPocketConnector> heyPocket() async {
    prefs.heypocketEnabled = true;
    await prefs.setHeypocketApiKey('pk_test');
    prefs.heypocketAutoUpload = true;
    prefs.heypocketKeySetAt = at.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return HeyPocketConnector(prefs);
  }

  FolderExportConnector folder(FakeFolder backend) {
    prefs.folderExportEnabled = true;
    prefs.folderExportTreeUri = 'content://folder';
    prefs.folderExportAutoUpload = true;
    prefs.folderExportAutoUploadAt = at.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return FolderExportConnector(prefs, backend: backend);
  }

  Future<OmiCloudConnector> omi() async {
    prefs.omiEnabled = true;
    await prefs.setOmiRefreshToken('test-fixture');
    await prefs.setOmiFirebaseApiKey('test-fixture');
    await prefs.setOmiIdToken('test-fixture');
    prefs.omiTokenExpiry = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = at.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return OmiCloudConnector(prefs);
  }

  FakeIntegration fake() => FakeIntegration('Cloud', autoUpload: true)..enabledByDefault = true;

  const uiChannel = MethodChannel('me.memrii.app/system');
  Future<void> nativeUi(String method, int generation) async {
    final reply = Completer<void>();
    TestWidgetsFlutterBinding.instance.channelBuffers.push(
      uiChannel.name,
      uiChannel.codec.encodeMethodCall(MethodCall(method, generation)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  AppUiLifecycle uiBridge(
    IntegrationCoordinator coordinator, {
    required Future<void> Function() attached,
    int? initialAttachment,
    Future<void>? startupWork,
    int? snapshotAttachment,
    int? snapshotForeground,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(uiChannel, (call) async {
      if (call.method == 'uiAttachmentGeneration') return snapshotAttachment;
      if (call.method == 'uiOpenGeneration') return snapshotForeground;
      return null;
    });
    addTearDown(() {
      uiChannel.setMethodCallHandler(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(uiChannel, null);
    });
    return AppUiLifecycle(
      channel: uiChannel,
      initialAttachmentGeneration: initialAttachment,
      startupWork: startupWork,
      onAttached: attached,
      onForegrounded: (generation) => coordinator.onAppOpened(uiGeneration: generation),
    )..listen();
  }

  test('cold startup snapshot/live events run attachment work and foreground validation once', () async {
    final destination = _LifecycleConnector();
    var loads = 0;
    var attachments = 1; // main already performed startup permissions/recovery
    final coordinator = service([destination], load: () async {
      loads++;
      return snapshot();
    }, pollInterval: const Duration(hours: 1));
    await coordinator.start();
    final bridge = uiBridge(coordinator,
        attached: () async => attachments++, initialAttachment: 1, snapshotAttachment: 1, snapshotForeground: 1);
    await bridge.recover();
    await nativeUi('uiAttached', 1);
    await nativeUi('uiForegrounded', 1);
    await settle();
    expect(attachments, 1);
    expect(destination.opens, 1);
    expect(loads, 1, reason: 'startup discovery suffices when validation changes nothing');
  });

  test('cached-engine return validates new generation without attachment work or archive reload', () async {
    final destination = _LifecycleConnector();
    var attachments = 0;
    var loads = 0;
    final coordinator = service([destination], load: () async {
      loads++;
      return snapshot();
    }, pollInterval: const Duration(hours: 1));
    await coordinator.start();
    uiBridge(coordinator, attached: () async => attachments++);
    await nativeUi('uiAttached', 1);
    await nativeUi('uiForegrounded', 1);
    await settle();
    // onStop/onStart: the same Activity is still attached.
    await nativeUi('uiForegrounded', 2);
    await settle();
    expect(destination.opens, 2);
    expect(attachments, 1);
    expect(loads, 1);
  });

  test('headless-to-UI lost attach and foreground events are recovered without waiting for permissions', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    final permission = Completer<void>();
    var attachments = 0;
    final bridge = uiBridge(coordinator, attached: () async {
      attachments++;
      await permission.future;
    }, snapshotAttachment: 1, snapshotForeground: 1);
    await bridge.recover(); // must finish despite the unresolved permission flow
    await nativeUi('uiAttached', 1);
    await nativeUi('uiForegrounded', 1);
    await settle();
    expect(attachments, 1);
    expect(destination.opens, 1);
    permission.complete();
    await settle();
  });

  test('new Activity attachment reruns UI setup once even immediately after previous attachment', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    var attachments = 0;
    uiBridge(coordinator, attached: () async => attachments++);
    await nativeUi('uiAttached', 1);
    await nativeUi('uiForegrounded', 1);
    await nativeUi('uiAttached', 2);
    await nativeUi('uiForegrounded', 2);
    await nativeUi('uiAttached', 2); // snapshot/live duplicate
    await nativeUi('uiAttached', 1); // delayed obsolete event
    await settle();
    expect(attachments, 2);
    expect(destination.opens, 2);
  });

  testWidgets('permission pause/resume and widget rebuilds emit no attachment or foreground generation',
      (tester) async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    var attachments = 0;
    uiBridge(coordinator, attached: () async => attachments++);
    await nativeUi('uiAttached', 1);
    await nativeUi('uiForegrounded', 1);
    await coordinator.onAppOpened(uiGeneration: 1);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(attachments, 1);
    expect(destination.opens, 1);
    coordinator.dispose(); // cancel the service timer before widget-test verification
  });

  test('live foreground and recovered snapshot reply before pending connector network validation', () async {
    final destination = _LifecycleConnector();
    final network = Completer<void>();
    destination.onOpen = () => network.future;
    final coordinator = service([destination]);
    await coordinator.start();
    final bridge = uiBridge(coordinator, attached: () async {}, snapshotForeground: 1);
    await nativeUi('uiForegrounded', 1);
    await bridge.recover();
    await settle();
    expect(destination.opens, 1);
    network.complete();
    await coordinator.onAppOpened(uiGeneration: 1);
  });

  test('attachment recovery waits for startup cleanup and serializes genuine reattachments', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    final startup = Completer<void>();
    final first = Completer<void>();
    var attachments = 0;
    uiBridge(coordinator, startupWork: startup.future, attached: () async {
      attachments++;
      if (attachments == 1) await first.future;
    });
    await nativeUi('uiAttached', 1);
    await nativeUi('uiAttached', 2);
    await settle();
    expect(attachments, 0);
    startup.complete();
    await settle();
    expect(attachments, 1);
    first.complete();
    await settle();
    expect(attachments, 2);
  });

  for (final status in [200, 401, 503]) {
    test('foreground HeyPocket HTTP $status updates automation only on changed configuration', () async {
      final destination = await heyPocket();
      // Park existing authorized automatic work; rejection must withdraw it,
      // whereas valid/outage checks must preserve it without loading the archive.
      AutomationSettings(prefs, 'heypocket').wifiOnly = true;
      recordings.add(recording('hp-foreground'));
      var loads = 0;
      final coordinator = service([destination],
          load: () async {
            loads++;
            return snapshot();
          },
          wifi: () async => false,
          pollInterval: const Duration(hours: 1));
      await coordinator.start();
      await settle();
      expect(coordinator.uploads.uploadingFiles, {'hp-foreground'});
      var attachments = 0;
      await http.runWithClient(() async {
        uiBridge(coordinator, attached: () async => attachments++);
        await nativeUi('uiForegrounded', 1);
        await coordinator.onAppOpened(uiGeneration: 1);
        await settle();
      }, () => MockClient((_) async => http.Response('{}', status)));
      expect(attachments, 0);
      expect(prefs.heypocketEnabled, status != 401);
      expect(prefs.heypocketApiKey, 'pk_test');
      expect(loads, status == 401 ? 2 : 1);
      expect(coordinator.uploads.uploadingFiles, status == 401 ? isEmpty : {'hp-foreground'});
    });
  }

  test('stale foreground A rejection preserves B without another archive reload', () async {
    final destination = await heyPocket();
    var loads = 0;
    final coordinator = service([destination], load: () async {
      loads++;
      return snapshot();
    });
    await coordinator.start();
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(() async {
      uiBridge(coordinator, attached: () async {});
      await nativeUi('uiForegrounded', 1);
      await entered.future;
      await coordinator.uploads.replaceCredentialsFor(destination.name, () => prefs.setHeypocketApiKey('pk_B'));
      // Existing configuration invalidation processes B before A returns.
      final checking = coordinator.onAppOpened(uiGeneration: 1);
      coordinator.automationChanged();
      await settle();
      final afterB = loads;
      response.complete(http.Response('{}', 401));
      await checking;
      await settle();
      expect(prefs.heypocketApiKey, 'pk_B');
      expect(prefs.heypocketEnabled, isTrue);
      expect(loads, afterB, reason: 'obsolete A rejection cannot invalidate B');
    },
        () => MockClient((_) async {
              entered.complete();
              return response.future;
            }));
  });

  test('cold UI generation is delivered once; re-attach/foreground opens again', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    await coordinator.onAppOpened(uiGeneration: 1);
    await coordinator.onAppOpened(uiGeneration: 1); // cold snapshot plus native event
    expect(destination.opens, 1);
    await coordinator.recordingsChanged(); // unrelated rebuild/data refresh
    expect(destination.opens, 1);
    await coordinator.onAppOpened(uiGeneration: 2);
    await coordinator.onAppOpened(uiGeneration: 1); // delayed stale event
    expect(destination.opens, 2);
    expect(destination.starts, 1);
  });

  test('attach before start waits for connector initialization without blocking readiness', () async {
    final gate = Completer<void>();
    final destination = _LifecycleConnector(startup: gate.future);
    final coordinator = service([destination]);
    final attach = coordinator.onAppOpened(uiGeneration: 1);
    await coordinator.start(waitForInitialDiscovery: false);
    final snapshotOpen = coordinator.onAppOpened(uiGeneration: 1);
    await settle();
    expect(destination.opens, 0);
    gate.complete();
    await Future.wait([attach, snapshotOpen]);
    expect(destination.opens, 1);
    expect(destination.starts, 1);
  });

  test('foreground opens serialize while a prior check is pending; failure does not poison later opens', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    final gate = Completer<void>();
    destination.onOpen = () async {
      if (destination.opens == 1) {
        await gate.future;
        throw StateError('temporary validation failure');
      }
    };
    await coordinator.start();
    final first = coordinator.onAppOpened(uiGeneration: 1);
    final second = coordinator.onAppOpened(uiGeneration: 2);
    await settle();
    expect(destination.opens, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(destination.opens, 2);
  });

  test('headless startup and disposal before startup perform no UI-open check', () async {
    final destination = _LifecycleConnector();
    final coordinator = service([destination]);
    await coordinator.start();
    expect(destination.opens, 0);
    final unopened = service([_LifecycleConnector()]);
    final pending = unopened.onAppOpened(uiGeneration: 1);
    unopened.dispose();
    await pending;
  });

  for (final rule in ['scope', 'minimum']) {
    test('settings $rule tightens queued work and loosens discovery without polling', () async {
      final destination = fake();
      final candidate = recording('rules-$rule');
      final completed = recording('already-delivered');
      destination.deliver(completed);
      recordings.addAll([candidate, completed]);
      final rules = AutomationSettings(prefs, 'test_Cloud')..wifiOnly = true;
      final coordinator = service([destination], wifi: () async => false, pollInterval: const Duration(hours: 1));
      final model = IntegrationSettingsModel(onAutomationChanged: coordinator.automationChanged);
      addTearDown(model.dispose);
      await coordinator.start();
      await settle();
      expect(coordinator.uploads.uploadingFiles, contains(candidate.uploadKey));
      model.updateAutomation(() {
        if (rule == 'scope') {
          rules.scope = AutomaticRecordingScope.priority;
        } else {
          rules.minimumSeconds = 300;
        }
      });
      expect(coordinator.uploads.uploadingFiles, isEmpty);
      await settle();
      expect(destination.uploadCalls, isEmpty);
      model.updateAutomation(() {
        if (rule == 'scope') {
          rules.scope = AutomaticRecordingScope.all;
        } else {
          rules.minimumSeconds = 30;
        }
      });
      await settle();
      expect(coordinator.uploads.uploadingFiles, contains(candidate.uploadKey));
      model.updateAutomation(() => rules.wifiOnly = false);
      await settle();
      expect(destination.uploadCalls.map((r) => r.id), [candidate.uploadKey]);
      expect(destination.hasDelivered(completed), isTrue);
    });
  }

  test('Wi-Fi rule loosening during a pending condition check unblocks discovery immediately', () async {
    final destination = fake();
    recordings.add(recording('wifi-race'));
    final wifi = Completer<bool>();
    final rules = AutomationSettings(prefs, 'test_Cloud')..wifiOnly = true;
    final coordinator = service([destination], wifi: () => wifi.future, pollInterval: const Duration(hours: 1));
    final model = IntegrationSettingsModel(onAutomationChanged: coordinator.automationChanged);
    addTearDown(model.dispose);
    await coordinator.start();
    model.updateAutomation(() => rules.wifiOnly = false);
    await settle();
    wifi.complete(false);
    await settle();
    expect(destination.uploadCalls, hasLength(1));
  });

  for (final manual in [false, true]) {
    test('Wi-Fi tightening cancels active automatic work at checkpoint; manual=$manual', () async {
      final destination = _CheckpointConnector();
      final candidate = recording('active-wifi');
      if (!manual) recordings.add(candidate);
      final coordinator = service([destination], wifi: () async => false, pollInterval: const Duration(hours: 1));
      final model = IntegrationSettingsModel(onAutomationChanged: coordinator.automationChanged);
      addTearDown(model.dispose);
      await coordinator.start();
      Future<Object?>? sending;
      if (manual) sending = coordinator.uploads.uploadConversation(candidate);
      await destination.entered.future;
      model.updateAutomation(() => AutomationSettings(prefs, 'test_Cloud').wifiOnly = true);
      await settle();
      destination.release.complete();
      if (sending != null) await sending;
      await settle();
      expect(destination.cancelled, !manual);
      expect(destination.hasDelivered(candidate), manual);
    });
  }

  test('startup can finish during a slow discovery and still observes headless recording changes', () async {
    final destination = fake();
    final gate = Completer<void>();
    final network = StreamController<Object?>();
    addTearDown(network.close);
    var loads = 0;
    var ready = false;
    recordings = [recording('startup-stale')];
    final coordinator = service([destination], load: () async {
      final result = snapshot();
      if (++loads == 1) await gate.future;
      return result;
    }, networkChanges: network.stream);
    final starting = coordinator.start(waitForInitialDiscovery: false).then((_) => ready = true);
    await settle();
    expect(ready, isTrue, reason: 'native readiness and UI startup need not wait for the archive');
    expect(loads, 1);
    expect(destination.uploadCalls, isEmpty);

    // A native sync can finish before the first frame and replace the source paths.
    recordings = [recording('startup-current')];
    changes.value++;
    network.add(null);
    var repeatedStartReady = false;
    final repeatedStart = coordinator.start(waitForInitialDiscovery: false).then((_) => repeatedStartReady = true);
    await settle();
    expect(repeatedStartReady, isTrue);
    expect(loads, 1, reason: 'repeated starts and network events do not launch concurrent scans');
    expect(destination.uploadCalls, isEmpty, reason: 'automation cannot use the incomplete archive');

    gate.complete();
    await Future.wait([starting, repeatedStart, coordinator.start()]);
    await settle();
    expect(loads, 2, reason: 'the changed recording invalidates the first snapshot');
    expect(destination.uploadCalls.map((r) => r.id), ['startup-current']);
    await settle();
    expect(destination.uploadCalls, hasLength(1));
  });

  test('headless restart resumes saved Omi backoff when its deadline expires without a change event', () async {
    await omi();
    var clock = at;
    final connector = _ClockedOmiConnector(prefs, () => clock);
    final c = recording('restored-backoff');
    recordings.add(c);
    final sidecar = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    File(sidecar).writeAsBytesSync([1, 0, 0, 0, 7]);
    await prefs.setOmiBackoffUntil(sidecar, clock.add(const Duration(minutes: 5)).millisecondsSinceEpoch);
    var loads = 0;
    var posts = 0;
    await http.runWithClient(() async {
      final coordinator = service([connector],
          now: () => clock,
          load: () async {
            loads++;
            return snapshot();
          });
      await coordinator.start();
      await settle();
      expect(loads, 1);
      expect(posts, 0);
      clock = clock.add(const Duration(minutes: 4));
      await settle();
      expect(loads, 1);
      expect(posts, 0);
      clock = clock.add(const Duration(minutes: 2));
      await settle();
      expect(loads, 2, reason: 'the expired saved deadline triggers fresh discovery');
      expect(posts, 1);
      expect(connector.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
      expect(prefs.getAutoUploadRetries(sidecar), 0);
      await settle();
      expect(posts, 1, reason: 'the restored retry remains deduplicated');
    },
        () => transport(onRequest: (r) {
              if (r.method == 'POST') posts++;
            }));
  });

  test('headless Pro discovers HeyPocket on processing completion, without a controller', () async {
    final hp = await heyPocket();
    final c = recording('headless');
    await http.runWithClient(() async {
      final coordinator = service([hp], recordingChanges: RecordingsManager.recordingsChangeNotifier);
      await coordinator.start();
      recordings.add(c);
      RecordingsManager.notifyRecordingsChanged();
      await settle();
      expect(prefs.isUploadedToHeypocket(c.uploadKey!), isTrue);
    }, transport);
  });

  test('headless Free rejects saved automatic preferences for all three destinations', () async {
    entitlements.isPro = false;
    final hp = await heyPocket();
    final backend = FakeFolder();
    final f = folder(backend);
    final o = await omi();
    final c = recording('free');
    File(IntegrationRecording.fromConversation(c).opusFrameSidecarPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    var uploadRequests = 0;
    await http.runWithClient(() async {
      final coordinator = service([hp, f, o]);
      await coordinator.start();
      recordings.add(c);
      changes.value++;
      await settle();
      expect(coordinator.uploads.uploadingFiles, isEmpty);
      for (final connector in [hp, f, o]) {
        expect(
            coordinator.uploads.sharingPolicy.authorizeUnattended(connector,
                coordinator.uploads.sharingPolicy.propose(connector, IntegrationRecording.fromConversation(c))),
            isNull);
      }
      expect(backend.calls, isEmpty);
      expect(uploadRequests, 0);
      expect(prefs.heypocketAutoUpload && prefs.folderExportAutoUpload && prefs.omiAutoUpload, isTrue);
    },
        () => transport(onRequest: (r) {
              if (r.method != 'GET') uploadRequests++;
            }));
  });

  test('headless Pro Auto-Save uses the selected folder without network or a UI', () async {
    final backend = FakeFolder();
    final coordinator = service([folder(backend)], wifi: () async => false);
    await coordinator.start();
    recordings.add(recording('folder'));
    changes.value++;
    await settle();
    expect(backend.files, hasLength(1));
  });

  test('headless Omi Pro sends only recordings with the processing-time sidecar', () async {
    final o = await omi();
    final ready = recording('omi');
    final missing = recording('no-sidecar');
    File(IntegrationRecording.fromConversation(ready).opusFrameSidecarPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    await http.runWithClient(() async {
      final coordinator = service([o]);
      await coordinator.start();
      recordings.addAll([ready, missing]);
      changes.value++;
      await settle();
      expect(o.hasDelivered(IntegrationRecording.fromConversation(ready)), isTrue);
      expect(o.hasDelivered(IntegrationRecording.fromConversation(missing)), isFalse);
    }, transport);
  });

  test('concurrent background and foreground triggers serialize loads and send once', () async {
    final destination = fake();
    final loadGate = Completer<void>();
    var loads = 0;
    var activeLoads = 0;
    var peakLoads = 0;
    recordings.add(recording('race'));
    final coordinator = service([destination], load: () async {
      loads++;
      activeLoads++;
      peakLoads = activeLoads > peakLoads ? activeLoads : peakLoads;
      await loadGate.future;
      activeLoads--;
      return snapshot();
    });
    final starting = coordinator.start();
    changes.value++;
    final foreground = coordinator.recordingsChanged();
    await settle(); // polling must not invalidate a load merely because it is slow
    loadGate.complete();
    await Future.wait([starting, foreground]);
    await settle();
    expect(peakLoads, 1);
    expect(loads, 2);
    expect(destination.uploadCalls, hasLength(1));
    expect(destination.maxObservedInFlight, 1);
    await coordinator.recordingsChanged();
    expect(destination.uploadCalls, hasLength(1));
  });

  test('settlement reloads paths and markers instead of sending a stale mid-run snapshot', () async {
    final destination = fake();
    AutomationSettings(prefs, 'test_Cloud').scope = AutomaticRecordingScope.priority;
    final coordinator = service([destination]);
    unsettled = true;
    recordings.add(recording('temporary'));
    await coordinator.start();
    changes.value++;
    expect(destination.uploadCalls, isEmpty);
    final finalRecording = recording('final');
    recordings = [finalRecording];
    markers = [
      MarkerConversation(
          markerTime: at,
          edlFile: File('${temp.path}/priority.edl'),
          segment: finalRecording.file,
          isHighPriority: true)
    ];
    unsettled = false;
    changes.value++;
    await settle();
    expect(destination.uploadCalls.single.id, 'final');
  });

  test('a recording change during a load discards its stale snapshot before granting', () async {
    final destination = fake();
    final gate = Completer<void>();
    var loads = 0;
    recordings = [recording('old')];
    final coordinator = service([destination], load: () async {
      final result = snapshot();
      if (++loads == 1) await gate.future;
      return result;
    });
    final starting = coordinator.start();
    recordings = [recording('new')];
    changes.value++;
    gate.complete();
    await starting;
    await settle();
    expect(destination.uploadCalls.single.id, 'new');
  });

  test('headless failed startup load is retried eventually', () async {
    final destination = fake();
    recordings.add(recording('retry'));
    var attempts = 0;
    final coordinator = service([destination], load: () async {
      if (++attempts == 1) throw const FileSystemException('transient fixture');
      return snapshot();
    });
    await coordinator.start(waitForInitialDiscovery: false);
    await settle();
    expect(attempts, 2);
    expect(destination.uploadCalls, hasLength(1));
  });

  test('headless HeyPocket retries a transport failure without archive or UI events', () async {
    final hp = await heyPocket();
    final c = recording('transport-retry');
    recordings.add(c);
    var clock = at;
    var posts = 0;
    var puts = 0;
    await http.runWithClient(() async {
      final coordinator = service([hp], now: () => clock);
      await coordinator.start();
      await settle();
      expect(prefs.isUploadedToHeypocket(c.uploadKey!), isFalse);
      expect(prefs.getAutoUploadRetries(c.uploadKey!), 1);
      await settle();
      expect(posts, 1, reason: 'a failed server must not be retried on every service tick');
      clock = clock.add(const Duration(minutes: 1));
      await settle();
      expect(prefs.isUploadedToHeypocket(c.uploadKey!), isTrue);
      expect(posts, 2);
      expect(puts, 2);
      expect(prefs.getAutoUploadRetries(c.uploadKey!), 0);
      await settle();
      expect(posts, 2, reason: 'delivery remains deduplicated after a retry');
    },
        () => MockClient((request) async {
              if (request.method == 'POST') {
                posts++;
                return http.Response('{"data":{"upload_url":"https://upload.example/audio"}}', 200);
              }
              if (++puts == 1) throw const SocketException('transient fixture');
              return http.Response('', 200);
            }));
  });

  test('headless automatic retries stop at the persisted three-failure budget', () async {
    final destination = fake()..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('budget'));
    var clock = at;
    final coordinator = service([destination], now: () => clock);
    await coordinator.start();
    await settle();
    for (var i = 0; i < 4; i++) {
      clock = clock.add(const Duration(minutes: 1));
      await settle();
    }
    expect(destination.uploadCalls, hasLength(3));
    expect(prefs.getAutoUploadRetries('budget'), 3);
    expect(destination.maxObservedInFlight, 1);
  });

  test('retry reload waits for processing and uses the moved recording', () async {
    final destination = fake();
    destination.onUpload = (_) async => throw const SocketException('transient fixture');
    final before = recording('moved');
    recordings.add(before);
    var clock = at;
    var loads = 0;
    final coordinator = service([destination],
        now: () => clock,
        load: () async {
          loads++;
          return snapshot();
        });
    await coordinator.start();
    await settle();
    unsettled = true;
    final after = Conversation(
      file: before.file.renameSync('${temp.path}/recording_moved_final.wav'),
      startTime: at,
      duration: before.duration,
      uploadKey: before.uploadKey,
    );
    recordings = [after];
    destination.onUpload = (r) async => destination.deliver(r);
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(loads, 1);
    expect(destination.uploadCalls, hasLength(1));
    unsettled = false;
    await settle();
    expect(loads, 2);
    expect(destination.uploadCalls, hasLength(2));
    expect(destination.uploadCalls.last.audioPath, after.file.path);
  });

  test('retry sweep reloads markers before authorizing a Priority recording', () async {
    final destination = fake()..onUpload = (_) async => throw const SocketException('transient fixture');
    final c = recording('retry-priority');
    recordings.add(c);
    markers = [
      MarkerConversation(
          markerTime: at, edlFile: File('${temp.path}/priority.edl'), segment: c.file, isHighPriority: true)
    ];
    AutomationSettings(prefs, 'test_Cloud').scope = AutomaticRecordingScope.priority;
    var clock = at;
    var loads = 0;
    final coordinator = service([destination],
        now: () => clock,
        load: () async {
          loads++;
          return snapshot();
        });
    await coordinator.start();
    await settle();
    markers.clear(); // the retry itself must reload, without another change event
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(loads, 2);
    expect(destination.uploadCalls, hasLength(1));
  });

  test('downgrade withdraws a scheduled retry, upgrade can rediscover it', () async {
    final destination = fake()..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('retry-downgrade'));
    var clock = at;
    final coordinator = service([destination], now: () => clock);
    await coordinator.start();
    await settle();
    entitlements.isPro = false;
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(destination.uploadCalls, hasLength(1));
    destination.onUpload = (r) async => destination.deliver(r);
    entitlements.isPro = true;
    await settle();
    expect(destination.uploadCalls, hasLength(2));
  });

  test('retry reload failure preserves discovery until an authoritative snapshot loads', () async {
    final destination = fake()..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('reload-retry'));
    var clock = at;
    var loads = 0;
    final coordinator = service([destination],
        now: () => clock,
        load: () async {
          if (++loads == 2) throw const FileSystemException('transient fixture');
          return snapshot();
        });
    await coordinator.start();
    await settle();
    destination.onUpload = (r) async => destination.deliver(r);
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(loads, 3);
    expect(destination.uploadCalls, hasLength(2));
  });

  test('backfill retries remain limited to confirmed identities after archive growth', () async {
    final destination = fake()
      ..autoUpload = false
      ..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('confirmed-retry', start: at.subtract(const Duration(days: 1))));
    var clock = at;
    final coordinator = service([destination], now: () => clock);
    await coordinator.start();
    expect(coordinator.uploads.startBackfill(destination.name, ['confirmed-retry']), 1);
    await settle();
    recordings.add(recording('unconfirmed', start: at.subtract(const Duration(days: 2))));
    destination.onUpload = (r) async => destination.deliver(r);
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(destination.uploadCalls.map((r) => r.id), ['confirmed-retry', 'confirmed-retry']);
    expect(AutomationSettings(prefs, 'test_Cloud').backfillIds, isEmpty);
  });

  test('stopped backfill cannot be revived by a scheduled retry', () async {
    final destination = fake()
      ..autoUpload = false
      ..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('retry-backfill', start: at.subtract(const Duration(days: 1))));
    var clock = at;
    final coordinator = service([destination], now: () => clock);
    await coordinator.start();
    expect(coordinator.uploads.startBackfill(destination.name, ['retry-backfill']), 1);
    await settle();
    expect(destination.uploadCalls, hasLength(1));
    expect(AutomationSettings(prefs, 'test_Cloud').backfillIds, ['retry-backfill']);
    coordinator.uploads.stopBackfill(destination.name);
    recordings.add(recording('unconfirmed', start: at.subtract(const Duration(days: 2))));
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(destination.uploadCalls, hasLength(1));
    expect(AutomationSettings(prefs, 'test_Cloud').backfillIds, isEmpty);
  });

  test('disposal cancels scheduled retry discovery', () async {
    final destination = fake()..onUpload = (_) async => throw const SocketException('transient fixture');
    recordings.add(recording('retry-disposed'));
    var clock = at;
    var loads = 0;
    final coordinator = service([destination],
        now: () => clock,
        load: () async {
          loads++;
          return snapshot();
        });
    await coordinator.start();
    await settle();
    coordinator.dispose();
    clock = clock.add(const Duration(minutes: 1));
    await settle();
    expect(loads, 1);
    expect(destination.uploadCalls, hasLength(1));
  });

  test('headless Omi resumes a pending server job without uploading the segment twice', () async {
    final o = await omi();
    final c = recording('pending-job');
    final binPath = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    File(binPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    recordings.add(c);
    var clock = at;
    var posts = 0;
    var polls = 0;
    final pending = Completer<void>();
    await http.runWithClient(() async {
      final coordinator = service([o], now: () => clock);
      await coordinator.start();
      await pending.future;
      await settle();
      expect(prefs.getOmiSegmentJobId('$binPath#0'), 'review-job');
      expect(prefs.isOmiSynced(binPath), isFalse);
      expect(prefs.getAutoUploadRetries(binPath), 0);
      expect(posts, 1);
      clock = clock.add(const Duration(minutes: 6));
      await settle();
      expect(prefs.isOmiSynced(binPath), isTrue);
      expect(prefs.getOmiSegmentJobId('$binPath#0'), isNull);
      expect(posts, 1, reason: 'continuation must poll the saved job, not send the audio again');
      expect(polls, 81);
    },
        () => MockClient((request) async {
              if (request.method == 'POST') {
                posts++;
                return http.Response('{"job_id":"review-job","poll_after_ms":0}', 202);
              }
              polls++;
              if (polls == 80) pending.complete();
              return http.Response(
                  polls <= 80 ? '{"status":"processing","poll_after_ms":0}' : '{"status":"completed"}', 200);
            }));
  });

  test('connectivity cannot dequeue automation while marker metadata is being reloaded', () async {
    final destination = fake();
    final c = recording('marker-race');
    recordings.add(c);
    markers = [
      MarkerConversation(
          markerTime: at, edlFile: File('${temp.path}/priority.edl'), segment: c.file, isHighPriority: true)
    ];
    AutomationSettings(prefs, 'test_Cloud')
      ..scope = AutomaticRecordingScope.priority
      ..wifiOnly = true;
    final network = StreamController<Object?>();
    addTearDown(network.close);
    var wifi = false;
    final gate = Completer<void>();
    var loads = 0;
    final coordinator = service([destination],
        load: () async {
          if (++loads > 1) await gate.future;
          return snapshot();
        },
        wifi: () async => wifi,
        networkChanges: network.stream);
    await coordinator.start();
    await settle();
    expect(coordinator.uploads.uploadingFiles, isNotEmpty);
    markers.clear();
    changes.value++;
    wifi = true;
    network.add(null);
    await settle();
    expect(destination.uploadCalls, isEmpty, reason: 'metadata reload must finish before dequeue');
    gate.complete();
    await settle();
    expect(destination.uploadCalls, isEmpty, reason: 'Priority rule no longer matches');
  });

  test('controller recreation borrows the same live manager and unsubscribes', () async {
    final destination = fake();
    final coordinator = service([destination]);
    await coordinator.start();
    final sync = _IdleSync();
    final first = RecordingsController(integrations: coordinator, walSync: sync)..init();
    var firstUpdates = 0;
    first.addListener(() => firstUpdates++);
    final manager = coordinator.uploads;
    first.dispose();
    final afterDispose = firstUpdates;
    final second = RecordingsController(integrations: coordinator, walSync: sync)..init();
    second.init(); // idempotent; no duplicate integration subscription
    expect(coordinator.uploads, same(manager));
    recordings.add(recording('recreated'));
    changes.value++;
    second.tryAutoUploadAll();
    await settle();
    expect(firstUpdates, afterDispose);
    expect(destination.uploadCalls, hasLength(1));
    second.dispose();
    expect(sync.listener, isNull);
    recordings.add(recording('after-ui-disposal'));
    changes.value++;
    await settle();
    expect(destination.uploadCalls, hasLength(2));
  });

  test('downgrade during asynchronous Wi-Fi check rejects queued automatic work', () async {
    final destination = fake();
    final wifi = Completer<bool>();
    final rules = AutomationSettings(prefs, 'test_Cloud')..wifiOnly = true;
    recordings.add(recording('downgrade'));
    final coordinator = service([destination], wifi: () => wifi.future);
    await coordinator.start();
    expect(coordinator.uploads.uploadingFiles, isNotEmpty);
    entitlements.isPro = false;
    wifi.complete(true);
    await settle();
    expect(destination.uploadCalls, isEmpty);
    expect(destination.autoUpload, isTrue);
    expect(rules.wifiOnly, isTrue);
  });

  test('manual HeyPocket, Folder and Omi work remain Free through the shared owner', () async {
    entitlements.isPro = false;
    final hp = await heyPocket();
    final backend = FakeFolder();
    final f = folder(backend);
    final o = await omi();
    final c = recording('manual');
    File(IntegrationRecording.fromConversation(c).opusFrameSidecarPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    await http.runWithClient(() async {
      final coordinator = service([hp, f, o], wifi: () async => false);
      await coordinator.start();
      expect(await coordinator.uploads.uploadConversation(c), isEmpty);
      await settle();
      expect(prefs.isUploadedToHeypocket(c.uploadKey!), isTrue);
      expect(backend.files, hasLength(1));
      expect(o.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
    }, transport);
  });

  test('headless backfill never expands confirmed identities and Stop withdraws remaining work', () async {
    final destination = fake()..autoUpload = false;
    final coordinator = service([destination], wifi: () async => false);
    AutomationSettings(prefs, 'test_Cloud').wifiOnly = true;
    final archive = recording('confirmed', start: at.subtract(const Duration(days: 1)));
    recordings.add(archive);
    await coordinator.start();
    expect(coordinator.uploads.startBackfill(destination.name, ['confirmed']), 1);
    recordings.add(recording('unconfirmed', start: at.subtract(const Duration(days: 2))));
    changes.value++;
    await settle();
    expect(coordinator.uploads.uploadingFiles, {'confirmed'});
    coordinator.uploads.stopBackfill(destination.name);
    await settle();
    expect(coordinator.uploads.uploadingFiles, isEmpty);
    expect(destination.uploadCalls, isEmpty);
  });

  test('application disposal cancels subscriptions, pending discovery and upload wake holds', () async {
    final destination = fake();
    final gate = Completer<void>();
    final network = StreamController<Object?>();
    addTearDown(network.close);
    var released = 0;
    var loads = 0;
    final coordinator = service([destination],
        load: () async {
          loads++;
          await gate.future;
          return snapshot();
        },
        networkChanges: network.stream,
        release: (_) => released++);
    final starting = coordinator.start();
    coordinator.dispose();
    recordings.add(recording('disposed'));
    changes.value++;
    gate.complete();
    await starting;
    network.add(null);
    await settle();
    expect(loads, 1);
    expect(destination.uploadCalls, isEmpty);
    expect(released, 1);
  });
}
