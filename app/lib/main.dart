import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/ui_lifecycle.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:provider/provider.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register the BLE Flutter API handler so native can call into Dart
  // (scan results, connection events, characteristic updates, etc.)
  BleFlutterApi.setUp(BleBridge.instance);

  initOpus(await opus_flutter.load());
  await SharedPreferencesUtil.init();
  // Bring the flat processing prefs into line with the recording mode.
  //
  // `manualMode` is only a label; the processor reads the flat vad* prefs, and
  // the two carried INDEPENDENT defaults. A fresh install is labelled Manual
  // (manualMode defaults true, matching the firmware's own DEFAULT_VAD_THRESHOLD
  // of 32769) while those flat prefs still hold auto-shaped legacy defaults:
  // Silero on, a 120 s silence split, a 3 s noise filter and a 60-minute cap. So
  // until the user first opened Recording Settings and saved, every manual
  // recording was cut by auto's rules — split at two minutes of quiet, quiet
  // stretches filed as ghost rows, and hard-capped at an hour. Nothing else
  // corrected it: the on-connect adopt only fires when the mode actually
  // CHANGES, and on a fresh install it already matches.
  //
  // Idempotent for anyone who has saved — it rewrites the flat prefs from the
  // same per-mode snapshot the settings page wrote them from — and corrective
  // for anyone who has not. Safe to run unconditionally because _saveSettings is
  // the only other writer of these keys.
  SharedPreferencesUtil().applyRecordingModeDefaults(SharedPreferencesUtil().manualMode);
  // Ask native whether a screen is attached BEFORE anything that needs one.
  //
  // Dart cannot tell on its own: its lifecycleState is null until the first lifecycle
  // event, and in a process with no Activity that null never resolves, so "no answer yet"
  // and "no screen at all" are indistinguishable from here. Only native knows.
  const systemChannel = MethodChannel('me.memrii.app/system');
  bool? uiAttached;
  int? initialAttachmentGeneration;
  try {
    uiAttached = await systemChannel.invokeMethod<bool>('hasUi');
  } catch (e) {
    // Null keeps the historical assume-foreground behaviour below.
    Logger.error('main: could not ask native whether a UI is attached ($e)');
  }

  try {
    if (uiAttached == true) {
      initialAttachmentGeneration = await systemChannel.invokeMethod<int>('uiAttachmentGeneration');
    }
  } catch (_) {
    // Platforms without the Android attachment bridge use startup work below.
  }

  // Permissions need an Activity to put a dialog on, and permission_handler THROWS
  // without one — `activity == null` is an explicit errorCallback in its PermissionManager,
  // which surfaces here as a PlatformException. main() runs headless now (the engine
  // outlives MainActivity, so WorkManager can start this process with no Activity ever),
  // and an uncaught throw here would kill main() before ServiceManager, before
  // DeviceProvider, and before the readiness signal — leaving the background sync this
  // whole change exists for with nothing to run. Asked for on the next attach instead.
  if (uiAttached != false) await _requestPermissionsSafely();

  await ServiceManager.init();
  await ServiceManager.instance().start();

  // The Flutter engine now outlives MainActivity (created and cached by MyApp on the
  // Android side, so an OS memory-reclaim of the Activity no longer takes Dart with it —
  // which is what lets a scheduled background sync find something to run). Three
  // consequences are handled below.

  // 1. DeviceProvider is constructed HERE, not by the widget tree, and that is
  //    load-bearing. Its constructor registers BleBridge.backgroundSyncRequestedCallback
  //    — the entry point for every scheduled sync. It used to be built by a LAZY
  //    ChangeNotifierProvider, i.e. by the first widget that read it, which was fine
  //    while the engine died with the Activity: no UI meant no Dart at all. Now a
  //    process can be started by WorkManager with no Activity ever attached, and with no
  //    view there is nothing to drive a frame, so the tree may never build. That would
  //    leave native reporting Dart alive, delivering the request, and BleBridge calling
  //    a null callback — a sync that reports success having done nothing, which is worse
  //    than the failure it replaced because it is silent.
  //
  final deviceProvider = DeviceProvider(uiAttached: uiAttached);

  // 2. Startup cleanup is process work: it can delete temporary extraction
  // files and must not race a background processor merely because an Activity
  // appears. Genuine attachments run only permissions and safe recovery below.
  final startupWork = _launchHousekeeping();
  final uiLifecycle = AppUiLifecycle(
    channel: systemChannel,
    startupWork: startupWork,
    initialAttachmentGeneration: initialAttachmentGeneration,
    onAttached: _onUiAttached,
    onForegrounded: (generation) => ServiceManager.instance().integrations.onAppOpened(uiGeneration: generation),
  )..listen();

  // Subscribe before recovery/discovery; snapshot recovery below also covers a
  // headless-to-UI attach that happened before the handler was installed.
  await startupWork;
  await ServiceManager.instance().integrations.start(waitForInitialDiscovery: false);

  // Snapshot/live generations deduplicate attachment work and connector checks.
  // recover() only waits for native state, never permission/network completion.
  await uiLifecycle.recover(assumeUiOnUnsupportedPlatform: uiAttached != false);

  // 3. Readiness is DART's to declare, not the engine's to assume. Native used to set
  //    isFlutterAlive the moment it created the engine, which is synchronously before a
  //    single line of Dart has run — fine while the engine only ever existed alongside an
  //    Activity, but a WorkManager-started process would otherwise be told Dart is ready
  //    and post a sync request at an engine with no Pigeon handler and no DeviceProvider.
  //    Everything the sync path needs is up by this point.
  try {
    await systemChannel.invokeMethod('dartReady');
  } catch (e) {
    Logger.error('main: could not signal readiness to native ($e)');
  }

  runApp(MyApp(deviceProvider: deviceProvider));
}

