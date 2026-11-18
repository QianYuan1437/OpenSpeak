package io.github.qianyuan1437.openspeak

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = MainApplication.ENGINE_ID

    // The engine outlives the activity; the bubble service keeps using it.
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
