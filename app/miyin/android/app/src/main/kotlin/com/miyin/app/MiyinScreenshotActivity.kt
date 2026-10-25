package com.miyin.app

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle

/** A transparent consent host keeps the app underneath visible in the screenshot. */
class MiyinScreenshotActivity : Activity() {
    private val requestCode = 4405

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        val manager = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(manager.createScreenCaptureIntent(), requestCode)
    }

    @Deprecated("MediaProjection consent uses the activity result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == this.requestCode && resultCode == RESULT_OK && data != null) {
            MiyinFloatingService.setAppForeground(true)
            val service = Intent(this, MiyinScreenshotCaptureService::class.java).apply {
                putExtra(MiyinScreenshotCaptureService.EXTRA_RESULT_CODE, resultCode)
                putExtra(MiyinScreenshotCaptureService.EXTRA_RESULT_DATA, data)
            }
            try {
                startForegroundService(service)
            } catch (_: Exception) {
                MiyinFloatingService.setScreenshotInProgress(false)
                startActivity(Intent(this, MainActivity::class.java).apply {
                    this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("miyin_screenshot_error", "无法启动截屏，请重试")
                })
            }
        } else {
            MiyinFloatingService.setScreenshotInProgress(false)
        }
        finish()
    }
}
