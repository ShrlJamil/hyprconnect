package io.github.shrljamil.hyprconnect_mobile

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/// Owns the app's single Flutter engine, independently of any
/// activity. The engine is created by whichever component comes
/// first (the keep-alive service or the main activity), stored in
/// the engine cache, and never destroyed with an activity.
///
/// This is what makes the connection survive OEM process kills:
/// when HyperOS kills the process and the sticky foreground
/// service is revived, the service recreates the engine here, the
/// Dart side boots, and the TCP listener and discovery come back
/// without the user opening the app. Before this, the engine only
/// existed inside MainActivity, so a revived service held its
/// notification and locks while nothing listened anymore.
object EngineHost {
    const val ENGINE_ID = "hyprconnect-main-engine"

    @Volatile
    private var started = false

    @Synchronized
    fun ensureStarted(context: Context) {
        if (started) return
        started = true
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) {
            // Already created (by whichever component ran first).
            return
        }
        val appContext = context.applicationContext
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appContext)
            loader.ensureInitializationComplete(appContext, null)
        } catch (_: Exception) {
            // The engine constructor initialises the loader itself
            // on versions where the explicit calls are unneeded.
        }
        val engine = FlutterEngine(appContext)
        GeneratedPluginRegistrant.registerWith(engine)
        NativeBridge.register(engine, appContext)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
    }
}
