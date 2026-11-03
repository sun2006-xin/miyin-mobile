package com.miyin.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class MiyinAutomaticUpdateChannel(
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(MiyinAutomaticUpdates.state(activity))
            "scheduleCheck" -> {
                MiyinAutomaticUpdates.enqueueCheck(activity)
                result.success(null)
            }
            "openInstallPermissionSettings" -> openInstallPermissionSettings(result)
            "continueSystemInstall" -> result.success(MiyinAutomaticUpdates.openPendingConfirmation(activity))
            "retryInstall" -> {
                MiyinAutomaticUpdates.retryPendingInstall(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun openInstallPermissionSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 26 || MiyinAutomaticUpdates.installPermissionGranted(activity)) {
            MiyinAutomaticUpdates.retryPendingInstall(activity)
            result.success(true)
            return
        }
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            result.success(true)
        } catch (_: Exception) {
            result.error("install_settings_unavailable", "无法打开系统的安装授权页面。", null)
        }
    }
}
