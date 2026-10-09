package com.example.bus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import kotlin.math.max

class TrackNotification(private val context: Context) {

    companion object {
        const val NOTIF_ID = 1001
        const val NOTIF_CHANNEL_ID = "live_activity"

        // Broadcast fired by the card's 取消追蹤 action.
        const val CANCEL_ACTION = "com.wheres.bus.action.CANCEL_TRACK"

        const val EXTRA_TRACK_ID = "track_id"

        const val LOCAL_TRACK_PREFIX = "local-"

        private const val METRO_MODE = "metro"

        // Stops remaining at or below which the ride reads as "act now",
        // regardless of the rider's own lead. One stop out is the last moment
        // standing up still helps.
        private const val ARRIVING_STOPS = 1

        @Volatile
        private var showingStops: Int = Int.MAX_VALUE

        @Volatile
        private var lastTrackId: String? = null

        @Volatile
        private var lastMode: String? = null

        private const val PREFS = "track_card"
        private const val KEY_CANCELLED_TRACK = "cancelled_track_id"
        private const val KEY_CANCELLED_AT = "cancelled_at_ms"

        private const val TOMBSTONE_MS = 2 * 60 * 1000L

        private const val ENDED_LINGER_MS = 8 * 1000L

        /** Reads a value that arrives as a number over the channel and as a string over FCM. */
        internal fun intOf(data: Map<String, Any?>, key: String): Int? = when (val value = data[key]) {
            is Number -> value.toInt()
            is String -> value.toIntOrNull()
            else -> null
        }

        internal fun longOf(data: Map<String, Any?>, key: String): Long? = when (val value = data[key]) {
            is Number -> value.toLong()
            is String -> value.toLongOrNull()
            else -> null
        }
    }

    /** Opens a session: the next reading is accepted whatever it says. */
    fun beginSession() {
        showingStops = Int.MAX_VALUE
        clearTombstone()
    }

    fun post(data: Map<String, Any?>, fromPush: Boolean = false): Boolean {
        val phase = data["phase"] as? String ?: "riding"
        val remaining = max(0, intOf(data, "remainingStops") ?: 0)
        val ended = phase == "arrived" || phase == "lost"
        if (isCancelled(data["trackId"] as? String)) return false
        if (fromPush && !ended && remaining > showingStops) return false
        showingStops = if (ended) Int.MAX_VALUE else remaining
        lastTrackId = data["trackId"] as? String
        lastMode = data["mode"] as? String
        ensureChannel()
        NotificationManagerCompat.from(context).notify(NOTIF_ID, buildTrack(data))
        return true
    }

    fun cancel(trackId: String? = null) {
        showingStops = Int.MAX_VALUE
        val session = trackId?.takeIf { it.isNotEmpty() } ?: lastTrackId
        lastTrackId = null
        lastMode = null
        if (!session.isNullOrEmpty()) writeTombstone(session)
        NotificationManagerCompat.from(context).cancel(NOTIF_ID)
    }

    fun dropUnpushedCard() {
        if (lastMode == METRO_MODE) return
        cancel()
    }

