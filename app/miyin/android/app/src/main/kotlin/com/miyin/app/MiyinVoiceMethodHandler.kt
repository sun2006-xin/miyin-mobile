package com.miyin.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Local synthesized audio playback bridge for the WebView UI. */
internal class MiyinVoiceMethodHandler(
    private val activity: FlutterActivity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private var mediaPlayer: MediaPlayer? = null
    private var audioTrack: AudioTrack? = null
    private var fastCompletion: Runnable? = null
    private var activePlaybackId: String? = null
    private var activeAudioFile: File? = null
    private var pendingPlaybackResult: MethodChannel.Result? = null
    private var prepareTimeout: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "playAudio" -> playAudio(call, result)
                "stopSpeaking" -> stopSpeaking(result)
                "offlineTtsStatus" -> offlineTtsStatus(result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e(TAG, "Voice method ${call.method} failed", error)
            result.error(
                "voice_unavailable",
                error.localizedMessage ?: "本机语音功能暂时不可用。",
                null,
            )
        }
    }

    fun onActivityPaused() {
        stopPlayback(emitStopped = true, completePending = true)
    }

    fun dispose() {
        stopPlayback(emitStopped = false, completePending = false)
        eventSink = null
    }

    private fun playAudio(call: MethodCall, result: MethodChannel.Result) {
        val nativeRequestAtMs = SystemClock.elapsedRealtime()
        val sessionId = readSessionId(call, result) ?: return
        val rawPath = call.argument<String>("path")
        if (rawPath.isNullOrBlank()) {
            result.error("invalid_audio_path", "离线语音文件无效。", null)
            return
        }
        val audioFile = try {
            File(rawPath).canonicalFile
        } catch (error: Exception) {
            result.error("invalid_audio_path", "离线语音文件无效。", null)
            return
        }
        val cacheRoot = File(activity.cacheDir.canonicalPath).path + File.separator
        if (!audioFile.path.startsWith(cacheRoot) || !audioFile.isFile) {
            result.error("invalid_audio_path", "离线语音文件不在应用缓存目录中。", null)
            return
        }

        stopPlayback(emitStopped = true, completePending = true)
        if (tryFastPcmPlayback(audioFile, sessionId, result, nativeRequestAtMs)) return
        val player = MediaPlayer()
        mediaPlayer = player
        activePlaybackId = sessionId
        activeAudioFile = audioFile
        pendingPlaybackResult = result
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            player.setDataSource(audioFile.path)
            player.setOnPreparedListener { prepared ->
                if (mediaPlayer !== prepared) return@setOnPreparedListener
                clearPrepareTimeout()
                try {
                    prepared.start()
                    if (!prepared.isPlaying) {
                        throw IllegalStateException("MediaPlayer did not start.")
                    }
                    Log.d(
                        TAG,
                        "playback nativeRequestToStartMs=${SystemClock.elapsedRealtime() - nativeRequestAtMs} " +
                            "status=speaking sessionId=$sessionId",
                    )
                    pendingPlaybackResult?.success(
                        mapOf("status" to "speaking", "sessionId" to sessionId),
                    )
                    pendingPlaybackResult = null
                    emitVoiceEvent("tts_started", sessionId)
                } catch (error: Exception) {
                    failPlayback(
                        prepared,
                        sessionId,
                        error.localizedMessage ?: "觅音无法启动语音播放。",
                    )
                }
            }
            player.setOnCompletionListener { completed ->
                if (mediaPlayer !== completed) return@setOnCompletionListener
                finishPlayback("tts_done", sessionId)
            }
            player.setOnErrorListener { failed, _, _ ->
                if (mediaPlayer === failed) {
                    failPlayback(
                        failed,
                        sessionId,
                        "觅音无法播放本机生成的语音。",
                    )
                }
                true
            }
            schedulePrepareTimeout(player, sessionId)
            player.prepareAsync()
        } catch (error: Exception) {
            pendingPlaybackResult = null
            mediaPlayer = null
            activePlaybackId = null
            activeAudioFile = null
            try {
                player.release()
            } catch (_: Exception) {}
            audioFile.delete()
            result.error(
                "tts_playback_failed",
                error.localizedMessage ?: "觅音无法播放本机生成的语音。",
                null,
            )
        }
    }

    private fun tryFastPcmPlayback(
        file: File,
        sessionId: String,
        result: MethodChannel.Result,
        requestedAtMs: Long,
    ): Boolean {
        var track: AudioTrack? = null
        try {
            val bytes = file.readBytes()
            if (bytes.size < 44 || bytes.size > MAX_FAST_WAV_BYTES ||
                String(bytes, 0, 4, Charsets.US_ASCII) != "RIFF" ||
                String(bytes, 8, 4, Charsets.US_ASCII) != "WAVE" ||
                String(bytes, 36, 4, Charsets.US_ASCII) != "data") return false
            val header = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val sampleRate = header.getInt(24)
            val dataLength = header.getInt(40)
            if (sampleRate !in 8000..48000 || dataLength <= 0 ||
                dataLength % 2 != 0 || dataLength + 44 > bytes.size ||
                header.getShort(20).toInt() != 1 || header.getShort(22).toInt() != 1 ||
                header.getShort(34).toInt() != 16) return false
            track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(dataLength)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            if (track.state != AudioTrack.STATE_INITIALIZED ||
                track.write(bytes, 44, dataLength) != dataLength) {
                track.release()
                return false
            }
            audioTrack = track
            activePlaybackId = sessionId
            activeAudioFile = file
            val frames = dataLength / 2
            track.setNotificationMarkerPosition(frames)
            track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(completed: AudioTrack?) {
                    if (audioTrack === completed && activePlaybackId == sessionId) finishPlayback("tts_done", sessionId)
                }
                override fun onPeriodicNotification(completed: AudioTrack?) = Unit
            }, mainHandler)
            track.play()
            val completion = Runnable {
                if (audioTrack === track && activePlaybackId == sessionId) finishPlayback("tts_done", sessionId)
            }
            fastCompletion = completion
            mainHandler.postDelayed(completion, frames * 1000L / sampleRate + 700L)
            Log.d(TAG, "playback nativeRequestToStartMs=${SystemClock.elapsedRealtime() - requestedAtMs} status=speaking fastPcm=true sessionId=$sessionId")
            result.success(mapOf("status" to "speaking", "sessionId" to sessionId))
            emitVoiceEvent("tts_started", sessionId)
            return true
        } catch (error: Exception) {
            if (audioTrack === track) {
                audioTrack = null
                activePlaybackId = null
                activeAudioFile = null
            }
            try { track?.release() } catch (_: Exception) {}
            Log.w(TAG, "Fast PCM unavailable; falling back to MediaPlayer", error)
            return false
        }
    }

    private fun offlineTtsStatus(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "status" to "bundled",
                "bundled" to true,
                "chineseReady" to true,
                "englishReady" to true,
                "modelBytes" to TTS_MODEL_BYTES,
                "sampleRate" to 44_100,
            ),
        )
    }

    private fun stopSpeaking(result: MethodChannel.Result) {
        stopPlayback(emitStopped = true, completePending = true)
        result.success(mapOf("status" to "stopped"))
    }

    private fun stopPlayback(emitStopped: Boolean, completePending: Boolean) {
        clearPrepareTimeout()
        clearFastCompletion()
        val sessionId = activePlaybackId
        val player = mediaPlayer
        mediaPlayer = null
        val fastTrack = audioTrack
        audioTrack = null
        activePlaybackId = null
        val audioFile = activeAudioFile
        activeAudioFile = null
        if (completePending) {
            pendingPlaybackResult?.success(mapOf("status" to "cancelled"))
        }
        pendingPlaybackResult = null
        try {
            player?.stop()
        } catch (_: IllegalStateException) {}
        player?.release()
        try { fastTrack?.stop() } catch (_: IllegalStateException) {}
        fastTrack?.release()
        audioFile?.delete()
        if (emitStopped && sessionId != null) emitVoiceEvent("tts_stopped", sessionId)
    }

    private fun finishPlayback(type: String, sessionId: String, message: String? = null) {
        clearPrepareTimeout()
        clearFastCompletion()
        val player = mediaPlayer
        mediaPlayer = null
        val fastTrack = audioTrack
        audioTrack = null
        activePlaybackId = null
        val audioFile = activeAudioFile
        activeAudioFile = null
        pendingPlaybackResult = null
        player?.release()
        try { fastTrack?.stop() } catch (_: IllegalStateException) {}
        fastTrack?.release()
        audioFile?.delete()
        emitVoiceEvent(type, sessionId, message = message)
    }

    private fun schedulePrepareTimeout(player: MediaPlayer, sessionId: String) {
        clearPrepareTimeout()
        val timeout = Runnable {
            if (mediaPlayer === player && pendingPlaybackResult != null) {
                failPlayback(
                    player,
                    sessionId,
                    "语音准备时间过长，请检查手机媒体音量后重试。",
                )
            }
        }
        prepareTimeout = timeout
        mainHandler.postDelayed(timeout, PLAYBACK_PREPARE_TIMEOUT_MS)
    }

    private fun clearPrepareTimeout() {
        prepareTimeout?.let(mainHandler::removeCallbacks)
        prepareTimeout = null
    }

    private fun clearFastCompletion() {
        fastCompletion?.let(mainHandler::removeCallbacks)
        fastCompletion = null
    }

    private fun failPlayback(player: MediaPlayer, sessionId: String, message: String) {
        if (mediaPlayer !== player) return
        pendingPlaybackResult?.error("tts_playback_failed", message, null)
        pendingPlaybackResult = null
        finishPlayback("tts_error", sessionId, message)
    }

    private fun readSessionId(call: MethodCall, result: MethodChannel.Result): String? {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrBlank() || sessionId.length > MAX_SESSION_ID_LENGTH) {
            result.error("invalid_session_id", "语音操作标识无效。", null)
            return null
        }
        return sessionId
    }

    private fun emitVoiceEvent(
        type: String,
        sessionId: String,
        text: String? = null,
        message: String? = null,
    ) {
        val event = buildMap<String, Any> {
            put("type", type)
            put("sessionId", sessionId)
            if (text != null) put("text", text)
            if (message != null) put("message", message)
        }
        activity.runOnUiThread { eventSink?.success(event) }
    }

    private companion object {
        const val TAG = "MiyinVoice"
        const val MAX_SESSION_ID_LENGTH = 96
        const val PLAYBACK_PREPARE_TIMEOUT_MS = 12_000L
        const val MAX_FAST_WAV_BYTES = 2_000_000
        const val TTS_MODEL_BYTES = 177_392_565L
    }
}
