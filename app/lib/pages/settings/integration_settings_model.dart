import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/entitlements/entitlement_service.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_api.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';

enum IntegrationId {
  folderExport('folderExport', 'Save to Folder', FolderExportConnector.connectorName),
  omiCloud('omiCloud', 'Omi Cloud (unofficial)', OmiCloudConnector.connectorName),
  heypocket('heypocket', 'HeyPocket', HeyPocketConnector.connectorName);

  const IntegrationId(this.storageKey, this.title, this.connectorName);
  final String storageKey;
  final String title;
  final String connectorName;
}

enum IntegrationConnectionState { idle, checking, connected, error }

/// A navigation session's presentation state. It does not own the upload engine.
class IntegrationSettingsModel extends ChangeNotifier {
  IntegrationSettingsModel({
    SharedPreferencesUtil? prefs,
    this.onCancelUploads,
    this.integrationChanges,
    this.uploads,
    this.onAutomationChanged,
    this.confirmCredentialChange,
    Future<bool> Function(String)? checkHeyPocket,
    Future<bool> Function(String, String)? checkOmi,
  })  : prefs = prefs ?? SharedPreferencesUtil(),
        _checkHeyPocket = checkHeyPocket ?? HeyPocketService.testConnection,
        _checkOmi = checkOmi ?? ((rt, ak) => OmiApiClient.testConnection(refreshToken: rt, apiKey: ak));

  final SharedPreferencesUtil prefs;
  final void Function(String connectorName, {bool autoOnly})? onCancelUploads;
  final Listenable? integrationChanges;
  final IntegrationUploadManager? uploads;
  final VoidCallback? onAutomationChanged;
  Future<bool> Function(IntegrationId)? confirmCredentialChange;
  final Future<bool> Function(String) _checkHeyPocket;
  final Future<bool> Function(String, String) _checkOmi;
  EntitlementService get entitlements => ApplicationEntitlements.current;
  late final _folder = FolderExportConnector(prefs);

  final heypocketController = TextEditingController();
  final omiRefreshTokenController = TextEditingController();
  final omiFirebaseApiKeyController = TextEditingController();
  bool heypocketObscured = true;
  bool omiObscured = true;
  bool showOmiManual = false;
  bool _disposed = false;
  bool _started = false;
  final _states = <IntegrationId, IntegrationConnectionState>{};
  final _revisions = <IntegrationId, int>{};
  final _writes = <IntegrationId, Future<void>>{};
  final _disconnecting = <IntegrationId>{};
  final _transitioning = <IntegrationId>{};
  Timer? _hpDebounce;
  Timer? _omiDebounce;

  List<IntegrationId> get order {
    final ids = {for (final id in IntegrationId.values) id.storageKey: id};
    return {...prefs.integrationListOrder.map((key) => ids[key]).whereType<IntegrationId>(), ...IntegrationId.values}
        .toList();
  }

  bool enabled(IntegrationId id) => switch (id) {
        IntegrationId.heypocket => prefs.heypocketEnabled,
        IntegrationId.omiCloud => prefs.omiEnabled,
        IntegrationId.folderExport => prefs.folderExportEnabled,
      };

  bool hasConfiguration(IntegrationId id) => switch (id) {
        IntegrationId.heypocket => prefs.heypocketApiKey.isNotEmpty,
        IntegrationId.omiCloud => prefs.omiRefreshToken.isNotEmpty && prefs.omiFirebaseApiKey.isNotEmpty,
        IntegrationId.folderExport => prefs.folderExportTreeUri.isNotEmpty,
      };

  bool hasRemovableConfiguration(IntegrationId id) =>
      hasConfiguration(id) ||
      (id == IntegrationId.omiCloud && (prefs.omiRefreshToken.isNotEmpty || prefs.omiFirebaseApiKey.isNotEmpty));

  IntegrationConnectionState connection(IntegrationId id) => _states[id] ?? IntegrationConnectionState.idle;
  bool isDisconnecting(IntegrationId id) => _disconnecting.contains(id);
  bool isChangingCredentials(IntegrationId id) =>
      _transitioning.contains(id) || (uploads?.isChangingCredentials(id.connectorName) ?? false);

  Connector _credentialConnector(IntegrationId id) => switch (id) {
        IntegrationId.omiCloud => OmiCloudConnector(prefs),
        IntegrationId.heypocket => HeyPocketConnector(prefs),
        IntegrationId.folderExport => _folder,
      };

