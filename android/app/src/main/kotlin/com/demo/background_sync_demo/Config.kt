package com.demo.background_sync_demo

object Config {
    const val TICK_MS = 60_000L
    /** Skip a write if the previous one was less than this long ago (shared by every wake path). */
    const val DEDUPE_MS = 55_000L
    const val WAKELOCK_MS = 30_000L
    const val WRITE_TIMEOUT_S = 20L
    const val AUTH_TIMEOUT_S = 15L
    const val UPLOAD_TIMEOUT_S = 100L
    /** Flush wake lock: long enough for a compressed image upload, always released in finally. */
    const val FLUSH_WAKELOCK_MS = 150_000L
    const val FLUSH_BATCH = 50

    /** Extra layer: keep the CPU awake between ticks (self-expiring, renewed every tick). */
    const val CONTINUOUS_WAKELOCK = true

    /** Extra layer: also arm an AlarmManager.setAlarmClock() alarm, which is exempt from Doze throttling. */
    const val USE_ALARM_CLOCK = true

    const val STATE_FOREGROUND = "foreground"
    const val STATE_BACKGROUND = "background"
    const val STATE_KILLED_RELAUNCH = "killed_relaunch"
    const val STATE_PUSH_WAKE = "push_wake"
    const val STATE_BG_TASK = "bg_task"
}
