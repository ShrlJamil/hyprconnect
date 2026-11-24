package io.github.shrljamil.hyprconnect_mobile

import android.Manifest
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/// The UI host only. The Flutter engine belongs to EngineHost
/// (created by the keep-alive service when the process starts
/// without any UI), this activity attaches to that cached engine,
/// and closing the activity must not destroy it: the connection
/// lives in the engine, not in this window.
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // The cached engine must exist before the activity
        // delegate looks it up during super.onCreate; an activity
        // launched into a fresh process creates it here, an
        // activity launched into the service's process finds it
        // already running.
        EngineHost.ensureStarted(this)
        super.onCreate(savedInstanceState)
        // Start the keep-alive service natively as well, so its
        // survival does not depend on the Dart side booting first.
        KeepAliveService.start(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun getCachedEngineId(): String = EngineHost.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Covers the activity-first path, where this activity
        // created the cached engine before the service ran; on
        // the service-first path the same registration simply
        // lands again on the same engine.
        NativeBridge.register(flutterEngine, applicationContext)
    }
}
