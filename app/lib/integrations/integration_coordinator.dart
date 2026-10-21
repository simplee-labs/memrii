import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connector_registry.dart';
import 'package:omi/integrations/integration_upload_manager.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:omi/utils/logger.dart';

/// A settled archive snapshot. UI filters never restrict automation's source.
class IntegrationSnapshot {
  const IntegrationSnapshot(this.batches, this.markers);
  final List<Batch> batches;
  final List<MarkerConversation> markers;
}

/// Application-lifetime integration owner, started before native's Dart-ready signal.
/// Controllers borrow [uploads]; they never start or dispose this service.
/// Dependencies are explicit so an isolated graph works without widgets or plugins.
class IntegrationCoordinator extends ChangeNotifier {
  IntegrationCoordinator({
    required this.connectors,
    required SharedPreferencesUtil prefs,
    required Future<IntegrationSnapshot> Function() loadRecordings,
    required Listenable recordingChanges,
    required bool Function() isProcessing,
    required bool Function() isPipelineIdle,
    required Future<bool> Function() checkOnWifi,
    AutomationPolicy? automation,
    Stream<Object?>? connectivityChanges,
    void Function(String reason)? acquireWake,
    void Function(String reason)? releaseWake,
    void Function(String text)? showUploadNotification,
    void Function()? settleNotification,
    Future<void> Function(Conversation)? convertToPassthrough,
    this.pollInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  })  : _loadRecordings = loadRecordings,
        _recordingChanges = recordingChanges,
        _isProcessing = isProcessing,
        _connectivityChanges = connectivityChanges {
    uploads = IntegrationUploadManager(
      connectors: connectors,
      prefs: prefs,
      automation: automation,
      batchesProvider: () => _snapshot.batches,
      markersProvider: () => _snapshot.markers,
      isDisposed: () => _disposed,
      isPipelineIdle: isPipelineIdle,
      // Queued automation also waits for an authoritative reload (including
      // marker/rule changes); connectivity must not unpark a stale snapshot.
      isProcessing: () => isProcessing() || _dirty,
      notifyUi: _notify,
      acquireWake: acquireWake ?? (_) {},
      releaseWake: releaseWake ?? (_) {},
      showUploadNotification: showUploadNotification ?? (_) {},
      settleNotification: settleNotification ?? () {},
      setPendingSnack: (message) {
        _pendingSnack = message;
        _notify();
      },
      checkOnWifi: checkOnWifi,
      convertToPassthrough: convertToPassthrough ?? _convertToPassthrough,
      now: now,
    );
  }

  /// Production wiring only. ServiceManager owns this instance and its teardown.
  factory IntegrationCoordinator.application({
    required SharedPreferencesUtil prefs,
    required bool Function() isPipelineIdle,
  }) {
    var wakeHeld = false;
    return IntegrationCoordinator(
      connectors: ConnectorRegistry.all(prefs),
      prefs: prefs,
      recordingChanges: RecordingsManager.recordingsChangeNotifier,
      isProcessing: () => RecordingsManager.recordingsUnsettled,
      isPipelineIdle: isPipelineIdle,
      loadRecordings: () async {
        final manager = RecordingsManager();
        final batches = await manager.getBatchesWithRetention();
        return IntegrationSnapshot(batches, await manager.getMarkerConversations());
      },
      checkOnWifi: () async => (await Connectivity().checkConnectivity()).contains(ConnectivityResult.wifi),
      connectivityChanges: Connectivity().onConnectivityChanged,
      acquireWake: (_) {
        if (wakeHeld) return;
        wakeHeld = true;
        // CPU/background assertion, independent of an Activity or screen wakelock.
        if (Platform.isAndroid || Platform.isIOS) unawaited(BleHostApi().acquireProcessingWakeLock());
      },
      releaseWake: (_) {
        if (!wakeHeld) return;
        wakeHeld = false;
        if (Platform.isAndroid || Platform.isIOS) unawaited(BleHostApi().releaseProcessingWakeLock());
      },
      showUploadNotification: (text) => unawaited(SyncNotification.uploading(text)),
      settleNotification: () {
        if (prefs.backgroundSyncIntervalMinutes > 0) {
          unawaited(SyncNotification.idle());
        } else {
          unawaited(SyncNotification.clear());
        }
      },
    );
  }

