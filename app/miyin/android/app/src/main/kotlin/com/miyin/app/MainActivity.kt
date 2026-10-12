package com.miyin.app

import android.hardware.display.DisplayManager
import android.provider.Settings
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val performanceChannelName = "com.miyin.app/performance"
    private val translationChannelName = "com.miyin.app/translation"
    private var translationChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            performanceChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setHighRefresh" -> {
                    setHighRefresh(call.argument<Boolean>("active") == true)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        translationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            translationChannelName,
        ).also { channel ->
            channel.setMethodCallHandler(MiyinTranslationMethodHandler())
        }
    }

    override fun onResume() {
        super.onResume()
        setHighRefresh(false)
    }

    override fun onPause() {
        setHighRefresh(false)
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            performanceChannelName,
        ).setMethodCallHandler(null)
        translationChannel?.setMethodCallHandler(null)
        translationChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun setHighRefresh(active: Boolean) {
        val preferredRate = if (active) userPeakRefreshRate() else null
        val attributes = window.attributes
        val targetRate = preferredRate ?: 0f
        if (attributes.preferredRefreshRate != targetRate) {
            attributes.preferredRefreshRate = targetRate
            window.attributes = attributes
        }
    }

    private fun userPeakRefreshRate(): Float? {
        val display = getSystemService(DisplayManager::class.java)
            ?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return null
        val currentMode = display.mode
        val supportedRates = display.supportedModes
            .asSequence()
            .filter {
                it.physicalWidth == currentMode.physicalWidth &&
                    it.physicalHeight == currentMode.physicalHeight
            }
            .map { it.refreshRate }
            .distinct()
            .toList()
        if (supportedRates.isEmpty()) return null

        val userPeakRate = Settings.System.getFloat(
            contentResolver,
            "peak_refresh_rate",
            0f,
        )
        if (!userPeakRate.isFinite() || userPeakRate <= 0f) return null

        return supportedRates
            .filter { it <= userPeakRate + 0.5f }
            .maxOrNull()
    }
}
