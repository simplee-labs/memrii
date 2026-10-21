import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_api.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/utils/logger.dart';

/// HeyPocket: uploads the finished audio file, with its start time and duration, in one
/// request per recording. Configured with an API key held in secure storage.
///
/// Its delivery ledger (`heypocketUploadedFiles`) and retry count are keyed by the
/// recording's upload key, which a re-file does not change — so a moved recording needs
/// nothing from [onRecordingMoved].
class HeyPocketConnector extends Connector {
  HeyPocketConnector(this._prefs);

  final SharedPreferencesUtil _prefs;

  static const connectorName = 'HeyPocket';

  @override
  String get name => connectorName;

  @override
  String get automationSettingsKey => 'heypocket';

  @override
  ConnectorCapabilities get capabilities => const ConnectorCapabilities(leavesDevice: true, sendsAudio: true);

  @override
  bool get isConfigured => _prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty;

  @override
  bool get isAutomaticSendingEnabled => _prefs.heypocketAutoUpload;

  @override
  bool isEligibleForAutomatic(IntegrationRecording r) {
    if (!_prefs.heypocketEnabled || !isConfigured || r.id == null) return false;
    final enabledAt = _prefs.heypocketKeySetAt;
    // Fail closed: with no recorded auto-upload-enabled time we never auto-upload
    // (a user request still works). A zero/legacy timestamp must not sweep up
    // recordings made before the Auto-Upload toggle was switched on.
    if (enabledAt <= 0) return false;
    if (r.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt))) return false;
    return true;
  }

  // HeyPocket uploads the recording's audio file (wav/m4a/ogg), so any recording whose
  // audio still exists can be sent on request — independent of when auto-upload was on.
  @override
  bool canSend(IntegrationRecording r) => isConfigured && r.id != null && r.audioExists;

  @override
  String get unavailableReason => 'Audio file is no longer available';

  @override
  bool hasDelivered(IntegrationRecording r) => r.id != null && _prefs.isUploadedToHeypocket(r.id!);

  @override
  bool hasExhaustedRetries(IntegrationRecording r) => _prefs.getAutoUploadRetries(r.id!) >= 3;

  @override
  String retryKey(IntegrationRecording r) => r.id!;

  @override
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled}) async {
    // One request per recording — no chunk progress and no mid-flight cancellation
    // point, so it can only bail before it starts.
    if (isCancelled?.call() ?? false) return;
    final r = upload.recording;
    final uploadKey = r.id!;
    try {
      await HeyPocketService.uploadRecording(_prefs.heypocketApiKey, r);
      await _prefs.markUploadedToHeypocket(uploadKey);
      await _prefs.clearAutoUploadRetry(uploadKey);
    } catch (e) {
      if (e is HeyPocketException && (e.statusCode == 401 || e.statusCode == 403)) {
        _prefs.heypocketEnabled = false;
      }
      rethrow;
    }
  }

  @override
  Future<void> forget(List<IntegrationRecording> deleted) async {
    final keys = deleted.map((r) => r.id).whereType<String>().toSet();
    if (keys.isNotEmpty) await _prefs.removeUploadedFromHeypocket(keys);
  }

  @override
  Future<void> forgetDeliveryHistory() async => _prefs.heypocketUploadedFiles = [];

  @override
  String? credentialFailureMessage(Object error) =>
      error is HeyPocketException && (error.statusCode == 401 || error.statusCode == 403)
          ? 'HeyPocket: API key revoked — update it in Integrations'
          : null;

  @override
  String get credentialFingerprint => _prefs.heypocketCredentialRevision.toString();

  @override
  bool get hasIncompleteDelivery => _prefs.autoUploadRetryKeys.any(SharedPreferencesUtil.isHeypocketRetryKey);

  @override
  Iterable<String> get incompleteDeliveryKeys =>
      _prefs.autoUploadRetryKeys.where(SharedPreferencesUtil.isHeypocketRetryKey);

  @override
  Future<void> clearIncompleteDelivery() =>
      _prefs.clearAutoUploadRetriesWhere(SharedPreferencesUtil.isHeypocketRetryKey);

  /// Checks the stored key against the service each time the UI opens and turns the
  /// connector off if the service says it is no longer valid. A network failure proves
  /// nothing about the key, so it leaves the connector as it was.
  @override
  Future<void> onAppOpened() async {
    final apiKey = _prefs.heypocketApiKey;
    if (apiKey.isEmpty) return;
    try {
      final ok = await HeyPocketService.testConnection(apiKey);
      if (!ok && _prefs.heypocketApiKey == apiKey) _prefs.heypocketEnabled = false;
    } catch (e) {
      Logger.error('HeyPocket startup check failed: $e');
    }
  }
}
