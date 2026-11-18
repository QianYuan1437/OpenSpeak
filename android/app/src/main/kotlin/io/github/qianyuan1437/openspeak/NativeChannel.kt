package io.github.qianyuan1437.openspeak

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Android side of the `openspeak/native` channel shared with the desktop runners. */
object NativeChannel {
    private var channel: MethodChannel? = null
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "openspeak/native")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> result.success(Settings.canDrawOverlays(app))
                "requestOverlayPermission" -> {
                    val i = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${app.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    app.startActivity(i)
                    result.success(null)
                }
                "startBubble" -> result.success(startBubble())
                "stopBubble" -> {
                    app.stopService(Intent(app, BubbleService::class.java))
                    result.success(null)
                }
                "bubbleState" -> {
                    BubbleService.instance?.update(
                        call.argument<String>("state") ?: "idle",
                        (call.argument<Double>("level") ?: 0.0).toFloat(),
                        call.argument<String>("text"),
                    )
                    result.success(null)
                }
                "copyText" -> {
                    val cm = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("OpenSpeak", call.argument<String>("text") ?: ""))
                    result.success(null)
                }
                "insertText" -> result.success(
                    InsertService.instance?.insert(call.argument<String>("text") ?: "") ?: false,
                )
                "accessibilityEnabled" -> result.success(InsertService.instance != null)
                "openAccessibilitySettings" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    private fun startBubble(): Boolean {
        if (!Settings.canDrawOverlays(app)) return false
        // A microphone foreground service may only start with the permission granted.
        if (app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        val i = Intent(app, BubbleService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) app.startForegroundService(i) else app.startService(i)
        return true
    }

    /** Sends a bubble/gesture event to Dart. */
    fun send(method: String) {
        main.post { channel?.invokeMethod(method, null) }
    }
}
