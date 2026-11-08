package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

object NnuUpdateInstaller {
    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "cn.nnu.rustdesk/update").setMethodCallHandler { call, result ->
            if (call.method != "install") {
                result.notImplemented()
            } else try {
                val file = File(call.arguments as String).canonicalFile
                val root = File(activity.cacheDir, "nnu-updates").canonicalFile
                require(file.path.startsWith(root.path + File.separator) && file.isFile && file.extension == "apk")
                if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + activity.packageName)))
                    result.success("permission")
                } else {
                    val uri = FileProvider.getUriForFile(activity, activity.packageName + ".nnu.update", file)
                    activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                    result.success("opened")
                }
            } catch (error: Exception) {
                result.error("install", "无法打开更新安装包：${error.message}", null)
            }
        }
    }
}
