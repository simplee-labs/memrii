import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/entitlements/entitlement_service.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/integrations/upload_types.dart';
import 'package:omi/pages/settings/integrations_page.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_entitlement_service.dart';

import '../pages/recordings/folder_export_integration_test.dart' show FakeFolder;
import '../pages/recordings/integration_upload_manager_test.dart' show FakeIntegration;

void main() {
  late SharedPreferencesUtil prefs;
  late TestEntitlementService entitlements;
  late Directory temp;
  final secure = <String, String>{};
  final start = DateTime(2026, 1, 1, 12);

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
    entitlements = TestEntitlementService();
    temp = Directory.systemTemp.createTempSync('pro_automation');
    FolderExportConnector.resetForTest();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Conversation recording(String id, {Duration duration = const Duration(minutes: 2), DateTime? at}) => Conversation(
        file: File('${temp.path}/recording_$id.wav')..writeAsBytesSync(List.filled(100, 7)),
        startTime: at ?? start,
        duration: duration,
        uploadKey: id,
      );
  Batch batch(List<Conversation> recordings) => Batch(
      dateString: '2026-01-01',
      date: start,
      rawSegments: const [],
      draftRecordings: const [],
      finalizedRecordings: recordings);
  FakeIntegration destination() => FakeIntegration('Cloud', autoUpload: true)..enabledByDefault = true;
  AutomationSettings settings() => AutomationSettings(prefs, 'test_Cloud');

  IntegrationUploadManager engine(List<Connector> connectors, List<Conversation> recordings,
          {List<MarkerConversation> markers = const [],
          Future<bool> Function()? wifi,
          void Function(Conversation)? converted,
          bool Function()? processing,
          DateTime Function()? now,
          EntitlementService? entitlementProvider}) =>
      IntegrationUploadManager(
        connectors: connectors,
        prefs: prefs,
        automation: AutomationPolicy(prefs, entitlements: entitlementProvider ?? entitlements),
        batchesProvider: () => [batch(recordings)],
        markersProvider: () => markers,
        isDisposed: () => false,
        isPipelineIdle: () => true,
        isProcessing: processing ?? () => false,
        notifyUi: () {},
        acquireWake: (_) {},
        releaseWake: (_) {},
        showUploadNotification: (_) {},
        settleNotification: () {},
        setPendingSnack: (_) {},
        checkOnWifi: wifi ?? () async => true,
        convertToPassthrough: (c) async => converted?.call(c),
        now: now,
      );
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 15));
  MarkerConversation marker(Conversation c, {bool priority = false}) => MarkerConversation(
      markerTime: c.startTime.add(const Duration(seconds: 5)),
      segment: c.file,
      edlFile: File('${c.file.path}.edl'),
      isHighPriority: priority);
  MockClient client() => MockClient((req) async => req.url.host == 'public.heypocketai.com'
      ? http.Response(
          jsonEncode({
            'data': {'upload_url': 'https://upload.example/audio'}
          }),
          200)
      : http.Response('{"status":"completed"}', 200));

  Future<HeyPocketConnector> heyPocket() async {
    prefs.heypocketEnabled = true;
    await prefs.setHeypocketApiKey('pk_test');
    prefs.heypocketAutoUpload = true;
    prefs.heypocketKeySetAt = start.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return HeyPocketConnector(prefs);
  }

  FolderExportConnector folder(FakeFolder backend) {
    prefs.folderExportEnabled = true;
    prefs.folderExportTreeUri = 'content://folder';
    prefs.folderExportAutoUpload = true;
    prefs.folderExportAutoUploadAt = start.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return FolderExportConnector(prefs, backend: backend);
  }

  Future<OmiCloudConnector> omi() async {
    prefs.omiEnabled = true;
    await prefs.setOmiRefreshToken('refresh-secret');
    await prefs.setOmiFirebaseApiKey('firebase-secret');
    await prefs.setOmiIdToken('id-secret');
    prefs.omiTokenExpiry = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = start.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    return OmiCloudConnector(prefs);
  }

  void writeOmiSidecar(Conversation c, {int frames = 1}) =>
      File(IntegrationRecording.fromConversation(c).opusFrameSidecarPath)
          .writeAsBytesSync(List<int>.generate(frames * 5, (i) => const [1, 0, 0, 0, 7][i % 5]));

  void integrationViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openIntegration(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> backToIntegrations(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  void expectFreeIntegrationUi({String? title}) {
    for (final name in title == null ? ['HeyPocket', 'Save to Folder', 'Omi Cloud (unofficial)'] : [title]) {
      expect(find.text(name), findsOneWidget);
    }
    for (final label in [
      'Auto-Upload',
      'Auto-Save',
      'Pro',
      'Upload Rules',
      'Recording scope',
      'Automatic minimum duration',
      'Automatic Conditions',
      'Wi-Fi only',
      'Archive Backfill',
      'Upload existing matching recordings',
      'Stop backfill',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.byType(DropdownButtonFormField<AutomaticRecordingScope>), findsNothing);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(find.textContaining('Pro required'), findsNothing);
    expect(find.textContaining('Automatically'), findsNothing);
    expect(find.textContaining('Auto-uploading'), findsNothing);
    expect(find.textContaining('Auto-saving'), findsNothing);
    expect(find.textContaining('saved backfill selection'), findsNothing);
    if (title != null) {
      expect(
          find.text(switch (title) {
            'HeyPocket' => 'Upload recordings to HeyPocket',
            'Save to Folder' => 'Save recordings to a folder you choose',
            _ => 'Upload recordings to Omi Cloud',
          }),
          findsOneWidget);
    }
  }

  test('application entitlement ignores stale overrides in every build', () async {
    SharedPreferences.setMockInitialValues({'developmentProOverride': true, 'isPro': true});
    await SharedPreferencesUtil.init();
    expect(const LocalEntitlementService().isPro, isFalse);
    expect(AutomationPolicy(prefs).entitlements.isPro, isFalse);
  });

  test('the public application provider cannot start automation in a debug test runtime', () async {
    entitlements.isPro = true;
    prefs.saveBool('developmentProOverride', true);
    final dest = destination();
    final m = engine([dest], [recording('public')], entitlementProvider: const LocalEntitlementService());
    m.tryAutoUploadAll();
    await tick();
    expect(dest.grants, isEmpty);
    expect(m.sharingPolicy.modeFor(dest), ApprovalMode.manual);
  });

  test('Free cannot start HeyPocket Auto-Upload or automatic retries', () async {
    final hp = await heyPocket();
    final c = recording('free');
    await prefs.setAutoUploadLastFailureAt(c.uploadKey!);
    final m = engine([hp], [c]);
    m.tryAutoUploadAll();
    await tick();
    expect(m.uploadingFiles, isEmpty);
    expect(m.sharingPolicy.modeFor(hp), ApprovalMode.manual);
    expect(m.integrationStatuses(c).single.state, IntegrationUploadState.failed);
    expect(prefs.isUploadedToHeypocket('free'), isFalse);
  });

  test('Free cannot start Auto-Save', () async {
    final backend = FakeFolder();
    final f = folder(backend);
    engine([f], [recording('free')]).tryAutoUploadAll();
    await tick();
    expect(backend.calls, isEmpty);
  });

  test('Free manager and sharing APIs reject restored automation and backfill without a UI', () async {
    final hp = await heyPocket();
    final backend = FakeFolder();
    final f = folder(backend);
    final rules = AutomationSettings(prefs, 'heypocket')
      ..scope = AutomaticRecordingScope.priority
      ..minimumSeconds = 60
      ..wifiOnly = true
      ..backfillIds = ['restored-archive'];
    final c = recording('restored-archive');
    final m = engine([hp, f], [c], markers: [marker(c, priority: true)]);
    for (final connector in [hp, f]) {
      expect(m.automation.isAvailable(connector), isFalse);
      final candidate = m.sharingPolicy.propose(connector, IntegrationRecording.fromConversation(c));
      expect(m.sharingPolicy.authorizeUnattended(connector, candidate), isNull);
      expect(m.backfillCandidates(connector.name), isEmpty);
      expect(m.startBackfill(connector.name, ['restored-archive']), 0);
    }
    m.automationChanged();
    m.tryAutoUploadAll();
    m.pumpAllLanes();
    await tick();
    expect(m.uploadingFiles, isEmpty);
    expect(prefs.isUploadedToHeypocket('restored-archive'), isFalse);
    expect(backend.calls, isEmpty);
    expect(rules.backfillIds, ['restored-archive']);
    expect(rules.scope, AutomaticRecordingScope.priority);
    expect(rules.minimumSeconds, 60);
    expect(rules.wifiOnly, isTrue);
    expect(prefs.heypocketAutoUpload, isTrue);
    expect(prefs.folderExportAutoUpload, isTrue);
  });

  test('Free manually uploads and retries HeyPocket over cellular with automatic Wi-Fi configured', () async {
    prefs.uploadOnWifiOnly = true; // stale legacy data cannot restore the old transport gate
    final hp = await heyPocket();
    AutomationSettings(prefs, 'heypocket').wifiOnly = true;
    final c = recording('manual');
    var wifiChecks = 0;
    final m = engine([hp], [c], wifi: () async {
      wifiChecks++;
      return false;
    });
    var fail = true;
    final transport = MockClient((req) async {
      if (fail) return http.Response('', 503);
      return req.method == 'POST'
          ? http.Response('{"data":{"upload_url":"https://upload.example/audio"}}', 200)
          : http.Response('', 200);
    });
    await http.runWithClient(() async {
      expect(await m.uploadConversation(c), isEmpty);
      await tick();
      expect(m.integrationStatuses(c).single.state, IntegrationUploadState.failed);
      expect(prefs.getAutoUploadRetries('manual'), 0);
      fail = false;
      expect(await m.uploadOne(c, hp.name, force: true), isEmpty);
      await tick();
    }, () => transport);
    expect(hp.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
    expect(wifiChecks, 0);
  });

  test('Free manually saves to Folder over cellular', () async {
    final backend = FakeFolder();
    final f = folder(backend);
    final c = recording('manual-folder');
    final m = engine([f], [c], wifi: () async => throw StateError('manual cannot check Wi-Fi'));
    expect(await m.uploadOne(c, f.name), isEmpty);
    await tick();
    expect(backend.files, hasLength(1));
    expect(f.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
  });

  test('malformed HeyPocket responses do not log signed upload URLs', () async {
    final hp = await heyPocket();
    final c = recording('malformed');
    final policy = SharingPolicy(prefs);
    final grant = policy.approveUserRequest(policy.propose(hp, IntegrationRecording.fromConversation(c)));
    final before = Logger.instance.talker.history.length;
    final transport = MockClient((_) async => http.Response('{"upload_url":"presigned-sentinel', 200));
    await expectLater(http.runWithClient(() => hp.send(grant), () => transport), throwsException);
    final logs = Logger.instance.talker.history.skip(before).map((entry) => entry.message).join('\n');
    expect(logs, isNot(contains('presigned-sentinel')));
  });

  for (final pro in [false, true]) {
    test('Omi Auto-Upload requires Pro while explicit manual uploads remain Free, Pro=$pro', () async {
      entitlements.isPro = pro;
      final o = await omi();
      final c = recording('omi-auto');
      final manual = recording('omi-manual', at: start.subtract(const Duration(days: 2)));
      writeOmiSidecar(c);
      writeOmiSidecar(manual);
      final m = engine([o], [c]);
      var requests = 0;
      final transport = MockClient((req) async {
        requests++;
        return http.Response('{"status":"completed"}', 200);
      });
      expect(o.isAutomaticSendingEnabled, isTrue, reason: 'saved consent is independent of entitlement');
      expect(o.isEligibleForAutomatic(IntegrationRecording.fromConversation(c)), isTrue);
      await http.runWithClient(() async {
        m.tryAutoUploadAll();
        await tick();
        expect(requests, pro ? 1 : 0);
        expect(o.hasDelivered(IntegrationRecording.fromConversation(c)), pro);
        expect(m.sharingPolicy.modeFor(o), pro ? ApprovalMode.automatic : ApprovalMode.manual);
        expect(await m.uploadOne(manual, o.name), isEmpty);
        await tick();
        expect(requests, pro ? 2 : 1);
      }, () => transport);
      expect(o.hasDelivered(IntegrationRecording.fromConversation(manual)), isTrue);
      expect(m.backfillCandidates(o.name), isEmpty);
      expect(m.startBackfill(o.name, ['omi']), 0);
    });
  }

  test('Omi automation requires consent, a valid cutoff and a sendable sidecar', () async {
    entitlements.isPro = true;
    final o = await omi();
    final before = recording('omi-before', at: start.subtract(const Duration(seconds: 1)));
    final boundary = recording('omi-boundary');
    final after = recording('omi-after', at: start.add(const Duration(seconds: 1)));
    final noSidecar = recording('omi-no-sidecar');
    for (final c in [before, boundary, after]) {
      writeOmiSidecar(c);
    }
    final m = engine([o], [before, boundary, after, noSidecar]);
    var requests = 0;
    final transport = MockClient((req) async {
      requests++;
      return http.Response('{"status":"completed"}', 200);
    });
    await http.runWithClient(() async {
      prefs.omiAutoUpload = false;
      m.tryAutoUploadAll();
      await tick();
      expect(requests, 0, reason: 'Pro alone never grants consent');
      prefs.omiAutoUpload = true;
      prefs.omiAutoUploadAt = 0;
      m.tryAutoUploadAll();
      await tick();
      expect(requests, 0, reason: 'a missing consent cutoff fails closed');
      prefs.omiAutoUploadAt = start.millisecondsSinceEpoch;
      m.tryAutoUploadAll();
      await tick();
      expect(requests, 2);
    }, () => transport);
    expect(o.hasDelivered(IntegrationRecording.fromConversation(before)), isFalse);
    expect(o.hasDelivered(IntegrationRecording.fromConversation(boundary)), isTrue);
    expect(o.hasDelivered(IntegrationRecording.fromConversation(after)), isTrue);
    expect(o.hasDelivered(IntegrationRecording.fromConversation(noSidecar)), isFalse);
  });

  test('Omi stops before its next chunk on downgrade and resumes after Pro returns', () async {
    entitlements.isPro = true;
    final o = await omi();
    final c = recording('omi-chunked', duration: const Duration(minutes: 4));
    writeOmiSidecar(c, frames: 9001);
    final m = engine([o], [c]);
    final started = Completer<void>();
    final firstResponse = Completer<void>();
    var requests = 0;
    final transport = MockClient((req) async {
      requests++;
      if (requests == 1) {
        started.complete();
        await firstResponse.future;
      }
      return http.Response('{"status":"completed"}', 200);
    });
    await http.runWithClient(() async {
      m.tryAutoUploadAll();
      await started.future.timeout(const Duration(seconds: 3));
      entitlements.isPro = false;
      m.automationChanged();
      firstResponse.complete();
      await tick();
      expect(requests, 1, reason: 'no new chunk begins after entitlement loss');
      expect(o.hasDelivered(IntegrationRecording.fromConversation(c)), isFalse);
      expect(prefs.omiSyncedSegmentCount(IntegrationRecording.fromConversation(c).opusFrameSidecarPath), 1);
      expect(prefs.omiAutoUpload, isTrue, reason: 'the saved opt-in survives');
      entitlements.isPro = true;
      m.automationChanged();
      await tick();
      expect(requests, 2, reason: 'the delivered first chunk is not uploaded again');
      expect(o.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
    }, () => transport);
  });

  test('Pro can Auto-Upload HeyPocket on Wi-Fi and Auto-Save without Wi-Fi', () async {
    entitlements.isPro = true;
    final hp = await heyPocket();
    final backend = FakeFolder();
    final f = folder(backend);
    AutomationSettings(prefs, 'heypocket').wifiOnly = true;
    AutomationSettings(prefs, 'folderExport').wifiOnly = true;
    final c = recording('pro');
    final m = engine([hp, f], [c]);
    await http.runWithClient(() async {
      m.tryAutoUploadAll();
      await tick();
    }, client);
    expect(hp.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
    expect(backend.files, hasLength(1));
  });

  test('automatic work parks then connectivity re-pumping wakes it; manual takes over a parked job', () async {
    entitlements.isPro = true;
    final dest = destination();
    settings().wifiOnly = true;
    final a = recording('a');
    final b = recording('b');
    var onWifi = false;
    final m = engine([dest], [a, b], wifi: () async => onWifi);
    m.tryAutoUploadAll();
    await tick();
    expect(dest.uploadCalls, isEmpty);
    expect(m.uploadingFiles, hasLength(2));
    expect(await m.uploadOne(a, dest.name), isEmpty);
    await tick();
    expect(dest.grants.single.basis, AuthorizationBasis.userRequest);
    onWifi = true;
    m.pumpAllLanes();
    await tick();
    expect(dest.grants.last.basis, AuthorizationBasis.automaticOptIn);
    expect(dest.uploadCalls, hasLength(2));
  });

  test('entitlement loss keeps manual jobs and saved configuration; restores future automation', () async {
    entitlements.isPro = true;
    final dest = destination();
    final s = settings()
      ..scope = AutomaticRecordingScope.all
      ..minimumSeconds = 30
      ..wifiOnly = false;
    final a = recording('a');
    final b = recording('b');
    final manual = recording('manual');
    final gate = Completer<void>();
    dest.onUpload = (r) async {
      await gate.future;
      if (!(dest.lastIsCancelled?.call() ?? false)) dest.deliver(r);
    };
    final m = engine([dest], [a, b]);
    m.tryAutoUploadAll();
    await tick();
    await m.uploadOne(manual, dest.name);
    entitlements.isPro = false;
    m.automationChanged();
    expect(dest.lastIsCancelled!(), isTrue, reason: 'active automatic work stops at its next checkpoint');
    expect(s.minimumSeconds, 30);
    expect(dest.autoUpload, isTrue);
    gate.complete();
    await tick();
    expect(dest.uploadCalls.map((r) => r.id), ['a', 'manual']);
    expect(dest.grants.last.basis, AuthorizationBasis.userRequest);
    expect(prefs.getAutoUploadRetries('a'), 0);
    expect(prefs.getAutoUploadLastFailureAt('a'), 0, reason: 'entitlement cancellation is not a failure');
    entitlements.isPro = true;
    m.automationChanged();
    await tick();
    expect(dest.hasDelivered(b), isTrue);
  });

  test('loss of Pro never cancels an in-flight manual request', () async {
    entitlements.isPro = true;
    final dest = destination();
    final gate = Completer<void>();
    dest.onUpload = (r) async {
      await gate.future;
      dest.deliver(r);
    };
    final c = recording('manual');
    final m = engine([dest], [c]);
    await m.uploadOne(c, dest.name);
    entitlements.isPro = false;
    m.automationChanged();
    expect(dest.lastIsCancelled!(), isFalse);
    gate.complete();
    await tick();
    expect(dest.hasDelivered(c), isTrue);
  });

  test('an already started single request can finish after downgrade; queued auto cannot begin', () async {
    entitlements.isPro = true;
    final dest = destination();
    final gate = Completer<void>();
    dest.onUpload = (r) async {
      await gate.future;
      dest.deliver(r);
    };
    final a = recording('a');
    final b = recording('b');
    final m = engine([dest], [a, b]);
    m.tryAutoUploadAll();
    await tick();
    entitlements.isPro = false;
    gate.complete();
    await tick();
    expect(dest.uploadCalls, hasLength(1));
    expect(dest.hasDelivered(a), isTrue);
    expect(m.uploadingFiles, isEmpty);
  });

  test('manual pending transport continuation retains userRequest for Free', () {
    fakeAsync((clock) {
      final dest = destination();
      var attempts = 0;
      dest.onUpload = (r) async {
        if (++attempts == 2) dest.deliver(r);
      };
      final c = recording('pending');
      final m = engine([dest], [c],
          wifi: () async => throw StateError('no manual conditions'), now: clock.getClock(DateTime.now()).now);
      m.uploadOne(c, dest.name);
      clock.flushMicrotasks();
      expect(attempts, 1);
      clock.elapse(const Duration(minutes: 5, seconds: 2));
      clock.flushMicrotasks();
      expect(attempts, 2);
      expect(dest.grants.every((g) => g.basis == AuthorizationBasis.userRequest), isTrue);
      expect(dest.hasDelivered(c), isTrue);
      m.tryAutoUploadAll();
      clock.flushMicrotasks();
      expect(attempts, 2);
    });
  });

  test('Free cannot discover review candidates without explicit approval', () {
    final dest = destination()..autoUpload = false;
    final m = engine([dest], [recording('review')]);
    m.sharingPolicy.setReviewMode(dest, true, now: start.subtract(const Duration(days: 1)));
    m.tryAutoUploadAll();
    expect(m.sharingPolicy.pendingReview(), isEmpty);
  });

  for (final scope in AutomaticRecordingScope.values) {
    test('recording scope ${scope.name} uses ordinary and Priority marker metadata', () async {
      entitlements.isPro = true;
      final dest = destination();
      settings().scope = scope;
      final plain = recording('plain');
      final marked = recording('marked');
      final priority = recording('priority');
      final m = engine([dest], [plain, marked, priority], markers: [marker(marked), marker(priority, priority: true)]);
      m.tryAutoUploadAll();
      await tick();
      expect(
          dest.uploadCalls.map((r) => r.id).toSet(),
          switch (scope) {
            AutomaticRecordingScope.all => {'plain', 'marked', 'priority'},
            AutomaticRecordingScope.marked => {'marked', 'priority'},
            AutomaticRecordingScope.priority => {'priority'},
          });
      expect(dest.uploadCalls.last.hasPriorityMarker, isTrue);
      expect(dest.uploadCalls.last.captureMode, RecordingCaptureMode.unknown);
    });
  }

  test('automatic duration respects equality and does not change the Free core filter', () async {
    entitlements.isPro = true;
    prefs.filterMinDurationSeconds = 10;
    settings().minimumSeconds = 60;
    final dest = destination();
    final short = recording('short', duration: const Duration(seconds: 59, milliseconds: 999));
    final equal = recording('equal', duration: const Duration(seconds: 60));
    final m = engine([dest], [short, equal]);
    m.tryAutoUploadAll();
    await tick();
    expect(dest.uploadCalls.map((r) => r.id), ['equal']);
    expect(prefs.filterMinDurationSeconds, 10);
    entitlements.isPro = false;
    prefs.filterMinDurationSeconds = 120;
    expect(prefs.filterMinDurationSeconds, 120);
    expect(await m.uploadOne(short, dest.name), isEmpty);
    await tick();
    expect(dest.hasDelivered(short), isTrue, reason: 'manual exports may include a short recording');
  });

  test('legacy Wi-Fi migration is conservative and idempotent', () async {
    SharedPreferences.setMockInitialValues({'uploadOnWifiOnly': true, 'filterMinDurationSeconds': 37});
    await SharedPreferencesUtil.init();
    final s = AutomationSettings(prefs, 'heypocket');
    expect(s.wifiOnly, isTrue);
    s.wifiOnly = false;
    await SharedPreferencesUtil.init();
    expect(s.wifiOnly, isFalse);
    expect(prefs.filterMinDurationSeconds, 37);
    expect(prefs.uploadOnWifiOnly, isTrue, reason: 'retained as migration/rollback data only');
  });

  test('legacy migration preserves an already configured new condition', () async {
    SharedPreferences.setMockInitialValues({'uploadOnWifiOnly': true, 'automation_heypocket_wifiOnly': false});
    await SharedPreferencesUtil.init();
    expect(AutomationSettings(prefs, 'heypocket').wifiOnly, isFalse);
  });

  test('Free cannot preview or start archive backfill', () {
    final dest = destination();
    final m = engine([dest], [recording('archive')]);
    expect(m.backfillCandidates(dest.name), isEmpty);
    expect(m.startBackfill(dest.name, ['archive']), 0);
    expect(settings().backfillIds, isEmpty);
  });

  test('backfill respects review mode and saved rejection; explicit manual approval stays Free', () async {
    entitlements.isPro = true;
    settings().wifiOnly = true;
    final dest = destination()..autoUpload = false;
    final c = recording('reviewed-archive');
    final m = engine([dest], [c], wifi: () async => false);
    final policy = m.sharingPolicy;
    policy.setReviewMode(dest, true, now: start.subtract(const Duration(days: 1)));
    expect(m.backfillCandidates(dest.name), isEmpty);
    expect(m.startBackfill(dest.name, ['reviewed-archive']), 0);
    policy.setReviewMode(dest, false);
    expect(m.startBackfill(dest.name, ['reviewed-archive']), 1);
    final candidate = policy.propose(dest, IntegrationRecording.fromConversation(c));
    final grant = policy.authorizeUnattended(dest, candidate)!;
    expect(grant.basis, AuthorizationBasis.automaticBackfill);
    policy.reject(candidate);
    expect(policy.isStillAuthorized(dest, grant), isFalse);
    expect(m.backfillCandidates(dest.name), isEmpty);
    m.automationChanged();
    await tick();
    expect(dest.uploadCalls, isEmpty);
    entitlements.isPro = false;
    await m.uploadOne(c, dest.name);
    await tick();
    expect(dest.grants.single.basis, AuthorizationBasis.userRequest);
  });

  test('backfill selects a confirmed matching snapshot, deduplicates and resumes after restart', () async {
    entitlements.isPro = true;
    final dest = destination()..enabledByDefault = false; // all predate normal cutoff
    settings()
      ..scope = AutomaticRecordingScope.marked
      ..wifiOnly = true;
    final matched = recording('matched');
    final delivered = recording('delivered');
    final unmarked = recording('unmarked');
    final later = recording('later');
    dest.deliver(delivered);
    final markers = [marker(matched), marker(delivered), marker(later)];
    final recordings = [matched, delivered, unmarked, later];
    final m = engine([dest], recordings, markers: markers, wifi: () async => false);
    m.tryAutoUploadAll();
    await tick();
    expect(dest.uploadCalls, isEmpty, reason: 'normal cutoff excludes the archive');
    expect(m.backfillCandidates(dest.name).toSet(), {'matched', 'later'});
    expect(m.startBackfill(dest.name, ['matched', 'matched', 'delivered', 'unmarked']), 1);
    m.startBackfill(dest.name, ['matched']);
    await tick();
    expect(m.uploadingFiles, hasLength(1));
    expect(dest.uploadCalls, isEmpty, reason: 'backfill honors automatic Wi-Fi');
    entitlements.isPro = false;
    m.automationChanged();
    expect(m.uploadingFiles, isEmpty);
    expect(settings().backfillIds, ['matched']);
    await SharedPreferencesUtil.init();
    entitlements.isPro = true;
    final restarted = engine([dest], recordings, markers: markers);
    restarted.tryAutoUploadAll();
    await tick();
    expect(dest.uploadCalls.map((r) => r.id), ['matched']);
    expect(dest.grants.single.basis, AuthorizationBasis.automaticBackfill);
    expect(settings().backfillIds, isEmpty);
    restarted.tryAutoUploadAll();
    await tick();
    expect(dest.uploadCalls, hasLength(1));
  });

  test('backfill cannot enlarge the confirmed selection when rules change', () async {
    entitlements.isPro = true;
    final dest = destination()..autoUpload = false;
    settings().scope = AutomaticRecordingScope.marked;
    final a = recording('a');
    final b = recording('b');
    final m = engine([dest], [a, b], markers: [marker(a)]);
    final preview = m.backfillCandidates(dest.name);
    settings().scope = AutomaticRecordingScope.all;
    expect(m.startBackfill(dest.name, preview), 1);
    await tick();
    expect(dest.uploadCalls.map((r) => r.id), ['a']);
  });

  test('backfill respects core filters, retry exhaustion, availability and processing', () async {
    entitlements.isPro = true;
    final dest = destination();
    final short = recording('short', duration: const Duration(seconds: 9));
    final exhausted = recording('exhausted');
    final missing = recording('missing');
    dest.markFailed(exhausted);
    dest.availableByDefault = false;
    dest.setAvailable(short, true);
    dest.setAvailable(exhausted, true);
    prefs.filterMinDurationSeconds = 10;
    final m = engine([dest], [short, exhausted, missing]);
    expect(m.backfillCandidates(dest.name), isEmpty);
    expect(engine([destination()], [recording('busy')], processing: () => true).backfillCandidates('Cloud'), isEmpty);
  });

  for (final pro in [false, true]) {
    test('passthrough never grants automation; manual post-delivery remains available, Pro=$pro', () async {
      entitlements.isPro = pro;
      prefs.passthroughMode = true;
      final dest = destination();
      final c = recording('retention');
      var conversions = 0;
      late IntegrationUploadManager m;
      m = engine([dest], [c], converted: (r) {
        if (m.deliveredEverywhereAvailable(r)) conversions++;
      });
      m.tryAutoUploadAll();
      await tick();
      expect(dest.uploadCalls.length, pro ? 1 : 0);
      if (!pro) {
        expect(conversions, 0);
        await m.uploadOne(c, dest.name);
        await tick();
      }
      expect(conversions, 1);
      expect(prefs.keepRecordingsDays, 0);
    });
  }

  test('Omi credentials stay in secure storage and logout clears all sensitive auth', () async {
    await omi();
    final plain = await SharedPreferences.getInstance();
    for (final key in ['omiCredentials', 'omiIdToken']) {
      expect(plain.containsKey(key), isFalse);
      expect(secure[key], isNotEmpty);
    }
    final pair = jsonDecode(secure['omiCredentials']!) as Map;
    expect(pair['refreshToken'], prefs.omiRefreshToken);
    expect(pair['apiKey'], prefs.omiFirebaseApiKey);
    expect(plain.containsKey('omiRefreshToken'), isFalse);
    expect(plain.containsKey('omiFirebaseApiKey'), isFalse);
    await OmiApiClient.signOut();
    expect(secure.values, everyElement(isEmpty));
    expect(prefs.omiEnabled, isFalse);
    expect(prefs.omiTokenExpiry, 0);
  });

  test('malformed Omi auth responses cannot expose credentials through exceptions', () async {
    await omi();
    prefs.omiTokenExpiry = 0;
    final transport = MockClient((_) async => http.Response('{"id_token":"credential-sentinel"', 200));
    Object? error;
    await http.runWithClient(() async {
      try {
        await OmiApiClient.refreshTokenIfNeeded();
      } catch (e) {
        error = e;
      }
    }, () => transport);
    expect(error, isA<OmiSyncException>());
    expect(error.toString(), isNot(contains('credential-sentinel')));
  });

  test('logout prevents an outstanding refresh from restoring credentials', () async {
    await omi();
    prefs.omiTokenExpiry = 0;
    final response = Completer<http.Response>();
    final transport = MockClient((_) => response.future);
    final refreshing = http.runWithClient(OmiApiClient.refreshTokenIfNeeded, () => transport);
    await tick();
    await OmiApiClient.signOut();
    response.complete(http.Response('{"id_token":"late-secret","refresh_token":"late-refresh"}', 200));
    await expectLater(refreshing, throwsA(isA<OmiSyncException>()));
    expect(secure.values, everyElement(isEmpty));
    expect(prefs.omiRefreshToken, isEmpty);
  });

  test('Session capture mode alone never identifies a Priority Recording', () {
    final c = Conversation(
        file: File('${temp.path}/session.wav'),
        startTime: start,
        duration: const Duration(minutes: 1),
        uploadKey: 'session',
        recordedManual: true);
    final r = IntegrationRecording.fromConversation(c);
    expect(r.captureMode, RecordingCaptureMode.manual);
    expect(r.hasPriorityMarker, isFalse);
    settings().scope = AutomaticRecordingScope.priority;
    expect(AutomationPolicy(prefs).matchesRules(destination(), r), isFalse);
  });

  test('manual request arriving during a Wi-Fi check is never stranded', () async {
    entitlements.isPro = true;
    settings().wifiOnly = true;
    final dest = destination();
    final gate = Completer<bool>();
    final c = recording('race');
    final m = engine([dest], [c], wifi: () => gate.future);
    m.tryAutoUploadAll();
    await m.uploadOne(c, dest.name);
    gate.complete(false);
    await tick();
    expect(dest.grants.single.basis, AuthorizationBasis.userRequest);
    expect(m.uploadingFiles, isEmpty);
  });

  test('entitlement loss during a connectivity check safely withdraws its queue', () async {
    entitlements.isPro = true;
    settings().wifiOnly = true;
    final dest = destination();
    final gate = Completer<bool>();
    final c = recording('race');
    final m = engine([dest], [c], wifi: () => gate.future);
    m.tryAutoUploadAll();
    entitlements.isPro = false;
    m.automationChanged();
    gate.complete(true);
    await tick();
    expect(dest.grants, isEmpty);
    expect(m.uploadingFiles, isEmpty);
  });

  test('stopping backfill withdraws queued automation without touching manual jobs', () async {
    entitlements.isPro = true;
    final dest = destination()..autoUpload = false;
    settings().wifiOnly = true;
    final a = recording('archive');
    final m = engine([dest], [a], wifi: () async => false);
    m.startBackfill(dest.name, ['archive']);
    await tick();
    expect(m.uploadingFiles, hasLength(1));
    m.stopBackfill(dest.name);
    await tick();
    expect(settings().backfillIds, isEmpty);
    expect(m.uploadingFiles, isEmpty);
    await m.uploadOne(a, dest.name);
    await tick();
    expect(dest.grants.single.basis, AuthorizationBasis.userRequest);
  });

  testWidgets('Free integration UI hides automation and allows manual destination setup', (tester) async {
    integrationViewport(tester);
    const folderChannel = MethodChannel('me.memrii.app/folderExport');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      folderChannel,
      (call) async => call.method == 'pickFolder' ? {'treeUri': 'content://chosen', 'label': 'My recordings'} : true,
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(folderChannel, null));
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      expectFreeIntegrationUi();
      expect(find.text('Enabled'), findsNothing);
      await openIntegration(tester, 'Omi Cloud (unofficial)');
      expectFreeIntegrationUi(title: 'Omi Cloud (unofficial)');
      expect(find.text('Log in with Omi'), findsOneWidget);
      expect(find.text('Log in via app.omi.me'), findsOneWidget);
      await backToIntegrations(tester);
      await openIntegration(tester, 'HeyPocket');
      expectFreeIntegrationUi(title: 'HeyPocket');
      final apiKeyField = find.byType(TextField);
      expect(tester.widget<TextField>(apiKeyField).decoration!.hintText, 'API key (pk_...)');
      await tester.enterText(apiKeyField, 'pk_manual_configuration');
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(prefs.heypocketApiKey, 'pk_manual_configuration');
      expect(prefs.heypocketEnabled, isTrue);
      await backToIntegrations(tester);
      await openIntegration(tester, 'Save to Folder');
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      expect(prefs.folderExportTreeUri, 'content://chosen');
      expect(prefs.folderExportEnabled, isTrue);
      expect(find.text('My recordings'), findsOneWidget);
      expect(find.text('Change folder'), findsOneWidget);
      expectFreeIntegrationUi(title: 'Save to Folder');
      expect(prefs.heypocketAutoUpload, isFalse);
      expect(prefs.folderExportAutoUpload, isFalse);
      expect(prefs.omiAutoUpload, isFalse);
      await tester.pumpWidget(const SizedBox());
    }, client);
  });

  testWidgets('Pro to Free to Pro hides automation while preserving and restoring its configuration', (tester) async {
    integrationViewport(tester);
    entitlements.isPro = true;
    ApplicationEntitlements.installLocalDevelopment(entitlements);
    addTearDown(() => ApplicationEntitlements.installLocalDevelopment(null));
    final hp = await heyPocket();
    final f = folder(FakeFolder());
    FolderExportConnector.defaultBackend = FakeFolder();
    addTearDown(FolderExportConnector.resetForTest);
    prefs.folderExportLabel = 'Saved recordings';
    final o = await omi();
    final hpCutoff = prefs.heypocketKeySetAt;
    final folderCutoff = prefs.folderExportAutoUploadAt;
    final omiCutoff = prefs.omiAutoUploadAt;
    final rules = AutomationSettings(prefs, 'heypocket')
      ..scope = AutomaticRecordingScope.priority
      ..minimumSeconds = 60
      ..wifiOnly = true
      ..backfillIds = ['saved-archive-id'];

    void expectSavedConfiguration() {
      expect(prefs.heypocketAutoUpload, isTrue);
      expect(prefs.heypocketKeySetAt, hpCutoff);
      expect(prefs.folderExportAutoUpload, isTrue);
      expect(prefs.folderExportAutoUploadAt, folderCutoff);
      expect(prefs.omiAutoUpload, isTrue);
      expect(prefs.omiAutoUploadAt, omiCutoff);
      expect(rules.scope, AutomaticRecordingScope.priority);
      expect(rules.minimumSeconds, 60);
      expect(rules.wifiOnly, isTrue);
      expect(rules.backfillIds, ['saved-archive-id']);
      expect(prefs.heypocketApiKey, 'pk_test');
      expect(prefs.folderExportTreeUri, 'content://folder');
      expect(prefs.omiRefreshToken, 'refresh-secret');
    }

    Future<void> expectProConfiguration() async {
      expect(find.byType(SwitchListTile), findsNothing);
      await openIntegration(tester, 'HeyPocket');
      expect(find.text('Auto-Upload'), findsOneWidget);
      expect(find.text('Upload Rules'), findsOneWidget);
      expect(find.text('Priority Recordings'), findsOneWidget);
      expect(find.text('60 seconds'), findsOneWidget);
      expect(find.text('Automatic Conditions'), findsOneWidget);
      expect(find.text('Archive Backfill'), findsOneWidget);
      expect(find.text('Stop backfill'), findsOneWidget);
      final wifi = tester
          .widget<SwitchListTile>(find.ancestor(of: find.text('Wi-Fi only'), matching: find.byType(SwitchListTile)));
      expect(wifi.value, isTrue);
      expect(wifi.onChanged, isNotNull);
      expect(find.text('Pro'), findsNWidgets(4));
      await backToIntegrations(tester);
      await openIntegration(tester, 'Save to Folder');
      expect(find.text('Auto-Save'), findsOneWidget);
      await backToIntegrations(tester);
      await openIntegration(tester, 'Omi Cloud (unofficial)');
      expect(find.text('Auto-Upload'), findsOneWidget);
      await backToIntegrations(tester);
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      await tester.pumpAndSettle();
      await expectProConfiguration();
      expectSavedConfiguration();
      await tester.pumpWidget(const SizedBox());
      // Reopening with the normal provider models running the public Free build.
      ApplicationEntitlements.installLocalDevelopment(null);
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      await tester.pumpAndSettle();
      expectFreeIntegrationUi();
      for (final title in ['HeyPocket', 'Save to Folder', 'Omi Cloud (unofficial)']) {
        await openIntegration(tester, title);
        expectFreeIntegrationUi(title: title);
        final enabled = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
        expect(enabled.value, isTrue);
        expect(enabled.onChanged, isNotNull);
        if (title == 'Save to Folder') {
          expect(find.text('Change folder'), findsOneWidget);
          expect(find.text('Saved recordings'), findsOneWidget);
        }
        await backToIntegrations(tester);
      }
      final policy = AutomationPolicy(prefs);
      for (final connector in [hp, f, o]) {
        expect(policy.isEffective(connector), isFalse);
      }
      expectSavedConfiguration();
      await tester.pumpWidget(const SizedBox());
      ApplicationEntitlements.installLocalDevelopment(entitlements);
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      await tester.pumpAndSettle();
      await expectProConfiguration();
      expectSavedConfiguration();
      expect(AutomationPolicy(prefs).isEffective(hp), isTrue);
      expect(AutomationPolicy(prefs).isEffective(f), isTrue);
      expect(AutomationPolicy(prefs).isEffective(o), isTrue);
      await tester.pumpWidget(const SizedBox());
    }, client);
  });

  testWidgets('startup provider reaches both automation policy and integration controls', (tester) async {
    entitlements.isPro = true;
    ApplicationEntitlements.installLocalDevelopment(entitlements);
    addTearDown(() => ApplicationEntitlements.installLocalDevelopment(null));
    integrationViewport(tester);

    expect(AutomationPolicy(prefs).entitlements, same(entitlements));
    expect(SharingPolicy(prefs).automation.entitlements, same(entitlements));
    expect(const LocalEntitlementService().isPro, isFalse);
    await omi();
    prefs.omiAutoUpload = false;
    prefs.omiAutoUploadAt = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      await tester.pumpAndSettle();
      await openIntegration(tester, 'HeyPocket');
      final scope = tester.widget<DropdownButtonFormField<AutomaticRecordingScope>>(
          find.byType(DropdownButtonFormField<AutomaticRecordingScope>));
      expect(scope.onChanged, isNotNull);
      final wifi = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .singleWhere((switchTile) => switchTile.title is Text && (switchTile.title as Text).data == 'Wi-Fi only');
      expect(wifi.onChanged, isNotNull);
      expect(prefs.heypocketAutoUpload, isFalse, reason: 'A Pro provider never grants upload consent');
      expect(prefs.folderExportAutoUpload, isFalse);
      expect(prefs.omiAutoUpload, isFalse, reason: 'sign-in and Pro alone never grant Omi upload consent');
      await backToIntegrations(tester);
      await openIntegration(tester, 'Omi Cloud (unofficial)');
      expect(find.text('Omi Cloud (unofficial)'), findsOneWidget);
      final omiAuto = find.ancestor(of: find.text('Auto-Upload').first, matching: find.byType(SwitchListTile));
      expect(tester.widget<SwitchListTile>(omiAuto).onChanged, isNotNull);
      await tester.tap(omiAuto);
      await tester.pump();
      expect(prefs.omiAutoUpload, isTrue);
      expect(prefs.omiAutoUploadAt, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    }, client);
  });

  testWidgets('Pro HeyPocket rules, conditions, backfill and Folder Auto-Save remain usable', (tester) async {
    integrationViewport(tester);
    entitlements.isPro = true;
    ApplicationEntitlements.installLocalDevelopment(entitlements);
    addTearDown(() => ApplicationEntitlements.installLocalDevelopment(null));
    await heyPocket();
    prefs.heypocketAutoUpload = false;
    folder(FakeFolder());
    prefs.folderExportAutoUpload = false;
    FolderExportConnector.defaultBackend = FakeFolder();
    addTearDown(FolderExportConnector.resetForTest);
    final rules = AutomationSettings(prefs, 'heypocket');
    var previews = 0;
    final confirmed = <String>[];
    var stops = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: IntegrationsPage(
        onPreviewBackfill: (name) {
          expect(name, HeyPocketConnector.connectorName);
          previews++;
          return ['archive'];
        },
        onStartBackfill: (name, ids) {
          expect(name, HeyPocketConnector.connectorName);
          confirmed.addAll(ids);
          rules.backfillIds = ids;
          return ids.length;
        },
        onStopBackfill: (name) {
          expect(name, HeyPocketConnector.connectorName);
          stops++;
          rules.backfillIds = [];
        },
      )));
      await tester.pumpAndSettle();
      await openIntegration(tester, 'HeyPocket');
      final hpAuto = find.ancestor(of: find.text('Auto-Upload').last, matching: find.byType(SwitchListTile));
      await tester.ensureVisible(hpAuto);
      await tester.tap(hpAuto);
      await tester.pumpAndSettle();
      expect(prefs.heypocketAutoUpload, isTrue);
      final scope = find.byType(DropdownButtonFormField<AutomaticRecordingScope>);
      await tester.ensureVisible(scope);
      await tester.tap(scope);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marked recordings').last);
      await tester.pumpAndSettle();
      expect(rules.scope, AutomaticRecordingScope.marked);
      await tester.tap(scope);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Priority Recordings').last);
      await tester.pumpAndSettle();
      expect(rules.scope, AutomaticRecordingScope.priority);
      final minimum = find.byType(DropdownButtonFormField<int>);
      await tester.ensureVisible(minimum);
      await tester.tap(minimum);
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 seconds').last);
      await tester.pumpAndSettle();
      expect(rules.minimumSeconds, 60);
      await tester.tap(find.text('Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(rules.wifiOnly, isTrue);
      await tester.tap(find.text('Upload existing matching recordings'));
      await tester.pumpAndSettle();
      expect(previews, 1);
      expect(confirmed, isEmpty, reason: 'backfill waits for explicit confirmation');
      expect(find.text('Upload existing recordings?'), findsOneWidget);
      await tester.tap(find.text('Upload'));
      await tester.pumpAndSettle();
      expect(confirmed, ['archive']);
      expect(find.text('Stop backfill'), findsOneWidget);
      await tester.tap(find.text('Stop backfill'));
      await tester.pumpAndSettle();
      expect(stops, 1);
      expect(rules.backfillIds, isEmpty);
      await backToIntegrations(tester);
      await openIntegration(tester, 'Save to Folder');
      final autoSave = find.ancestor(of: find.text('Auto-Save'), matching: find.byType(SwitchListTile));
      await tester.ensureVisible(autoSave);
      await tester.tap(autoSave);
      await tester.pumpAndSettle();
      expect(prefs.folderExportAutoUpload, isTrue);
      expect(prefs.folderExportAutoUploadAt, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    }, client);
  });

  testWidgets('Free Omi UI hides automation but keeps manual integration controls usable', (tester) async {
    integrationViewport(tester);
    await omi();
    final cutoff = prefs.omiAutoUploadAt;
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: IntegrationsPage()));
      await tester.pumpAndSettle();
      await openIntegration(tester, 'Omi Cloud (unofficial)');
      expectFreeIntegrationUi(title: 'Omi Cloud (unofficial)');
      expect(find.text('Unofficial integration. May stop working without notice.'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      final omiEnabled = find.ancestor(of: find.text('Enabled').first, matching: find.byType(SwitchListTile));
      final toggle = tester.widget<SwitchListTile>(omiEnabled);
      expect(toggle.value, isTrue);
      expect(toggle.onChanged, isNotNull);
      await tester.tap(omiEnabled);
      await tester.pump();
      expect(prefs.omiEnabled, isFalse);
      expect(prefs.omiAutoUpload, isTrue);
      expect(prefs.omiAutoUploadAt, cutoff);
      await tester.pumpWidget(const SizedBox());
    }, client);
  });
}
