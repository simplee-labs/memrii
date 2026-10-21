import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_entitlement_service.dart';

/// A connector whose opt-in and eligibility the test sets directly, and which records
/// every grant it is handed.
class _Dest extends Connector {
  _Dest(this.name, {this.automatic = false, this.eligible = true});

  @override
  final String name;
  bool automatic;
  bool eligible;
  final List<AuthorizedUpload> received = [];

  /// When set, a send waits on it — holds the lane so later jobs stay queued.
  Future<void>? gate;
  final Set<String?> _delivered = {};

  @override
  ConnectorCapabilities get capabilities => const ConnectorCapabilities(leavesDevice: true, sendsAudio: true);
  @override
  bool get isConfigured => true;
  @override
  bool get isAutomaticSendingEnabled => automatic;
  @override
  bool isEligibleForAutomatic(IntegrationRecording r) => eligible;
  @override
  bool canSend(IntegrationRecording r) => true;
  @override
  String get unavailableReason => '';
  @override
  bool hasDelivered(IntegrationRecording r) => _delivered.contains(r.id);
  @override
  bool hasExhaustedRetries(IntegrationRecording r) => false;
  @override
  String retryKey(IntegrationRecording r) => '$name|${r.id}';
  @override
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled}) async {
    received.add(upload);
    if (gate != null) await gate;
    _delivered.add(upload.recording.id);
  }
}

