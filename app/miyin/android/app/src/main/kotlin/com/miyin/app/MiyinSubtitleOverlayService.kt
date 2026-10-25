package com.miyin.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs

/** A user-controlled translated caption over other apps. */
class MiyinSubtitleOverlayService : Service() {
    private data class CaptionRow(
        val container: LinearLayout,
        val source: TextView,
        val translation: TextView,
    )

    companion object {
        private const val CHANNEL_ID = "miyin_live_subtitles"
        private const val NOTIFICATION_ID = 4303
        private const val QUICK_PREFS = "miyin_subtitle_quick_preferences"
        private var active: MiyinSubtitleOverlayService? = null
        private var appForeground = false
        var onQuickPreferencesChanged: ((Map<String, String>) -> Unit)? = null
        @Volatile var running = false
            private set

        fun setAppForeground(foreground: Boolean) {
            appForeground = foreground
            active?.updateVisibility()
        }

        fun updateCaption(source: String, translation: String) {
            active?.setCaption(source, translation)
        }

        fun updatePartial(source: String, translation: String = "") {
            active?.setPartial(source, translation)
        }

        fun configure(preferences: Map<String, String>) {
            active?.applyPreferences(preferences)
        }

        fun saveQuickPreferences(context: android.content.Context, preferences: Map<String, String>) {
            val editor = context.getSharedPreferences(QUICK_PREFS, android.content.Context.MODE_PRIVATE).edit()
            preferences["size"]?.takeIf { it in setOf("small", "standard", "large") }
                ?.let { editor.putString("size", it) }
            preferences["font"]?.takeIf { it in setOf("small", "standard", "large") }
                ?.let { editor.putString("font", it) }
            preferences["color"]?.takeIf { it in setOf("white", "mint", "yellow") }
                ?.let { editor.putString("color", it) }
            preferences["display"]?.takeIf { it in setOf("bilingual", "source", "translation") }
                ?.let { editor.putString("display", it) }
            editor.apply()
        }

        fun quickPreferences(context: android.content.Context): Map<String, String> {
            val prefs = context.getSharedPreferences(QUICK_PREFS, android.content.Context.MODE_PRIVATE)
            return listOf("size", "font", "color", "display").mapNotNull { key ->
                prefs.getString(key, null)?.let { key to it }
            }.toMap()
        }
    }

