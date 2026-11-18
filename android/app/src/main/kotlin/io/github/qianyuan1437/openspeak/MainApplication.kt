package io.github.qianyuan1437.openspeak

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the single Flutter engine for the whole process so the Dart
 * dictation pipeline keeps running for the floating bubble even after the
 * activity is closed.
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        NativeChannel.attach(this, engine)
    }

    companion object {
        const val ENGINE_ID = "openspeak_main"
    }
}
