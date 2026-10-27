package com.demo.background_sync_demo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.MetadataChanges
import com.google.firebase.firestore.Query
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Flutter = UI only. Everything real happens in SyncManager / SyncService; this just bridges. */
class MainActivity : FlutterActivity() {
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = SyncStore.get(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "sync/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    store.running = true
                    io.execute {
                        ExitReasons.record(this)
                        ManagedMode.apply(this)
                        SyncManager.init(this)
                        Scheduler.armWatchdog(this)
                        Scheduler.enqueueWorker(this)
                        Scheduler.startService(this, restart = true)
                        SyncManager.reconcile(this)
                    }
                    result.success(true)
                }
                "stop" -> {
                    store.running = false
                    Scheduler.cancelAll(this)
                    stopService(Intent(this, SyncService::class.java))
                    result.success(true)
                }
                "status" -> result.success(status())
                "permissions" -> result.success(permissions())
                "submitPost" -> {
                    val text = (call.argument<String>("text") ?: "").trim()
                    val path = call.argument<String>("path")
                    if (text.isEmpty() && path.isNullOrEmpty()) { result.error("empty", "Nothing to post", null) }
                    else {
                        io.execute { SyncManager.submitPost(this, text, path) }
                        result.success(true)
                    }
                }
                "fix" -> { fix(call.arguments as String); result.success(true) }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "sync/logs").setStreamHandler(QueryStream("logs", "n"))
        EventChannel(messenger, "sync/posts").setStreamHandler(QueryStream("posts", "clientTime"))
    }

    /** Live last-30 Firestore query (includes local pending writes, so it also works offline). */
    private inner class QueryStream(private val sub: String, private val orderField: String) : EventChannel.StreamHandler {
        private var reg: ListenerRegistration? = null

        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            io.execute {
                val uid = SyncManager.ensureAuth(this@MainActivity) ?: return@execute
                main.post {
                    reg = FirebaseFirestore.getInstance().collection("devices/$uid/$sub")
                        .orderBy(orderField, Query.Direction.DESCENDING).limit(30)
                        .addSnapshotListener(MetadataChanges.INCLUDE) { snap, err ->
                            if (err != null || snap == null) { sink.error("firestore", err?.message, null); return@addSnapshotListener }
                            sink.success(snap.documents.map { plain(it) })
                        }
                }
            }
        }

        override fun onCancel(args: Any?) { reg?.remove(); reg = null }
    }

    private fun plain(d: DocumentSnapshot): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        d.getData(DocumentSnapshot.ServerTimestampBehavior.ESTIMATE)?.forEach { (k, v) ->
            m[k] = if (v is Timestamp) v.toDate().time else v
        }
        m["id"] = d.id
        m["pendingWrite"] = d.metadata.hasPendingWrites()
        return m
    }

    private fun status(): Map<String, Any?> {
        val s = SyncStore.get(this)
        val now = System.currentTimeMillis()
        return mapOf(
            "running" to s.running,
            "n" to s.lastN,
            "lastWriteAt" to s.lastWriteAt,
            "lastAppState" to s.lastAppState,
            "pending" to s.pending(),
            "outbox" to s.pendingPosts().map {
                mapOf("id" to it.id, "text" to it.text, "imagePath" to it.imagePath, "clientTime" to it.clientTime)
            },
            "layers" to listOf(
                layer("1 Foreground service (dataSync)", SyncService.isRunning),
                layer("2 Wake lock per write", s.running),
                layer("3 Swipe-kill restart (START_STICKY + alarm)", s.running),
                layer("4 Exact alarm watchdog", s.watchdogNextAt > now - 5_000),
                layer("5 Boot / package-replaced receivers", s.running),
                layer("6 WorkManager 15 min", s.workerScheduled),
                layer("7 FCM data push", s.fcmToken != null),
            ),
        )
    }

    private fun layer(name: String, ok: Boolean) = mapOf("name" to name, "ok" to ok)

    private fun item(id: String, label: String, ok: Boolean, hint: String) =
        mapOf("id" to id, "label" to label, "ok" to ok, "hint" to hint)

    private fun permissions(): List<Map<String, Any?>> {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val notif = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val list = mutableListOf(
            item("notifications", "Notifications", notif, "Needed so the 'Sync running' notification is visible"),
            item("battery", "Ignore battery optimisation", pm.isIgnoringBatteryOptimizations(packageName), "Exempts the app from Doze network/CPU limits"),
            item("exact", "Exact alarms", Scheduler.canExact(this), "Lets the 60s watchdog fire on time"),
            item("oem", "OEM auto-start / background (${Build.MANUFACTURER})", SyncStore.get(this).oemAck || !OemIntents.hasKnownTarget(),
                if (OemIntents.hasKnownTarget()) "Tap to open the vendor screen: allow auto-start, set battery to 'No restrictions'" else "No vendor screen known for this device"),
        )
        list += item("managed", "Managed device (Force Stop locked)", ManagedMode.forceStopLocked(this),
            "Recommended for remote units: provision as device owner (README > Managed devices). Without it, Force Stop ends all sync")
        return list
    }

    private fun fix(id: String) {
        when (id) {
            "notifications" ->
                if (Build.VERSION.SDK_INT >= 33)
                    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            "battery" -> try {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
            "exact" ->
                if (Build.VERSION.SDK_INT >= 31)
                    startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
            "managed" -> {} // cannot be granted in-app: needs adb / QR provisioning, see README
            "oem" -> {
                // The OS cannot report this setting, so opening the vendor screen counts as acknowledged.
                if (OemIntents.open(this) == null)
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                SyncStore.get(this).oemAck = true
            }
        }
    }

    override fun onResume() { super.onResume(); AppForeground.isForeground = true }
    override fun onPause() { AppForeground.isForeground = false; super.onPause() }
}
