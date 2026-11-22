package io.github.shrljamil.hyprconnect_mobile

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Start the keep-alive service natively as well, so its
        // survival does not depend on the Dart side booting first.
        KeepAliveService.start(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKeepAlive" -> {
                        result.success(KeepAliveService.start(this))
                    }
                    "keepAliveStatus" -> {
                        result.success(
                            "running=${KeepAliveService.isRunning(this)}, " +
                                "last: ${KeepAliveService.status(this)}",
                        )
                    }
                    "openAutostartSettings" -> {
                        result.success(openAutostartSettings())
                    }
                    "showPairingNotification" -> {
                        val name = call.argument<String>("deviceName") ?: ""
                        val id = call.argument<String>("deviceId") ?: ""
                        showPairingNotification(name, id)
                        result.success(null)
                    }
                    "cancelPairingNotification" -> {
                        val id = call.argument<String>("deviceId") ?: ""
                        val manager = getSystemService(NotificationManager::class.java)
                        manager.cancel(pairingNotificationId(id))
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(power.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        openBatteryOptimizationSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pairingNotificationId(deviceId: String): Int = 1000 + deviceId.hashCode() % 10000

    private fun showPairingNotification(deviceName: String, deviceId: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                PAIRING_CHANNEL_ID,
                getString(R.string.notif_channel_pairing),
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            pairingNotificationId(deviceId),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, PAIRING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.pairing_notif_title))
            .setContentText(getString(R.string.pairing_notif_text, deviceName))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        manager.notify(pairingNotificationId(deviceId), notification)
    }

    /// Xiaomi's HyperOS / MIUI gates background survival behind
    /// its own Autostart switch, separate from the system battery
    /// exemption. Open that page when it exists; otherwise fall
    /// back to this app's system details page.
    private fun openAutostartSettings(): Boolean {
        val miui = Intent().apply {
            component = android.content.ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            )
        }
        return try {
            startActivity(miui)
            true
        } catch (e: Exception) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ),
                )
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun openBatteryOptimizationSettings() {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (power.isIgnoringBatteryOptimizations(packageName)) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    companion object {
        const val CHANNEL = "io.github.shrljamil.hyprconnect/native"
        const val PAIRING_CHANNEL_ID = "pairing"
    }
}
