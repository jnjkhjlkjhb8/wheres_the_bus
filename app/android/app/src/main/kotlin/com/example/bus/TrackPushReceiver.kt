package com.example.bus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.RemoteMessage

class TrackPushReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackPush"
        private const val PUSH_TYPE = "alight_track"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val app = context?.applicationContext ?: return
        val extras = intent?.extras ?: return
        val data = RemoteMessage(extras).data
        if (data["type"] != PUSH_TYPE) {
            Log.i(TAG, "broadcast reached us, not a card refresh (type=${data["type"]})")
            return
        }
        val drawn = TrackNotification(app).post(data, fromPush = true)
        Log.i(TAG, if (drawn) "card refreshed" else "card refresh dropped as stale or cancelled")
    }
}
