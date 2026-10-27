package com.demo.background_sync_demo

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Layer 7: high-priority data message from the Cloud Function every minute. */
class FcmService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        SyncManager.saveFcmToken(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val store = SyncStore.get(this)
        if (!store.running) return
        Log.d("FcmService", "push wake: ${message.data}")
        // High-priority FCM is exempt from background-FGS-start restrictions.
        if (!SyncService.isRunning) Scheduler.startService(this, restart = true)
        if (store.watchdogNextAt < System.currentTimeMillis()) Scheduler.armWatchdog(this)
        // onMessageReceived already runs on a worker thread with a ~20s budget.
        SyncManager.writeTick(this, Config.STATE_PUSH_WAKE)
    }
}
