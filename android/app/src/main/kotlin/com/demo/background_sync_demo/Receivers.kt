package com.demo.background_sync_demo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

/** Layer 4 (watchdog alarms) + layer 3 (post-kill restart alarm). */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val store = SyncStore.get(ctx)
        if (!store.running) return
        val pending = goAsync()
        // Re-arm first so a crash in the write path can never break the chain.
        Scheduler.armWatchdog(ctx)
        Thread {
            try {
                if (!SyncService.isRunning) Scheduler.startService(ctx, restart = true)
                // The watchdog writes directly too, so sync continues even if the service cannot start.
                SyncManager.writeTick(ctx, Config.STATE_BG_TASK)
            } catch (e: Exception) {
                Log.e("AlarmReceiver", "failed", e)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/** Layer 5: BOOT_COMPLETED / MY_PACKAGE_REPLACED. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val store = SyncStore.get(ctx)
        if (!store.running) return
        val pending = goAsync()
        Scheduler.armWatchdog(ctx, 5_000) // Android 15 may refuse dataSync FGS from boot: alarm + worker still run
        Scheduler.enqueueWorker(ctx)
        Scheduler.startService(ctx, restart = true)
        Thread {
            try { SyncManager.writeTick(ctx, Config.STATE_KILLED_RELAUNCH) } catch (_: Exception) {} finally { pending.finish() }
        }.start()
    }
}

/** Layer 6: last-resort restarter, 15 min period. */
class SyncWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val store = SyncStore.get(applicationContext)
        if (!store.running) return Result.success()
        if (!SyncService.isRunning) Scheduler.startService(applicationContext, restart = true)
        if (store.watchdogNextAt < System.currentTimeMillis()) Scheduler.armWatchdog(applicationContext)
        SyncManager.writeTick(applicationContext, Config.STATE_BG_TASK)
        return Result.success()
    }
}

/** Runs as soon as a network is available while records are queued (see Scheduler.enqueueFlushWhenOnline). */
class FlushWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val app = applicationContext
        val store = SyncStore.get(app)
        // Posts must upload even if the user has not started the 60 s sync.
        if (!store.running && store.pending() == 0L) return Result.success()
        if (store.running && !SyncService.isRunning) Scheduler.startService(app, restart = true)
        return if (SyncManager.flushPending(app)) Result.success() else Result.retry()
    }
}
