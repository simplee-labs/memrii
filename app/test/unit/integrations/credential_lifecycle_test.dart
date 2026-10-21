import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesUtil prefs;
  late Directory temp;
  final secure = <String, String>{};

  setUp(() async {
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
    temp = Directory.systemTemp.createTempSync('memrii-credential-test-');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
    temp.deleteSync(recursive: true);
  });

  Future<OmiCloudConnector> omi({bool expired = false}) async {
    prefs.omiEnabled = true;
    await prefs.setOmiRefreshToken('account-a-refresh');
    await prefs.setOmiFirebaseApiKey('api-key');
    await prefs.setOmiIdToken('account-a-id');
    prefs.omiTokenExpiry = expired ? 0 : DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    return OmiCloudConnector(prefs);
  }

  AuthorizedUpload upload(OmiCloudConnector connector) {
    final c = Conversation(
      file: File('${temp.path}/recording_test.wav')..writeAsBytesSync(List.filled(100, 7)),
      startTime: DateTime.now().subtract(const Duration(minutes: 5)),
      duration: const Duration(minutes: 2),
      uploadKey: 'credential-test',
    );
    final r = IntegrationRecording.fromConversation(c);
    File(r.opusFrameSidecarPath).writeAsBytesSync([1, 0, 0, 0, 7]);
    final policy = SharingPolicy(prefs);
    return policy.approveUserRequest(policy.propose(connector, r));
  }

  for (final status in [429, 500, 503]) {
    test('Omi upload-time refresh HTTP $status preserves the enabled connection', () async {
      final connector = await omi(expired: true);
      final grant = upload(connector);
      await http.runWithClient(() async {
        await expectLater(connector.send(grant),
            throwsA(isA<OmiSyncException>().having((e) => e.isAuthError, 'credential rejection', isFalse)));
        expect(prefs.omiEnabled, isTrue);
        expect(connector.wantsOpusFrameSidecar, isTrue);
        expect(prefs.omiRefreshToken, 'account-a-refresh');
      }, () => MockClient((_) async => http.Response('{}', status)));
    });

    test('HeyPocket settings and app-open HTTP $status preserve the saved connection', () async {
      await prefs.setHeypocketApiKey('pk_account_a');
      prefs.heypocketEnabled = true;
      final cancelled = <String>[];
      final model = IntegrationSettingsModel(onCancelUploads: (name, {autoOnly = false}) => cancelled.add(name));
      addTearDown(model.dispose);
      await http.runWithClient(() async {
        await model.recheck(IntegrationId.heypocket);
        await HeyPocketConnector(prefs).onAppOpened();
        expect(prefs.heypocketEnabled, isTrue);
        expect(prefs.heypocketApiKey, 'pk_account_a');
        expect(cancelled, isEmpty);
      }, () => MockClient((_) async => http.Response('{}', status)));
    });
  }

  for (final response in [
    http.Response('{}', 401),
    http.Response('{"error":{"message":"INVALID_REFRESH_TOKEN"}}', 400),
  ]) {
    test('confirmed Omi upload-time rejection HTTP ${response.statusCode} still disables the connection', () async {
      final connector = await omi(expired: true);
      final grant = upload(connector);
      await http.runWithClient(() async {
        await expectLater(connector.send(grant),
            throwsA(isA<OmiSyncException>().having((e) => e.isAuthError, 'credential rejection', isTrue)));
        expect(prefs.omiEnabled, isFalse);
      }, () => MockClient((_) async => response));
    });
  }

  for (final response in [
    http.Response('{}', 401),
    for (final code in [
      'INVALID_REFRESH_TOKEN',
      'USER_DISABLED',
      'TOKEN_EXPIRED',
      'PROJECT_NUMBER_MISMATCH',
      'API_KEY_INVALID'
    ])
      http.Response(
          jsonEncode({
            'error': {'message': code}
          }),
          400),
  ]) {
    test('Omi startup confirmed rejection ${response.body} disables saved credentials', () async {
      final connector = await omi(expired: true);
      await http.runWithClient(() => connector.onServicesStarted(), () => MockClient((_) async => response));
      expect(prefs.omiEnabled, isFalse);
      expect(connector.isConfigured, isFalse);
      expect(prefs.omiRefreshToken, 'account-a-refresh');
      expect(prefs.omiFirebaseApiKey, 'api-key');
    });
  }

  for (final status in [429, 500, 503, 400]) {
    test('Omi startup temporary/unrecognized HTTP $status retains connection', () async {
      final connector = await omi(expired: true);
      await http.runWithClient(() => connector.onServicesStarted(),
          () => MockClient((_) async => http.Response('{"error":{"message":"TEMPORARY_FAILURE"}}', status)));
      expect(prefs.omiEnabled, isTrue);
      expect(connector.isConfigured, isTrue);
    });
  }

  for (final error in [
    const SocketException('offline'),
    TimeoutException('timeout'),
    http.ClientException('unavailable')
  ]) {
    test('Omi startup ${error.runtimeType} preserves connection', () async {
      final connector = await omi(expired: true);
      await http.runWithClient(() => connector.onServicesStarted(), () => MockClient((_) async => throw error));
      expect(connector.isConfigured, isTrue);
    });
  }

  test('delayed startup A rejection cannot disable installed account B', () async {
    final connector = await omi(expired: true);
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    await http.runWithClient(() async {
      final startup = connector.onServicesStarted();
      await entered.future;
      await OmiApiClient.replaceCredentials(refreshToken: 'account-b-refresh', apiKey: 'api-b');
      response.complete(http.Response('{}', 401));
      await startup;
      expect(prefs.omiRefreshToken, 'account-b-refresh');
      expect(prefs.omiFirebaseApiKey, 'api-b');
      expect(connector.isConfigured, isTrue);
    },
        () => MockClient((_) async {
              entered.complete();
              return response.future;
            }));
  });

  test('an unrecognized Omi HTTP 400 refresh error preserves the enabled connection', () async {
    final connector = await omi(expired: true);
    final grant = upload(connector);
    await http.runWithClient(() async {
      await expectLater(connector.send(grant),
          throwsA(isA<OmiSyncException>().having((e) => e.isAuthError, 'credential rejection', isFalse)));
      expect(prefs.omiEnabled, isTrue);
    }, () => MockClient((_) async => http.Response('{"error":{"message":"TEMPORARY_FAILURE"}}', 400)));
  });

  testWidgets('an unavailable edited HeyPocket check preserves the saved key and queued uploads', (tester) async {
    await prefs.setHeypocketApiKey('pk_account_a_fixture');
    prefs.heypocketEnabled = true;
    final cancelled = <String>[];
    await http.runWithClient(() async {
      final model = IntegrationSettingsModel(onCancelUploads: (name, {autoOnly = false}) => cancelled.add(name))
        ..start();
      addTearDown(model.dispose);
      await tester.pumpAndSettle();
      model.heypocketController.text = 'pk_account_b_fixture';
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(model.connection(IntegrationId.heypocket), IntegrationConnectionState.error);
      expect(prefs.heypocketApiKey, 'pk_account_a_fixture');
      expect(prefs.heypocketEnabled, isTrue);
      expect(cancelled, isEmpty);
    }, () => MockClient((_) async => http.Response('{}', 503)));
  });

  testWidgets('a delayed app-open rejection cannot disable a validated replacement HeyPocket key', (tester) async {
    await prefs.setHeypocketApiKey('pk_account_a_fixture');
    prefs.heypocketEnabled = true;
    final oldResponse = Completer<http.Response>();
    await http.runWithClient(() async {
      final opening = HeyPocketConnector(prefs).onAppOpened();
      final model = IntegrationSettingsModel()..start();
      addTearDown(model.dispose);
      model.heypocketController.text = 'pk_account_b_fixture';
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(prefs.heypocketApiKey, 'pk_account_b_fixture');
      expect(prefs.heypocketEnabled, isTrue);
      oldResponse.complete(http.Response('{}', 401));
      await opening;
      await tester.pumpAndSettle();
      expect(prefs.heypocketEnabled, isTrue);
    },
        () => MockClient((request) async {
              if (request.headers['Authorization'] == 'Bearer pk_account_a_fixture') return oldResponse.future;
              return http.Response('{}', 200);
            }));
  });

  test('app-open rejection of the current HeyPocket key still disables it', () async {
    await prefs.setHeypocketApiKey('pk_account_a');
    prefs.heypocketEnabled = true;
    await http.runWithClient(
        () => HeyPocketConnector(prefs).onAppOpened(), () => MockClient((_) async => http.Response('{}', 401)));
    expect(prefs.heypocketEnabled, isFalse);
  });

  testWidgets('a validated manual Omi account change sends using the replacement account token', (tester) async {
    final connector = await omi();
    final grant = upload(connector);
    String? uploadAuth;
    Future<http.Response> response(http.Request request) async {
      if (request.url.host == 'securetoken.googleapis.com') {
        final b = request.body.contains('account-b-refresh');
        return http.Response(
            jsonEncode({
              'id_token': b ? 'account-b-id' : 'account-a-id',
              'refresh_token': b ? 'account-b-refresh' : 'account-a-refresh',
              'expires_in': '3600',
            }),
            200);
      }
      if (request.method == 'POST' && request.url.host == 'api.omi.me') uploadAuth = request.headers['Authorization'];
      return http.Response('{"status":"completed"}', 200);
    }

    await http.runWithClient(() async {
      final model = IntegrationSettingsModel()..start();
      addTearDown(model.dispose);
      await tester.pumpAndSettle();
      model.omiRefreshTokenController.text = 'account-b-refresh';
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(model.connection(IntegrationId.omiCloud), IntegrationConnectionState.connected);
      expect(prefs.omiRefreshToken, 'account-b-refresh');
      expect(prefs.omiTokenExpiry, 0);
    }, () => MockClient(response));
    await tester.runAsync(() => http.runWithClient(() => connector.send(grant), () => MockClient(response)));
    expect(uploadAuth, 'Bearer account-b-id');
  });

  test('fallback login without an ID token clears the previous account cache', () async {
    await omi();
    final model = IntegrationSettingsModel(checkOmi: (_, __) async => true);
    addTearDown(model.dispose);
    await model.acceptOmiLogin({'refreshToken': 'account-b-refresh', 'apiKey': 'api-key', 'flow': 'fallback'});
    expect(await prefs.omiIdToken, isEmpty);
    expect(prefs.omiTokenExpiry, 0);
    expect(prefs.omiRefreshToken, 'account-b-refresh');
    expect(prefs.omiEnabled, isTrue);
  });

  for (final oldStatus in [200, 401]) {
    test('an old Omi refresh HTTP $oldStatus cannot restore or disable replacement credentials', () async {
      await omi(expired: true);
      final entered = Completer<void>();
      final oldResponse = Completer<http.Response>();
      await http.runWithClient(() async {
        final refreshing = OmiApiClient.refreshTokenIfNeeded();
        final failure = expectLater(refreshing,
            throwsA(isA<OmiSyncException>().having((e) => e.isAuthError, 'stale credential rejection', isFalse)));
        await entered.future;
        await OmiApiClient.replaceCredentials(refreshToken: 'account-b-refresh', apiKey: 'new-api-key');
        oldResponse.complete(http.Response('{"id_token":"account-a-id","expires_in":"3600"}', oldStatus));
        await failure;
        expect(await prefs.omiIdToken, isEmpty);
        expect(prefs.omiTokenExpiry, 0);
        expect(prefs.omiRefreshToken, 'account-b-refresh');
        expect(prefs.omiEnabled, isTrue);
      },
          () => MockClient((_) async {
                entered.complete();
                return oldResponse.future;
              }));
    });
  }
}
