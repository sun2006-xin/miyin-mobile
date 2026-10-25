package com.miyin.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.concurrent.thread
import kotlin.math.abs

/** Captures only playback that Android and the playing app permit. */
class MiyinPlaybackCaptureService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "projection_result_code"
        const val EXTRA_RESULT_DATA = "projection_result_data"
        const val EXTRA_RECORDING_SESSION_ID = "recording_session_id"
        const val EXTRA_RECORD_SCREEN = "record_screen"
        const val EXTRA_RECORD_PLAYBACK_AUDIO = "record_playback_audio"
        private const val CHANNEL_ID = "miyin_playback_capture"
        private const val NOTIFICATION_ID = 4302
        @Volatile var running = false
            private set
        @Volatile private var activeRecording: MiyinSessionRecorder? = null
        @Volatile private var lastRecording: Map<String, Any?> = mapOf("state" to "idle")
        fun recordingStatus(): Map<String, Any?> = activeRecording?.status() ?: lastRecording
    }

    private var projection: MediaProjection? = null
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    private var sessionRecorder: MiyinSessionRecorder? = null
    private var capturePlaybackAudio = true
    @Volatile private var stopping = false
    private val main = Handler(Looper.getMainLooper())
    private val captureSessionId = UUID.randomUUID().toString()

    private fun emitCapture(type: String, fields: Map<String, Any?> = emptyMap()) {
        MiyinPlaybackEvents.emit(type, fields + ("captureSessionId" to captureSessionId))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running || stopping) return START_NOT_STICKY
        if (Build.VERSION.SDK_INT < 29) {
            fail("playback_unsupported", "此安卓版本不支持录制其他应用音频。")
            return START_NOT_STICKY
        }
        val code = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val resultData = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
        if (code == 0 || resultData == null) {
            fail("projection_missing", "需要重新允许系统音频录制。")
            return START_NOT_STICKY
        }
        capturePlaybackAudio = intent?.getBooleanExtra(EXTRA_RECORD_PLAYBACK_AUDIO, true) != false
        try {
            createChannel()
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            val manager = getSystemService(MediaProjectionManager::class.java)
            projection = manager.getMediaProjection(code, resultData)
            projection!!.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    if (stopping) return
                    emitCapture("capture_stopped", mapOf("reason" to "permission_revoked"))
                    stopSelf()
                }
            }, main)
            val recordingSessionId = intent?.getStringExtra(EXTRA_RECORDING_SESSION_ID)
            if (!recordingSessionId.isNullOrBlank()) {
                sessionRecorder = MiyinSessionRecorder(
                    this, recordingSessionId, captureSessionId,
                    intent?.getBooleanExtra(EXTRA_RECORD_SCREEN, false) == true,
                    capturePlaybackAudio,
                ) { type, fields -> emitCapture(type, fields) }.also {
                    activeRecording = it
                    it.start(projection!!)
                }
            }
            if (!capturePlaybackAudio) {
                running = true
                emitCapture("capture_started", mapOf("recordPlaybackAudio" to false))
                return START_NOT_STICKY
            }
            val config = AudioPlaybackCaptureConfiguration.Builder(projection!!)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minimum = AudioRecord.getMinBufferSize(
                16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minimum <= 0) error("Unsupported capture format")
            recorder = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minimum * 4, 32768))
                .setAudioPlaybackCaptureConfig(config)
                .build()
            if (recorder?.state != AudioRecord.STATE_INITIALIZED) error("AudioRecord did not initialize")
            recorder!!.startRecording()
            sessionRecorder?.markPlaybackStarted()
            running = true
            emitCapture("capture_started")
            worker = thread(name = "miyin-playback-capture") { captureLoop() }
        } catch (error: Exception) {
            fail("capture_start_failed", "无法采集此设备上的其他应用音频。")
        }
        return START_NOT_STICKY
    }

    private fun captureLoop() {
        val audio = recorder ?: return
        val chunk = ByteArray(8192)
        // Prefer a pause to end a phrase. A hard boundary is still needed for
        // uninterrupted speech, but carry the final acoustic frames forward so
        // a word straddling that boundary is not lost.
        val segment = java.io.ByteArrayOutputStream(256000)
        var audibleSamples = 0
        var trailingQuietBytes = 0
        var silentSegments = 0
        var segmentId = 0
        while (!stopping) {
            val count = try { audio.read(chunk, 0, chunk.size) } catch (_: Exception) { break }
            if (count < 0) break
            if (count == 0) continue
            sessionRecorder?.writeAudio(chunk, count)
            segment.write(chunk, 0, count)
            var position = 0
            var chunkAudibleSamples = 0
            while (position + 1 < count) {
                val sample = ((chunk[position].toInt() and 0xff) or
                    (chunk[position + 1].toInt() shl 8)).toShort().toInt()
                if (abs(sample) > 180) {
                    audibleSamples++
                    chunkAudibleSamples++
                }
                position += 2
            }
            // Forward small PCM blocks for a separate streaming preview. The
            // existing WAV segment remains the source of final transcript text.
            emitCapture("capture_audio", mapOf(
                "segmentId" to segmentId,
                "pcm" to chunk.copyOf(count),
            ))
            trailingQuietBytes = if (chunkAudibleSamples * 100 < (count / 2) * 2) {
                trailingQuietBytes + count
            } else {
                0
            }
            val phraseEnded = segment.size() >= 32000 && trailingQuietBytes >= 28800
            val lengthLimitReached = segment.size() >= 320000
            if (phraseEnded || lengthLimitReached) {
                val segmentBytes = segment.toByteArray()
                if (audibleSamples > maxOf(800, segment.size() / 48)) {
                    silentSegments = 0
                    try {
                        val path = saveWav(segmentBytes)
                        emitCapture("capture_segment", mapOf(
                            "segmentId" to segmentId,
                            "path" to path,
                            "durationMs" to segment.size() / 32,
                            "sampleRate" to 16000,
                        ))
                    } catch (_: Exception) {
                        emitCapture("capture_error", mapOf(
                            "code" to "segment_write_failed",
                            "message" to "无法保存临时音频段。",
                        ))
                    }
                } else {
                    silentSegments++
                    if (silentSegments == 3) emitCapture("capture_silent", mapOf(
                        "message" to "尚未收到可采集的媒体声音；有些应用禁止系统录制其音频。",
                    ))
                }
                segment.reset()
                segmentId++
                audibleSamples = 0
                trailingQuietBytes = 0
                if (lengthLimitReached && !phraseEnded) {
                    val overlapBytes = minOf(16000, segmentBytes.size) // 500 ms
                    val start = segmentBytes.size - overlapBytes
                    segment.write(segmentBytes, start, overlapBytes)
                    var index = start
                    while (index + 1 < segmentBytes.size) {
                        val sample = ((segmentBytes[index].toInt() and 0xff) or
                            (segmentBytes[index + 1].toInt() shl 8)).toShort().toInt()
                        if (abs(sample) > 180) audibleSamples++
                        index += 2
                    }
                }
            }
        }
        // Preserve the final spoken phrase when the meeting is stopped
        // between scheduled segment boundaries.
        if (segment.size() >= 32000 && audibleSamples > maxOf(800, segment.size() / 48)) {
            try {
                val path = saveWav(segment.toByteArray())
                emitCapture("capture_segment", mapOf(
                    "segmentId" to segmentId,
                    "path" to path,
                    "durationMs" to segment.size() / 32,
                    "sampleRate" to 16000,
                ))
            } catch (_: Exception) {
                emitCapture("capture_error", mapOf(
                    "code" to "segment_write_failed",
                    "message" to "无法保存最后一段临时音频。",
                ))
            }
        }
        if (activeRecording != null) sessionRecorder?.let {
            lastRecording = it.finish()
            activeRecording = null
        }
        emitCapture("capture_flushed")
        if (!stopping) main.post { stopSelf() }
    }

    private fun saveWav(pcm: ByteArray): String {
        val directory = File(cacheDir, "live-playback").apply { mkdirs() }
        val file = File(directory, "${UUID.randomUUID()}.wav")
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII)); putInt(36 + pcm.size)
            put("WAVEfmt ".toByteArray(Charsets.US_ASCII)); putInt(16)
            putShort(1.toShort()); putShort(1.toShort()); putInt(16000); putInt(32000)
            putShort(2.toShort()); putShort(16.toShort())
            put("data".toByteArray(Charsets.US_ASCII)); putInt(pcm.size)
        }.array()
        FileOutputStream(file).use { output ->
            output.write(header)
            output.write(pcm)
        }
        return file.absolutePath
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "觅音同传音频", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(if (capturePlaybackAudio) "觅音正在识别媒体声音" else "觅音正在录制同传画面")
            .setContentText(if (capturePlaybackAudio) "仅采集系统允许录制的媒体声音" else "录屏不含音轨；麦克风音频单独保存")
            .setOngoing(true)
            .build()
    }

    private fun fail(code: String, message: String) {
        emitCapture("capture_error", mapOf("code" to code, "message" to message))
        stopSelf()
    }

    override fun onDestroy() {
        stopping = true
        runCatching { recorder?.stop() }
        worker?.interrupt()
        runCatching { worker?.join(3000) }
        if (activeRecording != null) sessionRecorder?.let {
            lastRecording = it.finish()
            activeRecording = null
        }
        if (!capturePlaybackAudio) emitCapture("capture_flushed")
        sessionRecorder = null
        recorder?.release()
        recorder = null
        worker = null
        runCatching { projection?.stop() }
        projection = null
        if (running) emitCapture("capture_stopped", mapOf("reason" to "stopped"))
        running = false
        super.onDestroy()
    }
}
