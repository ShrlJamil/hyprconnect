package io.github.shrljamil.hyprconnect_mobile

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
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
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }
                    "appVersion" -> {
                        result.success(appVersion())
                    }
                    "canInstallPackages" -> {
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls(),
                        )
                    }
                    "openInstallPermissionSettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        } catch (e: Exception) {
                            // Fall through: the install intent will
                            // surface the same page on its own.
                        }
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(installApk(path))
                    }
                    "batteryStatus" -> {
                        result.success(batteryStatus())
                    }
                    "exportToDownloads" -> {
                        val path = call.argument<String>("path") ?: ""
                        val name = call.argument<String>("name") ?: ""
                        result.success(exportToDownloads(path, name))
                    }
                    "hasAllFilesAccess" -> {
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                                Environment.isExternalStorageManager(),
                        )
                    }
                    "openAllFilesAccessSettings" -> {
                        openAllFilesAccessSettings()
                        result.success(null)
                    }
                    "startSftpServer" -> {
                        // Binding and key generation do not
                        // belong on the platform thread.
                        Thread {
                            val info = SftpServer.start(applicationContext.filesDir.absolutePath)
                            android.os.Handler(android.os.Looper.getMainLooper())
                                .post {
                                    result.success(
                                        info?.let {
                                            mapOf(
                                                "port" to it.port,
                                                "user" to it.user,
                                                "password" to it.password,
                                            )
                                        },
                                    )
                                }
                        }.start()
                    }
                    "stopSftpServer" -> {
                        SftpServer.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// "1.0.0+4": the version name and build number of this
    /// install, in the same shape as the release tags.
    private fun appVersion(): String {
        val info = packageManager.getPackageInfo(packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return "${info.versionName}+$code"
    }

    /// Open the system installer on a downloaded update APK.
    private fun installApk(path: String): Boolean {
        return try {
            val file = java.io.File(path)
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                },
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /// The phone's current battery state for the battery
    /// plugin: the sticky ACTION_BATTERY_CHANGED intent carries
    /// level, scale and charging status without a receiver ever
    /// having to be registered.
    private fun batteryStatus(): Map<String, Any> {
        val intent = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to percent, "charging" to charging)
    }

    /// Copy a file from the app's private staging folder into
    /// the public Download/HyprConnect folder through
    /// MediaStore, so received files are visible in the file
    /// manager. Returns the public display path, or null below
    /// Android 10 or on any failure.
    private fun exportToDownloads(path: String, name: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val source = java.io.File(path)
        if (!source.exists()) return null
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/HyprConnect")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            val ext = name.substringAfterLast('.', "")
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            if (mime != null) put(MediaStore.MediaColumns.MIME_TYPE, mime)
        }
        val uri = resolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: return null
        try {
            val stream = resolver.openOutputStream(uri)
            if (stream == null) {
                resolver.delete(uri, null, null)
                return null
            }
            stream.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            // Read the real display name back: MediaStore
            // renames duplicates, and the app shows this path.
            var displayName = name
            resolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) displayName = cursor.getString(0)
            }
            return "Download/HyprConnect/$displayName"
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            return null
        }
    }

    /// The system page where the user grants this app access
    /// to all files, which the SFTP server needs to serve the
    /// shared storage.
    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
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

    /// The settings page's "Persistent notification" row: the
    /// system notification settings for this app, where the
    /// keep-alive and pairing notifications are controlled.
    private fun openNotificationSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                },
            )
        } catch (e: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
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
