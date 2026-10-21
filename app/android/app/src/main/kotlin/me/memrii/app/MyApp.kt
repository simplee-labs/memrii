package me.memrii.app

import android.app.Activity
import android.app.Application
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Owns one cached Flutter engine for the process lifetime. MainActivity adopts it without destroying it on
 * detach, so reclaiming a background Activity leaves Dart available to scheduled syncs.
 *
 * Cold starts can reach native wake callbacks before Dart registers its handlers; DeviceProvider must adopt
 * that pending cycle. Keep a single engine so foreground and headless work share BLE ownership.
 *
 * Channels registered here must be engine-scoped and Activity-free. UI-only operations use currentActivity,
 * which is null while no Activity is attached.
 */
class MyApp : Application() {
    companion object {
        private const val TAG = "OmiBle.MyApp"

        /** Cache key MainActivity adopts the engine by. */
        const val ENGINE_ID = "omi.main.engine"

        /**
         * The foreground Activity, or null when there is no UI attached.
         *
         * Volatile and nulled on detach: this is read from background threads, and
         * holding a destroyed Activity here would leak the whole view hierarchy for as
         * long as the process lives — which, with the foreground service running, is
         * potentially days.
         */
        @Volatile
        var currentActivity: Activity? = null

        // Main-thread UI lifecycle state survives Activity recreation with the engine.
        var uiOpenGeneration: Int = 0
        var uiAttachmentGeneration: Int = 0
        var uiForeground: Boolean = false

        /** Kotlin -> Dart signalling channel; also carries `moveTaskToBack` the other way. */
        @Volatile
        var systemChannel: MethodChannel? = null

        /**
         * Wires the platform APIs that belong to the engine rather than to any Activity.
         *
         * [BleHostApiImpl] is constructed with the application context and an Activity
         * *supplier*, not an Activity: the calls a background sync makes (manage/unmanage
         * a device, reschedule, take a wake lock) resolve against the application context
         * and work with no UI, while the genuinely Activity-bound ones (companion-device
         * pairing, permission dialogs) return early exactly as before when there is
         * nothing to show a dialog on.
         *
         * Callable from MainActivity too, for the fallback where the pre-warm failed and
         * the Activity had to build its own engine — otherwise that engine would come up
         * with no BLE, no encoder and no VAD runner at all.
         */
        fun registerEngineScopedApis(app: Application, engine: FlutterEngine) {
            OmiBleManager.initialize(app)
            val messenger = engine.dartExecutor.binaryMessenger
            val flutterApi = BleFlutterApi(messenger)
            val hostApi = BleHostApiImpl({ currentActivity }, flutterApi, app.applicationContext)
            BleHostApi.setUp(messenger, hostApi)
            OmiBleManager.bleHostApi = hostApi

            AacEncoderChannel(messenger)
            AudioCropChannel(messenger)

            // Save to Folder copies from the auto-upload sweep, which runs in background
            // syncs — engine-scoped for the same reason as the encoder.
            FolderExportChannel(app.applicationContext, messenger)

            // Android-only; iOS stays on the per-window fallback.
            //
            // Deliberately never destroyed. It used to be torn down in
            // MainActivity.onDestroy on a swipe-away, which was right while it belonged to
            // the Activity; it belongs to the engine now, and destroying it would leave
            // every later BACKGROUND sync without a batch runner — the exact runs this
            // change exists to enable. The expensive part, the ORT session, is released by
            // Dart's own `dispose` after each processing run; what stays resident is an
            // idle worker thread.
            VadBatchRunner(messenger)

            // Lets the root Flutter page minimize the app on Back instead of finishing
            // MainActivity — finishing tears down the BLE foreground service. With no
            // Activity attached there is nothing to minimize, so this reports false rather
            // than failing: Dart treats that as "could not minimize" and does nothing.
            systemChannel = MethodChannel(messenger, "me.memrii.app/system").apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "moveTaskToBack" -> result.success(currentActivity?.moveTaskToBack(true) ?: false)
                        // Whether a UI is attached RIGHT NOW. Dart asks at startup because
                        // its own lifecycleState is null until the first lifecycle event,
                        // and in a process with no Activity that null never resolves — so
                        // "no answer yet" and "no screen at all" are indistinguishable from
                        // Dart's side. This is the difference.
                        "hasUi" -> result.success(currentActivity != null)
                        "uiAttachmentGeneration" -> result.success(if (currentActivity != null) uiAttachmentGeneration else null)
                        "uiOpenGeneration" -> result.success(if (uiForeground) uiOpenGeneration else null)
                        "dartReady" -> {
                            OmiBleManager.isFlutterAlive = true
                            Log.d(TAG, "dartReady: Dart is up — background wake paths may deliver")
                            // Diagnostic records queue while Dart is down and are otherwise
                            // only drained by the NEXT record to arrive, so anything captured
                            // during startup — or during an outage that then went quiet —
                            // would sit in the queue until some unrelated BLE event happened.
                            // Boot-time records are exactly the ones with no successor.
                            WedgeDiagnostics.flushPendingRecords()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Re-register the WorkManager periodic sync task on every app start so
        // the interval stays current (UPDATE policy is idempotent if unchanged).
        BackgroundSyncWorker.scheduleFromPrefs(this)

        // Wrapped so a failure here DEGRADES instead of bricking the app. An exception out
        // of Application.onCreate takes the whole process down at launch, and MainActivity
        // would then fail its cache lookup anyway. If the failure leaves no cached engine,
        // MainActivity creates one; it registers APIs when bleHostApi is null.
        // Cache insertion precedes API registration, so a later failure may leave a
        // cached engine. Treat readiness as degraded, not guaranteed by this catch.
        try {
            val engine = FlutterEngine(this)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            registerEngineScopedApis(this, engine)
            Log.d(TAG, "onCreate: Flutter engine created and cached as $ENGINE_ID")
        } catch (e: Exception) {
            Log.e(
                TAG,
                "onCreate: could not pre-warm the Flutter engine — falling back to an " +
                    "Activity-owned engine, background sync will not run: $e"
            )
        }

        // isFlutterAlive is deliberately NOT set here. Creating the engine and running its
        // entrypoint are not the same thing: executeDartEntrypoint only schedules main(),
        // so at this instant no Pigeon handler is registered and no DeviceProvider exists.
        // Dart calls `dartReady` when the sync path is actually up (see main.dart) — which
        // also means a Dart main() that throws leaves the flag false, and the wake paths
        // correctly skip instead of posting into a half-built engine. It used to be set
        // from MainActivity, where it tracked the ACTIVITY and so went false on a reclaim
        // even though nothing was wrong with Dart.
    }
}
