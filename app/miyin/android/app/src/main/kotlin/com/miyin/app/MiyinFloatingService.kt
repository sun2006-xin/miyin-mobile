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
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.TextView
import kotlin.math.abs

/** The user-controlled shortcut stays visible until stopped, including in Miyin. */
class MiyinFloatingService : Service() {
    companion object {
        const val ACTION_STOP = "com.miyin.app.STOP_FLOATING"
        const val PREFS_NAME = "miyin_floating"
        const val PREF_ENABLED = "enabled"
        private const val PREF_DOCK_RIGHT = "dock_right"
        private const val CHANNEL_ID = "miyin_floating_shortcut"
        private const val NOTIFICATION_ID = 4301
        private var activeService: MiyinFloatingService? = null
        private var appForeground = false
        private var screenshotInProgress = false
        @Volatile var running = false
            private set

        fun setAppForeground(foreground: Boolean) {
            appForeground = foreground
            activeService?.setBallVisibility(!screenshotInProgress)
        }

        fun setScreenshotInProgress(inProgress: Boolean) {
            screenshotInProgress = inProgress
            activeService?.setBallVisibility(!inProgress)
        }
    }

    private var windowManager: WindowManager? = null
    private var ball: View? = null
    private var menu: LinearLayout? = null
    private var ballParams: WindowManager.LayoutParams? = null
    private var menuParams: WindowManager.LayoutParams? = null
    private var dockOnRight = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        dockOnRight = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .getBoolean(PREF_DOCK_RIGHT, true)
        activeService = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_ENABLED, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        createNotificationChannel()
        val notification = notification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (ball == null) attachBall()
        running = ball != null
        setBallVisibility(!screenshotInProgress)
        return START_NOT_STICKY
    }

    private fun setBallVisibility(visible: Boolean) {
        if (!visible) hideMenu()
        ball?.visibility = if (visible) View.VISIBLE else View.GONE
        ball?.alpha = if (appForeground) 0.78f else 0.94f
        val view = ball
        val position = ballParams
        if (view != null && position != null) {
            position.x = dockX(dockOnRight)
            position.y = position.y.coerceIn(dp(28), maxBallY())
            windowManager?.updateViewLayout(view, position)
            updateMenuPosition()
        }
    }

    private fun notification(): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("觅音悬浮球已开启")
            .setContentText("点按悬浮球使用翻译、同传与截屏翻译")
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(
            CHANNEL_ID, "觅音悬浮球", NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun rounded(color: Int, radiusDp: Int): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun ballSurface(): GradientDrawable = GradientDrawable(
        GradientDrawable.Orientation.TL_BR,
        intArrayOf(Color.rgb(8, 83, 111), Color.rgb(8, 138, 150), Color.rgb(42, 211, 184)),
    ).apply {
        shape = GradientDrawable.OVAL
        setStroke(dp(2), Color.argb(245, 239, 255, 254))
    }

    private fun params(width: Int, height: Int): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        return WindowManager.LayoutParams(
            dp(width), dp(height), type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
    }

    private fun attachBall() {
        val manager = getSystemService(WINDOW_SERVICE) as? WindowManager ?: return
        windowManager = manager
        val view = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            scaleType = ImageView.ScaleType.CENTER_CROP
            setPadding(dp(3), dp(3), dp(3), dp(3))
            elevation = dp(10).toFloat()
            background = ballSurface()
            outlineProvider = ViewOutlineProvider.BACKGROUND
            clipToOutline = true
            contentDescription = "觅音快捷工具，点击展开菜单"
        }
        val p = params(50, 50).apply {
            x = dockX(dockOnRight)
            y = resources.displayMetrics.heightPixels / 3
        }
        var downX = 0f
        var downY = 0f
        var originX = 0
        var originY = 0
        var moved = false
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    view.animate().scaleX(0.93f).scaleY(0.93f).setDuration(90).start()
                    downX = event.rawX
                    downY = event.rawY
                    originX = p.x
                    originY = p.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (abs(event.rawX - downX) > dp(6) || abs(event.rawY - downY) > dp(6)) moved = true
                    if (moved) {
                        p.x = (originX + event.rawX - downX).toInt()
                            .coerceIn(dockX(false), dockX(true))
                        p.y = (originY + event.rawY - downY).toInt()
                            .coerceIn(dp(28), maxBallY())
                        manager.updateViewLayout(view, p)
                        updateMenuPosition()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    if (!moved) {
                        toggleMenu()
                    } else {
                        dockOnRight = p.x + dp(25) >= resources.displayMetrics.widthPixels / 2
                        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                            .putBoolean(PREF_DOCK_RIGHT, dockOnRight).apply()
                        p.x = dockX(dockOnRight)
                        manager.updateViewLayout(view, p)
                        updateMenuPosition()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    dockOnRight = p.x + dp(25) >= resources.displayMetrics.widthPixels / 2
                    p.x = dockX(dockOnRight)
                    manager.updateViewLayout(view, p)
                    updateMenuPosition()
                    true
                }
                else -> false
            }
        }
        manager.addView(view, p)
        ball = view
        ballParams = p
    }

    private fun dockX(right: Boolean): Int =
        if (right) (resources.displayMetrics.widthPixels - dp(54)).coerceAtLeast(dp(4)) else dp(4)

    private fun maxBallY(): Int =
        (resources.displayMetrics.heightPixels - dp(100)).coerceAtLeast(dp(28))

    private fun menuButton(label: String, action: () -> Unit): TextView = TextView(this).apply {
        text = label
        textSize = 14f
        setTextColor(Color.rgb(15, 71, 77))
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), 0, dp(16), 0)
        minHeight = dp(46)
        setOnClickListener { action() }
    }

    private fun toggleMenu() {
        if (menu != null) { hideMenu(); return }
        val manager = windowManager ?: return
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            elevation = dp(10).toFloat()
            setPadding(0, dp(6), 0, dp(6))
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.rgb(252, 255, 254), Color.rgb(228, 247, 243)),
            ).apply { cornerRadius = dp(18).toFloat(); setStroke(dp(1), Color.rgb(181, 226, 219)) }
            addView(menuButton("▣  截屏翻译") {
                hideMenu()
                setScreenshotInProgress(true)
                startActivity(Intent(this@MiyinFloatingService, MiyinScreenshotActivity::class.java).apply {
                    this.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                })
            })
            addView(menuButton("文  文字翻译") { openApp("home") })
            addView(menuButton("◉  视频与会议同传") { openApp("video") })
            addView(menuButton("⚙  悬浮球设置") { openApp("floating-settings") })
            addView(menuButton("×  关闭悬浮球") {
                getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit().putBoolean(PREF_ENABLED, false).apply()
                stopSelf()
            })
        }
        val p = params(184, 242).apply {
            height = WindowManager.LayoutParams.WRAP_CONTENT
        }
        menuParams = p
        menu = panel
        updateMenuPosition()
        manager.addView(panel, p)
    }

    private fun updateMenuPosition() {
        val ballPosition = ballParams ?: return
        val panelPosition = menuParams ?: return
        panelPosition.x = if (dockOnRight) {
            (ballPosition.x - dp(190)).coerceAtLeast(0)
        } else {
            (ballPosition.x + dp(54)).coerceAtMost(
                (resources.displayMetrics.widthPixels - dp(184)).coerceAtLeast(0),
            )
        }
        val panel = menu ?: return
        val panelHeight = panel.height.takeIf { it > 0 } ?: dp(242)
        val maxTop = (resources.displayMetrics.heightPixels - panelHeight - dp(28))
            .coerceAtLeast(dp(28))
        panelPosition.y = ballPosition.y.coerceIn(dp(28), maxTop)
        if (panel.isAttachedToWindow) windowManager?.updateViewLayout(panel, panelPosition)
    }

    private fun openApp(screen: String?) {
        hideMenu()
        startActivity(Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (screen != null) putExtra("miyin_screen", screen)
        })
    }

    private fun hideMenu() {
        menu?.let { view -> runCatching { windowManager?.removeView(view) } }
        menu = null
        menuParams = null
    }

    override fun onDestroy() {
        hideMenu()
        ball?.let { view -> runCatching { windowManager?.removeView(view) } }
        ball = null
        ballParams = null
        running = false
        if (activeService === this) activeService = null
        super.onDestroy()
    }
}