/// A genuinely new Activity attachment may need UI permissions. Foregrounding
/// an already-attached Activity never dispatches this work. Startup/snapshot/live
/// duplicates are suppressed by attachment generation, rather than a time delay.
Future<void> _onUiAttached() async {
  await _requestPermissionsSafely();
  await _attachmentHousekeeping();
}

/// [SyncNotification.requestPermissions] can throw when no Activity is attached, and a
/// permission prompt is never worth failing a launch over.
Future<void> _requestPermissionsSafely() async {
  try {
    await SyncNotification.requestPermissions();
  } catch (e) {
    Logger.error('main: permission request failed ($e)');
  }
}

/// Process startup only: rescue interrupted extraction and remove orphaned
/// encoding output before integration discovery/background readiness.
Future<void> _launchHousekeeping() async {
  try {
    await RecordingsManager.cleanUpIncompleteExtraction();
    await RecordingsManager.cleanupOrphanedTempFiles();
  } catch (e) {
    Logger.error('main: startup cleanup failed: $e');
  }
  await _attachmentHousekeeping();
}

/// Safe on startup and genuine attachment: stamp logs and reclaim expired
/// discarded bins. runRecoverySweep yields while processing is active.
Future<void> _attachmentHousekeeping() async {
  // Version stamp, heading this open's log lines. Firmware is the last-read value
  // (nothing is connected yet); the connect that follows confirms it with a
  // device_version line of its own.
  //
  // Read from the flat lastLoggedFirmwareRevision string and NOT from `btDevice`, whose
  // getter jsonDecodes a stored blob — on the first call this still runs before runApp(),
  // so anything that throws is an app that will not start at all. The cost is that the
  // very first launch on a build says "unknown" until the first connect populates it.
  unawaited(DebugLogManager.logAppStart(
    lastKnownFirmware: SharedPreferencesUtil().lastLoggedFirmwareRevision,
  ));
  try {
    await RecordingsManager.runRecoverySweep();
  } catch (e) {
    Logger.error('main: launch housekeeping failed: $e');
  }
}

class MyApp extends StatefulWidget {
  /// Built in [main] before runApp — see the note there. Passed in rather than created
  /// by the provider so that it exists whether or not a UI ever attaches.
  final DeviceProvider deviceProvider;

  const MyApp({super.key, required this.deviceProvider});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider.value(value: widget.deviceProvider)],
      child: MaterialApp(
        title: 'memrii',
        theme: ThemeData.dark(),
        home: const RecordingsPage(),
      ),
    );
  }
}
