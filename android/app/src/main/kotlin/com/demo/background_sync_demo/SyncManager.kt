package com.demo.background_sync_demo

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreSettings
import com.google.firebase.firestore.PersistentCacheSettings
import com.google.firebase.firestore.SetOptions
import com.google.firebase.storage.FirebaseStorage
import com.google.firebase.storage.StorageMetadata
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock

/**
 * The single write path. Every layer (service loop, alarm watchdog, WorkManager, FCM, boot) calls
 * [writeTick]; user posts go through [submitPost]. Both only ever touch the local queue first, so nothing
 * depends on the network. Must be called off the main thread.
 *
 * Firestore layout:  devices/{deviceId}              meta fields (lastN, lastWriteAt, platform, fcmToken, ...)
 *                    devices/{deviceId}/logs/{id}    heartbeat "Test_n" records
 *                    devices/{deviceId}/posts/{id}   user posts (text + optional Storage image)
 * Storage:           devices/{deviceId}/images/{postId}.jpg
 */
object SyncManager {
    private const val TAG = "SyncManager"
    private val tickLock = Any()
    private val flushLock = ReentrantLock()
    private val flushQueued = AtomicBoolean(false)
    private val flushExecutor = Executors.newSingleThreadExecutor()
    private var initialised = false

    fun init(ctx: Context): Boolean = synchronized(this) {
        if (initialised) return true
        val app = ctx.applicationContext
        try {
            if (FirebaseApp.getApps(app).isEmpty() && FirebaseApp.initializeApp(app) == null) {
                Log.e(TAG, "Firebase not configured: add android/app/google-services.json")
                return false
            }
            try { // offline persistence: Firestore's own cache, in addition to our SQLite outbox
                FirebaseFirestore.getInstance().firestoreSettings = FirebaseFirestoreSettings.Builder()
                    .setLocalCacheSettings(PersistentCacheSettings.newBuilder().build()).build()
            } catch (_: Exception) { /* already used in this process */ }
            initialised = true
        } catch (e: Exception) {
            Log.e(TAG, "init failed", e)
        }
        initialised
    }

    private fun fs() = FirebaseFirestore.getInstance()

