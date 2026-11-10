package com.miyin.app

import android.app.DownloadManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.TimeUnit

private const val UPDATE_MANIFEST_URL =
    "https://api.github.com/repos/sun2006-xin/miyin-mobile/contents/docs/release/update.json?ref=main"
private const val UPDATE_WORK_NAME = "miyin-automatic-update-check"
private const val UPDATE_INSTALL_WORK_NAME = "miyin-automatic-update-install"
private const val UPDATE_PREFS = "miyin_automatic_updates"
private const val UPDATE_ACTION_INSTALL_STATUS = "com.miyin.app.UPDATE_INSTALL_STATUS"
private const val UPDATE_EXPECTED_CERT_SHA256 =
    "31366f2557af4b1d3a22fa01b1701ca6bca5bf48ccbd94cf3d7f8bab7fe4b800"

/** Owns the scheduled update check and the persistent DownloadManager queue. */
internal object MiyinAutomaticUpdates {
    @Volatile var appForeground: Boolean = false

    private fun appContext(context: Context) = context.applicationContext
    private fun prefs(context: Context) = appContext(context).getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)

    fun schedule(context: Context) {
        val app = appContext(context)
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val periodic = PeriodicWorkRequest.Builder(
            MiyinUpdateCheckWorker::class.java,
            12,
            TimeUnit.HOURS,
        ).setInitialDelay(12, TimeUnit.HOURS).setConstraints(constraints).build()
        val manager = WorkManager.getInstance(app)
        manager.enqueueUniquePeriodicWork(
            UPDATE_WORK_NAME,
            // Replace work retained from older builds, whose immediate check
            // could otherwise run while the first screen is still opening.
            ExistingPeriodicWorkPolicy.REPLACE,
            periodic,
        )
        // Do not let a retrying check from an older build race the first frame.
        manager.cancelUniqueWork("$UPDATE_WORK_NAME-now")
    }

    fun enqueueCheck(context: Context) {
        val preferences = prefs(context)
        val currentVersion = packageVersion(context).first
        val upgraded = preferences.getInt("check_schedule_version", -1) != currentVersion
        val request = OneTimeWorkRequest.Builder(MiyinUpdateCheckWorker::class.java)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
            .build()
        WorkManager.getInstance(appContext(context)).enqueueUniqueWork(
            "$UPDATE_WORK_NAME-now",
            if (upgraded) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
        preferences.edit().putInt("check_schedule_version", currentVersion).apply()
    }

    fun enqueueInstall(context: Context, versionCode: Long? = null) {
        val request = OneTimeWorkRequest.Builder(MiyinUpdateInstallWorker::class.java)
            .setInputData(
                androidx.work.Data.Builder().apply {
                    if (versionCode != null) putLong("versionCode", versionCode)
                }.build(),
            )
            .build()
        WorkManager.getInstance(appContext(context)).enqueueUniqueWork(
            UPDATE_INSTALL_WORK_NAME,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun packageVersion(context: Context): Pair<Int, String> {
        val app = appContext(context)
        @Suppress("DEPRECATION")
        val info = if (Build.VERSION.SDK_INT >= 33) {
            app.packageManager.getPackageInfo(
                app.packageName,
                PackageManager.PackageInfoFlags.of(0),
            )
        } else {
            app.packageManager.getPackageInfo(app.packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        return code.coerceAtMost(Int.MAX_VALUE.toLong()).toInt() to (info.versionName ?: "")
    }

    fun installPermissionGranted(context: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || appContext(context).packageManager.canRequestPackageInstalls()

    fun state(context: Context): Map<String, Any?> {
        val app = appContext(context)
        val preferences = prefs(app)
        val (versionCode, versionName) = packageVersion(app)
        val ids = preferences.getString(KEY_DOWNLOAD_IDS, "")
            .orEmpty().split(',').mapNotNull { it.toLongOrNull() }
        val download = app.getSystemService(DownloadManager::class.java)
        var downloaded = 0L
        var total = 0L
        var hasActiveDownload = false
        if (ids.isNotEmpty()) {
            val query = DownloadManager.Query().setFilterById(*ids.toLongArray())
            runCatching { download.query(query)?.use { cursor ->
                val statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                val bytesIndex = cursor.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val totalIndex = cursor.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                while (cursor.moveToNext()) {
                    val itemStatus = cursor.getInt(statusIndex)
                    if (itemStatus == DownloadManager.STATUS_PENDING ||
                        itemStatus == DownloadManager.STATUS_RUNNING ||
                        itemStatus == DownloadManager.STATUS_PAUSED
                    ) hasActiveDownload = true
                    if (bytesIndex >= 0) downloaded += cursor.getLong(bytesIndex).coerceAtLeast(0)
                    if (totalIndex >= 0) total += cursor.getLong(totalIndex).coerceAtLeast(0)
                }
            } }
        }
        return mapOf(
            "currentVersionCode" to versionCode,
            "currentVersionName" to versionName,
            "state" to preferences.getString(KEY_STATE, "idle"),
            "error" to preferences.getString(KEY_ERROR, ""),
            "updateVersionCode" to preferences.getLong(KEY_VERSION_CODE, 0L),
            "updateVersionName" to preferences.getString(KEY_VERSION_NAME, ""),
            "downloadedBytes" to downloaded,
            "totalBytes" to total,
            "downloadActive" to hasActiveDownload,
            "installPermissionGranted" to installPermissionGranted(app),
            "confirmationPending" to preferences.contains(KEY_CONFIRMATION_INTENT),
        )
    }

    fun openPendingConfirmation(context: Context): Boolean {
        val app = appContext(context)
        val preferences = prefs(app)
        val encoded = preferences.getString(KEY_CONFIRMATION_INTENT, null) ?: return false
        return try {
            val intent = android.content.Intent.parseUri(encoded, android.content.Intent.URI_INTENT_SCHEME)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            app.startActivity(intent)
            preferences.edit().remove(KEY_CONFIRMATION_INTENT).apply()
            true
        } catch (_: Exception) {
            false
        }
    }

    fun retryPendingInstall(context: Context) {
        val app = appContext(context)
        val currentState = prefs(app).getString(KEY_STATE, "")
        if (currentState == STATE_PERMISSION_REQUIRED && installPermissionGranted(app)) {
            enqueueInstall(app, prefs(app).getLong(KEY_VERSION_CODE, 0L))
        }
    }

    internal fun saveState(context: Context, state: String, error: String? = null) {
        prefs(context).edit().putString(KEY_STATE, state)
            .putString(KEY_ERROR, error?.take(300))
            .apply()
    }

    internal fun validateManifest(json: JSONObject): UpdateManifest {
        val version = json.optString("version")
        val versionCode = json.optLong("versionCode", -1L)
        val apkBytes = json.optLong("apkBytes", -1L)
        val apkSha256 = json.optString("apkSha256").lowercase(Locale.ROOT)
        val certificate = json.optString("certificateSha256").lowercase(Locale.ROOT)
        require(version.matches(Regex("[A-Za-z0-9.+_-]{1,80}"))) { "Invalid update version" }
        val versionSuffix = version.substringAfterLast('+', "")
        require(versionSuffix.toLongOrNull() == versionCode) { "Version code does not match version" }
        require(versionCode > 0 && apkBytes > 0 && apkBytes < 4L * 1024 * 1024 * 1024) { "Invalid update size" }
        require(apkSha256.matches(Regex("[0-9a-f]{64}"))) { "Invalid APK digest" }
        require(certificate == UPDATE_EXPECTED_CERT_SHA256) { "Unexpected update certificate" }
        val releaseUrl = json.optString("releaseUrl")
        val expectedTag = "v" + version.replace('+', '.')
        val parsedReleaseUrl = Uri.parse(releaseUrl)
        require(parsedReleaseUrl.scheme == "https" && parsedReleaseUrl.host == "github.com" &&
            parsedReleaseUrl.path == "/sun2006-xin/miyin-mobile/releases/tag/$expectedTag") {
            "Invalid release page"
        }
        val array = json.optJSONArray("parts") ?: error("Missing update parts")
        require(array.length() in 1..4) { "Invalid update part count" }
        val parts = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            val name = item.optString("file")
            val bytes = item.optLong("bytes", -1L)
            val digest = item.optString("sha256").lowercase(Locale.ROOT)
            val uri = Uri.parse(item.optString("url"))
            require(name.matches(Regex("Miyin-[A-Za-z0-9.+_-]+-arm64\\.apk\\.part[1-4]"))) { "Invalid update filename" }
            require(bytes > 0 && bytes < 2L * 1024 * 1024 * 1024) { "Invalid update part size" }
            require(digest.matches(Regex("[0-9a-f]{64}"))) { "Invalid update part digest" }
            val legacyDownload = uri.host == "github.com" &&
                uri.path.orEmpty().startsWith("/sun2006-xin/miyin-mobile/releases/download/$expectedTag/") &&
                uri.lastPathSegment == name
            val apiDownload = uri.host == "api.github.com" &&
                uri.path.orEmpty().matches(Regex("/repos/sun2006-xin/miyin-mobile/releases/assets/[0-9]+"))
            require(uri.scheme == "https" && (legacyDownload || apiDownload)) {
                "Invalid update download host"
            }
            UpdatePart(name, uri.toString(), bytes, digest)
        }.sortedBy { it.file.substringAfterLast("part").toInt() }
        require(parts.sumOf { it.bytes } == apkBytes) { "Update part sizes do not match APK size" }
        require(parts.map { it.file.substringAfterLast("part").toInt() } == (1..parts.size).toList()) {
            "Update part sequence is incomplete"
        }
        return UpdateManifest(
            version = version,
            versionCode = versionCode,
            apkBytes = apkBytes,
            apkSha256 = apkSha256,
            certificateSha256 = certificate,
            releaseUrl = releaseUrl,
            parts = parts,
            sourceJson = json.toString(),
        )
    }

    internal fun manifestFromPrefs(context: Context): UpdateManifest? = runCatching {
        val source = prefs(context).getString(KEY_MANIFEST, null) ?: return null
        validateManifest(JSONObject(source))
    }.getOrNull()

    internal fun downloadIds(context: Context): List<Long> =
        prefs(context).getString(KEY_DOWNLOAD_IDS, "").orEmpty()
            .split(',').mapNotNull { it.toLongOrNull() }

    internal fun saveDownloadQueue(context: Context, manifest: UpdateManifest, ids: List<Long>) {
        prefs(context).edit()
            .putString(KEY_MANIFEST, manifest.sourceJson)
            .putLong(KEY_VERSION_CODE, manifest.versionCode)
            .putString(KEY_VERSION_NAME, manifest.version)
            .putString(KEY_DOWNLOAD_IDS, ids.joinToString(","))
            .putString(KEY_STATE, STATE_DOWNLOADING)
            .remove(KEY_ERROR)
            .apply()
    }

    internal fun markPermissionRequired(context: Context) {
        prefs(context).edit()
            .putString(KEY_STATE, STATE_PERMISSION_REQUIRED)
            .putString(KEY_ERROR, "")
            .apply()
    }

    internal fun markInstallRequested(context: Context) {
        prefs(context).edit()
            .putString(KEY_STATE, STATE_INSTALLING)
            .putString(KEY_ERROR, "")
            .apply()
    }

    internal fun downloadDirectory(context: Context): File =
        appContext(context).getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: File(appContext(context).filesDir, "updates").apply { mkdirs() }

    internal fun clearSuccessfulUpdate(context: Context) {
        val app = appContext(context)
        val ids = downloadIds(app)
        if (ids.isNotEmpty()) runCatching { app.getSystemService(DownloadManager::class.java).remove(*ids.toLongArray()) }
        downloadIds(app).forEach { id ->
            runCatching {
                app.getSystemService(DownloadManager::class.java)
                    .query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val local = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
                            if (local >= 0) Uri.parse(cursor.getString(local)).path?.let(::File)?.delete()
                        }
                    }
            }
        }
        prefs(app).edit()
            .putString(KEY_STATE, STATE_INSTALLED)
            .remove(KEY_DOWNLOAD_IDS)
            .remove(KEY_CONFIRMATION_INTENT)
            .remove(KEY_ERROR)
            .apply()
    }

    internal fun markConfirmationRequired(context: Context, intentUri: String?) {
        prefs(context).edit()
            .putString(KEY_STATE, STATE_USER_ACTION_REQUIRED)
            .putString(KEY_CONFIRMATION_INTENT, intentUri)
            .apply()
    }

    internal fun markInstallFinished(context: Context, succeeded: Boolean, message: String? = null) {
        val nextState = if (succeeded) STATE_INSTALLED else STATE_FAILED
        prefs(context).edit()
            .putString(KEY_STATE, nextState)
            .putString(KEY_ERROR, message?.take(300))
            .remove(KEY_CONFIRMATION_INTENT)
            .apply()
        if (succeeded) clearSuccessfulUpdate(context)
    }

    internal fun markUpdateFailed(context: Context, message: String) {
        saveState(context, STATE_FAILED, message)
    }

    internal const val STATE_IDLE = "idle"
    internal const val STATE_UP_TO_DATE = "up_to_date"
    internal const val STATE_DOWNLOADING = "downloading"
    internal const val STATE_PERMISSION_REQUIRED = "permission_required"
    internal const val STATE_USER_ACTION_REQUIRED = "user_action_required"
    internal const val STATE_INSTALLING = "installing"
    internal const val STATE_INSTALLED = "installed"
    internal const val STATE_FAILED = "failed"

    private const val KEY_STATE = "state"
    private const val KEY_ERROR = "error"
    private const val KEY_MANIFEST = "manifest"
    private const val KEY_VERSION_CODE = "version_code"
    private const val KEY_VERSION_NAME = "version_name"
    private const val KEY_DOWNLOAD_IDS = "download_ids"
    private const val KEY_CONFIRMATION_INTENT = "confirmation_intent"
}

internal data class UpdatePart(
    val file: String,
    val url: String,
    val bytes: Long,
    val sha256: String,
)

internal data class UpdateManifest(
    val version: String,
    val versionCode: Long,
    val apkBytes: Long,
    val apkSha256: String,
    val certificateSha256: String,
    val releaseUrl: String,
    val parts: List<UpdatePart>,
    val sourceJson: String,
)

/** Runs on a network-constrained background schedule and starts resumable OS downloads. */
class MiyinUpdateCheckWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        return try {
            if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) return Result.success()
            val connection = URL(UPDATE_MANIFEST_URL).openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("Accept", "application/vnd.github.raw+json")
            connection.setRequestProperty("User-Agent", "Miyin-Android-Updater")
            val manifestBytes = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                var count: Int
                while (input.read(buffer).also { count = it } != -1) {
                    if (output.size() + count > 256 * 1024) error("Update manifest is too large")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            val manifest = MiyinAutomaticUpdates.validateManifest(
                JSONObject(String(manifestBytes, Charsets.UTF_8)),
            )
            val currentCode = MiyinAutomaticUpdates.packageVersion(applicationContext).first.toLong()
            if (manifest.versionCode <= currentCode) {
                val prefs = applicationContext.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
                val pending = prefs.getLong("version_code", 0L)
                if (pending <= currentCode) {
                    prefs.edit().putString("state", MiyinAutomaticUpdates.STATE_UP_TO_DATE)
                        .remove("confirmation_intent").apply()
                }
                return Result.success()
            }
            synchronized(MiyinAutomaticUpdates) {
            if (applicationContext.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
                    .getLong("version_code", 0L) != manifest.versionCode
            ) {
                val manager = applicationContext.getSystemService(DownloadManager::class.java)
                val oldIds = MiyinAutomaticUpdates.downloadIds(applicationContext)
                if (oldIds.isNotEmpty()) runCatching { manager.remove(*oldIds.toLongArray()) }
                queue(manifest)
            } else {
                reconcile(manifest)
            }
            }
            Result.success()
        } catch (_: IllegalArgumentException) {
            MiyinAutomaticUpdates.markUpdateFailed(applicationContext, "更新清单校验失败。")
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }

    private fun reconcile(manifest: UpdateManifest) {
        val prefs = applicationContext.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        when (prefs.getString("state", "")) {
            MiyinAutomaticUpdates.STATE_PERMISSION_REQUIRED,
            MiyinAutomaticUpdates.STATE_USER_ACTION_REQUIRED,
            MiyinAutomaticUpdates.STATE_INSTALLING,
            MiyinAutomaticUpdates.STATE_INSTALLED -> return
            "ready" -> {
                MiyinAutomaticUpdates.enqueueInstall(applicationContext, manifest.versionCode)
                return
            }
        }
        val ids = MiyinAutomaticUpdates.downloadIds(applicationContext)
        if (ids.isEmpty()) {
            queue(manifest)
            return
        }
        val statuses = queryStatuses(ids)
        if (statuses.isEmpty() || statuses.any { it == DownloadManager.STATUS_FAILED }) {
            val manager = applicationContext.getSystemService(DownloadManager::class.java)
            runCatching { manager.remove(*ids.toLongArray()) }
            queue(manifest)
        } else if (statuses.size == manifest.parts.size &&
            statuses.all { it == DownloadManager.STATUS_SUCCESSFUL }
        ) {
            prefs.edit().putString("state", "ready").apply()
            MiyinAutomaticUpdates.enqueueInstall(applicationContext, manifest.versionCode)
        } else {
            prefs.edit().putString("state", MiyinAutomaticUpdates.STATE_DOWNLOADING).apply()
        }
    }

    private fun queue(manifest: UpdateManifest) {
        val manager = applicationContext.getSystemService(DownloadManager::class.java)
        val directory = MiyinAutomaticUpdates.downloadDirectory(applicationContext)
        require(directory.exists() || directory.mkdirs())
        val ids = ArrayList<Long>(manifest.parts.size)
        try {
            for (part in manifest.parts) {
                val fileName = "miyin-${manifest.versionCode}-${part.file}"
                val request = DownloadManager.Request(Uri.parse(part.url))
                    .addRequestHeader("Accept", "application/octet-stream")
                    .setTitle("觅音正在下载更新")
                    .setDescription("版本 ${manifest.version} · 连接 Wi-Fi 后自动继续")
                    .setAllowedOverMetered(false)
                    .setAllowedOverRoaming(false)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalFilesDir(
                        applicationContext,
                        Environment.DIRECTORY_DOWNLOADS,
                        fileName,
                    )
                ids += manager.enqueue(request)
            }
            MiyinAutomaticUpdates.saveDownloadQueue(applicationContext, manifest, ids)
        } catch (error: Exception) {
            if (ids.isNotEmpty()) runCatching { manager.remove(*ids.toLongArray()) }
            throw error
        }
    }

    private fun queryStatuses(ids: List<Long>): List<Int> {
        if (ids.isEmpty()) return emptyList()
        val result = ArrayList<Int>(ids.size)
        val query = DownloadManager.Query().setFilterById(*ids.toLongArray())
        applicationContext.getSystemService(DownloadManager::class.java).query(query)?.use { cursor ->
            val index = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            if (index < 0) return emptyList()
            while (cursor.moveToNext()) result += cursor.getInt(index)
        }
        return result
    }
}

/** Verifies each split and the reconstructed APK stream before staging one PackageInstaller session. */
class MiyinUpdateInstallWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val manifest = MiyinAutomaticUpdates.manifestFromPrefs(applicationContext)
            ?: return Result.failure()
        val currentCode = MiyinAutomaticUpdates.packageVersion(applicationContext).first.toLong()
        if (currentCode >= manifest.versionCode) {
            MiyinAutomaticUpdates.clearSuccessfulUpdate(applicationContext)
            return Result.success()
        }
        if (!MiyinAutomaticUpdates.installPermissionGranted(applicationContext)) {
            MiyinAutomaticUpdates.markPermissionRequired(applicationContext)
            return Result.success()
        }
        val ids = MiyinAutomaticUpdates.downloadIds(applicationContext)
        if (ids.size != manifest.parts.size) return Result.success()
        val manager = applicationContext.getSystemService(DownloadManager::class.java)
        val statuses = ArrayList<Int>(ids.size)
        manager.query(DownloadManager.Query().setFilterById(*ids.toLongArray()))?.use { cursor ->
            val statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            while (cursor.moveToNext()) statuses += cursor.getInt(statusIndex)
        }
        if (statuses.size != manifest.parts.size ||
            statuses.any { it != DownloadManager.STATUS_SUCCESSFUL }
        ) return Result.success()

        var sessionId = -1
        return try {
            val files = manifest.parts.map { part ->
                File(
                    MiyinAutomaticUpdates.downloadDirectory(applicationContext),
                    "miyin-${manifest.versionCode}-${part.file}",
                ).canonicalFile.also { file ->
                    require(file.parentFile == MiyinAutomaticUpdates.downloadDirectory(applicationContext).canonicalFile)
                    require(file.isFile && file.length() == part.bytes) { "Downloaded update part size mismatch" }
                }
            }
            val installer = applicationContext.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(applicationContext.packageName)
                setSize(manifest.apkBytes)
                setAppLabel("觅音")
                if (Build.VERSION.SDK_INT >= 31) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
            }
            sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            stageAndVerify(session, files, manifest)
            val callbackIntent = android.content.Intent(applicationContext, MiyinUpdateInstallReceiver::class.java)
                .setAction(UPDATE_ACTION_INSTALL_STATUS)
                .putExtra(PackageInstaller.EXTRA_SESSION_ID, sessionId)
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val callback = PendingIntent.getBroadcast(
                applicationContext,
                sessionId,
                callbackIntent,
                pendingFlags,
            )
            MiyinAutomaticUpdates.markInstallRequested(applicationContext)
            session.commit(callback.intentSender)
            session.close()
            Result.success()
        } catch (error: Exception) {
            if (sessionId >= 0) runCatching {
                applicationContext.packageManager.packageInstaller.abandonSession(sessionId)
            }
            MiyinAutomaticUpdates.markUpdateFailed(applicationContext, "更新校验或安装未完成。")
            Result.success()
        }
    }

    private fun stageAndVerify(
        session: PackageInstaller.Session,
        files: List<File>,
        manifest: UpdateManifest,
    ) {
        val wholeDigest = MessageDigest.getInstance("SHA-256")
        var totalBytes = 0L
        session.openWrite("miyin-update.apk", 0L, manifest.apkBytes).use { output ->
            files.forEachIndexed { index, file ->
                val part = manifest.parts[index]
                val partDigest = MessageDigest.getInstance("SHA-256")
                var partBytes = 0L
                FileInputStream(file).use { input ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        partDigest.update(buffer, 0, count)
                        wholeDigest.update(buffer, 0, count)
                        partBytes += count
                        totalBytes += count
                    }
                }
                check(partBytes == part.bytes && hex(partDigest.digest()) == part.sha256) {
                    "Downloaded update part failed integrity check"
                }
            }
            session.fsync(output)
        }
        check(totalBytes == manifest.apkBytes && hex(wholeDigest.digest()) == manifest.apkSha256) {
            "Reconstructed APK failed integrity check"
        }
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(Locale.ROOT, it) }
}
