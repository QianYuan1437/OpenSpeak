package io.github.qianyuan1437.openspeak

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.TextView
import kotlin.math.abs

/**
 * Foreground service (type microphone) that draws the floating mic bubble
 * over other apps. Tap toggles dictation, long-press is push-to-talk, drag
 * moves it. The bubble never takes focus, so the target text field keeps it.
 */
class BubbleService : Service() {
    private lateinit var wm: WindowManager
    private lateinit var bubble: BubbleView
    private lateinit var params: WindowManager.LayoutParams
    private var toast: TextView? = null
    private val main = Handler(Looper.getMainLooper())
    private val hideToast = Runnable { removeToast() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        startInForeground()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        bubble = BubbleView(this)
        val size = dp(58)
        val prefs = getSharedPreferences("bubble", MODE_PRIVATE)
        params = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt("x", resources.displayMetrics.widthPixels - size - dp(8))
            y = prefs.getInt("y", resources.displayMetrics.heightPixels / 2)
        }
        bubble.setOnTouchListener(TouchHandler())
        wm.addView(bubble, params)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onDestroy() {
        instance = null
        removeToast()
        runCatching { wm.removeView(bubble) }
        super.onDestroy()
    }

    /** Called from Dart: state is idle | listening | processing | done | error. */
    fun update(state: String, level: Float, text: String?) {
        main.post {
            bubble.setState(state, level)
            when (state) {
                "done" -> showToast(getString(R.string.bubble_copied) + "\n" + (text ?: ""))
                "error" -> showToast(text ?: "")
                "listening", "processing" -> if (!text.isNullOrBlank()) showToast(text, sticky = true)
                else -> removeToast()
            }
        }
    }

    private fun showToast(text: String, sticky: Boolean = false) {
        val tv = toast ?: TextView(this).also { v ->
            v.setTextColor(Color.WHITE)
            v.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            v.setPadding(dp(14), dp(10), dp(14), dp(10))
            v.maxLines = 4
            v.background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.argb(235, 22, 22, 30))
            }
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                y = dp(96)
                width = (resources.displayMetrics.widthPixels * 0.86).toInt()
            }
            wm.addView(v, lp)
            toast = v
        }
        tv.text = text
        main.removeCallbacks(hideToast)
        if (!sticky) main.postDelayed(hideToast, 2600)
    }

    private fun removeToast() {
        toast?.let { runCatching { wm.removeView(it) } }
        toast = null
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.bubble_channel), NotificationManager.IMPORTANCE_MIN),
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n: Notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_mic)
            .setContentTitle(getString(R.string.bubble_title))
            .setContentText(getString(R.string.bubble_text))
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(1, n)
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private inner class TouchHandler : View.OnTouchListener {
        private val slop = ViewConfiguration.get(this@BubbleService).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var holding = false
        private val longPress = Runnable {
            holding = true
            bubble.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            NativeChannel.send("bubblePressStart")
        }

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY
                    startX = params.x; startY = params.y
                    dragging = false; holding = false
                    bubble.pressed(true)
                    main.postDelayed(longPress, 350)
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (!holding && (dragging || abs(dx) > slop || abs(dy) > slop)) {
                        if (!dragging) main.removeCallbacks(longPress)
                        dragging = true
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        wm.updateViewLayout(bubble, params)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    main.removeCallbacks(longPress)
                    bubble.pressed(false)
                    when {
                        holding -> NativeChannel.send("bubblePressEnd")
                        dragging -> snapToEdge()
                        e.actionMasked == MotionEvent.ACTION_UP -> NativeChannel.send("bubbleTap")
                    }
                }
            }
            return true
        }

        private fun snapToEdge() {
            val w = resources.displayMetrics.widthPixels
            params.x = if (params.x + params.width / 2 < w / 2) dp(4) else w - params.width - dp(4)
            wm.updateViewLayout(bubble, params)
            getSharedPreferences("bubble", MODE_PRIVATE).edit()
                .putInt("x", params.x).putInt("y", params.y).apply()
        }
    }

    companion object {
        private const val CHANNEL = "bubble"
        @Volatile var instance: BubbleService? = null
    }
}
