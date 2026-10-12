package com.miyin.app

import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Android implementation of the provider-independent Dart translation contract. */
internal class MiyinTranslationMethodHandler : MethodChannel.MethodCallHandler {
    private val modelManager by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        RemoteModelManager.getInstance()
    }
    private val supportedPairs = listOf(
        "zh-Hans" to "en",
        "en" to "zh-Hans",
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            dispatch(call, result)
        } catch (error: Exception) {
            Log.e(TAG, "Translation method ${call.method} failed", error)
            result.error(
                "translation_unavailable",
                error.localizedMessage ?: "本机翻译服务暂时不可用。",
                null,
            )
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supportedLanguagePairs" -> result.success(
                supportedPairs.map { (source, target) ->
                    mapOf("sourceTag" to source, "targetTag" to target)
                },
            )
            "getModelInfo" -> {
                val pair = languagePair(call)
                if (pair == null) {
                    result.success(mapOf("status" to "unsupported"))
                } else {
                    checkModels(managedModels(pair), result, onComplete = { downloaded ->
                        result.success(mapOf("status" to if (downloaded) "downloaded" else "notDownloaded"))
                    })
                }
            }
            "downloadModel" -> withLanguagePair(call, result) { pair ->
                val wifiOnly = call.argument<Boolean>("wifiOnly") ?: true
                downloadModels(managedModels(pair), wifiOnly, 0, result)
            }
            "deleteModel" -> withLanguagePair(call, result) { pair ->
                val sharedLanguages = supportedPairs
                    .filterNot { isSameUndirectedPair(it, pair) }
                    .flatMap { listOf(it.first, it.second) }
                    .mapNotNull(::toMlKitLanguage)
                    .toSet()
                val deletableModels = managedModels(pair).filterNot { it in sharedLanguages }
                deleteModels(deletableModels, 0, result)
            }
            "translate" -> translate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun translate(call: MethodCall, result: MethodChannel.Result) {
        val pair = languagePair(call)
        val text = call.argument<String>("text")
        if (pair == null) {
            result.error("unsupported_language_pair", "This language pair is not supported.", null)
            return
        }
        if (text.isNullOrBlank()) {
            result.error("invalid_text", "Text must not be blank.", null)
            return
        }

        // Check the target model first. Do not call downloadModelIfNeeded here:
        // translating must never trigger an implicit network download.
        checkModels(managedModels(pair), result, onComplete = { downloaded ->
            if (!downloaded) {
                result.error("model_missing", "Download the offline model first.", null)
                return@checkModels
            }

            val options = TranslatorOptions.Builder()
                .setSourceLanguage(pair.first)
                .setTargetLanguage(pair.second)
                .build()
            val translator = try {
                Translation.getClient(options)
            } catch (error: Exception) {
                result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
                return@checkModels
            }
            try {
                translator.translate(text)
                    .addOnSuccessListener { translated ->
                        result.success(mapOf("translatedText" to translated))
                    }
                    .addOnFailureListener { error ->
                        result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
                    }
                    .addOnCompleteListener {
                        translator.close()
                    }
            } catch (error: Exception) {
                translator.close()
                result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
            }
        })
    }

    private fun withLanguagePair(
        call: MethodCall,
        result: MethodChannel.Result,
        action: (Pair<String, String>) -> Unit,
    ) {
        val pair = languagePair(call)
        if (pair == null) {
            result.error("unsupported_language_pair", "This language pair is not supported.", null)
            return
        }
        action(pair)
    }

    private fun languagePair(call: MethodCall): Pair<String, String>? {
        val sourceTag = call.argument<String>("sourceTag") ?: return null
        val targetTag = call.argument<String>("targetTag") ?: return null
        val source = toMlKitLanguage(sourceTag) ?: return null
        val target = toMlKitLanguage(targetTag) ?: return null
        if (source == target) return null
        val pair = source to target
        return pair.takeIf { candidate ->
            supportedPairs.any { (supportedSource, supportedTarget) ->
                toMlKitLanguage(supportedSource) == candidate.first &&
                    toMlKitLanguage(supportedTarget) == candidate.second
            }
        }
    }

    private fun toMlKitLanguage(tag: String): String? = when (tag) {
        // The app stores the full BCP-47 script tag. ML Kit's model registry uses `zh`.
        "zh-Hans" -> TranslateLanguage.CHINESE
        "en" -> TranslateLanguage.ENGLISH
        else -> TranslateLanguage.fromLanguageTag(tag)
    }

    private fun remoteModel(language: String) =
        TranslateRemoteModel.Builder(language).build()

    private fun isSameUndirectedPair(
        first: Pair<String, String>,
        second: Pair<String, String>,
    ): Boolean =
        (first.first == second.first && first.second == second.second) ||
            (first.first == second.second && first.second == second.first)

    /**
     * English is built into ML Kit and must not be passed to RemoteModelManager.
     * Other languages use a remotely managed model; pair status therefore
     * checks every managed language required by the requested direction.
     */
    private fun managedModels(pair: Pair<String, String>): List<String> =
        listOf(pair.first, pair.second)
            .distinct()
            .filterNot { it == TranslateLanguage.ENGLISH }

    private fun checkModels(
        languages: List<String>,
        result: MethodChannel.Result,
        onComplete: (Boolean) -> Unit,
        index: Int = 0,
    ) {
        if (index >= languages.size) {
            onComplete(true)
            return
        }
        modelManager.isModelDownloaded(remoteModel(languages[index]))
            .addOnSuccessListener { downloaded ->
                if (!downloaded) {
                    onComplete(false)
                } else {
                    checkModels(languages, result, onComplete, index + 1)
                }
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "Could not read translation model status for ${languages[index]}", error)
                result.error("model_status_failed", error.localizedMessage ?: "Could not read model status.", null)
            }
    }

    private fun downloadModels(
        languages: List<String>,
        wifiOnly: Boolean,
        index: Int,
        result: MethodChannel.Result,
    ) {
        if (index >= languages.size) {
            result.success(null)
            return
        }
        val conditionsBuilder = DownloadConditions.Builder()
        if (wifiOnly) conditionsBuilder.requireWifi()
        modelManager.download(remoteModel(languages[index]), conditionsBuilder.build())
            .addOnSuccessListener {
                downloadModels(languages, wifiOnly, index + 1, result)
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "Could not download translation model for ${languages[index]}", error)
                result.error("model_download_failed", error.localizedMessage ?: "Model download failed.", null)
            }
    }

    private fun deleteModels(
        languages: List<String>,
        index: Int,
        result: MethodChannel.Result,
    ) {
        if (index >= languages.size) {
            result.success(null)
            return
        }
        modelManager.deleteDownloadedModel(remoteModel(languages[index]))
            .addOnSuccessListener {
                deleteModels(languages, index + 1, result)
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "Could not delete translation model for ${languages[index]}", error)
                result.error("model_delete_failed", error.localizedMessage ?: "Model deletion failed.", null)
            }
    }

    private companion object {
        const val TAG = "MiyinTranslation"
    }
}
