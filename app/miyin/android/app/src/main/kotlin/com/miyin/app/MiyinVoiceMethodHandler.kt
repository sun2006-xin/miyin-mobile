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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

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
    private val streamWriter = Executors.newSingleThreadExecutor()
    @Volatile private var isActivityPaused = true
    @Volatile private var activeStream: PcmStream? = null
    private class PcmStream(val id: String, val track: AudioTrack, val sampleRate: Int) {
        val queuedBytes = AtomicInteger(0)
        var framesWritten = 0L
        var accepting = true
        var firstChunk = true
        val createdAt = SystemClock.elapsedRealtime()
    }

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
                "beginAudioStream" -> beginAudioStream(call, result)
                "appendAudioStream" -> appendAudioStream(call, result)
                "finishAudioStream" -> finishAudioStream(call, result)
                "abortAudioStream" -> abortAudioStream(call, result)
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
        isActivityPaused = true
        stopPlayback(emitStopped = true, completePending = true)
    }

    fun onActivityResumed() {
        isActivityPaused = false
    }

    fun dispose() {
        isActivityPaused = true
        stopPlayback(emitStopped = false, completePending = false)
        streamWriter.shutdownNow()
        eventSink = null
    }

    private fun beginAudioStream(call: MethodCall, result: MethodChannel.Result) {
        val id = readSessionId(call, result) ?: return
        if (isActivityPaused) {
            result.success(mapOf("status" to "cancelled", "sessionId" to id)); return
        }
        val rate = call.argument<Int>("sampleRate") ?: 0
        if (rate !in 8000..48000) {
            result.error("invalid_pcm_rate", "语音采样率无效。", null); return
        }
        stopPlayback(emitStopped = true, completePending = true)
        val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(maxOf(minimum, rate / 5 * 2))
            .setTransferMode(AudioTrack.MODE_STREAM).build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release(); result.error("tts_playback_failed", "无法启动流式语音。", null); return
        }
        audioTrack = track; activePlaybackId = id
        activeStream = PcmStream(id, track, rate)
        track.play()
        result.success(mapOf("status" to "ready", "sessionId" to id))
    }

    private fun appendAudioStream(call: MethodCall, result: MethodChannel.Result) {
        val id = readSessionId(call, result) ?: return
        val stream = activeStream
        if (isActivityPaused || stream == null || stream.id != id || !stream.accepting) {
            result.success(mapOf("status" to "cancelled")); return
        }
        val bytes = call.argument<ByteArray>("pcm")
        if (bytes == null || bytes.isEmpty() || bytes.size % 2 != 0 || bytes.size > 65536) {
            result.error("invalid_pcm_chunk", "流式语音数据无效。", null); return
        }
        if (stream.queuedBytes.addAndGet(bytes.size) > MAX_STREAM_QUEUE_BYTES) {
            stream.queuedBytes.addAndGet(-bytes.size)
            result.error("tts_buffer_full", "语音缓冲已满，请缩短内容重试。", null); return
        }
        streamWriter.execute {
            try {
                var offset = 0
                while (activeStream === stream && offset < bytes.size) {
                    val written = stream.track.write(bytes, offset, minOf(8192, bytes.size - offset), AudioTrack.WRITE_BLOCKING)
                    if (written <= 0) throw IllegalStateException("PCM write failed: $written")
                    offset += written; stream.framesWritten += written / 2
                    if (stream.firstChunk) {
                        stream.firstChunk = false
                        Log.d(TAG, "stream firstPcmWriteMs=${SystemClock.elapsedRealtime() - stream.createdAt} sessionId=$id")
                        emitVoiceEvent("tts_started", id)
                    }
                }
            } catch (error: Exception) {
                mainHandler.post {
                    if (activeStream === stream) finishPlayback("tts_error", id, "流式语音播放失败。")
                }
            } finally { stream.queuedBytes.addAndGet(-bytes.size) }
        }
        // The PCM writer is separate from the UI thread. Return once accepted so
        // Dart can queue the next synthesis without waiting for playback to end.
        result.success(mapOf("status" to "speaking", "sessionId" to id))
    }

    private fun finishAudioStream(call: MethodCall, result: MethodChannel.Result) {
        val id = readSessionId(call, result) ?: return
        val stream = activeStream
        if (stream == null || stream.id != id) { result.success(mapOf("status" to "cancelled")); return }
        stream.accepting = false
        streamWriter.execute {
            val frames = stream.framesWritten
            mainHandler.post {
                if (activeStream !== stream) return@post
                val poll = object : Runnable {
                    override fun run() {
                        if (activeStream !== stream) return
                        val played = stream.track.playbackHeadPosition.toLong() and 0xffffffffL
                        if (played >= frames) finishPlayback("tts_done", id)
                        else { fastCompletion = this; mainHandler.postDelayed(this, 40L) }
                    }
                }
                fastCompletion = poll; mainHandler.post(poll)
            }
        }
        result.success(mapOf("status" to "finishing", "sessionId" to id))
    }

    private fun abortAudioStream(call: MethodCall, result: MethodChannel.Result) {
        val id = readSessionId(call, result) ?: return
        if (activeStream?.id == id) {
            if (call.argument<Boolean>("failed") == true) finishPlayback("tts_error", id, "语音生成中断，请重新朗读。")
            else stopPlayback(emitStopped = true, completePending = true)
        }
        result.success(mapOf("status" to "stopped"))
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
        if (isActivityPaused) {
            audioFile.delete()
            result.success(mapOf("status" to "cancelled", "sessionId" to sessionId))
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
                if (isActivityPaused) {
                    stopPlayback(emitStopped = true, completePending = true)
                    return@setOnPreparedListener
                }
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
        activeStream = null
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
        activeStream = null
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
        const val MAX_STREAM_QUEUE_BYTES = 8 * 1024 * 1024
        const val TTS_MODEL_BYTES = 177_392_565L
    }
}
