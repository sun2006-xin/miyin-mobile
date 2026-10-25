package com.miyin.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Plays only app-private conference clips, never arbitrary WebView paths. */
class MiyinLiveAudioPlaybackHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    private var player: MediaPlayer? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                val rawPath = call.argument<String>("path") ?: ""
                val file = runCatching { File(rawPath).canonicalFile }.getOrNull()
                val root = context.applicationInfo.dataDir.let { File(it).canonicalFile }
                val parentName = file?.parentFile?.name
                val safe = file != null && file.isFile &&
                    file.name.matches(Regex("[0-9a-f]{24}\\.wav")) &&
                    (parentName == "live-audio" || parentName == "live-audio-pending") &&
                    file.path.startsWith(root.path + File.separator)
                if (!safe) {
                    result.error("live_audio_missing", "这段本机音频已不存在。", null)
                    return
                }
                stop()
                try {
                    val next = MediaPlayer()
                    next.setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build())
                    next.setDataSource(file!!.path)
                    next.setOnCompletionListener { completed ->
                        if (player === completed) player = null
                        completed.release()
                    }
                    next.prepare()
                    player = next
                    next.start()
                    result.success(mapOf("status" to "playing"))
                } catch (_: Exception) {
                    stop()
                    result.error("live_audio_play_failed", "这段本机音频无法播放。", null)
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun stop() {
        val current = player
        player = null
        runCatching { current?.stop() }
        runCatching { current?.release() }
    }
}