void main() {
  late SharedPreferencesUtil prefs;
  late SharingPolicy policy;
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    policy =
        SharingPolicy(prefs, automation: AutomationPolicy(prefs, entitlements: TestEntitlementService(isPro: true)));
    tempDir = Directory.systemTemp.createTempSync('sharing_policy_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  IntegrationRecording rec(String id, {DateTime? start, List<DateTime> markers = const []}) => IntegrationRecording(
        id: id,
        audioPath: '/r/2026-09-30/recording_$id.m4a',
        startTime: start ?? DateTime(2026, 9, 30, 10),
        duration: const Duration(minutes: 4),
        captureMode: RecordingCaptureMode.manual,
        markers: markers,
      );

  group('UploadCandidate', () {
    test('describes what would be sent, where, and over what span', () {
      final marker = DateTime(2026, 9, 30, 10, 1);
      final c = policy.propose(_Dest('Cloud'), rec('k1', markers: [marker]));

      expect(c.destination, 'Cloud');
      expect(c.from, DateTime(2026, 9, 30, 10));
      expect(c.to, DateTime(2026, 9, 30, 10, 4));
      expect(c.sendsAudio, isTrue);
      expect(c.sendsTranscript, isFalse, reason: 'memrii makes no transcripts; a candidate says so');
      expect(c.markers, [marker]);
      expect(c.metadata['audioFormat'], 'm4a');
      expect(c.metadata['captureMode'], 'manual');
      expect(c.state, CandidateState.pending);
    });

    test('its identity follows the recording across a re-file (the upload key, not the path)', () {
      final a = rec('k1');
      final moved = IntegrationRecording(
          id: 'k1', audioPath: '/r/2026-09-29/recording_1.m4a', startTime: a.startTime, duration: a.duration);
      expect(policy.propose(_Dest('Cloud'), a).key, policy.propose(_Dest('Cloud'), moved).key);
    });
  });

  group('manual mode (the default)', () {
    test('nothing is authorized without the user asking', () {
      final dest = _Dest('Cloud');
      expect(policy.modeFor(dest), ApprovalMode.manual);
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('k1'))), isNull);
      expect(policy.pendingReview(), isEmpty, reason: 'manual mode does not even queue a proposal');
    });

    test('a user request is the approval', () {
      final dest = _Dest('Cloud');
      final grant = policy.approveUserRequest(policy.propose(dest, rec('k1')));
      expect(grant.basis, AuthorizationBasis.userRequest);
      expect(grant.candidate.state, CandidateState.approved);
      expect(grant.recording.id, 'k1');
      expect(policy.isStillAuthorized(dest, grant), isTrue);
    });
  });

  group('automatic mode', () {
    test('requires the explicit opt-in', () {
      final dest = _Dest('Cloud', automatic: false, eligible: true);
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('k1'))), isNull);

      dest.automatic = true;
      final grant = policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')));
      expect(grant, isNotNull);
      expect(grant!.basis, AuthorizationBasis.automaticOptIn);
    });

    test('only for eligible recordings (e.g. made after the opt-in)', () {
      final dest = _Dest('Cloud', automatic: true, eligible: false);
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('k1'))), isNull);
    });

    test('a grant lapses when the user switches automatic sending off', () {
      final dest = _Dest('Cloud', automatic: true);
      final grant = policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')))!;
      expect(policy.isStillAuthorized(dest, grant), isTrue);
      dest.automatic = false;
      expect(policy.isStillAuthorized(dest, grant), isFalse);
    });
  });

  group('review-queue mode', () {
    late _Dest dest;
    setUp(() {
      dest = _Dest('Cloud');
      policy.setReviewMode(dest, true, now: DateTime(2026, 9, 30));
    });

    test('a pending candidate is queued and not sent', () {
      expect(policy.modeFor(dest), ApprovalMode.reviewQueue);
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('k1'))), isNull);
      expect(policy.pendingReview(), ['Cloud|k1']);
      // Asked again, it is not queued twice.
      policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')));
      expect(policy.pendingReview(), ['Cloud|k1']);
    });

    test('an approved candidate is authorized; a rejected one never is', () {
      policy.approve(policy.propose(dest, rec('k1')));
      policy.reject(policy.propose(dest, rec('k2')));

      final approved = policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')));
      expect(approved, isNotNull);
      expect(approved!.basis, AuthorizationBasis.reviewApproved);
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('k2'))), isNull);
      expect(policy.pendingReview(), isEmpty);
    });

    test('rejecting after approval withdraws a grant that has not been used yet', () {
      policy.approve(policy.propose(dest, rec('k1')));
      final grant = policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')))!;
      policy.reject(policy.propose(dest, rec('k1')));
      expect(policy.isStillAuthorized(dest, grant), isFalse);
    });

    test('recordings from before review mode was switched on are not proposed', () {
      expect(policy.authorizeUnattended(dest, policy.propose(dest, rec('old', start: DateTime(2026, 9, 1)))), isNull);
      expect(policy.pendingReview(), isEmpty);
    });

    test('an explicit user request still sends a rejected recording', () {
      policy.reject(policy.propose(dest, rec('k1')));
      final grant = policy.approveUserRequest(policy.propose(dest, rec('k1')));
      expect(grant.basis, AuthorizationBasis.userRequest);
      expect(policy.isStillAuthorized(dest, grant), isTrue);
    });

    test('delivery clears the queue entry', () {
      policy.approve(policy.propose(dest, rec('k1')));
      final grant = policy.authorizeUnattended(dest, policy.propose(dest, rec('k1')))!;
      policy.noteDelivered(grant);
      expect(policy.propose(dest, rec('k1')).state, CandidateState.pending);
    });

    test('an unreadable queue store fails toward "not approved"', () async {
      await prefs.saveString('sharingReviewQueue', '{not json');
      expect(policy.propose(dest, rec('k1')).state, CandidateState.pending);
    });
  });

  // The same rules, end to end through the upload engine that actually calls send().
  group('through the upload engine', () {
    Conversation conv(String key) {
      final f = File('${tempDir.path}/recording_$key.wav')..writeAsBytesSync(List.filled(2048, 1));
      return Conversation(
          file: f, startTime: DateTime(2026, 9, 30, 11), duration: const Duration(minutes: 5), uploadKey: key);
    }

    IntegrationUploadManager engine(List<Connector> connectors, List<Conversation> finished) =>
        IntegrationUploadManager(
          connectors: connectors,
          prefs: prefs,
          policy: policy,
          batchesProvider: () => [
            Batch(
                dateString: '2026-09-30',
                date: DateTime(2026, 9, 30),
                rawSegments: const [],
                draftRecordings: const [],
                finalizedRecordings: finished)
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

    Future<void> settle(IntegrationUploadManager m) async {
      for (var i = 0; i < 200 && m.uploadingFiles.isNotEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }

    test('a manual-mode destination is sent nothing by the sweep', () async {
      final dest = _Dest('Cloud');
      final m = engine([dest], [conv('k1')]);
      m.tryAutoUploadAll();
      await settle(m);
      expect(dest.received, isEmpty);
    });

    test('a review-mode destination receives only what the user approved', () async {
      final dest = _Dest('Cloud');
      policy.setReviewMode(dest, true, now: DateTime(2026, 9, 30));
      final a = conv('a'), b = conv('b');
      final m = engine([dest], [a, b]);

      m.tryAutoUploadAll();
      await settle(m);
      expect(dest.received, isEmpty, reason: 'pending candidates are never sent');
      expect(policy.pendingReview(), unorderedEquals(['Cloud|a', 'Cloud|b']));

      policy.approve(policy.propose(dest, IntegrationRecording.fromConversation(a)));
      policy.reject(policy.propose(dest, IntegrationRecording.fromConversation(b)));
      m.tryAutoUploadAll();
      await settle(m);

      expect(dest.received.map((g) => g.recording.id), ['a']);
      expect(dest.received.single.basis, AuthorizationBasis.reviewApproved);
    });

    test('every send carries the grant for exactly that recording and destination', () async {
      final dest = _Dest('Cloud', automatic: true);
      final m = engine([dest], [conv('k1'), conv('k2')]);
      m.tryAutoUploadAll();
      await settle(m);

      expect(dest.received.map((g) => g.recording.id), unorderedEquals(['k1', 'k2']));
      expect(dest.received.every((g) => g.destination == 'Cloud'), isTrue);
      expect(dest.received.every((g) => g.basis == AuthorizationBasis.automaticOptIn), isTrue);
    });

    test('an automatic job queued before the user switched automatic sending off is not sent', () async {
      final dest = _Dest('Cloud', automatic: true);
      final release = Completer<void>();
      dest.gate = release.future;
      final m = engine([dest], [conv('k1'), conv('k2')]);

      m.tryAutoUploadAll(); // k1 in flight (held), k2 queued
      await Future.delayed(const Duration(milliseconds: 5));
      expect(dest.received, hasLength(1));

      dest.automatic = false; // the opt-in is withdrawn while k2 waits
      release.complete();
      await settle(m);

      expect(dest.received, hasLength(1), reason: 'the queued grant lapsed with the opt-in');
    });

    test('a user request goes to a manual-mode destination, with its own basis', () async {
      final dest = _Dest('Cloud');
      final c = conv('k1');
      final m = engine([dest], [c]);
      await m.uploadConversation(c);
      await settle(m);
      expect(dest.received.single.basis, AuthorizationBasis.userRequest);
    });
  });
}