    /**
     * Cheap "is there any network" check used only to fail fast (no 20 s wait per tick while offline).
     * Deliberately not requiring VALIDATED: a false negative would block writes, a false positive only costs a timeout.
     */
    fun isOnline(ctx: Context): Boolean {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

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

    private fun ok(task: Task<*>, secs: Long): Boolean = try {
        Tasks.await(task, secs, TimeUnit.SECONDS); true
    } catch (e: Exception) {
        Log.w(TAG, "task failed: ${e.javaClass.simpleName} ${e.message}"); false
    }

    /** Reconcile the local counter with devices/{id}.lastN using a transaction (max of both). */
    fun reconcile(ctx: Context) {
        val store = SyncStore.get(ctx)
        if (!isOnline(ctx)) return
        val uid = ensureAuth(ctx) ?: return
        val ref = fs().document("devices/$uid")
        try {
            val merged = Tasks.await(fs().runTransaction { tx ->
                val remote = tx.get(ref).getLong("lastN") ?: 0L
                val m = maxOf(remote, store.lastN)
                tx.set(ref, mapOf("lastN" to m), SetOptions.merge())
                m
            }, Config.WRITE_TIMEOUT_S, TimeUnit.SECONDS)
            synchronized(tickLock) { if (merged > store.lastN) store.lastN = merged }
        } catch (e: Exception) {
            Log.w(TAG, "reconcile skipped: ${e.message}")
        }
    }

    fun saveFcmToken(ctx: Context, token: String) {
        SyncStore.get(ctx).fcmToken = token
        requestFlush(ctx)
    }

    // ------------------------------------------------------------------ heartbeat

    /**
     * Records one heartbeat locally (fast, never blocks on the network) and flushes.
     * @param waitForFlush false for the service loop, so a slow upload can never delay the next tick.
     * @return true if a record was produced, false if skipped by the dedupe window.
     */
    fun writeTick(ctx: Context, appState: String, waitForFlush: Boolean = true): Boolean {
        val app = ctx.applicationContext
        val store = SyncStore.get(app)
        if (!init(app)) return false
        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bgsync:write")
        wl.acquire(Config.WAKELOCK_MS)
        val produced: Boolean
        try {
            produced = synchronized(tickLock) {
                val now = System.currentTimeMillis()
                val prev = store.lastWriteAt
                if (prev != 0L && now >= prev && now - prev < Config.DEDUPE_MS) {
                    Log.d(TAG, "skip $appState: last write ${(now - prev) / 1000}s ago")
                    false
                } else {
                    val n = store.lastN + 1
                    val gap = if (prev == 0L) 0L else maxOf(0L, (now - prev) / 1000)
                    store.lastN = n
                    store.lastWriteAt = now
                    store.lastAppState = appState
                    store.enqueue(QueuedRecord(0, UUID.randomUUID().toString().replace("-", ""), n, appState, now, gap))
                    Log.i(TAG, "tick Test_$n ($appState) gap=${gap}s")
                    true
                }
            }
        } finally {
            if (wl.isHeld) wl.release()
        }
        // Even a deduped wake is a free chance to push queued data (posts, offline backlog).
        if (waitForFlush) flushAll(app) else requestFlush(app)
        return produced
    }

    // ------------------------------------------------------------------ user posts

    /** Queue a post (text + optional image file). Works offline: it is flushed as soon as a network exists. */
    fun submitPost(ctx: Context, text: String, srcPath: String?): String {
        val app = ctx.applicationContext
        val store = SyncStore.get(app)
        val id = UUID.randomUUID().toString().replace("-", "")
        var dest: String? = null
        if (!srcPath.isNullOrEmpty()) {
            val dir = File(app.filesDir, "outbox").apply { mkdirs() }
            val f = File(dir, "$id.jpg")
            File(srcPath).copyTo(f, overwrite = true) // app-private copy: survives the picker's cache being cleared
            dest = f.absolutePath
        }
        store.addPost(id, text, dest, System.currentTimeMillis())
        Scheduler.enqueueFlushWhenOnline(app) // persistent: uploads on network return even if the app dies
        requestFlush(app)                      // immediate attempt when already online
        return id
    }

    // ------------------------------------------------------------------ flushing

    /** Coalesced async flush on a dedicated thread (never blocks callers such as the 60 s loop). */
    fun requestFlush(ctx: Context) {
        val app = ctx.applicationContext
        if (flushQueued.compareAndSet(false, true)) {
            flushExecutor.execute {
                flushQueued.set(false)
                try { flushAll(app) } catch (e: Exception) { Log.w(TAG, "flush: ${e.message}") }
            }
        }
    }

    /** Flush whatever is queued (called when connectivity returns). Off the main thread. */
    fun flushPending(ctx: Context): Boolean = flushAll(ctx.applicationContext)

    /** @return true when everything queued was delivered (or another flush is already running). */
    private fun flushAll(app: Context): Boolean {
        val store = SyncStore.get(app)
        if (!init(app)) return false
        if (!flushLock.tryLock()) return true
        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bgsync:flush")
        wl.acquire(Config.FLUSH_WAKELOCK_MS)
        try {
            if (store.pending() == 0L && !store.fcmDirty) return true
            if (!isOnline(app)) { Scheduler.enqueueFlushWhenOnline(app); return false }
            val uid = ensureAuth(app) ?: run { Scheduler.enqueueFlushWhenOnline(app); return false }
            val good = flushLogs(store, uid) && flushPosts(store, uid) && pushMeta(store, uid)
            if (!good) Scheduler.enqueueFlushWhenOnline(app)
            Log.i(TAG, "flush ok=$good pending=${store.pending()}")
            return good
        } finally {
            if (wl.isHeld) wl.release()
            flushLock.unlock()
        }
    }

    private fun metaFields(store: SyncStore, n: Long?): HashMap<String, Any> {
        val m = hashMapOf<String, Any>("platform" to "android")
        if (n != null) { m["lastN"] = n; m["lastWriteAt"] = FieldValue.serverTimestamp() } // only heartbeats bump lastWriteAt
        store.fcmToken?.let { m["fcmToken"] = it }
        store.lastExit?.let { m["lastExit"] = it }
        return m
    }

    /** Heartbeat rows, oldest first; stops at the first failure so ordering is preserved. */
    private fun flushLogs(store: SyncStore, uid: String): Boolean {
        val device = fs().document("devices/$uid")
        while (true) {
            val rows = store.peek(Config.FLUSH_BATCH)
            if (rows.isEmpty()) return true
            for (r in rows) {
                val rec = hashMapOf<String, Any?>(
                    "value" to "Test_${r.n}", "n" to r.n, "platform" to "android",
                    "appState" to r.appState, "deviceId" to uid, "clientTime" to r.clientTime,
                    "timestamp" to FieldValue.serverTimestamp(), "gapSeconds" to r.gapSeconds,
                )
                val batch = fs().batch()
                batch.set(device.collection("logs").document(r.key), rec) // fixed id: a retry rewrites the same doc
                batch.set(device, metaFields(store, r.n), SetOptions.merge())
                if (!ok(batch.commit(), Config.WRITE_TIMEOUT_S)) return false
                store.delete(r.seq)
                store.fcmDirty = false
            }
        }
    }

    /** Posts: upload the image to Storage, then write the Firestore document that references it. */
    private fun flushPosts(store: SyncStore, uid: String): Boolean {
        for (p in store.pendingPosts()) {
            var url = p.uploadedUrl
            val path = "devices/$uid/images/${p.id}.jpg"
            if (p.imagePath != null && url == null) {
                val f = File(p.imagePath)
                if (f.exists()) {
                    val ref = FirebaseStorage.getInstance().reference.child(path)
                    val up = ref.putFile(Uri.fromFile(f), StorageMetadata.Builder().setContentType("image/jpeg").build())
                    if (!ok(up, Config.UPLOAD_TIMEOUT_S)) { up.cancel(); return false }
                    url = try {
                        Tasks.await(ref.downloadUrl, Config.WRITE_TIMEOUT_S, TimeUnit.SECONDS).toString()
                    } catch (e: Exception) { return false }
                    store.setPostUrl(p.id, url) // never re-upload once the object exists
                } else {
                    url = "" // source file vanished: sync the text on its own
                }
            }
            val doc = hashMapOf<String, Any?>(
                "text" to p.text,
                "imagePath" to if (url.isNullOrEmpty()) null else path,
                "imageUrl" to if (url.isNullOrEmpty()) null else url,
                "clientTime" to p.clientTime,
                "timestamp" to FieldValue.serverTimestamp(),
                "deviceId" to uid, "platform" to "android",
            )
            if (!ok(fs().document("devices/$uid/posts/${p.id}").set(doc), Config.WRITE_TIMEOUT_S)) return false
            p.imagePath?.let { File(it).delete() }
            store.deletePost(p.id)
            Log.i(TAG, "post ${p.id} synced")
        }
        return true
    }

    /** Token / exit-reason changes with nothing else queued. */
    private fun pushMeta(store: SyncStore, uid: String): Boolean {
        if (!store.fcmDirty) return true
        val good = ok(fs().document("devices/$uid").set(metaFields(store, null), SetOptions.merge()), Config.WRITE_TIMEOUT_S)
        if (good) store.fcmDirty = false
        return good
    }
}