  bool hasPendingWork(IntegrationId id) =>
      uploads?.hasPendingWorkFor(id.connectorName) ??
      (_credentialConnector(id).hasIncompleteDelivery ||
          SharingPolicy(prefs).hasPendingAuthorization(_credentialConnector(id)));

  /// Validation and confirmation do not mutate the saved account or its uploads.
  /// Once accepted, the application-owned lane freezes before any storage await.
  Future<bool> _replaceCredentials(IntegrationId id, int revision, Future<void> Function() install) async {
    if (!_current(id, revision)) return false;
    final pending = hasPendingWork(id);
    final hadCredentials = switch (id) {
      IntegrationId.omiCloud => prefs.omiRefreshToken.isNotEmpty || prefs.omiFirebaseApiKey.isNotEmpty,
      IntegrationId.heypocket => prefs.heypocketApiKey.isNotEmpty,
      IntegrationId.folderExport => prefs.folderExportTreeUri.isNotEmpty,
    };
    if (!hadCredentials && !pending) {
      await install();
      return _current(id, revision);
    }
    if (pending) {
      final confirmed = await confirmCredentialChange?.call(id) ?? false;
      if (!_current(id, revision)) return false;
      if (!confirmed) {
        if (id == IntegrationId.omiCloud) {
          _setOmiFields(prefs.omiRefreshToken, prefs.omiFirebaseApiKey);
        } else if (id == IntegrationId.heypocket) {
          heypocketController.removeListener(_hpChanged);
          heypocketController.text = prefs.heypocketApiKey;
          heypocketController.addListener(_hpChanged);
        }
        _state(id, hasConfiguration(id) ? IntegrationConnectionState.connected : IntegrationConnectionState.idle);
        return false;
      }
    }
    _transitioning.add(id);
    try {
      if (uploads != null) {
        final transition = uploads!.replaceCredentialsFor(id.connectorName, () async {
          if (_current(id, revision)) await install();
        });
        refreshPresentation(); // the shared lane is already frozen
        await transition;
      } else {
        // Isolated settings graphs have no upload worker. Production always
        // supplies the application's shared manager through IntegrationsPage.
        final connector = _credentialConnector(id);
        refreshPresentation();
        await SharingPolicy(prefs).beginCredentialTransition(connector, DateTime.now());
        await connector.clearIncompleteDelivery();
        if (_current(id, revision)) await install();
      }
      return _current(id, revision);
    } finally {
      _transitioning.remove(id);
      refreshPresentation();
    }
  }

