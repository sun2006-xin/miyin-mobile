package com.miyin.app

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Public, user-owned exports in Music/Miyin/Live and Movies/Miyin/Live. */
internal object MiyinSessionRecordingStore {
    private const val PREFS = "miyin_session_recording_index"
    private const val KEY = "recordings"

    fun createAudio(context: Context, name: String): Uri = insert(
        context, MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, name, "audio/wav",
        "${Environment.DIRECTORY_MUSIC}/Miyin/Live/",
    )

    fun createVideo(context: Context, name: String): Uri = insert(
        context, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, name, "video/mp4",
        "${Environment.DIRECTORY_MOVIES}/Miyin/Live/",
    )

    private fun insert(context: Context, collection: Uri, name: String, mime: String, path: String): Uri {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, path)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        return context.contentResolver.insert(collection, values)
            ?: error("Could not create MediaStore item")
    }

    fun publish(context: Context, uri: Uri) {
        val updated = context.contentResolver.update(uri, ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }, null, null)
        check(updated > 0) { "MediaStore file could not be published" }
    }

    fun discard(context: Context, uri: Uri?) {
        if (uri != null) runCatching { context.contentResolver.delete(uri, null, null) }
    }

    @Synchronized fun save(context: Context, metadata: Map<String, Any?>) {
        val entries = read(context)
        val sessionId = metadata["recordingSessionId"] as? String ?: return
        val merged = JSONObject()
        for (index in entries.length() - 1 downTo 0) {
            if (entries.optJSONObject(index)?.optString("recordingSessionId") == sessionId) {
                val old = entries.optJSONObject(index)!!
                for (key in old.keys()) merged.put(key, old.opt(key))
                entries.remove(index)
            }
        }
        val incoming = JSONObject(metadata)
        for (key in incoming.keys()) merged.put(key, incoming.opt(key))
        entries.put(merged)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, entries.toString()).apply()
    }

    @Synchronized fun list(context: Context): List<Map<String, Any?>> {
        val entries = read(context)
        val result = ArrayList<Map<String, Any?>>()
        for (index in entries.length() - 1 downTo 0) {
            val item = entries.optJSONObject(index) ?: continue
            val audioUri = item.optString("audioUri")
            val videoUri = item.optString("videoUri")
            val microphoneUri = item.optString("microphoneUri")
            if (!exists(context, audioUri) && !exists(context, videoUri) &&
                !exists(context, microphoneUri)) continue
            result += mapOf(
                "recordingSessionId" to item.optString("recordingSessionId"),
                "captureSessionId" to item.optString("captureSessionId"),
                "state" to "saved",
                "startedAtMs" to item.optLong("startedAtMs"),
                "videoStartedAtMs" to item.optLong("videoStartedAtMs"),
                "playbackStartedAtMs" to item.optLong("playbackStartedAtMs"),
                "microphoneStartedAtMs" to item.optLong("microphoneStartedAtMs"),
                "endedAtMs" to item.optLong("endedAtMs"),
                "durationMs" to item.optLong("durationMs"),
                "audioUri" to audioUri.takeIf { exists(context, it) },
                "videoUri" to videoUri.takeIf { exists(context, it) },
                "microphoneUri" to microphoneUri.takeIf { exists(context, it) },
                "audioBytes" to item.optLong("audioBytes"),
                "videoBytes" to item.optLong("videoBytes"),
                "audioSource" to item.optString("audioSource"),
                "videoHasAudio" to item.optBoolean("videoHasAudio"),
                "videoAudioSources" to item.optJSONArray("videoAudioSources")?.let { array ->
                    (0 until array.length()).map { array.optString(it) }
                },
                "recordingError" to item.optString("recordingError").takeIf { it.isNotEmpty() },
                "audioName" to item.optString("audioName"),
                "videoName" to item.optString("videoName"),
                "microphoneName" to item.optString("microphoneName"),
                "microphoneBytes" to item.optLong("microphoneBytes"),
            )
        }
        return result
    }

    @Synchronized fun owns(context: Context, uri: String): Boolean = list(context).any {
        it["audioUri"] == uri || it["videoUri"] == uri || it["microphoneUri"] == uri
    }

    @Synchronized fun isVideo(context: Context, uri: String): Boolean = list(context).any {
        it["videoUri"] == uri
    }

    private fun read(context: Context): JSONArray = try {
        JSONArray(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]"))
    } catch (_: Exception) { JSONArray() }

    private fun exists(context: Context, raw: String?): Boolean {
        if (raw.isNullOrEmpty()) return false
        return runCatching {
            context.contentResolver.openFileDescriptor(Uri.parse(raw), "r")?.use { true } ?: false
        }.getOrDefault(false)
    }

    fun publishMicrophone(context: Context, sessionId: String, path: String,
                          startedAtMs: Long?): Map<String, Any?> {
        require(sessionId.isNotBlank() && sessionId.length <= 100 &&
            sessionId.all { it.isLetterOrDigit() || it == '-' || it == '_' })
        val source = File(path).canonicalFile
        val cacheRoot = context.cacheDir.canonicalFile.toPath()
        val filesRoot = context.filesDir.canonicalFile.toPath()
        require(source.toPath().startsWith(cacheRoot) || source.toPath().startsWith(filesRoot))
        require(source.isFile && source.extension.equals("wav", ignoreCase = true))
        require(source.length() in 45L..3_800_000_000L)
        FileInputStream(source).use { input ->
            val header = ByteArray(12)
            require(input.read(header) == 12 &&
                String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(header, 8, 4, Charsets.US_ASCII) == "WAVE")
        }
        val existing = list(context).firstOrNull { it["recordingSessionId"] == sessionId }
        val oldUri = existing?.get("microphoneUri") as? String
        if (oldUri != null) {
            if (startedAtMs != null) save(context, mapOf(
                "recordingSessionId" to sessionId, "microphoneStartedAtMs" to startedAtMs,
            ))
            return mapOf(
            "recordingSessionId" to sessionId,
            "microphoneUri" to oldUri,
            "microphoneName" to existing["microphoneName"],
            "microphoneBytes" to existing["microphoneBytes"],
            "audioSource" to "microphone",
            )
        }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val name = "Miyin-Live-$stamp-$sessionId-microphone.wav"
        val uri = createAudio(context, name)
        try {
            context.contentResolver.openFileDescriptor(uri, "w")?.use { descriptor ->
                FileInputStream(source).use { input ->
                    FileOutputStream(descriptor.fileDescriptor).use { output -> input.copyTo(output, 65536) }
                }
            } ?: error("Cannot open microphone export")
            publish(context, uri)
        } catch (error: Exception) {
            discard(context, uri)
            throw error
        }
        val metadata = mapOf<String, Any?>(
            "recordingSessionId" to sessionId,
            "microphoneUri" to uri.toString(),
            "microphoneName" to name,
            "microphoneBytes" to source.length(),
            "microphoneStartedAtMs" to startedAtMs,
        )
        save(context, metadata)
        return metadata + ("audioSource" to "microphone")
    }
}