  final List<Connector> connectors;
  late final IntegrationUploadManager uploads;
  final Future<IntegrationSnapshot> Function() _loadRecordings;
  final Listenable _recordingChanges;
  final bool Function() _isProcessing;
  final Stream<Object?>? _connectivityChanges;
  final Duration pollInterval;
  IntegrationSnapshot _snapshot = const IntegrationSnapshot([], []);
  final Map<String, String> _configuration = {};
  bool? _lastPro;
  bool _started = false;
  bool _disposed = false;
  bool _dirty = false;
  int _revision = 0;
  Future<void>? _refresh;
  Timer? _poll;
  StreamSubscription<Object?>? _connectivity;
  String? _pendingSnack;
  final _lifecycleReady = Completer<void>();
  Future<void> _connectorStartup = Future.value();
  Future<void> _appOpenTail = Future.value();
  int? _lastUiGeneration;

  String? consumePendingSnack() {
    final message = _pendingSnack;
    _pendingSnack = null;
    return message;
  }

  /// Subscribe synchronously before any asynchronous load; a startup completion
  /// cannot fall into a gap between discovery and listener registration.
  /// With [waitForInitialDiscovery] false, completion means listeners are registered;
  /// discovery continues independently and automation waits for settled metadata.
  Future<void> start({bool waitForInitialDiscovery = true}) {
    if (_disposed) throw StateError('Integration service is disposed');
    if (_started) return waitForInitialDiscovery ? _refresh ?? Future.value() : Future.value();
    _started = true;
    _recordingChanges.addListener(_recordingsChanged);
    _connectivity = _connectivityChanges?.listen((_) {
      if (!_disposed) uploads.pumpAllLanes();
    });
    _lastPro = uploads.automation.entitlements.isPro;
    _captureConfiguration();
    _poll = Timer.periodic(pollInterval, (_) => _pollState());
    _connectorStartup = Future.wait(connectors.map((connector) async {
      try {
        await connector.onServicesStarted();
      } catch (e) {
        Logger.error('Integration service: connector startup failed: $e');
      }
    }));
    _lifecycleReady.complete();
    final discovery = recordingsChanged();
    return waitForInitialDiscovery ? discovery : Future.value();
  }

