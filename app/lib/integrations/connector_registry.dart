import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/utils/logger.dart';

/// The connectors this build ships, and the few questions the rest of the app asks about
/// all of them at once.
///
/// Everything outside `lib/integrations/` that needs to know about destinations — the
/// recording layer when it renames or deletes a recording, the processor when it decides
/// whether to keep Opus frames, app start-up — goes through here, so none of it names a
/// destination. Adding a connector means adding it to [all]; nothing else outside this
/// directory changes.
class ConnectorRegistry {
  ConnectorRegistry._();

  /// Every connector, in stable engine order; the UI stores its own presentation order.
  /// Save to Folder is memrii's local
  /// destination and is listed with the others: it is authorized, queued and reported
  /// exactly like them, it just never leaves the phone.
  static List<Connector> all(SharedPreferencesUtil prefs) => [
        HeyPocketConnector(prefs),
        OmiCloudConnector(prefs),
        FolderExportConnector(prefs),
        // Add new connectors here.
      ];

  static bool hasAnyConfigured(SharedPreferencesUtil prefs) => all(prefs).any((c) => c.isConfigured);

  /// Whether the processor should write Opus frame sidecars for the recordings it
  /// finishes from now on: some enabled connector needs them.
  static bool wantsOpusFrameSidecar(SharedPreferencesUtil prefs) =>
      all(prefs).any((c) => c.capabilities.needsOpusFrameSidecar && c.wantsOpusFrameSidecar);

  /// The recording layer moved a recording on disk. Every connector is told, one after
  /// another, and none can stop the others or the caller.
  static Future<void> recordingMoved(RecordingMove move, {SharedPreferencesUtil? prefs}) async {
    for (final c in all(prefs ?? SharedPreferencesUtil())) {
      try {
        await c.onRecordingMoved(move);
      } catch (e) {
        Logger.error('ConnectorRegistry: ${c.name} could not follow a moved recording: $e');
      }
    }
  }

  /// [deleted] are about to be removed from the phone: every connector forgets them.
  static Future<void> recordingsDeleted(List<Conversation> deleted, {SharedPreferencesUtil? prefs}) async {
    if (deleted.isEmpty) return;
    final views = deleted.map(IntegrationRecording.fromConversation).toList(growable: false);
    for (final c in all(prefs ?? SharedPreferencesUtil())) {
      try {
        await c.forget(views);
      } catch (e) {
        Logger.error('ConnectorRegistry: ${c.name} could not forget deleted recordings: $e');
      }
    }
  }

  /// Debug Tools cleared every recording on the phone.
  static Future<void> forgetDeliveryHistory(SharedPreferencesUtil prefs) async {
    for (final c in all(prefs)) {
      await c.forgetDeliveryHistory();
    }
  }

  /// Once per process, after services start. Not awaited by the caller; a slow or
  /// failing connector holds up nothing.
  static Future<void> onServicesStarted(SharedPreferencesUtil prefs) async {
    await Future.wait(all(prefs).map((c) => c.onServicesStarted()));
  }

  /// Each time the UI opens.
  static Future<void> onAppOpened(SharedPreferencesUtil prefs) async {
    await Future.wait(all(prefs).map((c) => c.onAppOpened()));
  }
}
