package io.github.shrljamil.hyprconnect_mobile

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/// Keeps this process at foreground-service importance so Android
/// does not kill the discovery broadcaster and the TCP listener
/// while the app is in the background, the same approach KDE
/// Connect uses. The service holds a multicast lock (so UDP
/// discovery broadcasts are received with the screen off) and a
/// Wi-Fi lock, shows the mandatory persistent notification, and
/// owns the Flutter engine through EngineHost, so a revived
/// service revives the connection itself, not just the process.
///
/// Every lifecycle outcome is recorded to SharedPreferences so the
/// Dart side can show it in the in-app log: on OEM builds (MIUI /
/// HyperOS above all) a foreground service can be started and still
/// be killed by the vendor's own power manager, and the difference
/// between "never started", "crashed" and "killed later" decides
/// what the user has to change.
class KeepAliveService : Service() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        // The locks are an optimisation (reliable broadcast
        // reception, Wi-Fi staying awake); a failure to take one
        // must never take the service itself down.
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("hyprconnect:discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL, "hyprconnect:connection").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            // Continue without the locks.
        }
        try {
            startForegroundWithNotification()
            record(this, "foreground since ${now()}")
        } catch (e: Exception) {
            record(this, "startForeground failed: ${e.javaClass.simpleName}: ${e.message}")
            throw e
        }
        // The service owns the connection's survival, so it also
        // owns the Flutter engine: (re)creating it here is what
        // brings the Dart side, and with it the TCP listener and
        // discovery, back after the system killed the process.
        // Before this, a revived service held locks and a
        // notification while nothing listened anymore.
        EngineHost.ensureStarted(applicationContext)
    }

    private fun startForegroundWithNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notif_channel_connection),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.service_notif_title))
            .setContentText(getString(R.string.service_notif_text))
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The user swiped the app away: restart the service so the
        // connection survives without the task. Whether the OEM
        // honours this is exactly what the status record shows.
        record(this, "task removed at ${now()}, restarting")
        start(this)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        record(this, "destroyed at ${now()}")
        multicastLock?.release()
        wifiLock?.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val CHANNEL_ID = "connection"
        const val NOTIFICATION_ID = 1
        private const val PREFS = "keep_alive"
        private const val KEY_STATUS = "status"

        private fun now(): String =
            java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
                .format(java.util.Date())

        fun record(context: Context, status: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_STATUS, status)
                .apply()
        }

        fun status(context: Context): String =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_STATUS, "never started") ?: "never started"

        fun isRunning(context: Context): Boolean {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            @Suppress("DEPRECATION")
            return manager.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == KeepAliveService::class.java.name
            }
        }

        /// Start (or nudge) the service and report what happened, so
        /// the caller can log it instead of guessing.
        fun start(context: Context): String {
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, KeepAliveService::class.java),
                )
                "start requested at ${now()}, running=${isRunning(context)}"
            } catch (e: Exception) {
                val message = "start failed: ${e.javaClass.simpleName}: ${e.message}"
                record(context, message)
                message
            }
        }
    }
}
