package com.miyin.app

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.BufferedInputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max

/** Merges aligned 16 kHz WAV tracks into one AAC track beside the screen H.264 track. */
internal object MiyinSessionMp4Muxer {
    private const val RATE = 16000

    fun compose(context: Context, sessionId: String): Map<String, Any?> {
        val row = MiyinSessionRecordingStore.list(context).firstOrNull {
            it["recordingSessionId"] == sessionId
        } ?: error("No recording session")
        if (row["videoHasAudio"] == true) return row
        val silentVideo = (row["videoUri"] as? String)?.let(Uri::parse)
            ?: error("No screen recording")
        val videoStartedAtMs = (row["videoStartedAtMs"] as? Number)?.toLong()
            ?.takeIf { it > 0 } ?: (row["startedAtMs"] as? Number)?.toLong()
            ?: error("No video start time")
        val mic = (row["microphoneUri"] as? String)?.let(Uri::parse)
        val playback = (row["audioUri"] as? String)?.let(Uri::parse)
        if (mic == null && playback == null) error("No audio recording")
        val micStartedAtMs = (row["microphoneStartedAtMs"] as? Number)?.toLong()
            ?.takeIf { it > 0 } ?: videoStartedAtMs
        val playbackStartedAtMs = (row["playbackStartedAtMs"] as? Number)?.toLong()
            ?.takeIf { it > 0 } ?: videoStartedAtMs

        val sourceDescriptor = context.contentResolver.openFileDescriptor(silentVideo, "r")
            ?: error("Cannot open screen recording")
        val videoExtractor = MediaExtractor()
        val aacFile = File(context.cacheDir, "miyin-aac-$sessionId.m4a")
        var outputUri: Uri? = null
        try {
            videoExtractor.setDataSource(sourceDescriptor.fileDescriptor)
            val videoTrack = findTrack(videoExtractor, "video/")
            val videoFormat = videoExtractor.getTrackFormat(videoTrack)
            val fallbackDurationUs = ((row["durationMs"] as? Number)?.toLong() ?: 0L) * 1000L
            val videoDurationUs = if (videoFormat.containsKey(MediaFormat.KEY_DURATION))
                videoFormat.getLong(MediaFormat.KEY_DURATION) else fallbackDurationUs
            require(videoDurationUs > 0) { "Screen recording has no duration" }
            val audioSources = listOfNotNull(
                mic?.let { AlignedWav(context, it, micStartedAtMs, videoStartedAtMs) },
                playback?.let { AlignedWav(context, it, playbackStartedAtMs, videoStartedAtMs) },
            )
            try {
                encodeMixedAac(audioSources, videoDurationUs, aacFile)
            } finally {
                audioSources.forEach { it.close() }
            }
            val name = ((row["videoName"] as? String) ?: "Miyin-Live-$sessionId-screen.mp4")
                .replace("-screen.mp4", "-meeting.mp4")
            val pendingOutput = MiyinSessionRecordingStore.createVideo(context, name)
            outputUri = pendingOutput
            context.contentResolver.openFileDescriptor(pendingOutput, "rw")?.use { output ->
                remux(videoExtractor, videoTrack, aacFile, output)
            } ?: error("Cannot open merged MP4")
            MiyinSessionRecordingStore.publish(context, pendingOutput)
            val size = context.contentResolver.openFileDescriptor(pendingOutput, "r")?.use {
                it.statSize
            } ?: 0L
            val sources = listOfNotNull(
                if (mic != null) "microphone" else null,
                if (playback != null) "other_app_playback" else null,
            )
            val metadata = mapOf<String, Any?>(
                "recordingSessionId" to sessionId,
                "videoUri" to pendingOutput.toString(),
                "videoName" to name,
                "videoBytes" to size,
                "videoHasAudio" to true,
                "videoAudioSources" to sources,
            )
            MiyinSessionRecordingStore.save(context, metadata)
            MiyinSessionRecordingStore.discard(context, silentVideo)
            return metadata
        } catch (error: Exception) {
            MiyinSessionRecordingStore.discard(context, outputUri)
            throw error
        } finally {
            videoExtractor.release()
            sourceDescriptor.close()
            aacFile.delete()
        }
    }

    private fun findTrack(extractor: MediaExtractor, prefix: String): Int {
        for (index in 0 until extractor.trackCount) {
            if (extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                    ?.startsWith(prefix) == true) return index
        }
        error("Missing $prefix track")
    }

