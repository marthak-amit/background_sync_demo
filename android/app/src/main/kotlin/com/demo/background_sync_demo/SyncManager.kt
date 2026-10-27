package com.demo.background_sync_demo

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.MutableData
import com.google.firebase.database.ServerValue
import com.google.firebase.database.Transaction
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The single write path. Every layer (service loop, alarm watchdog, WorkManager, FCM, boot) calls
 * [writeTick]. Must be called off the main thread.
 */
object SyncManager {
    private const val TAG = "SyncManager"
    private val lock = Any()
    private var initialised = false

    fun init(ctx: Context): Boolean = synchronized(this) {
        if (initialised) return true
        val app = ctx.applicationContext
        try {
            if (FirebaseApp.getApps(app).isEmpty() && FirebaseApp.initializeApp(app) == null) {
                Log.e(TAG, "Firebase not configured: add android/app/google-services.json")
                return false
            }
            try {
                FirebaseDatabase.getInstance().setPersistenceEnabled(true) // offline persistence
            } catch (_: Exception) { /* already used in this process */ }
            initialised = true
        } catch (e: Exception) {
            Log.e(TAG, "init failed", e)
        }
        initialised
    }

    private fun db() = FirebaseDatabase.getInstance()

    /**
     * Cheap "is there any network" check used only to fail fast (no 20 s wait per tick while offline).
     * Deliberately not requiring VALIDATED: a false negative would block writes, a false positive only costs a timeout.
     */
    fun isOnline(ctx: Context): Boolean {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /** Flush whatever is queued (called when connectivity returns). Off the main thread. */
    fun flushPending(ctx: Context): Boolean {
        val app = ctx.applicationContext
        if (!init(app)) return false
        val store = SyncStore.get(app)
        if (store.pending() == 0L && !store.fcmDirty) return true
        val ok = flush(app, store)
        Log.i(TAG, "flushPending ok=$ok pending=${store.pending()}")
        return ok
    }

    fun logsRef(uid: String) = db().getReference("devices/$uid/logs")

    /** Returns the anonymous-auth uid (= deviceId), signing in if needed. Null when offline and never signed in. */
    fun ensureAuth(ctx: Context): String? {
        if (!init(ctx)) return null
        val auth = FirebaseAuth.getInstance()
        auth.currentUser?.let { SyncStore.get(ctx).deviceId = it.uid; return it.uid }
        if (Looper.myLooper() == Looper.getMainLooper()) return SyncStore.get(ctx).deviceId
        return try {
            val u = Tasks.await(auth.signInAnonymously(), Config.AUTH_TIMEOUT_S, TimeUnit.SECONDS).user
            u?.uid?.also { SyncStore.get(ctx).deviceId = it }
        } catch (e: Exception) {
            Log.w(TAG, "anonymous sign-in failed: ${e.message}")
            null
        }
    }

    /** Reconcile the local counter with devices/{id}/meta/lastN using a transaction (max of both). */
    fun reconcile(ctx: Context) {
        val store = SyncStore.get(ctx)
        val uid = ensureAuth(ctx) ?: return
        val latch = CountDownLatch(1)
        db().getReference("devices/$uid/meta/lastN").runTransaction(object : Transaction.Handler {
            override fun doTransaction(d: MutableData): Transaction.Result {
                val remote = (d.getValue(Long::class.java) ?: 0L)
                d.value = maxOf(remote, store.lastN)
                return Transaction.success(d)
            }

            override fun onComplete(e: DatabaseError?, committed: Boolean, s: DataSnapshot?) {
                if (committed) {
                    val merged = s?.getValue(Long::class.java) ?: 0L
                    synchronized(lock) { if (merged > store.lastN) store.lastN = merged }
                }
                latch.countDown()
            }
        }, false)
        latch.await(Config.WRITE_TIMEOUT_S, TimeUnit.SECONDS)
    }

    fun saveFcmToken(ctx: Context, token: String) {
        SyncStore.get(ctx).fcmToken = token
        Thread { try { flush(ctx, SyncStore.get(ctx)) } catch (_: Exception) {} }.start()
    }

    /** @return true if a record was produced, false if skipped by the dedupe window. */
    fun writeTick(ctx: Context, appState: String): Boolean {
        val app = ctx.applicationContext
        val store = SyncStore.get(app)
        if (!init(app)) return false
        synchronized(lock) {
            val now = System.currentTimeMillis()
            val prev = store.lastWriteAt
            if (prev != 0L && now >= prev && now - prev < Config.DEDUPE_MS) {
                Log.d(TAG, "skip $appState: last write ${(now - prev) / 1000}s ago")
                return false
            }
            val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bgsync:write")
            wl.acquire(Config.WAKELOCK_MS)
            try {
                val n = store.lastN + 1
                val gap = if (prev == 0L) 0L else maxOf(0L, (now - prev) / 1000)
                val key = db().reference.push().key ?: "k${now}_$n" // push ids work offline & are idempotent on retry
                store.lastN = n
                store.lastWriteAt = now
                store.lastAppState = appState
                store.enqueue(QueuedRecord(0, key, n, appState, now, gap))
                if (!flush(app, store)) Scheduler.enqueueFlushWhenOnline(app) // survives service death
                Log.i(TAG, "tick Test_$n ($appState) gap=${gap}s pending=${store.pending()}")
                return true
            } finally {
                if (wl.isHeld) wl.release()
            }
        }
    }

    /** Send queued records in order; stops at the first failure so ordering is preserved. */
    fun flush(ctx: Context, store: SyncStore): Boolean = synchronized(lock) {
        if (!isOnline(ctx)) return false // offline: keep the rows queued, retried on network-available / next tick
        val uid = ensureAuth(ctx) ?: return false
        val ref = db().getReference("devices/$uid")
        var rows = store.peek(Config.FLUSH_BATCH)
        if (rows.isEmpty() && store.fcmDirty) {
            return pushMeta(store, ref)
        }
        while (rows.isNotEmpty()) {
            for (r in rows) {
                val rec = hashMapOf<String, Any?>(
                    "value" to "Test_${r.n}", "n" to r.n, "platform" to "android",
                    "appState" to r.appState, "deviceId" to uid, "clientTime" to r.clientTime,
                    "timestamp" to ServerValue.TIMESTAMP, "gapSeconds" to r.gapSeconds,
                )
                val upd = hashMapOf<String, Any?>(
                    "logs/${r.key}" to rec,
                    "meta/lastN" to r.n,
                    "meta/lastWriteAt" to ServerValue.TIMESTAMP,
                    "meta/platform" to "android",
                )
                store.lastExit?.let { upd["meta/lastExit"] = it }
                store.fcmToken?.let { upd["meta/fcmToken"] = it }
                val latch = CountDownLatch(1)
                var ok = false
                ref.updateChildren(upd) { err, _ -> ok = err == null; latch.countDown() }
                if (!latch.await(Config.WRITE_TIMEOUT_S, TimeUnit.SECONDS) || !ok) return false
                store.delete(r.seq)
                store.fcmDirty = false
            }
            rows = store.peek(Config.FLUSH_BATCH)
        }
        true
    }

    private fun pushMeta(store: SyncStore, ref: com.google.firebase.database.DatabaseReference): Boolean {
        val latch = CountDownLatch(1)
        var ok = false
        val meta = hashMapOf<String, Any>("platform" to "android")
        store.fcmToken?.let { meta["fcmToken"] = it }
        store.lastExit?.let { meta["lastExit"] = it }
        ref.child("meta").updateChildren(meta) { e, _ ->
            ok = e == null; latch.countDown()
        }
        if (latch.await(Config.WRITE_TIMEOUT_S, TimeUnit.SECONDS) && ok) store.fcmDirty = false
        return ok
    }
}