    /** Whether this session was cancelled recently enough to still be refused. */
    private fun isCancelled(trackId: String?): Boolean {
        if (trackId.isNullOrEmpty()) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_CANCELLED_TRACK, null) != trackId) return false
        val age = System.currentTimeMillis() - prefs.getLong(KEY_CANCELLED_AT, 0)
        // A negative age means the device clock moved backwards under us. Treat
        // it as inside the window: refusing one late refresh costs a card that
        // was already dismissed, while trusting it reposts one.
        return age < TOMBSTONE_MS
    }

    private fun writeTombstone(trackId: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_CANCELLED_TRACK, trackId)
            .putLong(KEY_CANCELLED_AT, System.currentTimeMillis())
            .apply()
    }

    private fun clearTombstone() {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(KEY_CANCELLED_TRACK)
            .remove(KEY_CANCELLED_AT)
            .apply()
    }

    @androidx.annotation.VisibleForTesting
    internal fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            "下車提醒",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply { setShowBadge(false) }
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    @androidx.annotation.VisibleForTesting
    internal fun buildTrack(data: Map<String, Any?>): Notification {
        val mode = data["mode"] as? String ?: "bus"
        val phase = data["phase"] as? String ?: "riding"
        val vehicleLabel = data["vehicleLabel"] as? String ?: ""
        val vehicleId = (data["vehicleId"] as? String)?.takeIf { it.isNotEmpty() }
        val board = data["boardStation"] as? String ?: ""
        val target = data["targetStation"] as? String ?: ""
        val next = data["nextStation"] as? String ?: ""
        val hopCount = max(1, intOf(data, "hopCount") ?: 1)
        val remaining = max(0, intOf(data, "remainingStops") ?: 0)
        val lead = max(0, intOf(data, "leadStops") ?: 0)
        val etaMinutes = intOf(data, "etaMinutes")
        val departureMs = longOf(data, "scheduledDepartureMs")
        val delayMinutes = intOf(data, "delayMinutes") ?: 0

        // A terminal reading lingers briefly before Dart dismisses the lease:
        // 已到站 completes the bar, 追蹤失效 must be seen. Neither may vanish
        // silently — a card that just disappears reads as "still tracking".
        val ended = phase == "arrived" || phase == "lost"
        val live = !ended
        val waiting = phase == "waiting"
        val riding = live && !waiting

        val progress = when {
            phase == "arrived" -> hopCount
            else -> intOf(data, "currentIndex") ?: 0
        }.coerceIn(0, hopCount)

        val vehicle = if (vehicleId == null) vehicleLabel else "$vehicleLabel $vehicleId"

        val title = when (phase) {
            "lost" -> "追蹤失效"
            "arrived" -> "已到 $target"
            else -> "往 $target"
        }
        val text = when {
            phase == "lost" -> "請重新綁定"
            phase == "arrived" -> "追蹤結束"
            waiting -> boardingLine(vehicle, board, departureMs, delayMinutes)
            remaining <= ARRIVING_STOPS -> "準備下車 · 下一站 $next"
            else -> "$vehicle · 下一站 $next"
        }
        // Under 7 characters, so the status-bar chip renders it in full rather
        // than collapsing to the icon alone.
        val chip = when {
            phase == "lost" -> "失效"
            phase == "arrived" -> "已到站"
            waiting -> etaChip(etaMinutes)
            remaining <= ARRIVING_STOPS -> "下一站"
            else -> "剩${remaining}站"
        }

        val ink = ContextCompat.getColor(context, R.color.track_ink)
        val approach = ContextCompat.getColor(context, R.color.track_approach)
        val arriving = ContextCompat.getColor(context, R.color.track_arriving)

        val warmColor = if (remaining <= ARRIVING_STOPS) arriving else approach
        // The station the warm run starts after — the rider's own 提前站數.
        // Pushed past the end while there is nothing to warn about, so a
        // waiting or finished card has no warm run at all.
        val warmFrom = if (riding) hopCount - lead - 1 else hopCount
        val accent = if (riding && remaining <= ARRIVING_STOPS) arriving else ink

        val builder = NotificationCompat.Builder(context, NOTIF_CHANNEL_ID)
            .setSmallIcon(chipIcon(mode))
            .setColor(accent)
            .setOngoing(live)
            // Live Updates refresh on every station hop; only alert on the
            // first post.
            .setOnlyAlertOnce(true)
            .setContentTitle(title)
            .setContentText(text)
            .setShortCriticalText(chip)
            .setContentIntent(launchIntent())
            .setStyle(progressStyle(hopCount, progress, warmFrom, ink, warmColor))
            // Restores the app-name row. Without an explicit `when` the header
            // collapses to a bare icon, and a card that never says who posted
            // it is a card the rider cannot place.
            .setShowWhen(true)
            .setRequestPromotedOngoing(live)

        builder.setWhen(System.currentTimeMillis())

        builder.setTimeoutAfter(if (live) staleWindowMs(mode) else ENDED_LINGER_MS)

        // Below Android 16 there is no chip, so the reading has to live in the
        // notification itself. On 16+ this would only duplicate the chip.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) {
            builder.setSubText(chip)
        }

        if (live) {
            builder.addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithResource(context, R.drawable.ic_track_cancel),
                    "取消追蹤",
                    cancelIntent(data["trackId"] as? String),
                ).build(),
            )
        }

        return builder.build()
    }

    private fun progressStyle(
        hopCount: Int,
        progress: Int,
        warmFrom: Int,
        calmColor: Int,
        warmColor: Int,
    ): NotificationCompat.ProgressStyle {
        val passed = ContextCompat.getColor(context, R.color.track_passed)
        val notch = ContextCompat.getColor(context, R.color.track_notch)

        return NotificationCompat.ProgressStyle()
            .setProgress(progress)
            .setProgressSegments(
                (1..hopCount).map { at ->
                    NotificationCompat.ProgressStyle.Segment(1).setColor(
                        when {
                            at <= progress -> passed
                            at > warmFrom -> warmColor
                            else -> calmColor
                        },
                    )
                },
            )
            // Squares on the stations already behind the tracker. Nothing is
            // emitted ahead of it: the platform drops those, and a crowd of
            // never-drawn ticks buys nothing.
            .setProgressPoints(
                (1..progress.coerceAtMost(hopCount - 1)).map { at ->
                    NotificationCompat.ProgressStyle.Point(at).setColor(notch)
                },
            )
            .setProgressStartIcon(
                IconCompat.createWithResource(context, R.drawable.ic_track_board),
            )
            .setProgressEndIcon(
                IconCompat.createWithResource(context, R.drawable.ic_track_alight),
            )
            .setProgressTrackerIcon(
                IconCompat.createWithResource(context, R.drawable.ic_track_puck),
            )
            .setStyledByProgress(false)
    }

    private fun chipIcon(mode: String): Int = when (mode) {
        "metro" -> R.drawable.ic_track_metro
        "tra", "thsr" -> R.drawable.ic_track_rail
        else -> R.drawable.ic_track_bus
    }

    private fun staleWindowMs(mode: String): Long = when (mode) {
        "metro" -> 12 * 60 * 1000L
        "tra", "thsr" -> 40 * 60 * 1000L
        else -> 6 * 60 * 1000L
    }

    private fun boardingLine(
        vehicle: String,
        board: String,
        departureMs: Long?,
        delayMinutes: Int,
    ): String {
        if (departureMs == null) return "$vehicle · 於 $board 上車"
        val clock = timeFormat.format(java.util.Date(departureMs))
        val late = if (delayMinutes > 0) " · 誤點 ${delayMinutes} 分" else ""
        return "$vehicle · $clock 開$late"
    }

    private val timeFormat = java.text.SimpleDateFormat(
        "HH:mm",
        java.util.Locale.getDefault(),
    )

    private fun etaChip(etaMinutes: Int?): String = when {
        etaMinutes == null -> "進站中"
        etaMinutes <= 0 -> "進站中"
        else -> "${etaMinutes}分"
    }

    private fun cancelIntent(trackId: String?): PendingIntent {
        val intent = Intent(CANCEL_ACTION)
            .setPackage(context.packageName)
            .putExtra(EXTRA_TRACK_ID, trackId.orEmpty())
        return PendingIntent.getBroadcast(
            context,
            1,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun launchIntent(): PendingIntent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