    private fun encodeMixedAac(sources: List<AlignedWav>, durationUs: Long, output: File) {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 96000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var muxerStarted = false
        var track = -1
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val framesTotal = max(1L, durationUs * RATE / 1_000_000L)
            var framesSent = 0L
            var inputEnded = false
            var outputEnded = false
            var lastProgressNs = System.nanoTime()
            val info = MediaCodec.BufferInfo()
            val micSamples = ShortArray(4096)
            val appSamples = ShortArray(4096)
            while (!outputEnded) {
                check(System.nanoTime() - lastProgressNs < 30_000_000_000L) {
                    "AAC encoder did not make progress"
                }
                if (!inputEnded) {
                    val inputIndex = codec.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        lastProgressNs = System.nanoTime()
                        val input = codec.getInputBuffer(inputIndex) ?: error("AAC input missing")
                        input.clear()
                        val frames = minOf(input.remaining() / 2, 4096,
                            (framesTotal - framesSent).coerceAtLeast(0).toInt())
                        if (frames <= 0) {
                            codec.queueInputBuffer(inputIndex, 0, 0,
                                framesSent * 1_000_000L / RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            micSamples.fill(0, 0, frames)
                            appSamples.fill(0, 0, frames)
                            sources.getOrNull(0)?.fill(micSamples, framesSent, frames)
                            sources.getOrNull(1)?.fill(appSamples, framesSent, frames)
                            // When only one source exists, it occupies the first array.
                            for (i in 0 until frames) {
                                val mixed = (micSamples[i].toInt() + appSamples[i].toInt())
                                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                                input.put((mixed and 0xff).toByte())
                                input.put((mixed shr 8).toByte())
                            }
                            codec.queueInputBuffer(inputIndex, 0, frames * 2,
                                framesSent * 1_000_000L / RATE, 0)
                            framesSent += frames
                        }
                    }
                }
                when (val outputIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        lastProgressNs = System.nanoTime()
                        check(!muxerStarted)
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxerStarted = true
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (outputIndex >= 0) {
                        lastProgressNs = System.nanoTime()
                        val buffer = codec.getOutputBuffer(outputIndex)
                            ?: error("AAC output missing")
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(muxerStarted)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                }
            }
            check(muxerStarted)
            muxer.stop()
            muxerStarted = false
        } finally {
            runCatching { codec.stop() }
            codec.release()
            if (muxerStarted) runCatching { muxer.stop() }
            muxer.release()
        }
    }

    private fun remux(video: MediaExtractor, videoTrack: Int, aacFile: File,
                      output: ParcelFileDescriptor) {
        val audio = MediaExtractor()
        val muxer = MediaMuxer(output.fileDescriptor,
            MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
            audio.setDataSource(aacFile.absolutePath)
            val audioTrack = findTrack(audio, "audio/")
            val videoOut = muxer.addTrack(video.getTrackFormat(videoTrack))
            val audioOut = muxer.addTrack(audio.getTrackFormat(audioTrack))
            video.selectTrack(videoTrack)
            audio.selectTrack(audioTrack)
            muxer.start()
            started = true
            val buffer = ByteBuffer.allocateDirect(4 * 1024 * 1024)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val videoTime = video.sampleTime
                val audioTime = audio.sampleTime
                if (videoTime < 0 && audioTime < 0) break
                val takeVideo = videoTime >= 0 && (audioTime < 0 || videoTime <= audioTime)
                val extractor = if (takeVideo) video else audio
                val target = if (takeVideo) videoOut else audioOut
                buffer.clear()
                val length = extractor.readSampleData(buffer, 0)
                if (length < 0) break
                info.set(0, length, extractor.sampleTime, extractor.sampleFlags)
                buffer.position(0)
                buffer.limit(length)
                muxer.writeSampleData(target, buffer, info)
                extractor.advance()
            }
            muxer.stop()
            started = false
        } finally {
            if (started) runCatching { muxer.stop() }
            muxer.release()
            audio.release()
        }
    }

    private class AlignedWav(context: Context, uri: Uri, startedAtMs: Long,
                             videoStartedAtMs: Long) : AutoCloseable {
        private val input = BufferedInputStream(
            context.contentResolver.openInputStream(uri) ?: error("Cannot open WAV"), 65536,
        )
        private var nextFrame = max(0L, (startedAtMs - videoStartedAtMs) * RATE / 1000L)
        private var exhausted = false

        init {
            val header = ByteArray(44)
            readFully(header)
            val littleRate = (header[24].toInt() and 255) or
                ((header[25].toInt() and 255) shl 8) or
                ((header[26].toInt() and 255) shl 16) or
                ((header[27].toInt() and 255) shl 24)
            require(String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(header, 8, 4, Charsets.US_ASCII) == "WAVE" &&
                littleRate == RATE && header[22].toInt() == 1 && header[34].toInt() == 16) {
                "Unsupported WAV format"
            }
            val skipFrames = max(0L, (videoStartedAtMs - startedAtMs) * RATE / 1000L)
            skipFully(skipFrames * 2L)
        }

        fun fill(target: ShortArray, outputStartFrame: Long, count: Int) {
            if (exhausted) return
            for (i in 0 until count) {
                if (outputStartFrame + i < nextFrame) continue
                val low = input.read()
                val high = input.read()
                if (low < 0 || high < 0) { exhausted = true; break }
                target[i] = ((low and 255) or (high shl 8)).toShort()
                nextFrame++
            }
        }

        private fun readFully(bytes: ByteArray) {
            var position = 0
            while (position < bytes.size) {
                val count = input.read(bytes, position, bytes.size - position)
                if (count <= 0) error("Truncated WAV")
                position += count
            }
        }

        private fun skipFully(length: Long) {
            var remaining = length
            while (remaining > 0) {
                val count = input.skip(remaining)
                if (count <= 0) { exhausted = true; return }
                remaining -= count
            }
        }

        override fun close() { input.close() }
    }
}
