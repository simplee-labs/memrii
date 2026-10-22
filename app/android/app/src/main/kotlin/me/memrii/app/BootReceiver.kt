package me.memrii.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms the sync alarm after a reboot or an app update.
 *
 * A reboot clears every AlarmManager alarm, and nothing else would re-arm this one until
 * Dart next ran — which, with no UI opened, can be never: WorkManager's floor is 15 min,
 * Doze stretches it, and its work cannot start the foreground service without a battery-
 * optimisation exemption. Alarms survive an update, but the process does not, so
 * MY_PACKAGE_REPLACED re-arms too — harmless if it was still set, since arming replaces
 * the one PendingIntent.
 *
 * Arms the persisted next-sync time when that is still ahead, otherwise two minutes out;
 * from there the existing alarm path starts the foreground service and runs or records
 * the cycle. Only for a managed Omi the user has not disconnected, with auto-sync on —
 * the same gate as the alarm's own reconnect.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "OmiBle.Boot"
        private const val PREFS_MANAGED_DEVICE = "managed_device"
        private const val PREFS_USER_DISCONNECTED = "user_disconnected"
        private const val REARM_DELAY_MS = 2 * 60_000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val intervalMinutes = flutterPrefs.getLong("flutter.backgroundSyncIntervalMinutes", 30L)
        val config = context.getSharedPreferences(OmiBleForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
        if (intervalMinutes <= 0 ||
            config.getString(PREFS_MANAGED_DEVICE, null).isNullOrEmpty() ||
            config.getBoolean(PREFS_USER_DISCONNECTED, false)
        ) {
            Log.d(TAG, "$action: no managed Omi on auto-sync — leaving the sync alarm off")
            return
        }

        val now = System.currentTimeMillis()
        val persisted = config.getLong(OmiBleForegroundService.PREFS_NEXT_SYNC_MS, 0L)
        val next = if (persisted > now + REARM_DELAY_MS) persisted else now + REARM_DELAY_MS
        try {
            SyncAlarmReceiver.schedule(context.applicationContext, next)
            Log.i(TAG, "$action: sync alarm re-armed for ${java.util.Date(next)}")
        } catch (e: Exception) {
            Log.w(TAG, "$action: could not re-arm the sync alarm: ${e.message}")
        }
    }
}
