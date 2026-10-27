package com.demo.background_sync_demo

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/** Helpers for layers 3-6: restart alarms, watchdog alarms, WorkManager, safe service start. */
object Scheduler {
    private const val TAG = "Scheduler"
    const val ACTION_WATCHDOG = "com.demo.background_sync_demo.WATCHDOG"
    const val ACTION_WATCHDOG_CLOCK = "com.demo.background_sync_demo.WATCHDOG_CLOCK"
    const val ACTION_RESTART = "com.demo.background_sync_demo.RESTART"
    private const val RC_WATCHDOG = 101
    private const val RC_CLOCK = 102
    private const val RC_RESTART = 103
    private const val WORK_NAME = "bgsync-periodic"

    fun canExact(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
    }

    private fun pi(ctx: Context, action: String, rc: Int): PendingIntent =
        PendingIntent.getBroadcast(
            ctx, rc, Intent(ctx, AlarmReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Layer 4: exact, Doze-penetrating alarm in [delayMs]; each firing re-arms the next one. */
    fun armWatchdog(ctx: Context, delayMs: Long = Config.TICK_MS) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + delayMs
        try {
            if (canExact(ctx)) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_WATCHDOG, RC_WATCHDOG))
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_WATCHDOG, RC_WATCHDOG))
            SyncStore.get(ctx).watchdogNextAt = at
        } catch (e: SecurityException) {
            Log.w(TAG, "exact alarm denied: ${e.message}")
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_WATCHDOG, RC_WATCHDOG))
        }
        if (Config.USE_ALARM_CLOCK) armAlarmClock(ctx, am, at + 5_000)
    }

    /** Extra layer: setAlarmClock() alarms are never throttled by Doze / App Standby. */
    private fun armAlarmClock(ctx: Context, am: AlarmManager, at: Long) {
        try {
            val show = PendingIntent.getActivity(
                ctx, 0, Intent(ctx, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pi(ctx, ACTION_WATCHDOG_CLOCK, RC_CLOCK))
        } catch (e: Exception) {
            Log.w(TAG, "alarm clock failed: ${e.message}")
        }
    }

    /** Layer 3: restart the service in [delayMs] (used by onTaskRemoved / onDestroy). */
    fun scheduleRestart(ctx: Context, delayMs: Long = 1_000) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + delayMs
        try {
            if (canExact(ctx)) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_RESTART, RC_RESTART))
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_RESTART, RC_RESTART))
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, ACTION_RESTART, RC_RESTART))
        }
    }

    /** Layer 6: 15-minute periodic WorkManager job (WorkManager's minimum interval). */
    fun enqueueWorker(ctx: Context) {
        val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, req)
        SyncStore.get(ctx).workerScheduled = true
    }

    /**
     * Offline layer: when rows are stuck in the queue, ask WorkManager to flush them the moment any network
     * returns. WorkManager persists this across process death and reboot, independent of the service.
     */
    fun enqueueFlushWhenOnline(ctx: Context) {
        val req = OneTimeWorkRequestBuilder<FlushWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(ctx).enqueueUniqueWork("bgsync-flush", ExistingWorkPolicy.KEEP, req)
    }

    fun cancelAll(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pi(ctx, ACTION_WATCHDOG, RC_WATCHDOG))
        am.cancel(pi(ctx, ACTION_WATCHDOG_CLOCK, RC_CLOCK))
        am.cancel(pi(ctx, ACTION_RESTART, RC_RESTART))
        WorkManager.getInstance(ctx).cancelUniqueWork(WORK_NAME)
        SyncStore.get(ctx).apply { workerScheduled = false; watchdogNextAt = 0 }
    }

    /**
     * Starts the foreground service; swallows the "not allowed from background" exceptions because
     * the alarm/worker layers keep writing even when the service cannot be started.
     */
    fun startService(ctx: Context, restart: Boolean = false): Boolean {
        if (SyncService.isRunning && !restart) return true
        return try {
            val i = Intent(ctx, SyncService::class.java).putExtra(SyncService.EXTRA_RESTART, restart)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
            true
        } catch (e: Exception) {
            Log.w(TAG, "startService blocked: ${e.javaClass.simpleName} ${e.message}")
            false
        }
    }
}
