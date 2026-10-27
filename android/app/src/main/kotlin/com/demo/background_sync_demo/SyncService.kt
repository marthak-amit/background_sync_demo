package com.demo.background_sync_demo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Layers 1-3: foreground service with a 60s native loop, continuous-ish wake lock, swipe-kill survival. */
class SyncService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private var wakeLock: PowerManager.WakeLock? = null
    private var nextDue = 0L
    @Volatile private var pendingState: String? = null
    private var loopStarted = false

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        thread = HandlerThread("bgsync-loop").also { it.start() }
        handler = Handler(thread.looper)
        createChannel()
        enterForeground("Sync running")
    }

    private fun enterForeground(text: String) {
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
            ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(text), type)
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException: alarm / worker / FCM layers keep writing.
            Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName} ${e.message}")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val store = SyncStore.get(this)
        if (!store.running) { stopSelf(); return START_NOT_STICKY }
        enterForeground("Sync running")
        // null intent => the system re-created us after process death (START_STICKY).
        if (intent == null || intent.getBooleanExtra(EXTRA_RESTART, false)) pendingState = Config.STATE_KILLED_RELAUNCH
        Scheduler.armWatchdog(this)
        Scheduler.enqueueWorker(this)
        if (!loopStarted) {
            loopStarted = true
            nextDue = SystemClock.uptimeMillis()
            handler.post {
                try {
                    SyncManager.reconcile(this)
                    com.google.firebase.messaging.FirebaseMessaging.getInstance().token
                        .addOnSuccessListener { SyncManager.saveFcmToken(this, it) }
                } catch (e: Exception) { Log.w(TAG, "startup tasks: ${e.message}") }
            }
            handler.post(loop)
        }
        return START_STICKY
    }

    private val loop = object : Runnable {
        override fun run() {
            if (!SyncStore.get(this@SyncService).running) { stopSelf(); return }
            val state = pendingState ?: if (AppForeground.isForeground) Config.STATE_FOREGROUND else Config.STATE_BACKGROUND
            pendingState = null
            try {
                SyncManager.writeTick(this@SyncService, state)
            } catch (e: Exception) {
                Log.e(TAG, "tick failed", e)
            }
            holdWakeLock()
            updateNotification()
            // Fixed-rate scheduling so write time does not accumulate drift.
            nextDue += Config.TICK_MS
            val now = SystemClock.uptimeMillis()
            if (nextDue <= now) nextDue = now + Config.TICK_MS
            handler.postAtTime(this, nextDue)
        }
    }

    private fun holdWakeLock() {
        if (!Config.CONTINUOUS_WAKELOCK) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wl = wakeLock ?: pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bgsync:service").also {
            it.setReferenceCounted(false); wakeLock = it
        }
        wl.acquire(Config.TICK_MS * 2) // self-expiring; renewed every tick so it can never leak
    }

    private fun updateNotification() {
        val s = SyncStore.get(this)
        val t = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(s.lastWriteAt))
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIF_ID, buildNotification("Sync running · Test_${s.lastN} at $t"))
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Background sync", NotificationManager.IMPORTANCE_LOW)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sync running")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    /** Layer 3: swipe from recents. stopWithTask=false keeps us alive; the alarm covers OEMs that kill anyway. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (SyncStore.get(this).running) Scheduler.scheduleRestart(this, 1_000)
        super.onTaskRemoved(rootIntent)
    }

    /** Android 15+: dataSync services get a time limit; restart immediately instead of being killed. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "FGS timeout, restarting")
        if (SyncStore.get(this).running) Scheduler.scheduleRestart(this, 1_000)
        stopSelf()
    }

    override fun onDestroy() {
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
        wakeLock?.let { if (it.isHeld) it.release() }
        if (SyncStore.get(this).running) Scheduler.scheduleRestart(this, 1_000)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "SyncService"
        private const val CHANNEL_ID = "bgsync"
        private const val NOTIF_ID = 4242
        const val EXTRA_RESTART = "restart"
        @Volatile var isRunning = false
    }
}

/** Process-wide foreground flag fed by MainActivity lifecycle. */
object AppForeground {
    @Volatile var isForeground = false
}