  bool hidden(IntegrationId id) => !enabled(id) && prefs.hiddenIntegrations.contains(id.storageKey);
  List<IntegrationId> get visible => order.where((id) => !hidden(id)).toList();
  int get hiddenCount => order.where(hidden).length;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    prefs.integrationListOrder = order.map((id) => id.storageKey).toList();
    _revealEnabled();
    heypocketController.text = prefs.heypocketApiKey;
    omiRefreshTokenController.text = prefs.omiRefreshToken;
    omiFirebaseApiKeyController.text = prefs.omiFirebaseApiKey;
    heypocketController.addListener(_hpChanged);
    omiRefreshTokenController.addListener(_omiChanged);
    omiFirebaseApiKeyController.addListener(_omiChanged);
    integrationChanges?.addListener(refreshPresentation);
    for (final id in IntegrationId.values) {
      if (hasConfiguration(id)) unawaited(recheck(id));
    }
  }

  void _revealEnabled() {
    final normalized = order
        .where((id) => !enabled(id) && prefs.hiddenIntegrations.contains(id.storageKey))
        .map((id) => id.storageKey)
        .toList();
    if (normalized.join('|') != prefs.hiddenIntegrations.join('|')) prefs.hiddenIntegrations = normalized;
  }

  void refreshPresentation() {
    if (_disposed) return;
    _revealEnabled();
    notifyListeners();
  }

  void update(VoidCallback change) {
    if (_disposed) return;
    change();
    refreshPresentation();
  }

  /// Preference setters publish to SharedPreferences' synchronous cache before
  /// returning and retain their existing asynchronous durable writes. Notify
  /// the application owner only after that authoritative value is visible.
  void updateAutomation(VoidCallback change) {
    if (_disposed) return;
    change();
    onAutomationChanged?.call();
    refreshPresentation();
  }

  void setHidden(IntegrationId id, bool value) {
    if (_disposed || (value && enabled(id))) return;
    final keys = {...prefs.hiddenIntegrations};
    value ? keys.add(id.storageKey) : keys.remove(id.storageKey);
    prefs.hiddenIntegrations = keys.toList();
    refreshPresentation();
  }

  void reorder(int oldIndex, int newIndex) {
    if (_disposed) return;
    final ids = order;
    if (newIndex > oldIndex) newIndex--;
    ids.insert(newIndex, ids.removeAt(oldIndex));
    prefs.integrationListOrder = ids.map((id) => id.storageKey).toList();
    refreshPresentation();
  }

  int _next(IntegrationId id) => _revisions[id] = (_revisions[id] ?? 0) + 1;
  bool _current(IntegrationId id, int revision) => !_disposed && _revisions[id] == revision;
  void _state(IntegrationId id, IntegrationConnectionState state) {
    if (_disposed) return;
    _states[id] = state;
    refreshPresentation();
  }

  /// Serializes saves and disconnects, so clearing credentials wins over a save
  /// already in secure storage. Revision checks also discard stale HTTP results.
  Future<void> _write(IntegrationId id, Future<void> Function() action) {
    final next = (_writes[id] ?? Future<void>.value()).catchError((Object _) {}).then((_) => action());
    _writes[id] = next;
    return next;
  }

  void _disable(IntegrationId id) {
    switch (id) {
      case IntegrationId.heypocket:
        prefs.heypocketEnabled = false;
      case IntegrationId.omiCloud:
        prefs.omiEnabled = false;
      case IntegrationId.folderExport:
        prefs.folderExportEnabled = false;
    }
    onCancelUploads?.call(id.connectorName);
  }

  Future<void> recheck(IntegrationId id) async {
    if (_disposed || isChangingCredentials(id) || !hasConfiguration(id)) return;
    final revision = _next(id);
    final hpKey = prefs.heypocketApiKey;
    final rt = prefs.omiRefreshToken;
    final ak = prefs.omiFirebaseApiKey;
    final tree = prefs.folderExportTreeUri;
    _state(id, IntegrationConnectionState.checking);
    final valid = switch (id) {
      IntegrationId.heypocket => await _checkHeyPocket(hpKey).catchError((_) => true),
      IntegrationId.omiCloud => await _checkOmi(rt, ak).catchError((_) => true),
      IntegrationId.folderExport => await FolderExportConnector.defaultBackend.hasAccess(tree).catchError((_) => false),
    };
    if (!_current(id, revision)) return;
    final same = switch (id) {
      IntegrationId.heypocket => prefs.heypocketApiKey == hpKey,
      IntegrationId.omiCloud => prefs.omiRefreshToken == rt && prefs.omiFirebaseApiKey == ak,
      IntegrationId.folderExport => prefs.folderExportTreeUri == tree,
    };
    if (!same) {
      if (hasConfiguration(id)) {
        unawaited(recheck(id));
      } else {
        _state(id, IntegrationConnectionState.idle);
      }
      return;
    }
    if (!valid && id != IntegrationId.folderExport) _disable(id);
    _state(id, valid ? IntegrationConnectionState.connected : IntegrationConnectionState.error);
    if (valid && id == IntegrationId.omiCloud) unawaited(OmiApiClient.refreshSpeechProfileStatus());
  }

  void _hpChanged() {
    if (isDisconnecting(IntegrationId.heypocket) || isChangingCredentials(IntegrationId.heypocket)) return;
    final key = heypocketController.text;
    if (key == prefs.heypocketApiKey) return; // selection/focus changes are not credential edits
    final revision = _next(IntegrationId.heypocket);
    _hpDebounce?.cancel();
    if (key.isEmpty) {
      // An incomplete edit is a draft. Disconnect has its own confirmed action.
      _state(IntegrationId.heypocket, IntegrationConnectionState.idle);
    } else if (key.length > 10 && key.startsWith('pk_')) {
      _hpDebounce = Timer(const Duration(milliseconds: 800), () => _testHp(key, revision));
    } else if (connection(IntegrationId.heypocket) == IntegrationConnectionState.checking) {
      _state(
          IntegrationId.heypocket,
          hasConfiguration(IntegrationId.heypocket)
              ? IntegrationConnectionState.connected
              : IntegrationConnectionState.idle);
    }
  }

  Future<void> _testHp(String key, int revision) async {
    const id = IntegrationId.heypocket;
    if (!_current(id, revision)) return;
    _state(id, IntegrationConnectionState.checking);
    final bool valid;
    try {
      valid = await _checkHeyPocket(key);
    } catch (_) {
      if (_current(id, revision)) _state(id, IntegrationConnectionState.error);
      return;
    }
    try {
      if (!_current(id, revision)) return;
      if (!valid) {
        _state(id, IntegrationConnectionState.error);
        return;
      }
      await _write(id, () async {
        if (!_current(id, revision)) return;
        if (prefs.heypocketApiKey != key &&
            !await _replaceCredentials(id, revision, () => prefs.setHeypocketApiKey(key))) {
          return;
        }
        if (!_current(id, revision)) return;
        prefs.heypocketEnabled = true;
        _state(id, IntegrationConnectionState.connected);
      });
    } catch (_) {
      if (!_current(id, revision)) return;
      _disable(id);
      _state(id, IntegrationConnectionState.error);
    }
  }

  void _omiChanged() {
    if (isDisconnecting(IntegrationId.omiCloud) || isChangingCredentials(IntegrationId.omiCloud)) return;
    final rt = omiRefreshTokenController.text.trim();
    final ak = omiFirebaseApiKeyController.text.trim();
    if (rt == prefs.omiRefreshToken && ak == prefs.omiFirebaseApiKey) return;
    final revision = _next(IntegrationId.omiCloud);
    _omiDebounce?.cancel();
    if (rt.isEmpty || ak.isEmpty) {
      _state(IntegrationId.omiCloud, IntegrationConnectionState.idle);
    } else {
      _omiDebounce = Timer(const Duration(milliseconds: 800), () => _testOmi(rt, ak, revision));
    }
  }

  Future<void> _testOmi(String rt, String ak, int revision) async {
    const id = IntegrationId.omiCloud;
    if (!_current(id, revision)) return;
    _state(id, IntegrationConnectionState.checking);
    final bool valid;
    try {
      valid = await _checkOmi(rt, ak);
    } catch (_) {
      if (!_current(id, revision)) return;
      // An unavailable check leaves the saved connection and its uploads intact.
      _state(id, IntegrationConnectionState.error);
      return;
    }
    if (!_current(id, revision)) return;
    if (!valid) {
      _state(id, IntegrationConnectionState.error);
      return;
    }
    try {
      await _write(id, () async {
        if (!_current(id, revision)) return;
        final isNew = prefs.omiRefreshToken != rt || prefs.omiFirebaseApiKey != ak;
        if (isNew &&
            !await _replaceCredentials(id, revision, () async {
              await OmiApiClient.replaceCredentials(
                  refreshToken: rt, apiKey: ak, isCurrent: () => _current(id, revision));
            })) {
          return;
        }
        if (isNew) prefs.omiEnabled = true;
        _state(id, IntegrationConnectionState.connected);
      });
    } catch (_) {
      if (!_current(id, revision)) return;
      _disable(id);
      _state(id, IntegrationConnectionState.error);
    }
  }

  Future<void> acceptOmiLogin(Map<String, String> result) async {
    const id = IntegrationId.omiCloud;
    if (_disposed || isDisconnecting(id) || isChangingCredentials(id)) return;
    final revision = _next(id);
    _omiDebounce?.cancel();
    final rt = result['refreshToken'];
    final ak = result['apiKey'];
    if (rt == null || ak == null) return;
    _state(id, IntegrationConnectionState.checking);
    try {
      final valid = await _checkOmi(rt, ak);
      if (!_current(id, revision)) return;
      if (!valid) {
        _state(id, IntegrationConnectionState.error);
        return;
      }
      await _write(id, () async {
        if (!_current(id, revision)) return;
        final token = result['idToken'] ?? '';
        if (!await _replaceCredentials(id, revision, () async {
          await OmiApiClient.replaceCredentials(
            refreshToken: rt,
            apiKey: ak,
            idToken: token,
            expiresIn: int.tryParse(result['expiresIn'] ?? '') ?? 3600,
            isCurrent: () => _current(id, revision),
          );
        })) {
          return;
        }
        prefs.omiAuthUid = result['uid'] ?? '';
        prefs.omiAuthEmail = result['email'] ?? '';
        prefs.omiConnectedViaFallback = result['flow'] == 'fallback';
        prefs.omiEnabled = true;
        _setOmiFields(rt, ak);
        _state(id, IntegrationConnectionState.connected);
      });
    } catch (_) {
      if (_current(id, revision)) _state(id, IntegrationConnectionState.error);
    }
  }

  void _setOmiFields(String rt, String ak) {
    omiRefreshTokenController.removeListener(_omiChanged);
    omiFirebaseApiKeyController.removeListener(_omiChanged);
    omiRefreshTokenController.text = rt;
    omiFirebaseApiKeyController.text = ak;
    omiRefreshTokenController.addListener(_omiChanged);
    omiFirebaseApiKeyController.addListener(_omiChanged);
  }

  Future<void> chooseFolder() async {
    if (_disposed) return;
    const id = IntegrationId.folderExport;
    final revision = _next(id);
    final previous = connection(id);
    _state(id, IntegrationConnectionState.checking);
    try {
      final picked = await FolderExportConnector.defaultBackend.pickFolder();
      if (!_current(id, revision)) return;
      if (picked == null) {
        _state(id, previous);
        return;
      }
      await _write(id, () async {
        if (!_current(id, revision)) return;
        if (picked.treeUri != prefs.folderExportTreeUri) onCancelUploads?.call(id.connectorName);
        await _folder.useFolder(picked);
        if (_current(id, revision)) _state(id, IntegrationConnectionState.connected);
      });
    } catch (_) {
      if (_current(id, revision)) _state(id, previous);
      rethrow;
    }
  }

  Future<void> disconnect(IntegrationId id) async {
    if (_disposed || isDisconnecting(id)) return;
    _disconnecting.add(id);
    _next(id);
    if (id == IntegrationId.heypocket) _hpDebounce?.cancel();
    if (id == IntegrationId.omiCloud) _omiDebounce?.cancel();
    _disable(id);
    _state(id, IntegrationConnectionState.checking);
    try {
      await _write(id, () async {
        switch (id) {
          case IntegrationId.heypocket:
            if (uploads != null) {
              await uploads!.replaceCredentialsFor(id.connectorName, () => prefs.setHeypocketApiKey(''));
            } else {
              await SharingPolicy(prefs).beginCredentialTransition(_credentialConnector(id), DateTime.now());
              await _credentialConnector(id).clearIncompleteDelivery();
              await prefs.setHeypocketApiKey('');
            }
          case IntegrationId.omiCloud:
            if (uploads != null) {
              await uploads!.replaceCredentialsFor(id.connectorName, OmiApiClient.signOut);
            } else {
              await SharingPolicy(prefs).beginCredentialTransition(_credentialConnector(id), DateTime.now());
              await _credentialConnector(id).clearIncompleteDelivery();
              await OmiApiClient.signOut();
            }
            prefs.omiConnectedViaFallback = false;
          case IntegrationId.folderExport:
            await _folder.removeFolder();
        }
        if (_disposed) return;
        if (id == IntegrationId.heypocket) {
          heypocketController.removeListener(_hpChanged);
          heypocketController.clear();
          heypocketController.addListener(_hpChanged);
        } else if (id == IntegrationId.omiCloud) {
          _setOmiFields('', '');
          showOmiManual = false;
        }
        _state(id, IntegrationConnectionState.idle);
      });
    } catch (_) {
      _state(id, IntegrationConnectionState.error);
      rethrow;
    } finally {
      _disconnecting.remove(id);
      refreshPresentation();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    integrationChanges?.removeListener(refreshPresentation);
    _hpDebounce?.cancel();
    _omiDebounce?.cancel();
    heypocketController.dispose();
    omiRefreshTokenController.dispose();
    omiFirebaseApiKeyController.dispose();
    super.dispose();
  }
}

class IntegrationStatusIndicator extends StatelessWidget {
  const IntegrationStatusIndicator({super.key, required this.model, required this.id});
  final IntegrationSettingsModel model;
  final IntegrationId id;

  @override
  Widget build(BuildContext context) {
    final state = model.connection(id);
    final status = state == IntegrationConnectionState.checking
        ? 'Checking'
        : state == IntegrationConnectionState.error
            ? 'Needs attention'
            : !model.hasConfiguration(id)
                ? 'Not configured'
                : model.enabled(id)
                    ? 'Enabled'
                    : 'Disabled';
    final color = switch (status) {
      'Needs attention' => Colors.redAccent,
      'Enabled' => Colors.green,
      'Disabled' => Colors.amber,
      _ => Colors.grey.shade600,
    };
    return Semantics(
      label: '${id.title}: $status',
      child: Tooltip(
        message: status,
        child: status == 'Checking'
            ? const SizedBox(
                width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey))
            : Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ),
    );
  }
}
