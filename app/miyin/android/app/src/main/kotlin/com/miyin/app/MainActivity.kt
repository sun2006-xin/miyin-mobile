package com.miyin.app

import android.hardware.display.DisplayManager
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var phoneLlm: PhoneLlmRuntime? = null
    private val performanceChannelName = "com.miyin.app/performance"
    private val translationChannelName = "com.miyin.app/translation"
    private val attachmentOcrChannelName = "com.miyin.app/attachment-ocr"
    private val voiceChannelName = "com.miyin.app/voice"
    private val voiceEventsChannelName = "com.miyin.app/voice-events"
    private val floatingChannelName = "com.miyin.app/floating"
    private val subtitleChannelName = "com.miyin.app/subtitle-overlay"
    private val microphoneSessionChannelName = "com.miyin.app/microphone-session"
    private val liveAudioChannelName = "com.miyin.app/live-audio"
    private var translationChannel: MethodChannel? = null
    private var translationHandler: MiyinTranslationMethodHandler? = null
    private var attachmentOcrChannel: MethodChannel? = null
    private var attachmentOcrHandler: MiyinAttachmentOcrMethodHandler? = null
    private var voiceChannel: MethodChannel? = null
    private var voiceEventsChannel: EventChannel? = null
    private var voiceHandler: MiyinVoiceMethodHandler? = null
    private var floatingChannel: MethodChannel? = null
    private var playbackCaptureBridge: MiyinPlaybackCaptureBridge? = null
    private var subtitleChannel: MethodChannel? = null
    private var microphoneSessionChannel: MethodChannel? = null
    private var liveAudioChannel: MethodChannel? = null
    private var liveAudioHandler: MiyinLiveAudioPlaybackHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        phoneLlm = PhoneLlmRuntime(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.miyin.app/chat-local").setMethodCallHandler(phoneLlm)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.miyin.app/chat-secrets")
            .setMethodCallHandler(MiyinChatSecrets(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.miyin.app/voice-secrets")
            .setMethodCallHandler(MiyinChatSecrets(this, voice = true))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.miyin.app/chat-actions")
            .setMethodCallHandler { call, result ->
                if (call.method == "openUrl") {
                    val value = call.arguments as? String
                    val url = value?.let { runCatching { Uri.parse(it) }.getOrNull() }
                    if (value == null || url == null || value.length > 4096 || url.scheme !in listOf("https", "http") ||
                        url.host.isNullOrEmpty() || !url.userInfo.isNullOrEmpty() || value.any { it <= ' ' }) {
                        result.error("invalid_url", "只支持普通网页链接。", null)
                    } else try {
                        startActivity(Intent(Intent.ACTION_VIEW, url).apply { addCategory(Intent.CATEGORY_BROWSABLE) })
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("browser_unavailable", "没有可用的浏览器。", null)
                    }
                } else if (call.method != "shareText") {
                    result.notImplemented()
                } else {
                    val text = call.arguments as? String
                    if (text.isNullOrEmpty() || text.length > 256000) {
                        result.error("invalid_text", "分享内容为空或过长。", null)
                    } else try {
                        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                        }, "分享觅音对话"))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("share_unavailable", "没有可用的分享应用。", null)
                    }
                }
            }
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
        val localTranslationHandler = MiyinTranslationMethodHandler()
        translationHandler = localTranslationHandler
        translationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            translationChannelName,
        ).also { channel ->
            channel.setMethodCallHandler(localTranslationHandler)
        }
        val imageOcrHandler = MiyinAttachmentOcrMethodHandler(this)
        attachmentOcrHandler = imageOcrHandler
        attachmentOcrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            attachmentOcrChannelName,
        ).also { channel ->
            channel.setMethodCallHandler(imageOcrHandler)
        }
        val speechHandler = MiyinVoiceMethodHandler(this)
        voiceHandler = speechHandler
        voiceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            voiceChannelName,
        ).also { channel ->
            channel.setMethodCallHandler(speechHandler)
        }
        voiceEventsChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            voiceEventsChannelName,
        ).also { channel ->
            channel.setStreamHandler(speechHandler)
        }
        floatingChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            floatingChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialScreen" -> {
                        val screen = intent?.getStringExtra("miyin_screen")
                        val captionAction = intent?.getStringExtra("miyin_caption_action")
                        intent?.removeExtra("miyin_screen")
                        intent?.removeExtra("miyin_caption_action")
                        result.success(if (screen == "video" && captionAction == "language") "video:caption-language" else screen)
                    }
                    "initialScreenshot" -> {
                        val path = intent?.getStringExtra("miyin_screenshot_path")
                        intent?.removeExtra("miyin_screenshot_path")
                        result.success(path)
                    }
                    "initialScreenshotError" -> {
                        val message = intent?.getStringExtra("miyin_screenshot_error")
                        intent?.removeExtra("miyin_screenshot_error")
                        result.success(message)
                    }
                    "status" -> result.success(mapOf(
                        "permissionGranted" to Settings.canDrawOverlays(this),
                        "enabled" to MiyinFloatingService.running,
                    ))
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        if (!enabled) {
                            getSharedPreferences(MiyinFloatingService.PREFS_NAME, MODE_PRIVATE)
                                .edit().putBoolean(MiyinFloatingService.PREF_ENABLED, false).apply()
                            stopService(Intent(this, MiyinFloatingService::class.java))
                            result.success(mapOf("enabled" to false, "permissionGranted" to Settings.canDrawOverlays(this)))
                        } else if (!Settings.canDrawOverlays(this)) {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ))
                            result.success(mapOf("enabled" to false, "permissionGranted" to false, "permissionRequested" to true))
                        } else {
                            try {
                                val serviceIntent = Intent(this, MiyinFloatingService::class.java)
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(serviceIntent)
                                else startService(serviceIntent)
                                getSharedPreferences(MiyinFloatingService.PREFS_NAME, MODE_PRIVATE)
                                    .edit().putBoolean(MiyinFloatingService.PREF_ENABLED, true).apply()
                                result.success(mapOf("enabled" to true, "permissionGranted" to true))
                            } catch (error: Exception) {
                                result.error("floating_start_failed", "悬浮球启动失败，请检查系统设置。", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        playbackCaptureBridge = MiyinPlaybackCaptureBridge(this).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
        subtitleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            subtitleChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ))
                            result.success(mapOf("status" to "permission_requested"))
                        } else {
                            try {
                                val service = Intent(this, MiyinSubtitleOverlayService::class.java)
                                val preferences = call.argument<HashMap<String, String>>("preferences")
                                if (preferences != null) {
                                    MiyinSubtitleOverlayService.saveQuickPreferences(this, preferences)
                                    service.putExtra("subtitle_preferences", preferences)
                                }
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service)
                                else startService(service)
                                result.success(mapOf("status" to "started"))
                            } catch (error: Exception) {
                                result.error("subtitle_overlay_failed", "无法显示跨应用字幕。", null)
                            }
                        }
                    }
                    "update" -> {
                        MiyinSubtitleOverlayService.updateCaption(
                            call.argument<String>("source") ?: "",
                            call.argument<String>("translation") ?: "",
                        )
                        result.success(null)
                    }
                    "updatePartial" -> {
                        MiyinSubtitleOverlayService.updatePartial(
                            call.argument<String>("source") ?: "",
                            call.argument<String>("translation") ?: "",
                        )
                        result.success(null)
                    }
                    "configure" -> {
                        val preferences = call.argument<HashMap<String, String>>("preferences") ?: hashMapOf()
                        MiyinSubtitleOverlayService.saveQuickPreferences(this, preferences)
                        MiyinSubtitleOverlayService.configure(preferences)
                        result.success(null)
                    }
                    "quickPreferences" -> result.success(
                        MiyinSubtitleOverlayService.quickPreferences(this),
                    )
                    "stop" -> {
                        stopService(Intent(this, MiyinSubtitleOverlayService::class.java))
                        result.success(null)
                    }
                    "status" -> result.success(mapOf(
                        "running" to MiyinSubtitleOverlayService.running,
                        "permissionGranted" to Settings.canDrawOverlays(this),
                    ))
                    else -> result.notImplemented()
                }
            }
        }
        MiyinSubtitleOverlayService.onQuickPreferencesChanged = { changed ->
            subtitleChannel?.invokeMethod("quickPreferencesChanged", changed)
        }
        microphoneSessionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            microphoneSessionChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            result.error("microphone_permission_denied", "请先允许觅音使用麦克风。", null)
                        } else {
                            try {
                                val service = Intent(this, MiyinMicrophoneSessionService::class.java)
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service)
                                else startService(service)
                                result.success(mapOf("status" to "started"))
                            } catch (error: Exception) {
                                result.error("microphone_service_failed", "无法在后台保持麦克风同传。", null)
                            }
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, MiyinMicrophoneSessionService::class.java))
                        result.success(null)
                    }
                    "status" -> result.success(mapOf("running" to MiyinMicrophoneSessionService.running))
                    else -> result.notImplemented()
                }
            }
        }
        liveAudioHandler = MiyinLiveAudioPlaybackHandler(this).also { handler ->
            liveAudioChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                liveAudioChannelName,
            ).also { channel -> channel.setMethodCallHandler(handler) }
        }
    }

    @Deprecated("Used to receive the MediaProjection consent result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (playbackCaptureBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val screenshot = intent.getStringExtra("miyin_screenshot_path")
        if (screenshot != null) {
            intent.removeExtra("miyin_screenshot_path")
            floatingChannel?.invokeMethod("openScreenshot", screenshot)
            return
        }
        val screenshotError = intent.getStringExtra("miyin_screenshot_error")
        if (screenshotError != null) {
            intent.removeExtra("miyin_screenshot_error")
            floatingChannel?.invokeMethod("screenshotError", screenshotError)
            return
        }
        val screen = intent.getStringExtra("miyin_screen") ?: return
        val captionAction = intent.getStringExtra("miyin_caption_action")
        intent.removeExtra("miyin_screen")
        intent.removeExtra("miyin_caption_action")
        floatingChannel?.invokeMethod(
            "openScreen",
            if (screen == "video" && captionAction == "language") "video:caption-language" else screen,
        )
    }

    override fun onResume() {
        super.onResume()
        voiceHandler?.onActivityResumed()
        phoneLlm?.setForeground(true)
        MiyinFloatingService.setAppForeground(true)
        MiyinSubtitleOverlayService.setAppForeground(true)
        val restoreFloating = getSharedPreferences(MiyinFloatingService.PREFS_NAME, MODE_PRIVATE)
            .getBoolean(MiyinFloatingService.PREF_ENABLED, false)
        if (restoreFloating && Settings.canDrawOverlays(this) && !MiyinFloatingService.running) {
            val serviceIntent = Intent(this, MiyinFloatingService::class.java)
            runCatching {
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(serviceIntent)
                else startService(serviceIntent)
            }
        }
        setHighRefresh(false)
    }

    override fun onPause() {
        phoneLlm?.setForeground(false)
        MiyinFloatingService.setAppForeground(false)
        MiyinSubtitleOverlayService.setAppForeground(false)
        voiceHandler?.onActivityPaused()
        setHighRefresh(false)
        super.onPause()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level == android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
            level == android.content.ComponentCallbacks2.TRIM_MEMORY_COMPLETE) phoneLlm?.stop()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        phoneLlm?.stop()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        phoneLlm?.dispose(); phoneLlm = null
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            performanceChannelName,
        ).setMethodCallHandler(null)
        translationChannel?.setMethodCallHandler(null)
        translationChannel = null
        translationHandler?.dispose()
        translationHandler = null
        attachmentOcrChannel?.setMethodCallHandler(null)
        attachmentOcrChannel = null
        attachmentOcrHandler?.dispose()
        attachmentOcrHandler = null
        voiceChannel?.setMethodCallHandler(null)
        voiceChannel = null
        voiceEventsChannel?.setStreamHandler(null)
        voiceEventsChannel = null
        voiceHandler?.dispose()
        voiceHandler = null
        floatingChannel?.setMethodCallHandler(null)
        floatingChannel = null
        playbackCaptureBridge?.dispose()
        playbackCaptureBridge = null
        subtitleChannel?.setMethodCallHandler(null)
        subtitleChannel = null
        MiyinSubtitleOverlayService.onQuickPreferencesChanged = null
        microphoneSessionChannel?.setMethodCallHandler(null)
        microphoneSessionChannel = null
        liveAudioHandler?.stop()
        liveAudioChannel?.setMethodCallHandler(null)
        liveAudioChannel = null
        liveAudioHandler = null
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
