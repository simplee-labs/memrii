import 'package:omi/backend/preferences.dart';
import 'package:omi/entitlements/entitlement_service.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/integration_recording.dart';

enum AutomaticRecordingScope { all, marked, priority }

/// Small persisted destination-specific rules. Core recording/capture preferences stay separate.
class AutomationSettings {
  AutomationSettings(this._prefs, this.key);
  final SharedPreferencesUtil _prefs;
  final String key;
  String get _prefix => 'automation_$key';

  AutomaticRecordingScope get scope => AutomaticRecordingScope.values.firstWhere(
        (s) => s.name == _prefs.getString('${_prefix}_scope'),
        orElse: () => AutomaticRecordingScope.all,
      );
  set scope(AutomaticRecordingScope value) => _prefs.saveString('${_prefix}_scope', value.name);

  int get minimumSeconds => _prefs.getInt('${_prefix}_minimumSeconds', defaultValue: 0).clamp(0, 86400);
  set minimumSeconds(int value) => _prefs.saveInt('${_prefix}_minimumSeconds', value.clamp(0, 86400));

  bool get wifiOnly => _prefs.getBool('${_prefix}_wifiOnly', defaultValue: false);
  set wifiOnly(bool value) => _prefs.saveBool('${_prefix}_wifiOnly', value);

  /// A confirmed snapshot of recording identities, rather than an open-ended archive cutoff.
  /// Survives process restarts and entitlement loss. Discovery never enlarges this list.
  List<String> get backfillIds => _prefs.getStringList('${_prefix}_backfillIds');
  set backfillIds(List<String> value) => _prefs.saveStringList('${_prefix}_backfillIds', value);

  Future<void> clearBackfill() => _prefs.saveStringList('${_prefix}_backfillIds', []);
}

/// Entitlement and selection live above transport. The connector's existing opt-in and
/// cutoff methods are a transitional adapter for old preferences, not effective permission.
class AutomationPolicy {
  AutomationPolicy(this._prefs, {EntitlementService? entitlements})
      : entitlements = entitlements ?? ApplicationEntitlements.current;

  final SharedPreferencesUtil _prefs;
  final EntitlementService entitlements;

  AutomationSettings? settingsFor(Connector connector) {
    final key = connector.automationSettingsKey;
    return key == null ? null : AutomationSettings(_prefs, key);
  }

  bool isAvailable(Connector connector) =>
      entitlements.isPro && connector.capabilities.supportsAutomaticSending && connector.isConfigured;

  bool isEffective(Connector connector) => isAvailable(connector) && connector.isAutomaticSendingEnabled;

  bool matchesRules(Connector connector, IntegrationRecording recording) {
    final settings = settingsFor(connector);
    if (recording.duration < Duration(seconds: settings?.minimumSeconds ?? 0)) return false;
    return switch (settings?.scope ?? AutomaticRecordingScope.all) {
      AutomaticRecordingScope.all => true,
      AutomaticRecordingScope.marked => recording.markers.isNotEmpty || recording.hasPriorityMarker,
      AutomaticRecordingScope.priority => recording.hasPriorityMarker,
    };
  }

  bool eligible(Connector connector, IntegrationRecording recording) =>
      isEffective(connector) && connector.isEligibleForAutomatic(recording) && matchesRules(connector, recording);

  bool eligibleForBackfill(Connector connector, IntegrationRecording recording) =>
      isAvailable(connector) && connector.canSend(recording) && matchesRules(connector, recording);

  bool requestedBackfill(Connector connector, IntegrationRecording recording) =>
      eligibleForBackfill(connector, recording) &&
      (settingsFor(connector)?.backfillIds.contains(recording.id ?? recording.audioPath) ?? false);

  /// Conditions apply only to unattended network transfers. Manual grants never ask here.
  /// Phone charging is deliberately deferred until a reliable platform monitor is available.
  bool requiresWifi(Connector connector) =>
      connector.capabilities.leavesDevice && (settingsFor(connector)?.wifiOnly ?? false);

  void noteDelivered(Connector connector, IntegrationRecording recording) {
    final settings = settingsFor(connector);
    if (settings == null) return;
    final ids = [...settings.backfillIds];
    if (ids.remove(recording.id ?? recording.audioPath)) settings.backfillIds = ids;
  }
}
