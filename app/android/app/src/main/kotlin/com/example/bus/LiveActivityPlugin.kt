package com.example.bus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class LiveActivityPlugin(
    private val context: Context,
    private val notificationPermission: NotificationPermissionCoordinator,
) {

    companion object {
        private const val TAG = "LiveActivity"
        private const val CHANNEL_NAME = "com.wheres.bus/live_activity"

        @Volatile
        var dartIsListening: Boolean = false
            private set
    }

    private val card = TrackNotification(context)

    private var channel: MethodChannel? = null

    private var receiverRegistered = false

    // The 取消追蹤 action reaches Dart only while the process is alive. A dead
    // one is covered by TrackCancelReceiver, which is in the manifest and takes
    // the card down without needing an isolate to talk to.
    private val cancelReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            channel?.invokeMethod("onCancelTrack", null)
        }
    }

    @androidx.annotation.VisibleForTesting
    internal val cancelReceiverForTest: BroadcastReceiver
        get() = cancelReceiver

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_NAME)
        NotificationManagerCompat.from(context).cancel(TrackNotification.NOTIF_ID)
        ContextCompat.registerReceiver(
            context,
            cancelReceiver,
            IntentFilter(TrackNotification.CANCEL_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
        dartIsListening = true
        channel!!.setMethodCallHandler { call, result ->
            @Suppress("UNCHECKED_CAST")
            val data = call.arguments as? Map<String, Any?> ?: emptyMap()
            when (call.method) {
                "start" -> {
                    card.beginSession()
                    try {
                        card.post(data)
                    } catch (e: Throwable) {
                        Log.e(TAG, "could not post the tracking card", e)
                        throw e
                    }
                    result.success("${TrackNotification.NOTIF_ID}")
                }
                "requestNotificationPermission" -> {
                    notificationPermission.request { granted -> result.success(granted) }
                }
                // Whether anything this app posts can be seen at all. Asked
                // rather than remembered: the rider can revoke it in system
                // settings at any time, and the app is not told.
                "notificationsEnabled" -> {
                    result.success(NotificationManagerCompat.from(context).areNotificationsEnabled())
                }
                // Once the runtime prompt has been refused, the system stops
                // showing it, and the only way back is the settings screen —
                // so the app has to be able to point at it.
                "openNotificationSettings" -> {
                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(null)
                }
                "update" -> {
                    try {
                        card.post(data)
                    } catch (e: Throwable) {
                        Log.e(TAG, "could not refresh the tracking card", e)
                        throw e
                    }
                    result.success(null)
                }
                "stop" -> {
                    card.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        dartIsListening = false
        // The session behind a bus or rail card is this engine's; it does not
        // outlive it, so neither should the card.
        card.dropUnpushedCard()
        if (receiverRegistered) {
            context.unregisterReceiver(cancelReceiver)
            receiverRegistered = false
        }
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
