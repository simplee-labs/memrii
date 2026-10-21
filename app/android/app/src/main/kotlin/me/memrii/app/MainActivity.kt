package me.memrii.app

import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * The UI host. It no longer OWNS the Flutter engine — [MyApp] creates and caches it, and
 * this adopts it by id.
 *
 * That is the whole point: an OS memory-reclaim destroy used to take the engine with it,
 * leaving the process and the BLE link alive with no Dart to run a sync. See [MyApp] for
 * the measurement. Everything registered on the engine now lives in [MyApp]; what remains
 * here is only what genuinely needs an Activity.
 */
class MainActivity : FlutterActivity() {

    /**
     * Adopt the process-wide engine rather than building one per Activity.
     *
     * FlutterActivity then attaches and detaches it around this Activity's lifecycle
     * instead of creating and destroying it, which is what lets Dart outlive a reclaim.
     */
    override fun getCachedEngineId(): String? =
        // Only if an engine was cached. API registration may still need the fallback below.
        // FlutterActivity THROWS on a cache miss,
        // so returning the id unconditionally would turn a failed pre-warm into an app
        // that cannot launch at all. Returning null instead makes FlutterActivity build
        // its own engine, which configureFlutterEngine then registers the platform APIs
        // on — degrading to exactly the pre-change behaviour rather than to a brick.
        if (FlutterEngineCache.getInstance().contains(MyApp.ENGINE_ID)) MyApp.ENGINE_ID else null

    /**
     * Never tear the engine down with this Activity — not even on a deliberate finish.
     *
     * A swipe-away stops the foreground service (see [onDestroy]) and the process is then
     * free to die on its own, taking the engine with it. Destroying it here instead would
     * also cover the RECLAIM case, which is exactly the one that must not destroy it.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register APIs if absent, including an Activity-created engine after a cache miss.
        // A partially failed prewarm can also leave a cached engine without bleHostApi.
        // On the normal path MyApp already registered it.
        if (OmiBleManager.bleHostApi == null) {
            MyApp.registerEngineScopedApis(application, flutterEngine)
        }

        // Publish the Activity for the engine-scoped APIs that can use one when it exists
        // (companion-device pairing, permission dialogs, moveTaskToBack).
        MyApp.currentActivity = this
        OmiBleManager.bleHostApi?.initCompanionManager(this)
        // A new Activity attachment makes UI capabilities available. Returning
        // the same stopped Activity to the foreground does not reattach it.
        MyApp.uiAttachmentGeneration += 1
        MyApp.systemChannel?.invokeMethod("uiAttached", MyApp.uiAttachmentGeneration)
    }

    override fun onStart() {
        super.onStart()
        // A stopped Activity returning to the foreground also opens the UI; it
        // need not configure/attach the cached engine again. onStart excludes
        // trivial rebuilds and onResume cycles caused by permission dialogs.
        MyApp.uiForeground = true
        MyApp.uiOpenGeneration += 1
        MyApp.systemChannel?.invokeMethod("uiForegrounded", MyApp.uiOpenGeneration)
    }

    override fun onStop() {
        if (MyApp.currentActivity === this) MyApp.uiForeground = false
        super.onStop()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        OmiBleManager.bleHostApi?.onActivityResult(requestCode, resultCode, data)
        FolderExportChannel.instance?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        // When the user closes the app (swipe away), stop the foreground service. The
        // service handles disconnecting all managed devices in its own onDestroy.
        //
        // Gated on isFinishing, and that distinction now carries the whole feature: a
        // reclaim (isFinishing == false) must leave the service — and therefore the
        // process, and therefore the engine — running, which is what lets a background
        // sync happen at all.
        if (isFinishing) {
            OmiBleForegroundService.stopService(this)
        }
        super.onDestroy()
    }

    /**
     * Fires on every engine DETACH, including an OS memory-reclaim destroy.
     *
     * It used to null `flutterApi` and clear `isFlutterAlive` here, because the engine
     * really was going away with the Activity. It no longer is, so doing that would tell
     * both wake paths Dart is dead while it is running perfectly well — reintroducing the
     * exact bug this change removes. All that is released is the Activity reference,
     * which must not outlive the Activity.
     */
    override fun cleanUpFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        MyApp.currentActivity = null
        OmiBleManager.bleHostApi?.releaseCompanionManager()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
