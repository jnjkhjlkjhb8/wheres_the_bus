package com.example.bus

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Launcher shortcuts (long-press the app icon). Dart sets them so titles
 * follow the in-app language; each opens a wheresthebus:// link, which reaches
 * go_router through the activity's existing deep-link filter, so there is
 * nothing to hand back to Dart. See home_shortcuts.dart.
 */
class HomeShortcutsPlugin(private val context: Context) {

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "me.rabbitsayhello.wheresthebus/home_shortcuts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        @Suppress("UNCHECKED_CAST")
                        val items = call.arguments as? List<Map<String, String>> ?: emptyList()
                        ShortcutManagerCompat.setDynamicShortcuts(context, items.mapNotNull(::shortcut))
                        result.success(null)
                    }
                    // Android delivers the pick as a deep link instead.
                    "pending" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
    }

    private fun shortcut(spec: Map<String, String>): ShortcutInfoCompat? {
        val path = spec["path"] ?: return null
        val title = spec["title"] ?: return null
        val icon = if (spec["icon"] == "bookmark") R.drawable.ic_shortcut_bookmark else R.drawable.ic_shortcut_search
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("wheresthebus://$path"), context, MainActivity::class.java)
        return ShortcutInfoCompat.Builder(context, path)
            .setShortLabel(title)
            .setIcon(IconCompat.createWithResource(context, icon))
            .setIntent(intent)
            .build()
    }
}