    private var manager: WindowManager? = null
    private var panel: LinearLayout? = null
    private var historyScroll: ScrollView? = null
    private var historyContainer: LinearLayout? = null
    private var emptyView: TextView? = null
    private var sourceView: TextView? = null
    private var partialTranslationView: TextView? = null
    private val captionRows = mutableListOf<CaptionRow>()
    private var settingsRow: LinearLayout? = null
    private var settingsButton: TextView? = null
    private var fontButton: TextView? = null
    private var sizeButton: TextView? = null
    private var colorButton: TextView? = null
    private var displayButton: TextView? = null
    private var params: WindowManager.LayoutParams? = null
    private var displayEnabled = true
    private var displayMode = "bilingual"
    private var captionColor = "white"
    private var fontMode = "standard"
    private var sizeMode = "standard"
    private var backdropMode = "medium"
    private var settingsOpen = false
    private var outsideY = 0
    private val controlViews = mutableListOf<TextView>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        active = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "觅音跨应用字幕", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("miyin_screen", "video")
        }
        val pending = PendingIntent.getActivity(
            this, 4303, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("觅音同传字幕正在显示")
            .setContentText("点按返回同传页面")
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (panel == null) attachPanel()
        running = panel != null
        @Suppress("DEPRECATION")
        val selected = intent?.getSerializableExtra("subtitle_preferences") as? HashMap<*, *>
        if (selected != null) {
            val fromApp = selected.entries.mapNotNull { (key, value) ->
                if (key is String && value is String) key to value else null
            }.toMap()
            applyPreferences(fromApp)
        }
        updateVisibility()
        return START_NOT_STICKY
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun text(size: Float, color: Int): TextView = TextView(this).apply {
        textSize = size
        setTextColor(color)
        maxLines = 3
    }

    private fun control(label: String, onClick: () -> Unit): TextView = text(12f, Color.WHITE).apply {
        text = label
        gravity = Gravity.CENTER
        minHeight = dp(38)
        setPadding(dp(7), 0, dp(7), 0)
        setOnClickListener { onClick() }
        controlViews.add(this)
    }

    private fun attachPanel() {
        val window = getSystemService(WINDOW_SERVICE) as? WindowManager ?: return
        manager = window
        val outline = GradientDrawable().apply {
            setColor(Color.argb(154, 12, 27, 30))
            cornerRadius = dp(12).toFloat()
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(5), dp(12), dp(8))
            background = outline
            elevation = dp(2).toFloat()
            contentDescription = "觅音同传字幕，拖动标题可移动"
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val dragHandle = control("觅音同传 · 拖动", {}).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, dp(6), 0)
        }
        header.addView(dragHandle, LinearLayout.LayoutParams(0, dp(38), 1f))
        val gear = control("⚙ 设置", { toggleSettings() }).apply {
            contentDescription = "展开字幕快捷设置"
        }
        header.addView(gear)
        card.addView(header)
        val history = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val waiting = text(12f, Color.rgb(216, 237, 233)).apply {
            text = "等待语音…"
            setPadding(0, dp(5), 0, dp(5))
        }
        history.addView(waiting)
        val scroll = ScrollView(this).apply {
            isFillViewport = false
            isVerticalScrollBarEnabled = true
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            addView(history)
        }
        card.addView(scroll, LinearLayout.LayoutParams(-1, dp(168)))
        val original = text(12f, Color.rgb(216, 237, 233)).apply {
            visibility = View.GONE
            setPadding(0, dp(3), 0, 0)
            contentDescription = "正在识别的原文"
        }
        card.addView(original)
        val provisionalTranslation = text(16f, Color.WHITE).apply {
            visibility = View.GONE
            contentDescription = "待确认的临时译文"
        }
        card.addView(provisionalTranslation)
        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            setPadding(0, dp(5), 0, 0)
        }
        val firstRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val font = control("字号：标准", { cycleFont() })
        val size = control("高度：标准", { cycleSize() })
        val color = control("字色：白", { cycleColor() })
        val display = control("原文＋译文", { cycleDisplay() })
        firstRow.addView(font, LinearLayout.LayoutParams(0, dp(40), 1f))
        firstRow.addView(size, LinearLayout.LayoutParams(0, dp(40), 1f))
        firstRow.addView(color, LinearLayout.LayoutParams(0, dp(40), 1f))
        controls.addView(firstRow)
        val secondRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        secondRow.addView(display, LinearLayout.LayoutParams(0, dp(40), 1f))
        secondRow.addView(control("翻译方向 ↗", { openLanguagePicker() }), LinearLayout.LayoutParams(0, dp(40), 1f))
        controls.addView(secondRow)
        card.addView(controls)
        historyScroll = scroll
        historyContainer = history
        emptyView = waiting
        sourceView = original
        partialTranslationView = provisionalTranslation
        settingsRow = controls
        settingsButton = gear
        fontButton = font
        sizeButton = size
        colorButton = color
        displayButton = display
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        val p = WindowManager.LayoutParams(
            resources.displayMetrics.widthPixels - dp(32),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(16)
            y = resources.displayMetrics.heightPixels - dp(230)
        }
        outsideY = p.y
        var downX = 0f
        var downY = 0f
        var originX = 0
        var originY = 0
        var moved = false
        dragHandle.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY
                    originX = p.x; originY = p.y; moved = false; true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (abs(event.rawX - downX) > dp(8) || abs(event.rawY - downY) > dp(8)) moved = true
                    if (moved) {
                        p.x = (originX + event.rawX - downX).toInt().coerceIn(0, dp(32))
                        p.y = (originY + event.rawY - downY).toInt()
                            .coerceIn(dp(32), resources.displayMetrics.heightPixels - dp(110))
                        outsideY = p.y
                        window.updateViewLayout(card, p)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) openVideo()
                    true
                }
                else -> false
            }
        }
        window.addView(card, p)
        panel = card
        params = p
        card.post { positionWithinScreen() }
    }

    private fun positionWithinScreen() {
        val view = panel ?: return
        val p = params ?: return
        val maxTop = (resources.displayMetrics.heightPixels - view.height - dp(24))
            .coerceAtLeast(dp(24))
        val corrected = p.y.coerceIn(dp(24), maxTop)
        if (corrected != p.y) {
            p.y = corrected
            if (!appForeground) outsideY = corrected
            runCatching { manager?.updateViewLayout(view, p) }
        }
    }

    private fun setCaption(source: String, translation: String) {
        if (source.isBlank() && translation.isBlank()) return
        val history = historyContainer ?: return
        val scroll = historyScroll
        val wasAtBottom = scroll == null ||
            scroll.scrollY >= history.height - scroll.height - dp(24)
        val entry = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(6))
        }
        val original = text(12f, Color.rgb(216, 237, 233)).apply { text = source.take(250) }
        val translated = text(16f, Color.WHITE).apply {
            text = translation.take(250)
            setPadding(0, dp(2), 0, 0)
        }
        entry.addView(original)
        entry.addView(translated)
        history.addView(entry)
        captionRows.add(CaptionRow(entry, original, translated))
        if (captionRows.size > 80) history.removeView(captionRows.removeAt(0).container)
        sourceView?.text = ""
        partialTranslationView?.text = ""
        updateTextSizes()
        updateTextColors()
        updateDisplayMode()
        updateWindowSize()
        if (wasAtBottom) scroll?.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun setPartial(source: String, translation: String) {
        if (source.isBlank()) return
        sourceView?.text = source.take(250)
        partialTranslationView?.text = translation.take(250)
        if (captionRows.isEmpty()) emptyView?.text = "正在识别…"
        updateDisplayMode()
        panel?.post { positionWithinScreen() }
    }

    private fun toggleSettings() {
        settingsOpen = !settingsOpen
        settingsRow?.visibility = if (settingsOpen) View.VISIBLE else View.GONE
        settingsButton?.contentDescription = if (settingsOpen) "收起字幕快捷设置" else "展开字幕快捷设置"
        panel?.post { positionWithinScreen() }
    }

    private fun cycleFont() {
        fontMode = when (fontMode) { "small" -> "standard"; "standard" -> "large"; else -> "small" }
        fontButton?.text = when (fontMode) { "small" -> "字号：小"; "large" -> "字号：大"; else -> "字号：标准" }
        updateTextSizes()
        updateWindowSize()
        persistQuickPreference("font", fontMode)
    }

    private fun cycleSize() {
        sizeMode = when (sizeMode) { "small" -> "standard"; "standard" -> "large"; else -> "small" }
        sizeButton?.text = when (sizeMode) { "small" -> "高度：两段"; "large" -> "高度：更多"; else -> "高度：标准" }
        updateWindowSize()
        persistQuickPreference("size", sizeMode)
    }

    private fun cycleColor() {
        captionColor = when (captionColor) { "white" -> "mint"; "mint" -> "yellow"; else -> "white" }
        colorButton?.text = when (captionColor) { "mint" -> "字色：薄荷"; "yellow" -> "字色：暖黄"; else -> "字色：白" }
        updateTextColors()
        persistQuickPreference("color", captionColor)
    }

    private fun cycleDisplay() {
        displayMode = when (displayMode) { "bilingual" -> "translation"; "translation" -> "source"; else -> "bilingual" }
        displayButton?.text = when (displayMode) { "source" -> "仅原文"; "translation" -> "仅译文"; else -> "原文＋译文" }
        updateDisplayMode()
        persistQuickPreference("display", displayMode)
    }

    private fun persistQuickPreference(key: String, value: String) {
        getSharedPreferences(QUICK_PREFS, MODE_PRIVATE).edit().putString(key, value).apply()
        onQuickPreferencesChanged?.invoke(mapOf(key to value))
    }

    private fun updateDisplayMode() {
        sourceView?.visibility = if (displayMode != "translation" && !sourceView?.text.isNullOrBlank())
            View.VISIBLE else View.GONE
        partialTranslationView?.visibility = if (displayMode != "source" && !partialTranslationView?.text.isNullOrBlank())
            View.VISIBLE else View.GONE
        emptyView?.visibility = if (captionRows.isEmpty()) View.VISIBLE else View.GONE
        captionRows.forEach { row ->
            row.source.visibility = if (displayMode == "translation") View.GONE else View.VISIBLE
            row.translation.visibility = if (displayMode == "source") View.GONE else View.VISIBLE
        }
    }

    private fun updateTextSizes() {
        val translationSize = when (fontMode) { "small" -> 13f; "large" -> 20f; else -> 16f }
        val sourceSize = translationSize - 3f
        sourceView?.textSize = sourceSize
        partialTranslationView?.textSize = translationSize
        emptyView?.textSize = sourceSize
        captionRows.forEach { row ->
            row.source.textSize = sourceSize
            row.translation.textSize = translationSize
        }
    }

    private fun updateWindowSize() {
        val width = resources.displayMetrics.widthPixels - dp(32)
        historyScroll?.layoutParams?.let { layout ->
            val maximum = when (sizeMode) { "small" -> 112; "large" -> 264; else -> 168 }
            val rowHeight = when (fontMode) { "small" -> 48; "large" -> 70; else -> 56 }
            val contentHeight = if (captionRows.isEmpty()) 30 else captionRows.size * rowHeight + 8
            layout.height = dp(contentHeight.coerceAtMost(maximum))
            historyScroll?.layoutParams = layout
        }
        params?.let { p ->
            p.width = width
            p.x = ((resources.displayMetrics.widthPixels - width) / 2).coerceAtLeast(0)
            panel?.let { view -> runCatching { manager?.updateViewLayout(view, p) } }
        }
        panel?.post { positionWithinScreen() }
    }

    private fun updateTextColors() {
        val light = backdropMode == "light"
        controlViews.forEach { it.setTextColor(if (light) Color.rgb(19, 48, 53) else Color.WHITE) }
        val sourceColor = if (light) Color.rgb(54, 78, 81) else Color.rgb(216, 237, 233)
        sourceView?.setTextColor(sourceColor)
        emptyView?.setTextColor(sourceColor)
        val translationColor = when (captionColor) {
            "mint" -> if (light) Color.rgb(0, 111, 104) else Color.rgb(165, 250, 230)
            "yellow" -> if (light) Color.rgb(117, 75, 0) else Color.rgb(255, 231, 151)
            else -> if (light) Color.rgb(19, 48, 53) else Color.WHITE
        }
        partialTranslationView?.setTextColor(translationColor)
        captionRows.forEach { row ->
            row.source.setTextColor(sourceColor)
            row.translation.setTextColor(translationColor)
        }
    }

    private fun openVideo() = openApp(false)

    private fun openLanguagePicker() = openApp(true)

    private fun openApp(languagePicker: Boolean) {
        startActivity(Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("miyin_screen", "video")
            if (languagePicker) putExtra("miyin_caption_action", "language")
        })
    }

    private fun applyPreferences(selected: Map<String, String>) {
        displayEnabled = selected["enabled"] != "false"
        displayMode = selected["display"].takeIf { it in setOf("bilingual", "source", "translation") }
            ?: "bilingual"
        fontMode = selected["font"].takeIf { it in setOf("small", "standard", "large") } ?: "standard"
        fontButton?.text = when (fontMode) { "small" -> "字号：小"; "large" -> "字号：大"; else -> "字号：标准" }
        updateTextSizes()
        val cardColor = when (selected["backdrop"]) {
            "clear" -> Color.argb(75, 12, 27, 30)
            "light" -> Color.argb(194, 249, 255, 253)
            "dark" -> Color.argb(194, 10, 21, 25)
            else -> Color.argb(154, 12, 27, 30)
        }
        panel?.background = GradientDrawable().apply {
            setColor(cardColor)
            cornerRadius = dp(12).toFloat()
        }
        backdropMode = selected["backdrop"] ?: "medium"
        captionColor = selected["color"].takeIf { it in setOf("white", "mint", "yellow") } ?: "white"
        colorButton?.text = when (captionColor) { "mint" -> "字色：薄荷"; "yellow" -> "字色：暖黄"; else -> "字色：白" }
        displayButton?.text = when (displayMode) { "source" -> "仅原文"; "translation" -> "仅译文"; else -> "原文＋译文" }
        updateTextColors()
        updateDisplayMode()
        sizeMode = selected["size"].takeIf { it in setOf("small", "standard", "large") } ?: "standard"
        sizeButton?.text = when (sizeMode) { "small" -> "高度：两段"; "large" -> "高度：更多"; else -> "高度：标准" }
        updateWindowSize()
        params?.let { p ->
            p.y = when (selected["position"]) {
                "top" -> dp(100)
                "middle" -> resources.displayMetrics.heightPixels / 2 - dp(70)
                else -> resources.displayMetrics.heightPixels - dp(230)
            }
            outsideY = p.y
            panel?.let { view -> runCatching { manager?.updateViewLayout(view, p) } }
        }
        panel?.post { positionWithinScreen() }
        updateVisibility()
    }

    private fun updateVisibility() {
        panel?.visibility = if (displayEnabled) View.VISIBLE else View.GONE
        val view = panel ?: return
        val p = params ?: return
        // Keep the app's own controls readable while captions remain visible in-app.
        val nextY = if (appForeground)
            (resources.displayMetrics.heightPixels - view.height - dp(24)).coerceAtLeast(dp(130))
        else outsideY
        if (p.y != nextY) {
            p.y = nextY
            runCatching { manager?.updateViewLayout(view, p) }
        }
    }

    override fun onDestroy() {
        panel?.let { runCatching { manager?.removeView(it) } }
        panel = null
        historyScroll = null
        historyContainer = null
        emptyView = null
        sourceView = null
        captionRows.clear()
        settingsRow = null
        settingsButton = null
        fontButton = null
        sizeButton = null
        colorButton = null
        displayButton = null
        controlViews.clear()
        params = null
        running = false
        if (active === this) active = null
        super.onDestroy()
    }
}
