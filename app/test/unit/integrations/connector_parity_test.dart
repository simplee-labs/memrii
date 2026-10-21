import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connector_registry.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_api.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_entitlement_service.dart';

/// Behavioural parity of the two network connectors with the integrations they replaced
/// (HeyPocketPassthroughIntegration / OmiPassthroughIntegration): same requests, same
/// ledger keys, same failure handling. Every HTTP call is answered by a MockClient — no
/// production API is contacted.
void main() {
  late Directory tempDir;
  late SharedPreferencesUtil prefs;
  late SharingPolicy policy;
  final secure = <String, String>{};

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    secure.clear();
    // Secure storage in memory, so credentials written by the test read back.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return secure[args['key'] as String];
          case 'delete':
            secure.remove(args['key']);
            return null;
          default:
            return null;
        }
      },
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    policy =
        SharingPolicy(prefs, automation: AutomationPolicy(prefs, entitlements: TestEntitlementService(isPro: true)));
    tempDir = Directory.systemTemp.createTempSync('connector_parity');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// A finished recording on disk, as the processor leaves one.
  Conversation recording(String key, {DateTime? start, String ext = 'm4a'}) {
    final startTime = start ?? DateTime(2026, 9, 30, 14, 5);
    final day = Directory('${tempDir.path}/recordings/2026-09-30')..createSync(recursive: true);
    final file = File('${day.path}/recording_${startTime.millisecondsSinceEpoch}.$ext')
      ..writeAsBytesSync(List.filled(4096, 7));
    return Conversation(
        file: file, startTime: startTime, duration: const Duration(minutes: 3, seconds: 20), uploadKey: key);
  }

  IntegrationRecording view(Conversation c) => IntegrationRecording.fromConversation(c);

  AuthorizedUpload userGrant(Connector connector, Conversation c) =>
      policy.approveUserRequest(policy.propose(connector, view(c)));

  group('HeyPocket', () {
    Future<void> configure() async {
      prefs.heypocketEnabled = true;
      await prefs.setHeypocketApiKey('hp-key');
    }

    test('is off and unconfigured by default, so it can send nothing', () {
      final hp = HeyPocketConnector(prefs);
      expect(hp.isConfigured, isFalse);
      expect(hp.isAutomaticSendingEnabled, isFalse);
      expect(hp.canSend(view(recording('k1'))), isFalse);
    });

    test('automatic eligibility fails closed without a recorded opt-in time, and respects it', () async {
      await configure();
      final hp = HeyPocketConnector(prefs);
      final c = recording('k1', start: DateTime(2026, 9, 30, 14));
      expect(hp.isEligibleForAutomatic(view(c)), isFalse, reason: 'no opt-in time recorded');

      prefs.heypocketKeySetAt = DateTime(2026, 9, 30, 15).millisecondsSinceEpoch;
      expect(hp.isEligibleForAutomatic(view(c)), isFalse, reason: 'recorded before the opt-in');
      prefs.heypocketKeySetAt = DateTime(2026, 9, 30, 13).millisecondsSinceEpoch;
      expect(hp.isEligibleForAutomatic(view(c)), isTrue);
    });

    test('sends the audio file with its title, start and duration, then records delivery', () async {
      await configure();
      final hp = HeyPocketConnector(prefs);
      final c = recording('k1');
      final requests = <http.BaseRequest>[];
      final bodies = <String>[];
      final client = MockClient((req) async {
        requests.add(req);
        if (req.method == 'POST') {
          bodies.add(req.body);
          return http.Response(
              jsonEncode({
                'data': {'upload_url': 'https://upload.example/presigned'}
              }),
              200);
        }
        return http.Response('', 200); // the presigned PUT
      });

      await http.runWithClient(() => hp.send(userGrant(hp, c)), () => client);

      expect(requests.map((r) => '${r.method} ${r.url.host}${r.url.path}'),
          ['POST public.heypocketai.com/api/v1/public/recordings/upload-url', 'PUT upload.example/presigned']);
      expect(requests.first.headers['Authorization'], 'Bearer hp-key');
      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['file_name'], c.file.uri.pathSegments.last);
      expect(body['content_type'], 'audio/mp4');
      expect(body['duration'], 200);
      expect(body['recording_at'], startsWith('2026-09-30T14:05:00'));
      expect(hp.hasDelivered(view(c)), isTrue);
      expect(prefs.isUploadedToHeypocket('k1'), isTrue, reason: 'same ledger, same key as before');
    });

    test('a revoked key turns the connector off and surfaces the credential message', () async {
      await configure();
      final hp = HeyPocketConnector(prefs);
      final c = recording('k1');
      final client = MockClient((req) async => http.Response('', 401));

      Object? error;
      try {
        await http.runWithClient(() => hp.send(userGrant(hp, c)), () => client);
      } catch (e) {
        error = e;
      }

      expect(error, isA<HeyPocketException>());
      expect(prefs.heypocketEnabled, isFalse);
      expect(hp.credentialFailureMessage(error!), contains('API key revoked'));
      expect(hp.credentialFailureMessage(Exception('other')), isNull);
      expect(hp.hasDelivered(view(c)), isFalse);
    });

    // Its retry key is the upload key, force-unwrapped, so the sweep must rule a keyless
    // recording out on eligibility before it ever asks for one — the order it always had.
    test('the automatic sweep skips a recording with no upload key rather than throwing', () async {
      await configure();
      prefs.heypocketAutoUpload = true; // stamps the opt-in: now
      final day = Directory('${tempDir.path}/recordings/2026-09-30')..createSync(recursive: true);
      final keyless = Conversation(
          file: File('${day.path}/recording_9.m4a')..writeAsBytesSync(List.filled(64, 1)),
          startTime: DateTime.now().add(const Duration(minutes: 1)),
          duration: const Duration(minutes: 1));
      final m = IntegrationUploadManager(
        connectors: [HeyPocketConnector(prefs)],
        prefs: prefs,
        policy: policy,
        batchesProvider: () => [
          Batch(
              dateString: '2026-09-30',
              date: DateTime(2026, 9, 30),
              rawSegments: const [],
              draftRecordings: const [],
              finalizedRecordings: [keyless])
        ],
        isDisposed: () => false,
        isPipelineIdle: () => true,
        isProcessing: () => false,
        notifyUi: () {},
        acquireWake: (_) {},
        releaseWake: (_) {},
        showUploadNotification: (_) {},
        settleNotification: () {},
        setPendingSnack: (_) {},
        checkOnWifi: () async => true,
        convertToPassthrough: (_) async {},
      );

      expect(m.tryAutoUploadAll, returnsNormally);
      expect(m.uploadingFiles, isEmpty);
    });

    test('keyed by upload key: a re-file changes nothing, a delete forgets', () async {
      final hp = HeyPocketConnector(prefs);
      await prefs.markUploadedToHeypocket('k1');
      final c = recording('k1');
      await hp.onRecordingMoved(RecordingMove(c.file.path, '${c.file.parent.path}/recording_1.m4a'));
      expect(hp.hasDelivered(view(c)), isTrue);
      await hp.forget([view(c)]);
      expect(hp.hasDelivered(view(c)), isFalse);
    });
  });

  group('Omi Cloud', () {
    Future<void> configure() async {
      prefs.omiEnabled = true;
      await prefs.setOmiRefreshToken('rt');
      await prefs.setOmiFirebaseApiKey('api-key');
      await prefs.setOmiIdToken('id-token');
      prefs.omiTokenExpiry = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    }

    /// The Opus frame sidecar the processor writes: 4-byte LE length + packet per frame.
    void writeSidecar(Conversation c, {int frames = 10}) {
      final b = BytesBuilder();
      for (var i = 0; i < frames; i++) {
        b.add((ByteData(4)..setUint32(0, 60, Endian.little)).buffer.asUint8List());
        b.add(List.filled(60, i));
      }
      File(view(c).opusFrameSidecarPath).writeAsBytesSync(b.toBytes());
    }

    test('asks for Opus frame sidecars while enabled, even before sign-in (as omiEnabled did)', () {
      final omi = OmiCloudConnector(prefs);
      expect(ConnectorRegistry.wantsOpusFrameSidecar(prefs), isFalse);
      prefs.omiEnabled = true;
      expect(omi.isConfigured, isFalse, reason: 'not signed in');
      expect(ConnectorRegistry.wantsOpusFrameSidecar(prefs), isTrue);
      expect(ProcessingSettings.fromPrefs().writeOpusFrameSidecar, isTrue);
      prefs.omiEnabled = false;
      expect(ProcessingSettings.fromPrefs().writeOpusFrameSidecar, isFalse);
    });

    test('can send only a recording that has a sidecar', () async {
      await configure();
      final omi = OmiCloudConnector(prefs);
      final c = recording('k1');
      expect(omi.canSend(view(c)), isFalse);
      expect(omi.unavailableReason, 'Recorded before Omi sync was enabled');
      writeSidecar(c);
      expect(omi.canSend(view(c)), isTrue);
    });

    test('sends the sidecar as fs320 segments and records delivery under its path', () async {
      await configure();
      final omi = OmiCloudConnector(prefs);
      final c = recording('k1');
      writeSidecar(c);
      final uploads = <String>[];
      final client = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer id-token');
        expect(req.url.toString(), 'https://api.omi.me/v2/sync-local-files');
        uploads.add(req.headers['content-type'] ?? '');
        return http.Response(jsonEncode({'status': 'completed'}), 200);
      });

      await http.runWithClient(() => omi.send(userGrant(omi, c)), () => client);

      expect(uploads, hasLength(1), reason: '10 frames is one chunk');
      expect(uploads.single, startsWith('multipart/form-data'));
      final binPath = view(c).opusFrameSidecarPath;
      expect(prefs.isOmiSynced(binPath), isTrue, reason: 'same ledger, same key as before');
      expect(omi.hasDelivered(view(c)), isTrue);
      expect(omi.retryKey(view(c)), binPath);
    });

    test('a busy server backs the recording off without failing or delivering', () async {
      await configure();
      final omi = OmiCloudConnector(prefs);
      final c = recording('k1');
      writeSidecar(c);
      final client = MockClient((req) async => http.Response('busy', 503));

      await http.runWithClient(() => omi.send(userGrant(omi, c)), () => client);

      expect(omi.hasDelivered(view(c)), isFalse);
      expect(omi.isBackingOff(view(c)), isTrue);
      expect(prefs.getAutoUploadRetries(omi.retryKey(view(c))), 0, reason: 'busy spends no retry');
    });

    test('an auth failure turns the connector off and surfaces the credential message', () async {
      await configure();
      final omi = OmiCloudConnector(prefs);
      final c = recording('k1');
      writeSidecar(c);
      final client = MockClient((req) async => http.Response('nope', 401));

      Object? error;
      try {
        await http.runWithClient(() => omi.send(userGrant(omi, c)), () => client);
      } catch (e) {
        error = e;
      }
      expect(error, isA<OmiSyncException>());
      expect(prefs.omiEnabled, isFalse);
      expect(omi.credentialFailureMessage(error!), contains('credentials invalid'));
    });

    test('follows a moved recording: its whole upload state moves with the sidecar path', () async {
      final omi = OmiCloudConnector(prefs);
      final from = recording('k1', start: DateTime(2026, 9, 30, 9));
      final toPath = '${from.file.parent.path}/recording_${DateTime(2026, 9, 30, 10).millisecondsSinceEpoch}.m4a';
      final fromBin = view(from).opusFrameSidecarPath;
      await prefs.markOmiSynced(fromBin);
      await prefs.incrementAutoUploadRetry(fromBin);

      await ConnectorRegistry.recordingMoved(RecordingMove(from.file.path, toPath), prefs: prefs);

      final toBin = IntegrationRecording.opusFrameSidecarPathOf(toPath);
      expect(prefs.isOmiSynced(toBin), isTrue);
      expect(prefs.isOmiSynced(fromBin), isFalse);
      expect(prefs.getAutoUploadRetries(toBin), 1);
      expect(
          omi.hasDelivered(IntegrationRecording.fromConversation(
              Conversation(file: File(toPath), startTime: DateTime(2026, 9, 30, 10), duration: Duration.zero))),
          isTrue);
    });
  });

  group('ConnectorRegistry', () {
    test('lists the three connectors, Save to Folder among them', () {
      expect(ConnectorRegistry.all(prefs).map((c) => c.name), ['HeyPocket', 'Omi Cloud', 'Folder']);
      expect(ConnectorRegistry.hasAnyConfigured(prefs), isFalse, reason: 'every destination is off by default');
      expect(ConnectorRegistry.all(prefs).any((c) => c.isAutomaticSendingEnabled), isFalse);
    });

    test('a deletion makes every connector forget the recording', () async {
      FolderExportConnector.resetForTest();
      final c = recording('k1');
      await prefs.markUploadedToHeypocket('k1');
      await prefs.markOmiSynced(view(c).opusFrameSidecarPath);
      prefs.folderExportLedger = jsonEncode({
        'k1': {'uri': 'doc0', 'name': 'x.m4a', 'startMs': 1}
      });

      await ConnectorRegistry.recordingsDeleted([c], prefs: prefs);

      expect(prefs.isUploadedToHeypocket('k1'), isFalse);
      expect(prefs.isOmiSynced(view(c).opusFrameSidecarPath), isFalse);
      expect(FolderExportConnector(prefs).hasDelivered(view(c)), isFalse);
    });

    test('clearing delivery history keeps Save to Folder\'s ledger (its copies are the user\'s)', () async {
      FolderExportConnector.resetForTest();
      final c = recording('k1');
      await prefs.markUploadedToHeypocket('k1');
      await prefs.markOmiSynced(view(c).opusFrameSidecarPath);
      prefs.folderExportLedger = jsonEncode({
        'k1': {'uri': 'doc0', 'name': 'x.m4a', 'startMs': 1}
      });

      await ConnectorRegistry.forgetDeliveryHistory(prefs);

      expect(prefs.isUploadedToHeypocket('k1'), isFalse);
      expect(prefs.isOmiSynced(view(c).opusFrameSidecarPath), isFalse);
      expect(FolderExportConnector(prefs).hasDelivered(view(c)), isTrue);
    });
  });

  group('IntegrationRecording', () {
    test('is built from the recording model with nothing of the capture pipeline in it', () {
      final c = Conversation(
        file: File('/data/recordings/2026-09-30/recording_1759240000000.wav'),
        startTime: DateTime.fromMillisecondsSinceEpoch(1759240000000),
        duration: const Duration(seconds: 90),
        uploadKey: 'aabbcc_recording_1759240000000.m4a',
        sessionId: 42,
        recordedManual: false,
        clockCorrected: true,
        relativeBins: const ['1759239900/1759239900_42.bin'],
      );
      final r = IntegrationRecording.fromConversation(c, markers: [DateTime(2026, 9, 30)]);

      expect(r.id, c.uploadKey);
      expect(r.audioPath, c.file.path);
      expect(r.audioFormat, 'wav');
      expect(r.startTime, c.startTime);
      expect(r.duration, c.duration);
      expect(r.sessionId, 42);
      expect(r.captureMode, RecordingCaptureMode.automatic);
      expect(r.clockCorrected, isTrue);
      expect(r.timeUncertain, isFalse);
      expect(r.markers, hasLength(1));
      expect(r.opusFrameSidecarPath, '/data/recordings/2026-09-30/recording_fs320_1759240000000.bin',
          reason: 'the on-disk name Omi Cloud state is keyed by must not change');
    });

    test('an unknown-time recording says so', () {
      final c = Conversation(
          file: File('/data/recordings/1970-01-01/unknown_5000.wav'),
          startTime: DateTime.fromMillisecondsSinceEpoch(5000),
          duration: Duration.zero);
      expect(IntegrationRecording.fromConversation(c).timeUncertain, isTrue);
      expect(IntegrationRecording.fromConversation(c).captureMode, RecordingCaptureMode.unknown);
    });
  });
}
