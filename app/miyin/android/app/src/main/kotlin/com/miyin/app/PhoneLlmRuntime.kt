package com.miyin.app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** APK native executable, private model file and authenticated loopback only. */
class PhoneLlmRuntime(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val contextTokens = 4096
    private val worker = Executors.newSingleThreadExecutor()
    private val epoch = AtomicInteger()
    @Volatile private var process: Process? = null
    @Volatile private var apiKey: String? = null
    @Volatile private var ready = false
    @Volatile private var visionReady = false
    private var launches = 0
    private val handler = Handler(Looper.getMainLooper())
    private val retention = ModelKeepAlive(object : ModelKeepAlive.Scheduler {
        override fun postDelayed(task: Runnable, delayMillis: Long) { handler.postDelayed(task, delayMillis) }
        override fun removeCallbacks(task: Runnable) { handler.removeCallbacks(task) }
    }, Runnable { stop() }, 5 * 60 * 1000L)
    private val directory get() = File(activity.filesDir, "chat-model")
    private val sha = "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223"
    private fun health(): Boolean = try {
        val connection = URL("http://127.0.0.1:11438/health").openConnection() as HttpURLConnection
        connection.connectTimeout = 500; connection.readTimeout = 500
        apiKey?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
        try { connection.responseCode == 200 } finally { connection.disconnect() }
    } catch (_: Exception) { false }
    fun stop() { epoch.incrementAndGet(); ready = false; visionReady = false; process?.destroy(); process = null; apiKey = null }
    fun setForeground(value: Boolean) { if (value) retention.foreground() else retention.background() }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "stop") { stop(); result.success(null); return }
        if (call.method == "status") {
            result.success(mapOf("bundled" to File(activity.applicationInfo.nativeLibraryDir,"libmiyin_llama.so").exists(),"ready" to (ready && process?.isAlive == true),"vision" to (visionReady && ready && process?.isAlive == true)))
            return
        }
        if (call.method != "prepare") { result.notImplemented(); return }
        if (android.os.Build.VERSION.SDK_INT < 28) { result.error("local_model", "手机内置聊天模型需要 Android 9 或以上版本。你仍可配置云端模型。", null); return }
        val ticket = epoch.get()
        val needsVision = call.argument<Boolean>("vision") == true
        val requestedAt = SystemClock.elapsedRealtime()
        worker.execute {
            try {
                val enteredAt = SystemClock.elapsedRealtime()
                fun checkActive() { check(ticket == epoch.get()) { "canceled" } }
                checkActive()
                // A busy loopback health probe is not evidence that an already
                // loaded process should be destroyed. Only cold/unready starts
                // need the health handshake; subsequent turns retain its cache.
                val reused = ready && process?.isAlive == true && (!needsVision || visionReady)
                var modelFileMs = 0L
                var copiedModel = false
                var processStartMs = 0L
                var readyWaitMs = 0L
                if (!reused) {
                    ready = false; visionReady = false; process?.destroy(); process = null
                    val fileStartedAt = SystemClock.elapsedRealtime()
                    directory.mkdirs()
                    val model = File(directory,"model.gguf")
                    val preferences = activity.getSharedPreferences("miyin-local-model",0)
                    if (!model.exists() || model.length() != 1280835840L || preferences.getString("verified","") != "$sha:${model.lastModified()}") {
                        copiedModel = true
                        val temporary = File(directory,"model.part")
                        val digest = MessageDigest.getInstance("SHA-256")
                        activity.assets.open("flutter_assets/assets/chat-model/model.gguf").use { source ->
                            temporary.outputStream().use { target ->
                                val buffer = ByteArray(1024*1024)
                                while (true) { checkActive(); val count = source.read(buffer); if (count < 0) break; digest.update(buffer,0,count); target.write(buffer,0,count) }
                            }
                        }
                        check(digest.digest().joinToString("") { "%02x".format(it) } == sha) { "integrity" }
                        checkActive(); check(temporary.renameTo(model)) { "storage" }
                        preferences.edit().putString("verified","$sha:${model.lastModified()}").apply()
                    }
                    checkActive()
                    val projector = File(directory,"mmproj.gguf")
                    if (needsVision) {
                        val projectorSha = "3dc9c77a3323342e6a08b85cf715bf8d8d20704fb50723ba2458487703cb9c24"
                        if (!projector.exists() || projector.length() != 361518784L || preferences.getString("vision-verified","") != "$projectorSha:${projector.lastModified()}") {
                            val temporary = File(directory,"mmproj.part")
                            val digest = MessageDigest.getInstance("SHA-256")
                            try {
                                activity.assets.open("flutter_assets/assets/chat-model/mmproj.gguf").use { source ->
                                    temporary.outputStream().use { target ->
                                        val buffer = ByteArray(1024*1024)
                                        while (true) { checkActive(); val count = source.read(buffer); if (count < 0) break; digest.update(buffer,0,count); target.write(buffer,0,count) }
                                    }
                                }
                                check(digest.digest().joinToString("") { "%02x".format(it) } == projectorSha) { "vision_integrity" }
                                checkActive(); check(temporary.renameTo(projector)) { "vision_storage" }
                                preferences.edit().putString("vision-verified","$projectorSha:${projector.lastModified()}").apply()
                            } finally { temporary.delete() }
                        }
                        checkActive()
                    }
                    modelFileMs = SystemClock.elapsedRealtime() - fileStartedAt
                    val executable = File(activity.applicationInfo.nativeLibraryDir,"libmiyin_llama.so")
                    check(executable.exists()) { "missing_runtime" }
                    val key = UUID.randomUUID().toString()
                    apiKey = key
                    val arguments = mutableListOf(executable.absolutePath,"-m",model.absolutePath,"-c",contextTokens.toString(),"-t","4","--host","127.0.0.1","--port","11438","-np","1","--api-key",key,"--log-disable")
                    if (needsVision) arguments.addAll(listOf("--mmproj",projector.absolutePath,"--no-mmproj-offload","--image-max-tokens","768","--mtmd-batch-max-tokens","256"))
                    val launcher = ProcessBuilder(arguments)
                    // The fixed runtime chooses the best supported CPU module.
                    // Keep all dependency lookup inside the APK's extracted
                    // native directory; the ARMv8.0 module remains the fallback.
                    launcher.environment()["LD_LIBRARY_PATH"] = executable.parentFile!!.absolutePath
                    val processStartedAt = SystemClock.elapsedRealtime()
                    val child = launcher.redirectErrorStream(true)
                        .redirectOutput(File(directory,"runtime.log")).start()
                    processStartMs = SystemClock.elapsedRealtime() - processStartedAt
                    launches++
                    process = child
                    val waitStartedAt = SystemClock.elapsedRealtime()
                    try {
                        var ready = false
                        repeat(if (needsVision) 180 else 120) { if (!ready) { checkActive(); check(child.isAlive) { "load_failed" }; ready = health(); if (!ready) Thread.sleep(500) } }
                        check(ready) { "load_timeout" }; checkActive()
                        readyWaitMs = SystemClock.elapsedRealtime() - waitStartedAt
                        visionReady = needsVision
                    } catch (error: Exception) { child.destroy(); if (process === child) process = null; throw error }
                }
                ready = true
                val elapsed = SystemClock.elapsedRealtime() - requestedAt
                Log.d("MiyinPhoneLlm", "prepare reused=$reused launches=$launches queueMs=${enteredAt-requestedAt} modelFileMs=$modelFileMs copiedModel=$copiedModel processStartMs=$processStartMs readyWaitMs=$readyWaitMs totalMs=$elapsed")
                val key = apiKey ?: error("canceled")
                activity.runOnUiThread {
                    if (ticket != epoch.get()) result.error("local_model", "本机模型已释放，请重试。", null)
                    else result.success(mapOf("endpoint" to "http://127.0.0.1:11438/v1", "key" to key, "contextTokens" to contextTokens,"reused" to reused,"prepareMs" to elapsed,"vision" to visionReady))
                }
            } catch (error: Exception) {
                val code = error.message.orEmpty()
                activity.runOnUiThread { result.error("local_model", if (code == "canceled") "已停止本机模型。" else "本机模型未能准备，请检查存储和可用内存后重试。",null) }
            }
        }
    }
    fun dispose() { retention.dispose(); stop(); worker.shutdownNow() }
}
