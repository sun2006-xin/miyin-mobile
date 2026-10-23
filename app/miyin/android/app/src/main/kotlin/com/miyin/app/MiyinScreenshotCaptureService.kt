package com.miyin.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.File
import java.io.FileOutputStream

/** Captures one frame after explicit system consent and hands it to local OCR. */
class MiyinScreenshotCaptureService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "screenshot_result_code"
        const val EXTRA_RESULT_DATA = "screenshot_result_data"
        private const val CHANNEL_ID = "miyin_screenshot"
        private const val NOTIFICATION_ID = 4305
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var reader: ImageReader? = null
    private var captured = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val code = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
        if (code == 0 || data == null) { stopSelf(); return START_NOT_STICKY }
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "觅音截屏翻译", NotificationManager.IMPORTANCE_LOW),
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
                else Notification.Builder(this)
            val notification = builder.setSmallIcon(android.R.drawable.ic_menu_crop)
                .setContentTitle("觅音正在截取当前画面")
                .setOngoing(true).build()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else startForeground(NOTIFICATION_ID, notification)
            projection = getSystemService(MediaProjectionManager::class.java).getMediaProjection(code, data)
            projection!!.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { stopSelf() }
            }, main)
            val metrics = resources.displayMetrics
            val width = metrics.widthPixels
            val height = metrics.heightPixels
            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            // Let SurfaceFlinger finish a frame after the system consent closes.
            // The floating shortcut stays hidden for the entire capture session.
            main.postDelayed({ startCapture(width, height, metrics.densityDpi) }, 350)
        } catch (_: Exception) { reportFailure("截屏失败，请重试") }
        return START_NOT_STICKY
    }

    private fun startCapture(width: Int, height: Int, densityDpi: Int) {
        try {
            val display = projection!!.createVirtualDisplay(
                "miyin-screenshot", width, height, densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader!!.surface, null, main,
            )
            reader!!.setOnImageAvailableListener({ source ->
                if (captured) { source.acquireLatestImage()?.close(); return@setOnImageAvailableListener }
                val image = source.acquireLatestImage() ?: return@setOnImageAvailableListener
                captured = true
                try {
                    val plane = image.planes[0]
                    val strideWidth = plane.rowStride / plane.pixelStride
                    val bitmap = Bitmap.createBitmap(strideWidth, height, Bitmap.Config.ARGB_8888)
                    bitmap.copyPixelsFromBuffer(plane.buffer)
                    val crop = Bitmap.createBitmap(bitmap, 0, 0, width, height)
                    bitmap.recycle()
                    val folder = File(cacheDir, "screenshot-translation").apply { mkdirs() }
                    val file = File(folder, "screenshot-${System.currentTimeMillis()}.jpg")
                    FileOutputStream(file).use { crop.compress(Bitmap.CompressFormat.JPEG, 93, it) }
                    crop.recycle()
                    startActivity(Intent(this, MainActivity::class.java).apply {
                        this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("miyin_screenshot_path", file.absolutePath)
                    })
                } catch (_: Exception) {
                    startActivity(Intent(this, MainActivity::class.java).apply {
                        this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("miyin_screenshot_error", "截屏失败，请重试")
                    })
                } finally {
                    image.close()
                    display?.release()
                    stopSelf()
                }
            }, main)
            main.postDelayed({ if (!captured) { display?.release(); reportFailure("没有取得屏幕画面，请重试") } }, 3500)
        } catch (_: Exception) { reportFailure("截屏失败，请重试") }
    }

    private fun reportFailure(message: String) {
        startActivity(Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("miyin_screenshot_error", message)
        })
        stopSelf()
    }

    override fun onDestroy() {
        MiyinFloatingService.setScreenshotInProgress(false)
        reader?.close()
        projection?.stop()
        super.onDestroy()
    }
}
