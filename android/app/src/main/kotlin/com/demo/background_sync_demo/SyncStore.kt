package com.demo.background_sync_demo

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** A user post (text + optional image) waiting to be uploaded. */
data class PostRow(
    val id: String,
    val text: String,
    val imagePath: String?,
    val clientTime: Long,
    val uploadedUrl: String?,
)

data class QueuedRecord(
    val seq: Long,
    val key: String,
    val n: Long,
    val appState: String,
    val clientTime: Long,
    val gapSeconds: Long,
)

/** Local persistence: counter / timestamps in SharedPreferences, offline write queue in SQLite. */
class SyncStore private constructor(ctx: Context) :
    SQLiteOpenHelper(ctx, "sync_queue.db", null, 2) {

    private val prefs: SharedPreferences =
        ctx.getSharedPreferences("sync_prefs", Context.MODE_PRIVATE)

    private fun createPosts(db: SQLiteDatabase) = db.execSQL(
        "CREATE TABLE IF NOT EXISTS posts(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, " +
            "text TEXT NOT NULL, image_path TEXT, client_time INTEGER NOT NULL, uploaded_url TEXT)"
    )

    override fun onCreate(db: SQLiteDatabase) {
        createPosts(db)
        db.execSQL(
            "CREATE TABLE queue(seq INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL, " +
                "n INTEGER NOT NULL, app_state TEXT NOT NULL, client_time INTEGER NOT NULL, gap INTEGER NOT NULL)"
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) { createPosts(db) }

    // commit() (not apply()) on purpose: the counter must hit disk before we write remotely.
    var lastN: Long
        get() = prefs.getLong("lastN", 0L)
        set(v) { prefs.edit().putLong("lastN", v).commit() }

    var lastWriteAt: Long
        get() = prefs.getLong("lastWriteAt", 0L)
        set(v) { prefs.edit().putLong("lastWriteAt", v).commit() }

    /** True while the user wants sync on. Every layer checks this first. */
    var running: Boolean
        get() = prefs.getBoolean("running", false)
        set(v) { prefs.edit().putBoolean("running", v).commit() }

    var deviceId: String?
        get() = prefs.getString("deviceId", null)
        set(v) { prefs.edit().putString("deviceId", v).apply() }

    var fcmToken: String?
        get() = prefs.getString("fcmToken", null)
        set(v) { prefs.edit().putString("fcmToken", v).putBoolean("fcmDirty", true).commit() }

    var fcmDirty: Boolean
        get() = prefs.getBoolean("fcmDirty", false)
        set(v) { prefs.edit().putBoolean("fcmDirty", v).apply() }

    var watchdogNextAt: Long
        get() = prefs.getLong("watchdogNextAt", 0L)
        set(v) { prefs.edit().putLong("watchdogNextAt", v).apply() }

    var workerScheduled: Boolean
        get() = prefs.getBoolean("workerScheduled", false)
        set(v) { prefs.edit().putBoolean("workerScheduled", v).apply() }

    var oemAck: Boolean
        get() = prefs.getBoolean("oemAck", false)
        set(v) { prefs.edit().putBoolean("oemAck", v).apply() }

    var lastExit: String?
        get() = prefs.getString("lastExit", null)
        set(v) { prefs.edit().putString("lastExit", v).commit() }

    var exitSeenAt: Long
        get() = prefs.getLong("exitSeenAt", 0L)
        set(v) { prefs.edit().putLong("exitSeenAt", v).commit() }

    var lastAppState: String
        get() = prefs.getString("lastAppState", "-") ?: "-"
        set(v) { prefs.edit().putString("lastAppState", v).apply() }

    fun enqueue(r: QueuedRecord) {
        val cv = ContentValues().apply {
            put("key", r.key); put("n", r.n); put("app_state", r.appState)
            put("client_time", r.clientTime); put("gap", r.gapSeconds)
        }
        writableDatabase.insertOrThrow("queue", null, cv)
    }

    fun peek(limit: Int): List<QueuedRecord> {
        val out = ArrayList<QueuedRecord>()
        readableDatabase.rawQuery(
            "SELECT seq,key,n,app_state,client_time,gap FROM queue ORDER BY seq ASC LIMIT $limit", null
        ).use { c ->
            while (c.moveToNext()) {
                out += QueuedRecord(c.getLong(0), c.getString(1), c.getLong(2), c.getString(3), c.getLong(4), c.getLong(5))
            }
        }
        return out
    }

    fun delete(seq: Long) {
        writableDatabase.delete("queue", "seq=?", arrayOf(seq.toString()))
    }

    /** Heartbeat rows + posts still waiting to reach Firebase. */
    fun pending(): Long = count("queue") + count("posts")

    private fun count(table: String): Long =
        readableDatabase.rawQuery("SELECT COUNT(*) FROM $table", null).use { if (it.moveToFirst()) it.getLong(0) else 0L }

    fun addPost(id: String, text: String, imagePath: String?, clientTime: Long) {
        val cv = ContentValues().apply {
            put("id", id); put("text", text); put("image_path", imagePath); put("client_time", clientTime)
        }
        writableDatabase.insertOrThrow("posts", null, cv)
    }

    fun pendingPosts(): List<PostRow> {
        val out = ArrayList<PostRow>()
        readableDatabase.rawQuery(
            "SELECT id,text,image_path,client_time,uploaded_url FROM posts ORDER BY seq ASC", null
        ).use { c ->
            while (c.moveToNext()) {
                out += PostRow(c.getString(0), c.getString(1), c.getString(2), c.getLong(3), c.getString(4))
            }
        }
        return out
    }

    fun setPostUrl(id: String, url: String) {
        writableDatabase.execSQL("UPDATE posts SET uploaded_url=? WHERE id=?", arrayOf(url, id))
    }

    fun deletePost(id: String) {
        writableDatabase.delete("posts", "id=?", arrayOf(id))
    }

    companion object {
        @Volatile private var inst: SyncStore? = null
        fun get(ctx: Context): SyncStore =
            inst ?: synchronized(this) { inst ?: SyncStore(ctx.applicationContext).also { inst = it } }
    }
}
