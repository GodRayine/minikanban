package com.minikanban.minikanban

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Помимо запуска Flutter отвечает за разрешение доступа к локальной сети
 * (Android 16+/17: ACCESS_LOCAL_NETWORK) — без него телефон не может
 * подключиться к ПК по Wi-Fi.
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // granted | denied | notRequired
                    "status" -> result.success(status())
                    "request" -> request(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun permissionKnown(): Boolean =
        try {
            packageManager.getPermissionInfo(LOCAL_NETWORK, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }

    private fun status(): String {
        // Разрешение появилось в Android 16 (API 36); на более старых
        // системах доступ к локальной сети даёт обычный INTERNET.
        if (Build.VERSION.SDK_INT < 36 || !permissionKnown()) return "notRequired"
        return if (checkSelfPermission(LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) {
            "granted"
        } else {
            "denied"
        }
    }

    private fun request(result: MethodChannel.Result) {
        if (status() != "denied") {
            result.success(status())
            return
        }
        if (pendingResult != null) {
            result.error("busy", "Запрос разрешения уже выполняется", null)
            return
        }
        pendingResult = result
        requestPermissions(arrayOf(LOCAL_NETWORK), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return
        val result = pendingResult ?: return
        pendingResult = null
        result.success(status())
    }

    private companion object {
        const val CHANNEL = "minikanban/local_network"
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
        const val REQUEST_CODE = 4731
    }
}
