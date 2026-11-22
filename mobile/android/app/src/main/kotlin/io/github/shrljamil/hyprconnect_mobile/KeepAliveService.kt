package io.github.shrljamil.hyprconnect_mobile

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

/// Keeps this process at foreground-service importance so Android
/// does not kill the discovery broadcaster and the TCP listener
/// while the app is in the background, the same approach KDE
/// Connect uses. The service itself does no protocol work: it holds
/// a multicast lock (so UDP discovery broadcasts are received with
/// the screen off) and a Wi-Fi lock, and shows the mandatory
/// persistent notification.
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
        startForegroundWithNotification()
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
            .setSmallIcon(R.mipmap.ic_launcher)
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

    override fun onDestroy() {
        multicastLock?.release()
        wifiLock?.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val CHANNEL_ID = "connection"
        const val NOTIFICATION_ID = 1
    }
}
