package com.example.bus

import android.app.LocaleManager
import android.content.Context
import android.os.Build
import android.os.LocaleList
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Android 13+ per-app language, kept in step with the in-app setting by
 * system_app_language.dart. Tags are BCP-47; "" means follow the system.
 * Below API 33 there is no such setting: get answers null, set is a no-op.
 */
class AppLanguagePlugin(private val context: Context) {

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "me.rabbitsayhello.wheresthebus/app_language")
            .setMethodCallHandler { call, result ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val manager = context.getSystemService(LocaleManager::class.java)
                when (call.method) {
                    "get" -> result.success(manager.applicationLocales.toLanguageTags())
                    "set" -> {
                        manager.applicationLocales =
                            LocaleList.forLanguageTags(call.arguments as? String ?: "")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
