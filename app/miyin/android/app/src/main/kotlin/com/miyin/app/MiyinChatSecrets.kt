package com.miyin.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Only Dart can access this channel. No credential is returned to JavaScript. */
class MiyinChatSecrets(context: Context, voice: Boolean = false) : MethodChannel.MethodCallHandler {
    // Native-only namespaces: independent writers cannot overwrite chat keys.
    private val prefs = context.getSharedPreferences(if (voice) "miyin_voice_credentials" else "miyin_chat_credentials", Context.MODE_PRIVATE)
    private val alias = if (voice) "miyin.voice.credentials.v1" else "miyin.deepseek.credentials.v1"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
            generateKey()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> {
                    val saved = prefs.getString("sealed", null)
                    if (saved == null) result.success(null) else {
                        val parts = saved.split(":")
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                        result.success(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
                    }
                }
                "write" -> {
                    val value = call.arguments as? String ?: error("invalid input")
                    require(value.length <= 8192)
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, key())
                    val sealed = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
                        Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
                    check(prefs.edit().putString("sealed", sealed).commit())
                    result.success(null)
                }
                "clear" -> {
                    check(prefs.edit().remove("sealed").commit())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            result.error("credential_storage", "无法读取或保存服务配置，请重新配置。", null)
        }
    }
}
