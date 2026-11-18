package io.github.qianyuan1437.openspeak

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/** The round mic button drawn in the overlay; colour + halo follow state/level. */
class BubbleView(context: Context) : View(context) {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG)
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val glyphFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private var state = "idle"
    private var level = 0f
    private var shownLevel = 0f
    private var isPressed = false
    private var spin = 0f
    private val spinner = ValueAnimator.ofFloat(0f, 360f).apply {
        duration = 900
        repeatCount = ValueAnimator.INFINITE
        addUpdateListener { spin = it.animatedValue as Float; invalidate() }
    }

    fun setState(s: String, l: Float) {
        state = s
        level = l.coerceIn(0f, 1f)
        if (s == "processing") {
            if (!spinner.isStarted) spinner.start()
        } else {
            spinner.cancel()
        }
        invalidate()
    }

    fun pressed(p: Boolean) {
        isPressed = p
        invalidate()
    }

    override fun onDetachedFromWindow() {
        spinner.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(c: Canvas) {
        val w = width.toFloat()
        val cx = w / 2
        val cy = height / 2f
        val color = when (state) {
            "listening" -> Color.rgb(229, 72, 77)
            "processing" -> Color.rgb(245, 165, 36)
            "error" -> Color.rgb(160, 60, 60)
            else -> Color.rgb(91, 91, 214)
        }
        val target = if (state == "listening") level else 0f
        shownLevel += (target - shownLevel) * 0.5f
        val r = w * 0.36f
        if (state == "listening") {
            halo.color = color
            halo.alpha = 70
            c.drawCircle(cx, cy, r + (w / 2 - r) * shownLevel, halo)
        }
        fill.color = color
        fill.alpha = if (isPressed) 200 else 240
        fill.setShadowLayer(w * 0.05f, 0f, w * 0.02f, Color.argb(90, 0, 0, 0))
        c.drawCircle(cx, cy, r, fill)

        if (state == "processing") {
            glyph.strokeWidth = w * 0.05f
            val a = r * 0.5f
            c.drawArc(RectF(cx - a, cy - a, cx + a, cy + a), spin, 270f, false, glyph)
            return
        }
        // Microphone glyph.
        val gw = r * 0.26f
        val top = cy - r * 0.55f
        val bot = cy + r * 0.12f
        c.drawRoundRect(RectF(cx - gw, top, cx + gw, bot), gw, gw, glyphFill)
        glyph.strokeWidth = r * 0.11f
        val hw = gw * 1.8f
        c.drawArc(RectF(cx - hw, cy - r * 0.32f, cx + hw, cy + r * 0.3f), 0f, 180f, false, glyph)
        c.drawLine(cx, cy + r * 0.3f, cx, cy + r * 0.5f, glyph)
    }
}
