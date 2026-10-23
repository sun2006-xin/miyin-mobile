package com.miyin.app

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.Uri
import kotlin.concurrent.thread
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

internal object MiyinPlaybackEvents {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    fun listen(events: EventChannel.EventSink?) { sink = events }

    fun emit(type: String, fields: Map<String, Any?> = emptyMap()) {
        main.post { sink?.success(mapOf("type" to type) + fields) }
    }
}

internal class MiyinPlaybackCaptureBridge(private val activity: MainActivity) :
    EventChannel.StreamHandler {
    companion object {
        const val REQUEST_CODE = 4302
        const val METHOD_CHANNEL = "com.miyin.app/playback-capture"
        const val EVENT_CHANNEL = "com.miyin.app/playback-capture-events"
    }

    private var pendingPermission = false
    private var pendingRecordingSessionId: String? = null
    private var pendingRecordScreen = false
    private var pendingRecordPlaybackAudio = true
    private var cancelledPendingPermission = false
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    fun register(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> {
                        val wantsRecording = call.argument<Boolean>("recordSession") == true
                        val sessionId = call.argument<String>("recordingSessionId")
                        if (wantsRecording && (sessionId.isNullOrBlank() || sessionId.length > 100 ||
                                !sessionId.all { it.isLetterOrDigit() || it == '-' || it == '_' })) {
                            result.error("invalid_recording_session", "录制会话编号无效。", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT < 29) {
                            result.error("playback_unsupported", "此安卓版本不支持录制其他应用音频。", null)
                        } else if (pendingPermission) {
                            result.success(mapOf("status" to "permission_requested"))
                        } else if (MiyinPlaybackCaptureService.running) {
                            result.success(mapOf("status" to "capturing", "recording" to
                                MiyinPlaybackCaptureService.recordingStatus()))
                        } else {
                            try {
                                pendingPermission = true
                                cancelledPendingPermission = false
                                pendingRecordingSessionId = if (wantsRecording) sessionId else null
                                pendingRecordScreen = wantsRecording && call.argument<Boolean>("recordScreen") == true
                                pendingRecordPlaybackAudio = call.argument<Boolean>("recordPlaybackAudio") != false
                                val manager = activity.getSystemService(MediaProjectionManager::class.java)
                                activity.startActivityForResult(
                                    manager.createScreenCaptureIntent(), REQUEST_CODE,
                                )
                                result.success(mapOf("status" to "permission_requested"))
                            } catch (error: Exception) {
                                pendingPermission = false
                                pendingRecordingSessionId = null
                                pendingRecordScreen = false
                                pendingRecordPlaybackAudio = true
                                result.error("projection_unavailable", "无法打开系统音频授权。", null)
                            }
                        }
                    }
                    "stopCapture" -> {
                        if (pendingPermission) cancelledPendingPermission = true
                        activity.stopService(Intent(activity, MiyinPlaybackCaptureService::class.java))
                        result.success(mapOf("status" to "stopping"))
                    }
                    "status" -> result.success(mapOf(
                        "running" to MiyinPlaybackCaptureService.running,
                        "permissionRequested" to pendingPermission,
                    ))
                    "recordingStatus" -> result.success(MiyinPlaybackCaptureService.recordingStatus())
                    "listRecordings" -> result.success(MiyinSessionRecordingStore.list(activity))
                    "publishMicrophoneRecording" -> {
                        val sessionId = call.argument<String>("recordingSessionId")
                        val path = call.argument<String>("path")
                        if (sessionId.isNullOrBlank() || path.isNullOrBlank()) {
                            result.error("invalid_microphone_recording", "缺少麦克风录音文件。", null)
                        } else thread(name = "miyin-publish-microphone") {
                            val published = runCatching {
                                val mic = MiyinSessionRecordingStore.publishMicrophone(
                                    activity, sessionId, path,
                                    (call.argument<Number>("microphoneStartedAtMs"))?.toLong(),
                                )
                                mic + composeAndReport(sessionId)
                            }
                            activity.runOnUiThread {
                                published.fold(
                                    onSuccess = {
                                        if (it["muxError"] != null) result.error(
                                            "mp4_audio_mux_failed", it["muxError"] as String, null,
                                        ) else result.success(it)
                                    },
                                    onFailure = {
                                        result.error("microphone_export_failed", "麦克风录音导出失败，请检查手机剩余空间。", null)
                                    },
                                )
                            }
                        }
                    }
                    "composeRecording" -> {
                        val sessionId = call.argument<String>("recordingSessionId")
                        if (sessionId.isNullOrBlank()) {
                            result.error("invalid_recording_session", "缺少录制会话编号。", null)
                        } else thread(name = "miyin-compose-recording") {
                            val composed = composeAndReport(sessionId)
                            activity.runOnUiThread {
                                if (composed["muxError"] != null) result.error(
                                    "mp4_audio_mux_failed", composed["muxError"] as String, null,
                                ) else result.success(composed)
                            }
                        }
                    }
                    "openRecording" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null || !MiyinSessionRecordingStore.owns(activity, uri)) {
                            result.error("recording_not_found", "未找到这份同传录制文件。", null)
                        } else try {
                            val parsed = Uri.parse(uri)
                            val mime = if (MiyinSessionRecordingStore.isVideo(activity, uri))
                                "video/mp4" else "audio/wav"
                            activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(parsed, mime)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            })
                            result.success(mapOf("status" to "opened"))
                        } catch (_: Exception) {
                            result.error("recording_viewer_missing", "手机上没有可打开此录制文件的应用。", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingPermission = false
        if (cancelledPendingPermission) {
            cancelledPendingPermission = false
            pendingRecordingSessionId = null
            pendingRecordScreen = false
            pendingRecordPlaybackAudio = true
            return true
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingRecordingSessionId = null
            pendingRecordScreen = false
            pendingRecordPlaybackAudio = true
            MiyinPlaybackEvents.emit("capture_error", mapOf(
                "code" to "projection_denied",
                "message" to "没有获得系统录屏授权。",
            ))
            return true
        }
        try {
            val serviceIntent = Intent(activity, MiyinPlaybackCaptureService::class.java).apply {
                putExtra(MiyinPlaybackCaptureService.EXTRA_RESULT_CODE, resultCode)
                putExtra(MiyinPlaybackCaptureService.EXTRA_RESULT_DATA, data)
                putExtra(MiyinPlaybackCaptureService.EXTRA_RECORDING_SESSION_ID, pendingRecordingSessionId)
                putExtra(MiyinPlaybackCaptureService.EXTRA_RECORD_SCREEN, pendingRecordScreen)
                putExtra(MiyinPlaybackCaptureService.EXTRA_RECORD_PLAYBACK_AUDIO, pendingRecordPlaybackAudio)
            }
            pendingRecordingSessionId = null
            pendingRecordScreen = false
            pendingRecordPlaybackAudio = true
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(serviceIntent)
            else activity.startService(serviceIntent)
        } catch (error: Exception) {
            pendingRecordingSessionId = null
            pendingRecordScreen = false
            pendingRecordPlaybackAudio = true
            MiyinPlaybackEvents.emit("capture_error", mapOf(
                "code" to "capture_start_failed",
                "message" to "系统音频采集未能启动。",
            ))
        }
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        MiyinPlaybackEvents.listen(events)
    }

    private fun composeAndReport(sessionId: String): Map<String, Any?> {
        val captureId = MiyinSessionRecordingStore.list(activity)
            .firstOrNull { it["recordingSessionId"] == sessionId }?.get("captureSessionId")
        return runCatching { MiyinSessionMp4Muxer.compose(activity, sessionId) }.fold(
            onSuccess = { merged ->
                MiyinPlaybackEvents.emit("recording_saved", merged + mapOf(
                    "captureSessionId" to captureId, "recordingSessionId" to sessionId,
                ))
                merged
            },
            onFailure = {
                val message = "有声录屏合成失败；画面和分轨录音已保留。"
                MiyinSessionRecordingStore.save(activity, mapOf(
                    "recordingSessionId" to sessionId,
                    "recordingError" to message,
                ))
                MiyinPlaybackEvents.emit("recording_error", mapOf(
                    "captureSessionId" to captureId,
                    "recordingSessionId" to sessionId,
                    "code" to "mp4_audio_mux_failed",
                    "message" to message,
                ))
                mapOf("recordingSessionId" to sessionId,
                    "videoHasAudio" to false, "muxError" to message)
            },
        )
    }

    override fun onCancel(arguments: Any?) {
        MiyinPlaybackEvents.listen(null)
    }

    fun dispose() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        MiyinPlaybackEvents.listen(null)
        methodChannel = null
        eventChannel = null
    }
}
