package com.miyin.app

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/** Full-session playback WAV and silent MP4, both published to user-visible MediaStore. */
internal class MiyinSessionRecorder(
    private val context: Context,
    val sessionId: String,
    private val captureSessionId: String,
    private val recordScreen: Boolean,
    private val recordPlaybackAudio: Boolean,
    private val emit: (String, Map<String, Any?>) -> Unit,
) {
    private val startedAtMs = System.currentTimeMillis()
    private val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(startedAtMs))
    private var audioUri: Uri? = null
    private var audioDescriptor: ParcelFileDescriptor? = null
    private var audioStream: FileOutputStream? = null
    private var audioBytes = 0L
    private var videoUri: Uri? = null
    private var videoDescriptor: ParcelFileDescriptor? = null
    private var videoRecorder: MediaRecorder? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var videoStarted = false
    private var videoStartedAtMs = 0L
    private var playbackStartedAtMs = 0L
    private var ended = false
    private val audioName = "Miyin-Live-$stamp-$sessionId-playback.wav"
    private val videoName = "Miyin-Live-$stamp-$sessionId-screen.mp4"

    fun start(projection: MediaProjection) {
        if (recordPlaybackAudio) try {
            audioUri = MiyinSessionRecordingStore.createAudio(context, audioName)
            audioDescriptor = context.contentResolver.openFileDescriptor(audioUri!!, "rw")
                ?: error("Cannot open WAV for writing")
            audioStream = FileOutputStream(audioDescriptor!!.fileDescriptor).apply { write(wavHeader(0)) }
        } catch (_: Exception) {
            discardAudio()
            emit("recording_error", mapOf(
                "recordingSessionId" to sessionId,
                "code" to "audio_export_failed",
                "message" to "无法建立完整同传音频文件，请检查手机剩余空间。",
            ))
        }
        if (recordScreen) startVideo(projection)
        emit("recording_started", status())
    }

    @Synchronized fun writeAudio(pcm: ByteArray, count: Int) {
        if (ended || audioStream == null || count <= 0) return
        // RIFF/WAV uses 32-bit chunk lengths; keep well inside its maximum.
        if (audioBytes + count > 3_800_000_000L) {
            audioFailure("audio_size_limit", "完整录音已达到 WAV 文件大小上限。")
            return
        }
        try {
            audioStream!!.write(pcm, 0, count)
            audioBytes += count
        } catch (_: Exception) {
            audioFailure("audio_write_failed", "写入完整同传音频失败，请检查手机剩余空间。")
        }
    }

    @Synchronized fun markPlaybackStarted() { playbackStartedAtMs = System.currentTimeMillis() }

    private fun audioFailure(code: String, message: String) {
        discardAudio()
        emit("recording_error", mapOf(
            "recordingSessionId" to sessionId, "code" to code, "message" to message,
        ))
    }

    private fun startVideo(projection: MediaProjection) {
        try {
            videoUri = MiyinSessionRecordingStore.createVideo(context, videoName)
            videoDescriptor = context.contentResolver.openFileDescriptor(videoUri!!, "rw")
                ?: error("Cannot open MP4 for writing")
            val metrics = context.resources.displayMetrics
            val width = metrics.widthPixels.coerceAtLeast(2)
            val height = metrics.heightPixels.coerceAtLeast(2)
            val scale = minOf(1.0, 1280.0 / maxOf(width, height))
            val encodedWidth = ((width * scale).roundToInt() / 2 * 2).coerceAtLeast(2)
            val encodedHeight = ((height * scale).roundToInt() / 2 * 2).coerceAtLeast(2)
            @Suppress("DEPRECATION")
            val recorder = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
            videoRecorder = recorder
            recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            recorder.setVideoSize(encodedWidth, encodedHeight)
            recorder.setVideoFrameRate(15)
            recorder.setVideoEncodingBitRate(2_000_000)
            recorder.setMaxFileSize(1_800_000_000L)
            recorder.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED) {
                    emit("recording_error", mapOf(
                        "recordingSessionId" to sessionId,
                        "code" to "video_size_limit",
                        "message" to "录屏达到文件大小上限，正在结束本次同传录制。",
                    ))
                    (context as? MiyinPlaybackCaptureService)?.stopSelf()
                }
            }
            recorder.setOutputFile(videoDescriptor!!.fileDescriptor)
            recorder.prepare()
            virtualDisplay = projection.createVirtualDisplay(
                "Miyin live recording", encodedWidth, encodedHeight,
                metrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                recorder.surface, null, null,
            ) ?: error("Cannot create virtual display")
            recorder.start()
            videoStarted = true
            videoStartedAtMs = System.currentTimeMillis()
        } catch (_: Exception) {
            discardVideo()
            emit("recording_error", mapOf(
                "recordingSessionId" to sessionId,
                "code" to "screen_export_failed",
                "message" to "录屏未能启动；其他应用音频仍可单独保存。",
            ))
        }
    }

    @Synchronized fun finish(): Map<String, Any?> {
        if (ended) return status()
        ended = true
        val endedAtMs = System.currentTimeMillis()
        var publishedAudio: Uri? = null
        var publishedVideo: Uri? = null
        if (audioBytes > 0) {
            try {
                val stream = audioStream ?: error("WAV stream missing")
                stream.channel.position(0)
                stream.write(wavHeader(audioBytes.toInt()))
                stream.fd.sync()
                stream.close()
                audioStream = null
                audioDescriptor?.close()
                audioDescriptor = null
                MiyinSessionRecordingStore.publish(context, audioUri!!)
                publishedAudio = audioUri
            } catch (_: Exception) {
                discardAudio()
                emit("recording_error", mapOf("recordingSessionId" to sessionId,
                    "code" to "audio_finalize_failed", "message" to "完整音频保存失败。"))
            }
        } else discardAudio()
        if (videoStarted) {
            try {
                virtualDisplay?.release()
                virtualDisplay = null
                videoRecorder?.stop()
                videoRecorder?.release()
                videoRecorder = null
                videoDescriptor?.close()
                videoDescriptor = null
                MiyinSessionRecordingStore.publish(context, videoUri!!)
                publishedVideo = videoUri
            } catch (_: Exception) {
                discardVideo()
                emit("recording_error", mapOf("recordingSessionId" to sessionId,
                    "code" to "video_finalize_failed", "message" to "录屏文件未能完成保存。"))
            }
        } else discardVideo()
        val savedVideoBytes = publishedVideo?.let { uri ->
            runCatching {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
            }.getOrDefault(0L)
        } ?: 0L
        val metadata = mapOf<String, Any?>(
            "recordingSessionId" to sessionId,
            "captureSessionId" to captureSessionId,
            "state" to "saved",
            "startedAtMs" to startedAtMs,
            "videoStartedAtMs" to videoStartedAtMs,
            "playbackStartedAtMs" to playbackStartedAtMs,
            "endedAtMs" to endedAtMs,
            "durationMs" to endedAtMs - startedAtMs,
            "audioUri" to publishedAudio?.toString(),
            "videoUri" to publishedVideo?.toString(),
            "audioName" to if (publishedAudio != null) audioName else null,
            "videoName" to if (publishedVideo != null) videoName else null,
            "audioBytes" to if (publishedAudio != null) audioBytes + 44 else 0L,
            "videoBytes" to savedVideoBytes,
            "audioSource" to if (recordPlaybackAudio) "other_app_playback" else "none",
            "videoHasAudio" to false,
        )
        if (publishedAudio != null || publishedVideo != null) {
            MiyinSessionRecordingStore.save(context, metadata)
        }
        emit("recording_saved", metadata)
        return metadata
    }

    @Synchronized fun status(): Map<String, Any?> = mapOf(
        "recordingSessionId" to sessionId,
        "state" to if (ended) "saved" else "recording",
        "startedAtMs" to startedAtMs,
        "elapsedMs" to System.currentTimeMillis() - startedAtMs,
        "audioSource" to if (recordPlaybackAudio) "other_app_playback" else "none",
        "videoHasAudio" to false,
        "screenRequested" to recordScreen,
        "audioBytes" to audioBytes,
        "videoRecording" to videoStarted,
    )

    private fun discardAudio() {
        runCatching { audioStream?.close() }; audioStream = null
        runCatching { audioDescriptor?.close() }; audioDescriptor = null
        MiyinSessionRecordingStore.discard(context, audioUri); audioUri = null
    }

    private fun discardVideo() {
        runCatching { virtualDisplay?.release() }; virtualDisplay = null
        runCatching { if (videoStarted) videoRecorder?.stop() }
        runCatching { videoRecorder?.release() }; videoRecorder = null
        videoStarted = false
        runCatching { videoDescriptor?.close() }; videoDescriptor = null
        MiyinSessionRecordingStore.discard(context, videoUri); videoUri = null
    }

    private fun wavHeader(pcmSize: Int): ByteArray = ByteBuffer.allocate(44)
        .order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII)); putInt(36 + pcmSize)
            put("WAVEfmt ".toByteArray(Charsets.US_ASCII)); putInt(16)
            putShort(1.toShort()); putShort(1.toShort()); putInt(16000); putInt(32000)
            putShort(2.toShort()); putShort(16.toShort())
            put("data".toByteArray(Charsets.US_ASCII)); putInt(pcmSize)
        }.array()
}
