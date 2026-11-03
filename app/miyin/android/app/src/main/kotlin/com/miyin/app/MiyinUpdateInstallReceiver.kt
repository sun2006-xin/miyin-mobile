package com.miyin.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.app.DownloadManager

/** Completes background downloads and handles Android's install-session result. */
class MiyinUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            DownloadManager.ACTION_DOWNLOAD_COMPLETE -> {
                val completedId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                if (completedId >= 0 && MiyinAutomaticUpdates.downloadIds(context).contains(completedId)) {
                    val manifest = MiyinAutomaticUpdates.manifestFromPrefs(context)
                    MiyinAutomaticUpdates.enqueueInstall(context, manifest?.versionCode)
                }
            }

            INSTALL_STATUS_ACTION -> handleInstallStatus(context, intent)
        }
    }

    private fun handleInstallStatus(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_SUCCESS -> MiyinAutomaticUpdates.markInstallFinished(context, true)
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmation = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(PackageInstaller.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(PackageInstaller.EXTRA_INTENT)
                }
                MiyinAutomaticUpdates.markConfirmationRequired(
                    context,
                    confirmation?.toUri(Intent.URI_INTENT_SCHEME),
                )
                if (MiyinAutomaticUpdates.appForeground) {
                    MiyinAutomaticUpdates.openPendingConfirmation(context)
                }
            }

            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?.takeIf { it.isNotBlank() }
                MiyinAutomaticUpdates.markInstallFinished(context, false, message ?: "系统没有完成安装。")
            }
        }
    }

    private companion object {
        const val INSTALL_STATUS_ACTION = "com.miyin.app.UPDATE_INSTALL_STATUS"
    }
}