  /// Native foreground generations count UI opens, independently of widget builds.
  /// Startup's snapshot query and its live event share a generation, so cold
  /// startup runs once. Hooks wait for service initialization without delaying
  /// native readiness; later opens are serialized even if a check is still running.
  Future<void> onAppOpened({int? uiGeneration}) {
    if (_disposed) return Future.value();
    if (uiGeneration != null) {
      if (_lastUiGeneration != null && uiGeneration <= _lastUiGeneration!) return _appOpenTail;
      _lastUiGeneration = uiGeneration;
    }
    return _appOpenTail = _appOpenTail.then((_) async {
      await _lifecycleReady.future;
      await _connectorStartup;
      if (_disposed) return;
      await Future.wait(connectors.map((connector) async {
        try {
          await connector.onAppOpened();
        } catch (e) {
          Logger.error('Integration service: app-open check failed: $e');
        }
      }));
      // Successful validation and outages do not change the archive. Reuse the
      // authoritative configuration/entitlement invalidation path only when
      // eligibility changed (including a confirmed credential rejection).
      if (!_disposed) _pollState();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _recordingsChanged() => unawaited(recordingsChanged());

  /// All UI/background triggers converge here. Loads are serialized; a change
  /// during a load invalidates that snapshot before any authorization is minted.
  /// Dirty work survives processing and failed loads and is retried without a UI.
  Future<void> recordingsChanged() {
    if (_disposed) return Future.value();
    _dirty = true;
    _revision++;
    return _refresh ??= _refreshRecordings().whenComplete(() => _refresh = null);
  }

  Future<void> _refreshRecordings() async {
    while (_dirty && !_disposed) {
      if (_isProcessing()) return;
      final revision = _revision;
      try {
        final next = await _loadRecordings();
        if (_disposed) return;
        if (_isProcessing()) return;
        if (revision != _revision) continue;
        _snapshot = next;
        _dirty = false;
        uploads.tryAutoUploadAll();
      } catch (e) {
        Logger.error('Integration service: recording refresh failed: $e');
        return; // remain dirty; retry via the service timer
      }
    }
  }

  void automationChanged() {
    if (_disposed) return;
    // UI listeners may run synchronously when queues change. Mark the archive
    // dirty first so they cannot pump automation using the previous snapshot.
    _dirty = true;
    // Withdraw grants immediately; discovery then reloads authoritative metadata.
    uploads.automationChanged(discover: false);
    _recordingsChanged();
  }

  String _configurationOf(Connector c) => '${c.credentialFingerprint}|${c.isConfigured}|${c.isAutomaticSendingEnabled}';
  void _captureConfiguration() {
    for (final c in connectors) {
      _configuration[c.name] = _configurationOf(c);
    }
  }

  void _pollState() {
    if (_disposed) return;
    final pro = uploads.automation.entitlements.isPro;
    final changed = pro != _lastPro || connectors.any((c) => _configuration[c.name] != _configurationOf(c));
    if (changed) {
      _lastPro = pro;
      _captureConfiguration();
      automationChanged();
      _notify();
    } else if (_refresh == null &&
        (_dirty || uploads.deferredSweepReady || uploads.retrySweepReady) &&
        !_isProcessing()) {
      _recordingsChanged();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_lifecycleReady.isCompleted) _lifecycleReady.complete();
    if (_started) _recordingChanges.removeListener(_recordingsChanged);
    _poll?.cancel();
    unawaited(_connectivity?.cancel());
    uploads.dispose();
    super.dispose();
  }

  // Moved from RecordingsController; delivery/retention guards are unchanged.
  Future<void> _convertToPassthrough(Conversation conversation) async {
    try {
      final filePath = conversation.file.path;
      final fileDir = conversation.file.parent.path;
      final audioFileName = filePath.split('/').last;
      final basePath = filePath.contains('.') ? filePath.substring(0, filePath.lastIndexOf('.')) : filePath;
      final metaFile = File('$basePath.meta');
      if (!await metaFile.exists()) {
        Logger.error('Passthrough: Aborting — no .meta sidecar found for $filePath');
        return;
      }
      if (!uploads.deliveredEverywhereAvailable(conversation)) return;
      final bytes = await metaFile.readAsBytes();
      if (bytes.length >= 417) {
        final keyLen = bytes[416];
        final flagOffset = 417 + keyLen;
        final alreadyPassthrough = flagOffset < bytes.length && (bytes[flagOffset] & 0x01) != 0;
        if (!alreadyPassthrough) {
          if (flagOffset < bytes.length) {
            final out = Uint8List.fromList(bytes);
            out[flagOffset] |= 0x01;
            await metaFile.writeAsBytes(out);
          } else {
            final out = Uint8List(flagOffset + 1)..setRange(0, bytes.length, bytes);
            out[flagOffset] = 0x01;
            await metaFile.writeAsBytes(out);
          }
        }
      }
      if (await conversation.file.exists()) await conversation.file.delete();
      try {
        final edlFiles = await Directory(fileDir)
            .list()
            .where((e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'))
            .cast<File>()
            .toList();
        for (final edl in edlFiles) {
          try {
            final json = jsonDecode(await edl.readAsString()) as Map<String, dynamic>;
            if (json['segmentFilename'] == audioFileName) await edl.delete();
          } catch (_) {}
        }
      } catch (_) {}
      RecordingsManager.notifyRecordingsChanged();
    } catch (e) {
      Logger.error('Passthrough: Failed to convert conversation: $e');
    }
  }
}
