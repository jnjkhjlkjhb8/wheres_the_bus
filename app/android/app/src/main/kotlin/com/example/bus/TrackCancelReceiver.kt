package com.example.bus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class TrackCancelReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackCancel"
        private const val CANCEL_PATH = "/api/track/cancel"
        private const val TIMEOUT_MS = 10_000
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val app = context?.applicationContext ?: return
        val trackId = intent?.getStringExtra(TrackNotification.EXTRA_TRACK_ID).orEmpty()
        TrackNotification(app).cancel(trackId)

        // Dart's CancelTrack is the authoritative path whenever there is a Dart:
        // it is install-bound and it tears the session down in the app too. This
        // fallback only runs when nobody is listening for the same broadcast.
        if (LiveActivityPlugin.dartIsListening) return

        if (trackId.isEmpty()) return
        // A device-local session has nothing to cancel anywhere else: it lived
        // in the process that is now gone, and the card it drew is already
        // down. Only a server-minted metro session is worth a request.
        if (trackId.startsWith(TrackNotification.LOCAL_TRACK_PREFIX)) return
        val baseUrl = app.getString(R.string.api_base_url)
        if (baseUrl.isEmpty()) return

        val pending = goAsync()
        thread {
            try {
                postCancel(baseUrl, trackId)
            } catch (e: Exception) {
                Log.i(TAG, "cancel could not reach the server: ${e.javaClass.simpleName}")
            } finally {
                pending.finish()
            }
        }
    }

    private fun postCancel(baseUrl: String, trackId: String) {
        val connection = URL(baseUrl.trimEnd('/') + CANCEL_PATH).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.doOutput = true
            connection.setRequestProperty("content-type", "application/json")
            // The id is server-minted and matched against a fixed UUID shape at
            // the other end, so it cannot carry anything into the JSON.
            connection.outputStream.use { it.write("""{"track_id":"$trackId"}""".toByteArray()) }
            Log.i(TAG, "cancel posted, status ${connection.responseCode}")
        } finally {
            connection.disconnect()
        }
    }
}
