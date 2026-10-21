import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_api.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/pages/settings/integration_settings_page.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_entitlement_service.dart';
import '../pages/recordings/integration_upload_manager_test.dart' show FakeIntegration;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesUtil prefs;
  late Directory temp;
  late DateTime clock;
  var recordingIndex = 0;
  final secure = <String, String>{};
  Future<void> Function(String key, String value)? beforeWrite;
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() async {
    secure.clear();
    beforeWrite = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'write') {
        final key = args['key'] as String;
        final value = args['value'] as String;
        await beforeWrite?.call(key, value);
        secure[key] = value;
      }
      if (call.method == 'read') return secure[args['key'] as String];
      if (call.method == 'delete') secure.remove(args['key'] as String);
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    temp = Directory.systemTemp.createTempSync('credential-transition-');
    clock = DateTime(2026, 10, 4, 12);
    recordingIndex = 0;
    await prefs.setOmiRefreshToken('A-refresh');
    await prefs.setOmiFirebaseApiKey('A-key');
    prefs.omiEnabled = true;
    await prefs.setOmiIdToken('A-id');
    prefs.omiTokenExpiry = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    temp.deleteSync(recursive: true);
  });

  Conversation recording(String id, {int chunks = 1, DateTime? start}) {
    final at = start ?? clock.subtract(const Duration(days: 1));
    final c = Conversation(
      file: File('${temp.path}/recording_${at.millisecondsSinceEpoch + recordingIndex++}.wav')
        ..writeAsBytesSync(List.filled(100, 7)),
      startTime: at,
      duration: Duration(minutes: chunks * 3),
      uploadKey: id,
    );
    final frames = BytesBuilder();
    for (var i = 0; i < (chunks - 1) * 9000 + 1; i++) {
      frames.add([1, 0, 0, 0, 7]);
    }
    File(IntegrationRecording.fromConversation(c).opusFrameSidecarPath).writeAsBytesSync(frames.takeBytes());
    return c;
  }

  Batch batch(List<Conversation> recordings) => Batch(
      dateString: '2026-10-03', date: clock, rawSegments: [], draftRecordings: [], finalizedRecordings: recordings);

  IntegrationUploadManager engine(List<Connector> connectors, List<Conversation> recordings,
      {Future<bool> Function()? wifi, bool Function()? processing}) {
    final manager = IntegrationUploadManager(
      connectors: connectors,
      prefs: prefs,
      automation: AutomationPolicy(prefs, entitlements: TestEntitlementService(isPro: true)),
      batchesProvider: () => [batch(recordings)],
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
      convertToPassthrough: (_) async {},
      now: () => clock,
    );
    addTearDown(manager.dispose);
    return manager;
  }

  Future<void> until(bool Function() predicate) async {
    for (var i = 0; i < 100 && !predicate(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(predicate(), isTrue, reason: 'controlled operation should have reached its checkpoint');
  }

  Future<void> installB() async {
    await OmiApiClient.replaceCredentials(refreshToken: 'B-refresh', apiKey: 'B-key', idToken: 'B-id');
  }

  Future<HeyPocketConnector> heypocket({bool automatic = false}) async {
    await prefs.setHeypocketApiKey('pk_account_A');
    prefs.heypocketEnabled = true;
    if (automatic) {
      prefs.heypocketAutoUpload = true;
      prefs.heypocketKeySetAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    }
    return HeyPocketConnector(prefs);
  }

  Future<http.Response> success(http.Request request) async =>
      request.method == 'POST' && request.url.host == 'public.heypocketai.com'
          ? http.Response('{"data":{"upload_url":"https://upload.test/account-A"}}', 200)
          : http.Response('{"status":"completed"}', 200);

  test('replacement discards partial chunk and remote job state while retaining completed delivery', () async {
    await prefs.markOmiSynced('/recording_fs320_done.bin');
    await prefs.markOmiSegmentSynced('/recording_fs320_partial.bin#0');
    await prefs.setOmiSegmentTotal('/recording_fs320_partial.bin', 5);
    await prefs.setOmiSegmentJobId('/recording_fs320_partial.bin#1', 'A-job');
    final model = IntegrationSettingsModel(checkOmi: (_, __) async => true, confirmCredentialChange: (_) async => true);
    addTearDown(model.dispose);
    await model.acceptOmiLogin({'refreshToken': 'B-refresh', 'apiKey': 'B-key'});
    expect(prefs.isOmiSynced('/recording_fs320_done.bin'), isTrue);
    expect(prefs.omiSyncedSegments, isEmpty);
    expect(prefs.getOmiSegmentJobId('/recording_fs320_partial.bin#1'), isNull);
    expect(prefs.getOmiSegmentTotal('/recording_fs320_partial.bin'), 0);
  });

  test('a stale revision during storage cannot leave a mixed Omi credential pair', () async {
    var current = true;
    beforeWrite = (key, value) async {
      if (value.contains('B-refresh')) current = false;
    };
    await OmiApiClient.replaceCredentials(refreshToken: 'B-refresh', apiKey: 'B-key', isCurrent: () => current);
    expect(
      (prefs.omiRefreshToken, prefs.omiFirebaseApiKey),
      anyOf(('A-refresh', 'A-key'), ('B-refresh', 'B-key')),
    );
    await SharedPreferencesUtil.init();
    expect(
      (prefs.omiRefreshToken, prefs.omiFirebaseApiKey),
      anyOf(('A-refresh', 'A-key'), ('B-refresh', 'B-key')),
    );
  });

  test('completed Omi delivery survives replacement, skips discovery, and permits manual re-upload', () async {
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final connector = OmiCloudConnector(prefs);
    final c = recording('completed', chunks: 2);
    final r = IntegrationRecording.fromConversation(c);
    await prefs.markOmiSynced(r.opusFrameSidecarPath);
    final manager = engine([connector], [c]);
    expect(manager.hasPendingWorkFor(connector.name), isFalse);
    await manager.replaceCredentialsFor(connector.name, installB);
    final headers = <String?>[];
    await http.runWithClient(() async {
      manager.tryAutoUploadAll();
      expect(manager.activeUploadCountFor(connector.name), 0);
      expect(connector.hasDelivered(r), isTrue);
      await manager.uploadOne(c, connector.name, force: true);
      await until(() => manager.activeUploadCountFor(connector.name) == 0);
    },
        () => MockClient((request) async {
              headers.add(request.headers['Authorization']);
              return success(request);
            }));
    expect(headers, ['Bearer B-id', 'Bearer B-id']);
    expect(connector.hasDelivered(r), isTrue);
  });

  test('active Omi chunk settles against A; explicit upload after replacement starts every chunk against B', () async {
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final connector = OmiCloudConnector(prefs);
    final c = recording('partial', chunks: 3);
    final r = IntegrationRecording.fromConversation(c);
    final manager = engine([connector], [c]);
    final entered = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final requests = <(String?, String)>[];
    await http.runWithClient(() async {
      manager.tryAutoUploadAll();
      await entered.future;
      final switching = manager.replaceCredentialsFor(connector.name, installB);
      expect(manager.isChangingCredentials(connector.name), isTrue);
      expect(prefs.omiRefreshToken, 'A-refresh');
      manager.tryAutoUploadAll();
      manager.pumpAllLanes();
      expect(await manager.uploadOne(c, connector.name), isNotEmpty);
      firstResponse.complete(http.Response('{"status":"completed"}', 200));
      await switching;
      expect(requests, hasLength(1));
      expect(requests.single.$1, 'Bearer A-id');
      expect(prefs.omiSyncedSegments, isEmpty);
      expect(prefs.getOmiSegmentTotal(r.opusFrameSidecarPath), 0);
      expect(connector.hasDelivered(r), isFalse);
      manager.tryAutoUploadAll();
      expect(manager.activeUploadCountFor(connector.name), 0);
      // A restarted manager must not rediscover A's cancelled automatic recording.
      engine([connector], [c]).tryAutoUploadAll();
      expect(requests, hasLength(1));
      await manager.uploadOne(c, connector.name);
      await until(() => manager.activeUploadCountFor(connector.name) == 0);
      expect(requests.skip(1).map((e) => e.$1), everyElement('Bearer B-id'));
      expect(requests, hasLength(4));
      expect(requests[1].$2, requests[0].$2, reason: 'B starts with chunk zero, not the tail');
      final timestamps = requests.skip(1).map((e) => int.parse(e.$2.split('_').last.split('.').first)).toList();
      expect(timestamps[1] - timestamps[0], 180);
      expect(timestamps[2] - timestamps[1], 180);
      expect(connector.hasDelivered(r), isTrue);
    },
        () => MockClient((request) async {
              final filename = RegExp('filename="([^"]+)"').firstMatch(request.body)!.group(1)!;
              requests.add((request.headers['Authorization'], filename));
              if (requests.length == 1) {
                entered.complete();
                return firstResponse.future;
              }
              return success(request);
            }));
  });

  test('saved A remote jobs are discarded before B can upload', () async {
    final connector = OmiCloudConnector(prefs);
    final c = recording('job', chunks: 2);
    final path = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    await prefs.markOmiSegmentSynced('$path#0');
    await prefs.setOmiSegmentJobId('$path#1', 'A-remote-job');
    final manager = engine([connector], []); // persisted state outside the archive snapshot
    expect(manager.hasPendingWorkFor(connector.name), isTrue);
    await manager.replaceCredentialsFor(connector.name, installB);
    expect(prefs.getOmiSegmentJobId('$path#1'), isNull);
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await manager.uploadOne(c, connector.name);
      await until(() => manager.activeUploadCountFor(connector.name) == 0);
    },
        () => MockClient((request) async {
              requests.add(request);
              return success(request);
            }));
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.method == 'POST' && r.headers['Authorization'] == 'Bearer B-id'), isTrue);
    expect(requests.any((r) => r.url.path.contains('A-remote-job')), isFalse);
  });

  test('replacement during an A job poll never reattaches that job with B', () async {
    final connector = OmiCloudConnector(prefs);
    final c = recording('poll', chunks: 2);
    final path = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    await prefs.setOmiSegmentJobId('$path#0', 'A-poll-job');
    final manager = engine([connector], [c]);
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await manager.uploadOne(c, connector.name);
      await entered.future;
      final switching = manager.replaceCredentialsFor(connector.name, installB);
      response.complete(http.Response('{"status":"queued","poll_after_ms":30000}', 200));
      await switching;
      manager.pumpAllLanes();
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.headers['Authorization'], 'Bearer A-id');
      expect(prefs.getOmiSegmentJobId('$path#0'), isNull);
      expect(prefs.omiSyncedSegments, isEmpty);
    },
        () => MockClient((request) async {
              requests.add(request);
              entered.complete();
              return response.future;
            }));
  });

  test('Omi replacement clears saved backoff/retries and preserves HeyPocket and Folder retries', () async {
    final connector = OmiCloudConnector(prefs);
    final c = recording('backoff');
    final path = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    await prefs.incrementAutoUploadRetry(path);
    await prefs.setAutoUploadLastFailureAt(path);
    await prefs.incrementAutoUploadRetry('hp-recording');
    await prefs.setAutoUploadLastFailureAt('hp-recording');
    await prefs.incrementAutoUploadRetry('folder_recording');
    await prefs.setOmiBackoffUntil(path, clock.add(const Duration(minutes: 5)).millisecondsSinceEpoch);
    await prefs.incrementOmiBusyStreak(path);
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final manager = engine([connector], [c]);
    manager.tryAutoUploadAll();
    await manager.replaceCredentialsFor(connector.name, installB);
    expect(prefs.getAutoUploadRetries(path), 0);
    expect(prefs.getAutoUploadLastFailureAt(path), 0);
    expect(prefs.getOmiBackoffUntil(path), 0);
    expect(prefs.getOmiBusyStreak(path), 0);
    expect(prefs.getAutoUploadRetries('hp-recording'), 1);
    expect(prefs.getAutoUploadLastFailureAt('hp-recording'), greaterThan(0));
    expect(prefs.getAutoUploadRetries('folder_recording'), 1);
    clock = clock.add(const Duration(hours: 1));
    expect(manager.retrySweepReady, isFalse);
    manager.tryAutoUploadAll();
    manager.pumpAllLanes();
    expect(manager.activeUploadCountFor(connector.name), 0);
  });

  test('HeyPocket active two-step upload finishes A; queued manual upload never inherits B', () async {
    final connector = await heypocket();
    final x = recording('hp-active');
    final y = recording('hp-queued');
    final manager = engine([connector], [x, y]);
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await manager.uploadOne(x, connector.name);
      await entered.future;
      await manager.uploadOne(y, connector.name);
      expect(manager.activeUploadCountFor(connector.name), 2);
      final switching = manager.replaceCredentialsFor(connector.name, () => prefs.setHeypocketApiKey('pk_account_B'));
      expect(prefs.heypocketApiKey, 'pk_account_A');
      response.complete(await success(requests.first));
      await switching;
      manager.pumpAllLanes();
      expect(requests.map((r) => r.method), ['POST', 'PUT']);
      expect(requests.first.headers['Authorization'], 'Bearer pk_account_A');
      expect(prefs.isUploadedToHeypocket(x.uploadKey!), isTrue);
      expect(prefs.isUploadedToHeypocket(y.uploadKey!), isFalse);
      expect(manager.activeUploadCountFor(connector.name), 0);
      await manager.uploadOne(y, connector.name);
      await until(() => manager.activeUploadCountFor(connector.name) == 0);
      expect(requests[2].headers['Authorization'], 'Bearer pk_account_B');
    },
        () => MockClient((request) async {
              requests.add(request);
              if (requests.length == 1) {
                entered.complete();
                return response.future;
              }
              return success(request);
            }));
  });

  test('unfinished confirmed backfill is withdrawn, persists across restart, and requires new confirmation', () async {
    final connector = await heypocket(automatic: true);
    final recordings = [recording('X'), recording('Y'), recording('Z')];
    final rules = AutomationSettings(prefs, 'heypocket')..wifiOnly = true;
    var onWifi = true;
    final manager = engine([connector], recordings, wifi: () async => onWifi);
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      expect(manager.startBackfill(connector.name, ['X', 'Y', 'Z']), 3);
      await until(() => prefs.isUploadedToHeypocket('X'));
      await until(() => manager.activeUploadCountFor(connector.name) == 2);
      final staleGrant = manager.sharingPolicy.authorizeUnattended(
          connector, manager.sharingPolicy.propose(connector, IntegrationRecording.fromConversation(recordings[1])))!;
      await manager.replaceCredentialsFor(connector.name, () => prefs.setHeypocketApiKey('pk_account_B'));
      expect(rules.backfillIds, isEmpty);
      expect(prefs.isUploadedToHeypocket('X'), isTrue);
      expect(prefs.isUploadedToHeypocket('Y'), isFalse);
      expect(prefs.isUploadedToHeypocket('Z'), isFalse);
      expect(manager.sharingPolicy.isStillAuthorized(connector, staleGrant), isFalse);
      onWifi = true;
      final restarted = engine([connector], recordings);
      restarted.tryAutoUploadAll();
      restarted.pumpAllLanes();
      expect(restarted.activeUploadCountFor(connector.name), 0);
      expect(requests, hasLength(2));
      expect(restarted.startBackfill(connector.name, ['Y', 'Z']), 2);
      await until(() => prefs.isUploadedToHeypocket('Z'));
      expect(requests.where((r) => r.method == 'POST').skip(1).map((r) => r.headers['Authorization']),
          everyElement('Bearer pk_account_B'));
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.method == 'PUT') onWifi = false;
              return success(request);
            }));
  });

  test('cancelled future-dated recordings cannot regain automatic authorization after clock correction', () async {
    final connector = await heypocket(automatic: true);
    final c = recording('future-dated', start: clock.add(const Duration(days: 1)));
    final manager = engine([connector], [c], wifi: () async => false);
    AutomationSettings(prefs, 'heypocket').wifiOnly = true;
    manager.tryAutoUploadAll();
    await until(() => manager.activeUploadCountFor(connector.name) == 1);
    await manager.replaceCredentialsFor(connector.name, () => prefs.setHeypocketApiKey('pk_account_B'));
    final restarted = engine([connector], [c]);
    restarted.tryAutoUploadAll();
    expect(restarted.activeUploadCountFor(connector.name), 0);
    // New recordings retain the saved opt-in and rules.
    final fresh = recording('fresh', start: clock.add(const Duration(seconds: 1)));
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      final newManager = engine([connector], [fresh]);
      newManager.tryAutoUploadAll();
      await until(() => prefs.isUploadedToHeypocket('fresh'));
    },
        () => MockClient((request) async {
              requests.add(request);
              return success(request);
            }));
    expect(requests.first.headers['Authorization'], 'Bearer pk_account_B');
  });

  test('ordinary Omi token refresh rotates a coherent pair without clearing any delivery or retry state', () async {
    final c = recording('refresh');
    final path = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    await prefs.markOmiSegmentSynced('$path#0');
    await prefs.setOmiSegmentJobId('$path#1', 'A-job');
    await prefs.incrementAutoUploadRetry(path);
    await prefs.incrementAutoUploadRetry('hp-recording');
    prefs.omiTokenExpiry = 0;
    final generation = OmiApiClient.credentialGeneration;
    await http.runWithClient(
        OmiApiClient.refreshTokenIfNeeded,
        () => MockClient((_) async =>
            http.Response('{"id_token":"rotated-A-id","refresh_token":"rotated-A-refresh","expires_in":"3600"}', 200)));
    expect(OmiApiClient.credentialGeneration, generation);
    expect(prefs.omiRefreshToken, 'rotated-A-refresh');
    expect(prefs.omiFirebaseApiKey, 'A-key');
    expect(prefs.getOmiSegmentJobId('$path#1'), 'A-job');
    expect(prefs.isOmiSegmentSynced('$path#0'), isTrue);
    expect(prefs.getAutoUploadRetries(path), 1);
    expect(prefs.getAutoUploadRetries('hp-recording'), 1);
    expect(prefs.getString('sharingCredentialBoundaries'), isEmpty);
  });

  test('HeyPocket replacement clears only its retries, not Omi or Folder state', () async {
    final connector = await heypocket();
    await prefs.incrementAutoUploadRetry('hp-recording');
    await prefs.setAutoUploadLastFailureAt('hp-recording');
    await prefs.incrementAutoUploadRetry('/recording_fs320_A.bin');
    await prefs.incrementAutoUploadRetry('folder_recording');
    await prefs.setOmiSegmentJobId('/recording_fs320_A.bin#0', 'A-job');
    await engine([connector], []).replaceCredentialsFor(connector.name, () => prefs.setHeypocketApiKey('pk_account_B'));
    expect(prefs.getAutoUploadRetries('hp-recording'), 0);
    expect(prefs.getAutoUploadLastFailureAt('hp-recording'), 0);
    expect(prefs.getAutoUploadRetries('/recording_fs320_A.bin'), 1);
    expect(prefs.getAutoUploadRetries('folder_recording'), 1);
    expect(prefs.getOmiSegmentJobId('/recording_fs320_A.bin#0'), 'A-job');
  });

  test('a failed Omi secure write preserves the coherent saved pair and expires the old cached token', () async {
    beforeWrite = (_, value) async {
      if (value.contains('B-refresh')) throw PlatformException(code: 'storage-unavailable');
    };
    await expectLater(installB(), throwsA(isA<PlatformException>()));
    expect((prefs.omiRefreshToken, prefs.omiFirebaseApiKey), ('A-refresh', 'A-key'));
    expect(prefs.omiTokenExpiry, 0);
    expect(await prefs.omiIdToken, isEmpty);
    await SharedPreferencesUtil.init();
    expect((prefs.omiRefreshToken, prefs.omiFirebaseApiKey), ('A-refresh', 'A-key'));
  });

  test('Omi stays unconfigured while its atomic credential bundle is being written', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeWrite = (_, value) async {
      if (value.contains('B-refresh')) {
        entered.complete();
        await release.future;
      }
    };
    final saving = installB();
    await entered.future;
    expect(OmiCloudConnector(prefs).isConfigured, isFalse);
    expect((prefs.omiRefreshToken, prefs.omiFirebaseApiKey), ('A-refresh', 'A-key'));
    release.complete();
    await saving;
    expect(OmiCloudConnector(prefs).isConfigured, isTrue);
    expect((prefs.omiRefreshToken, prefs.omiFirebaseApiKey), ('B-refresh', 'B-key'));
  });

  test('legacy Omi credentials migrate to one secure bundle, and a damaged bundle fails closed', () async {
    secure
      ..remove('omiCredentials')
      ..['omiRefreshToken'] = 'legacy-refresh'
      ..['omiFirebaseApiKey'] = 'legacy-key';
    await SharedPreferencesUtil.init();
    expect((prefs.omiRefreshToken, prefs.omiFirebaseApiKey), ('legacy-refresh', 'legacy-key'));
    expect(jsonDecode(secure['omiCredentials']!), {'refreshToken': 'legacy-refresh', 'apiKey': 'legacy-key'});
    expect(secure.containsKey('omiRefreshToken'), isFalse);
    expect(secure.containsKey('omiFirebaseApiKey'), isFalse);
    secure['omiCredentials'] = '{broken';
    secure['omiRefreshToken'] = 'obsolete-A-refresh';
    await SharedPreferencesUtil.init();
    expect(prefs.omiRefreshToken, isEmpty);
    expect(prefs.omiFirebaseApiKey, isEmpty);
    expect(OmiCloudConnector(prefs).isConfigured, isFalse);
  });

  test('Omi cannot appear configured with only a refresh token', () async {
    await prefs.setOmiCredentials(refreshToken: 'A-refresh', apiKey: '');
    expect(OmiCloudConnector(prefs).isConfigured, isFalse);
    expect(OmiApiClient.isSignedIn, isFalse);
  });

  test('no pending work replaces credentials without requesting confirmation', () async {
    var confirmations = 0;
    final connector = OmiCloudConnector(prefs);
    final manager = engine([connector], []);
    final model = IntegrationSettingsModel(
      uploads: manager,
      checkOmi: (_, __) async => true,
      confirmCredentialChange: (_) async {
        confirmations++;
        return false;
      },
    );
    addTearDown(model.dispose);
    await model.acceptOmiLogin({'refreshToken': 'B-refresh', 'apiKey': 'B-key', 'idToken': 'B-id'});
    expect(confirmations, 0);
    expect(prefs.omiRefreshToken, 'B-refresh');
    expect(model.connection(IntegrationId.omiCloud), IntegrationConnectionState.connected);
  });

  test('first configuration preserves the pre-existing automatic opt-in for recordings awaiting sign-in', () async {
    await OmiApiClient.signOut();
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final c = recording('first-login');
    final connector = OmiCloudConnector(prefs);
    final manager = engine([connector], [c]);
    final model = IntegrationSettingsModel(uploads: manager, checkOmi: (_, __) async => true);
    addTearDown(model.dispose);
    await model.acceptOmiLogin({'refreshToken': 'B-refresh', 'apiKey': 'B-key', 'idToken': 'B-id'});
    await http.runWithClient(() async {
      manager.tryAutoUploadAll();
      await until(() => connector.hasDelivered(IntegrationRecording.fromConversation(c)));
    }, () => MockClient(success));
  });

  testWidgets('Cancel in the account warning leaves credentials, manual queue, and automation unchanged',
      (tester) async {
    await heypocket(automatic: true);
    final connector = FakeIntegration(HeyPocketConnector.connectorName);
    final x = recording('cancel-active');
    final y = recording('cancel-queued');
    final gate = Completer<void>();
    connector.onUpload = (r) async {
      await gate.future;
      connector.deliver(r);
    };
    final manager = engine([connector], [x, y]);
    final model = IntegrationSettingsModel(uploads: manager, checkHeyPocket: (_) async => true)..start();
    addTearDown(model.dispose);
    final cutoff = prefs.heypocketKeySetAt;
    final rules = AutomationSettings(prefs, 'heypocket')..backfillIds = ['cancel-queued'];
    await manager.uploadOne(x, connector.name);
    await manager.uploadOne(y, connector.name);
    await tester.pumpWidget(MaterialApp(home: IntegrationSettingsPage(id: IntegrationId.heypocket, model: model)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'pk_account_B');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Change account?'), findsOneWidget);
    expect(prefs.heypocketApiKey, 'pk_account_A');
    expect(manager.activeUploadCountFor(connector.name), 2);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.heypocketApiKey, 'pk_account_A');
    expect(manager.activeUploadCountFor(connector.name), 2);
    expect(connector.lastIsCancelled!(), isFalse);
    expect(prefs.heypocketAutoUpload, isTrue);
    expect(prefs.heypocketKeySetAt, cutoff);
    expect(rules.backfillIds, ['cancel-queued']);
    expect(prefs.getString('sharingCredentialBoundaries'), isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(connector.uploadCalls, hasLength(2));
    expect(connector.hasDelivered(IntegrationRecording.fromConversation(y)), isTrue);
  });

  testWidgets('accepted account warning freezes the lane before storage and presents B only after settlement',
      (tester) async {
    await heypocket();
    final connector = FakeIntegration(HeyPocketConnector.connectorName);
    final x = recording('accept-active');
    final y = recording('accept-queued');
    final gate = Completer<void>();
    connector.onUpload = (_) => gate.future;
    final manager = engine([connector], [x, y]);
    final model = IntegrationSettingsModel(uploads: manager, checkHeyPocket: (_) async => true)..start();
    addTearDown(model.dispose);
    await manager.uploadOne(x, connector.name);
    await manager.uploadOne(y, connector.name);
    await tester.pumpWidget(MaterialApp(home: IntegrationSettingsPage(id: IntegrationId.heypocket, model: model)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'pk_account_B');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Change Account'));
    await tester.pump();
    expect(manager.isChangingCredentials(connector.name), isTrue);
    expect(connector.lastIsCancelled!(), isTrue);
    expect(manager.activeUploadCountFor(connector.name), 1);
    expect(prefs.heypocketApiKey, 'pk_account_A');
    expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.checking);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    gate.complete();
    await tester.pumpAndSettle();
    expect(prefs.heypocketApiKey, 'pk_account_B');
    expect(connector.uploadCalls, hasLength(1));
    expect(manager.activeUploadCountFor(connector.name), 0);
    expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.connected);
  });

  test('transition cancels a paused lane resume timer and invalidates previously minted manual grants', () async {
    final connector = FakeIntegration('Cloud');
    final c = recording('paused');
    final manager = engine([connector], [c]);
    final oldGrant = manager.sharingPolicy
        .approveUserRequest(manager.sharingPolicy.propose(connector, IntegrationRecording.fromConversation(c)));
    connector.onUpload = (r) async => connector.backOff(r);
    fakeAsync((async) {
      manager.uploadOne(c, connector.name);
      async.flushMicrotasks();
      expect(connector.uploadCalls, hasLength(1));
      var installed = false;
      manager.replaceCredentialsFor(connector.name, () async {
        installed = true;
      });
      async.flushMicrotasks();
      expect(installed, isTrue);
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(connector.uploadCalls, hasLength(1));
      expect(manager.activeUploadCountFor(connector.name), 0);
    });
    expect(manager.sharingPolicy.isStillAuthorized(connector, oldGrant), isFalse);
    final freshGrant = manager.sharingPolicy
        .approveUserRequest(manager.sharingPolicy.propose(connector, IntegrationRecording.fromConversation(c)));
    expect(manager.sharingPolicy.isStillAuthorized(connector, freshGrant), isTrue);
  });

  test('shutdown during active settlement never installs replacement credentials', () async {
    final connector = FakeIntegration('Cloud');
    final c = recording('shutdown');
    final gate = Completer<void>();
    connector.onUpload = (_) => gate.future;
    final manager = engine([connector], [c]);
    await manager.uploadOne(c, connector.name);
    var installed = false;
    final switching = manager.replaceCredentialsFor(connector.name, () async {
      installed = true;
    });
    final failure = expectLater(switching, throwsStateError);
    manager.dispose();
    gate.complete();
    await failure;
    expect(installed, isFalse);
  });

  test('overlapping replacement and disconnect serialize without releasing the lane between them', () async {
    final connector = OmiCloudConnector(prefs);
    final manager = engine([connector], []);
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeWrite = (_, value) async {
      if (value.contains('B-refresh')) {
        entered.complete();
        await release.future;
      }
    };
    final first = manager.replaceCredentialsFor(connector.name, installB);
    await entered.future;
    final second = manager.replaceCredentialsFor(connector.name, OmiApiClient.signOut);
    expect(manager.isChangingCredentials(connector.name), isTrue);
    release.complete();
    await first;
    expect(manager.isChangingCredentials(connector.name), isTrue);
    await second;
    expect(prefs.omiRefreshToken, isEmpty);
    expect(prefs.omiFirebaseApiKey, isEmpty);
    expect(manager.isChangingCredentials(connector.name), isFalse);
  });

  test('discovery and connectivity during credential transition cannot recreate cancelled automation', () async {
    final connector = await heypocket(automatic: true);
    final c = recording('discovery-race');
    final changes = ValueNotifier(0);
    final connectivity = StreamController<Object?>.broadcast();
    addTearDown(changes.dispose);
    addTearDown(connectivity.close);
    final loadEntered = Completer<void>();
    final loadRelease = Completer<void>();
    final coordinator = IntegrationCoordinator(
      connectors: [connector],
      prefs: prefs,
      automation: AutomationPolicy(prefs, entitlements: TestEntitlementService(isPro: true)),
      loadRecordings: () async {
        if (!loadEntered.isCompleted) loadEntered.complete();
        await loadRelease.future;
        return IntegrationSnapshot([
          batch([c])
        ], []);
      },
      recordingChanges: changes,
      isProcessing: () => false,
      isPipelineIdle: () => true,
      checkOnWifi: () async => true,
      connectivityChanges: connectivity.stream,
      pollInterval: const Duration(milliseconds: 10),
      now: () => clock,
    );
    addTearDown(coordinator.dispose);
    final started = coordinator.start();
    await loadEntered.future;
    final storageEntered = Completer<void>();
    final storageRelease = Completer<void>();
    final switching = coordinator.uploads.replaceCredentialsFor(connector.name, () async {
      storageEntered.complete();
      await storageRelease.future;
      await prefs.setHeypocketApiKey('pk_account_B');
    });
    await storageEntered.future;
    loadRelease.complete();
    connectivity.add(null);
    await started;
    expect(coordinator.uploads.activeUploadCountFor(connector.name), 0);
    storageRelease.complete();
    await switching;
    connectivity.add(null);
    changes.value++;
    await coordinator.recordingsChanged();
    expect(coordinator.uploads.activeUploadCountFor(connector.name), 0);
    expect(prefs.isUploadedToHeypocket(c.uploadKey!), isFalse);
  });

  test('HeyPocket upload-time 403 rejects credentials just like connection validation', () async {
    final connector = await heypocket();
    final c = recording('forbidden');
    final policy = SharingPolicy(prefs);
    final grant = policy.approveUserRequest(policy.propose(connector, IntegrationRecording.fromConversation(c)));
    await http.runWithClient(() async {
      await expectLater(connector.send(grant),
          throwsA(isA<HeyPocketException>().having((e) => e.statusCode, 'credential rejection', 403)));
      expect(prefs.heypocketEnabled, isFalse);
    }, () => MockClient((_) async => http.Response('{}', 403)));
  });

  test('replacement during upload-time token refresh waits for A and sends no follow-up chunk', () async {
    prefs.omiTokenExpiry = 0;
    final connector = OmiCloudConnector(prefs);
    final c = recording('refresh-race', chunks: 2);
    final manager = engine([connector], [c]);
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await manager.uploadOne(c, connector.name);
      await entered.future;
      final switching = manager.replaceCredentialsFor(connector.name, installB);
      expect(prefs.omiRefreshToken, 'A-refresh');
      response.complete(http.Response('{"id_token":"refreshed-A-id","expires_in":"3600"}', 200));
      await switching;
      expect(requests, hasLength(1));
      expect(requests.single.url.host, 'securetoken.googleapis.com');
      expect(requests.single.body, contains('A-refresh'));
      expect(await prefs.omiIdToken, 'B-id');
      expect(connector.hasDelivered(IntegrationRecording.fromConversation(c)), isFalse);
      expect(prefs.omiSyncedSegments, isEmpty);
    },
        () => MockClient((request) async {
              requests.add(request);
              entered.complete();
              return response.future;
            }));
  });

  test('an A speech-profile response cannot overwrite B account metadata', () async {
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(() async {
      final checking = OmiApiClient.refreshSpeechProfileStatus();
      await entered.future;
      await installB();
      response.complete(http.Response('{"has_profile":true}', 200));
      expect(await checking, isNull);
      expect(prefs.omiHasSpeechProfile, isFalse);
      expect(prefs.omiSpeechProfileCheckedAtMs, 0);
    },
        () => MockClient((request) async {
              expect(request.headers['Authorization'], 'Bearer A-id');
              entered.complete();
              return response.future;
            }));
  });

  test('a failed credential transition releases the lane and still permits fresh manual work', () async {
    final connector = FakeIntegration('Cloud');
    final c = recording('failed-transition');
    final manager = engine([connector], [c]);
    await expectLater(
        manager.replaceCredentialsFor(connector.name, () async {
          throw StateError('storage failed');
        }),
        throwsStateError);
    expect(manager.isChangingCredentials(connector.name), isFalse);
    await manager.uploadOne(c, connector.name);
    await until(() => manager.activeUploadCountFor(connector.name) == 0);
    expect(connector.hasDelivered(IntegrationRecording.fromConversation(c)), isTrue);
  });

  test('persisted absent Omi work remains suppressed after a re-file even with a future date', () async {
    final connector = OmiCloudConnector(prefs);
    final c = recording('absent-source', start: clock.add(const Duration(days: 1)));
    final path = IntegrationRecording.fromConversation(c).opusFrameSidecarPath;
    await prefs.setOmiSegmentJobId('$path#0', 'A-absent-job');
    final manager = engine([connector], []);
    await manager.replaceCredentialsFor(connector.name, installB);
    final toPath = '${temp.path}/recording_1791300000000.wav';
    await connector.onRecordingMoved(RecordingMove(c.file.path, toPath));
    final to = Conversation(
        file: File(toPath)..writeAsBytesSync([7]),
        startTime: clock.add(const Duration(days: 2)),
        duration: c.duration,
        uploadKey: c.uploadKey);
    File(IntegrationRecording.fromConversation(to).opusFrameSidecarPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.millisecondsSinceEpoch;
    final restarted = engine([connector], [to]);
    restarted.tryAutoUploadAll();
    expect(restarted.activeUploadCountFor(connector.name), 0);
    expect(prefs.getOmiSegmentJobId('$path#0'), isNull);
  });

  testWidgets('incomplete or rejected credential drafts preserve the saved account and pending work', (tester) async {
    await heypocket();
    var cancellations = 0;
    final model = IntegrationSettingsModel(
        checkHeyPocket: (key) async => key == 'pk_account_A',
        checkOmi: (_, __) async => true,
        onCancelUploads: (_, {autoOnly = false}) {
          cancellations++;
        })
      ..start();
    addTearDown(model.dispose);
    await tester.pumpAndSettle();
    model.heypocketController.clear();
    model.omiRefreshTokenController.clear();
    await tester.pump();
    expect(prefs.heypocketApiKey, 'pk_account_A');
    expect(prefs.omiRefreshToken, 'A-refresh');
    expect(prefs.heypocketEnabled, isTrue);
    expect(prefs.omiEnabled, isTrue);
    model.heypocketController.text = 'pk_rejected_candidate';
    await tester.pump(const Duration(milliseconds: 900));
    expect(prefs.heypocketApiKey, 'pk_account_A');
    expect(prefs.heypocketEnabled, isTrue);
    expect(cancellations, 0);
  });

  test('delayed same-account token rotation preserves configured state and automatic grants', () async {
    prefs.omiAutoUpload = true;
    prefs.omiAutoUploadAt = clock.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    prefs.omiTokenExpiry = 0;
    final connector = OmiCloudConnector(prefs);
    final c = recording('rotating');
    final policy =
        SharingPolicy(prefs, automation: AutomationPolicy(prefs, entitlements: TestEntitlementService(isPro: true)));
    final grant =
        policy.authorizeUnattended(connector, policy.propose(connector, IntegrationRecording.fromConversation(c)))!;
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeWrite = (_, value) async {
      if (value.contains('rotated-A-refresh')) {
        entered.complete();
        await release.future;
      }
    };
    final generation = OmiApiClient.credentialGeneration;
    await http.runWithClient(() async {
      final refreshing = OmiApiClient.refreshTokenIfNeeded();
      await entered.future;
      expect(connector.isConfigured, isTrue);
      expect(policy.isStillAuthorized(connector, grant), isTrue);
      expect(OmiApiClient.credentialGeneration, generation);
      release.complete();
      await refreshing;
      expect(connector.isConfigured, isTrue);
      expect(policy.isStillAuthorized(connector, grant), isTrue);
    },
        () => MockClient((_) async =>
            http.Response('{"id_token":"rotated-A-id","refresh_token":"rotated-A-refresh","expires_in":"3600"}', 200)));
  });
}
