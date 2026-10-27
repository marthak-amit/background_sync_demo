package com.demo.background_sync_demo

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/**
 * Records why the previous process died (API 30+) so a Force Stop is visible in Firebase as meta/lastExit
 * instead of just an unexplained gap. REASON_USER_REQUESTED == Settings -> Force stop.
 */
object ExitReasons {
    fun record(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val store = SyncStore.get(ctx)
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val newest = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 5)
            .filter { it.timestamp > store.exitSeenAt }
            .maxByOrNull { it.timestamp } ?: return
        store.exitSeenAt = newest.timestamp
        store.lastExit = "${name(newest.reason)}@${newest.timestamp}"
        store.fcmDirty = true // forces a meta push even when no record is queued
    }

    private fun name(r: Int) = when (r) {
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED_FORCE_STOP"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        else -> "OTHER_$r"
    }
}
