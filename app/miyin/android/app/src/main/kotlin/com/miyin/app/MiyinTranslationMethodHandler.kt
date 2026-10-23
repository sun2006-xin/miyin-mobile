package com.miyin.app

import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Android implementation of the provider-independent Dart translation contract. */
internal class MiyinTranslationMethodHandler : MethodChannel.MethodCallHandler {
    private data class CachedTranslator(
        val client: Translator,
        var activeCalls: Int = 0,
        var retired: Boolean = false,
    )

    private val translators = LinkedHashMap<Pair<String, String>, CachedTranslator>(8, 0.75f, true)

    fun dispose() {
        translators.values.forEach { it.client.close() }
        translators.clear()
    }

    private fun acquireTranslator(pair: Pair<String, String>): CachedTranslator {
        val cached = translators[pair] ?: run {
            val options = TranslatorOptions.Builder()
                .setSourceLanguage(pair.first)
                .setTargetLanguage(pair.second)
                .build()
            CachedTranslator(Translation.getClient(options)).also { translators[pair] = it }
        }
        cached.activeCalls++
        return cached
    }

    private fun releaseTranslator(cached: CachedTranslator) {
        cached.activeCalls--
        if (cached.retired && cached.activeCalls == 0) cached.client.close()
        evictIdleTranslators()
    }

    private fun evictIdleTranslators() {
        if (translators.size <= 4) return
        val iterator = translators.entries.iterator()
        while (translators.size > 4 && iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.value.activeCalls == 0) {
                entry.value.client.close()
                iterator.remove()
            }
        }
    }

    private fun retireTranslatorsFor(language: String) {
        val iterator = translators.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (language != entry.key.first && language != entry.key.second) continue
            iterator.remove()
            entry.value.retired = true
            if (entry.value.activeCalls == 0) entry.value.client.close()
        }
    }

    private val modelManager by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        RemoteModelManager.getInstance()
    }
    private val supportedLanguages = listOf(
        "af" to "南非荷兰语",
        "ar" to "阿拉伯语",
        "be" to "白俄罗斯语",
        "bg" to "保加利亚语",
        "bn" to "孟加拉语",
        "ca" to "加泰罗尼亚语",
        "cs" to "捷克语",
        "cy" to "威尔士语",
        "da" to "丹麦语",
        "de" to "德语",
        "el" to "希腊语",
        "en" to "英语",
        "eo" to "世界语",
        "es" to "西班牙语",
        "et" to "爱沙尼亚语",
        "fa" to "波斯语",
        "fi" to "芬兰语",
        "fr" to "法语",
        "ga" to "爱尔兰语",
        "gl" to "加利西亚语",
        "gu" to "古吉拉特语",
        "he" to "希伯来语",
        "hi" to "印地语",
        "hr" to "克罗地亚语",
        "ht" to "海地克里奥尔语",
        "hu" to "匈牙利语",
        "id" to "印度尼西亚语",
        "is" to "冰岛语",
        "it" to "意大利语",
        "ja" to "日语",
        "ka" to "格鲁吉亚语",
        "kn" to "卡纳达语",
        "ko" to "韩语",
        "lt" to "立陶宛语",
        "lv" to "拉脱维亚语",
        "mk" to "马其顿语",
        "mr" to "马拉地语",
        "ms" to "马来语",
        "mt" to "马耳他语",
        "nl" to "荷兰语",
        "no" to "挪威语",
        "pl" to "波兰语",
        "pt" to "葡萄牙语",
        "ro" to "罗马尼亚语",
        "ru" to "俄语",
        "sk" to "斯洛伐克语",
        "sl" to "斯洛文尼亚语",
        "sq" to "阿尔巴尼亚语",
        "sv" to "瑞典语",
        "sw" to "斯瓦希里语",
        "ta" to "泰米尔语",
        "te" to "泰卢固语",
        "th" to "泰语",
        "tl" to "菲律宾语",
        "tr" to "土耳其语",
        "uk" to "乌克兰语",
        "ur" to "乌尔都语",
        "vi" to "越南语",
        "zh-Hans" to "简体中文",
    )
    private val supportedPairs by lazy {
        supportedLanguages.flatMap { (source, _) ->
            supportedLanguages.mapNotNull { (target, _) ->
                if (source == target) null else source to target
            }
        }
    }

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
            "supportedLanguages" -> result.success(
                supportedLanguages.map { (tag, name) ->
                    mapOf("tag" to tag, "name" to name)
                },
            )
            "supportedLanguagePairs" -> result.success(
                supportedPairs.map { (source, target) ->
                    mapOf("sourceTag" to source, "targetTag" to target)
                },
            )
            "getDownloadedModels" -> modelManager
                .getDownloadedModels(TranslateRemoteModel::class.java)
                .addOnSuccessListener { downloadedModels ->
                    result.success(
                        downloadedModels.mapNotNull { model ->
                            val language = supportedLanguages.firstOrNull { (tag, _) ->
                                toMlKitLanguage(tag) == model.language
                            } ?: return@mapNotNull null
                            if (model.language == TranslateLanguage.ENGLISH) {
                                return@mapNotNull null
                            }
                            mapOf("tag" to language.first, "name" to language.second)
                        }.sortedBy { it["name"] as String },
                    )
                }
                .addOnFailureListener { error ->
                    Log.e(TAG, "Could not list downloaded translation models", error)
                    result.error(
                        "model_list_failed",
                        error.localizedMessage ?: "Could not read downloaded language models.",
                        null,
                    )
                }
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
            "deleteModel" -> result.error(
                "language_model_requires_explicit_delete",
                "Translation models are shared by language. Select one language model in offline resources to delete it.",
                null,
            )
            "deleteLanguageModel" -> deleteLanguageModel(call, result)
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

            val translator = try {
                acquireTranslator(pair)
            } catch (error: Exception) {
                result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
                return@checkModels
            }
            try {
                translator.client.translate(text)
                    .addOnSuccessListener { translated ->
                        result.success(mapOf("translatedText" to translated))
                    }
                    .addOnFailureListener { error ->
                        result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
                    }
                    .addOnCompleteListener {
                        releaseTranslator(translator)
                    }
            } catch (error: Exception) {
                releaseTranslator(translator)
                result.error("translation_failed", error.localizedMessage ?: "Translation failed.", null)
            }
        })
    }

    private fun deleteLanguageModel(call: MethodCall, result: MethodChannel.Result) {
        val tag = call.argument<String>("languageTag")
        val language = tag?.let(::toMlKitLanguage)
        if (language == null || supportedLanguages.none { toMlKitLanguage(it.first) == language }) {
            result.error("unsupported_language", "This translation language is not supported.", null)
            return
        }
        if (language == TranslateLanguage.ENGLISH) {
            result.error("built_in_language_model", "English is built in and cannot be deleted.", null)
            return
        }
        modelManager.deleteDownloadedModel(remoteModel(language))
            .addOnSuccessListener {
                retireTranslatorsFor(language)
                result.success(null)
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "Could not delete translation model for $language", error)
                result.error(
                    "model_delete_failed",
                    error.localizedMessage ?: "Model deletion failed.",
                    null,
                )
            }
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
            candidate.first != candidate.second &&
                supportedLanguages.any { toMlKitLanguage(it.first) == candidate.first } &&
                supportedLanguages.any { toMlKitLanguage(it.first) == candidate.second }
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

    private companion object {
        const val TAG = "MiyinTranslation"
    }
}
