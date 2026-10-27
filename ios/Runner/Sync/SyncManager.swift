import UIKit
import Network
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase
import FirebaseMessaging

/// The single write path. Every layer (timer, location, audio, PushKit, silent FCM, BGTask, relaunch)
/// calls `writeTick`. Flutter never touches this.
final class SyncManager {
    static let shared = SyncManager()

    private let store = SyncStore.shared
    private let workQueue = DispatchQueue(label: "sync.work")
    private var timer: Timer?
    private var configured = false
    private var observing = false
    private let monitor = NWPathMonitor()
    private var monitorStarted = false
    private(set) var online = true

    var isConfigured: Bool { configured }
    var timerActive: Bool { timer?.isValid ?? false }

    // MARK: - Firebase

    func configureFirebase() {
        guard !configured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            NSLog("[Sync] GoogleService-Info.plist missing: add it to ios/Runner")
            return
        }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        Database.database().isPersistenceEnabled = true // offline persistence
        configured = true
    }

    /// Blocking; call only from `workQueue` / a background queue. Returns the anonymous uid (= deviceId).
    func ensureUid() -> String? {
        guard configured else { return nil }
        if let u = Auth.auth().currentUser { store.deviceId = u.uid; return u.uid }
        // Keychain can be unreadable before first unlock after reboot: never mint a second identity then.
        if store.deviceId != nil { return nil }
        let sem = DispatchSemaphore(value: 0)
        var uid: String?
        Auth.auth().signInAnonymously { r, _ in uid = r?.user.uid; sem.signal() }
        _ = sem.wait(timeout: .now() + 15)
        if let uid { store.deviceId = uid }
        return uid
    }

    /// Reconcile local counter with devices/{id}/meta/lastN using a transaction (max of both).
    func reconcile() {
        workQueue.async {
            guard let uid = self.ensureUid() else { return }
            let sem = DispatchSemaphore(value: 0)
            Database.database().reference(withPath: "devices/\(uid)/meta/lastN").runTransactionBlock({ data in
                let remote = (data.value as? NSNumber)?.int64Value ?? 0
                data.value = max(remote, self.store.lastN)
                return TransactionResult.success(withValue: data)
            }, andCompletionBlock: { _, committed, snap in
                if committed, let merged = (snap?.value as? NSNumber)?.int64Value, merged > self.store.lastN {
                    self.store.lastN = merged
                }
                sem.signal()
            })
            _ = sem.wait(timeout: .now() + Config.writeTimeout)
        }
    }

    func saveFcmToken(_ t: String) { store.fcmToken = t; workQueue.async { self.flush() } }
    func saveVoipToken(_ t: String) { store.voipToken = t; workQueue.async { self.flush() } }

    // MARK: - writeTick

    /// Layer 3: each write is wrapped in beginBackgroundTask / endBackgroundTask.
    func writeTick(_ appState: String, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask(withName: "sync-write") {
                app.endBackgroundTask(bg); bg = .invalid
            }
            self.workQueue.async {
                self.performTick(appState)
                DispatchQueue.main.async {
                    if bg != .invalid { app.endBackgroundTask(bg) }
                    completion?()
                }
            }
        }
    }

    private func performTick(_ appState: String) {
        guard configured, store.running else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let prev = store.lastWriteAt
        if prev != 0 && now >= prev && now - prev < Config.dedupeMs {
            NSLog("[Sync] skip %@: last write %llds ago", appState, (now - prev) / 1000)
            return
        }
        let n = store.lastN + 1
        let gap: Int64 = prev == 0 ? 0 : max(0, (now - prev) / 1000)
        let key = Database.database().reference().childByAutoId().key ?? UUID().uuidString
        store.lastN = n
        store.lastWriteAt = now
        store.lastAppState = appState
        store.enqueue(QueuedRecord(seq: 0, key: key, n: n, appState: appState, clientTime: now, gap: gap))
        flush()
        NSLog("[Sync] tick Test_%lld (%@) gap=%llds pending=%d", n, appState, gap, store.pending())
    }

    /// Send queued records in order; stops at the first failure so ordering is preserved.
    private func flush() {
        guard online else { return } // offline: rows stay queued, flushed by the path monitor / next tick
        guard let uid = ensureUid() else { return }
        let ref = Database.database().reference(withPath: "devices/\(uid)")
        var rows = store.peek(50)
        while !rows.isEmpty {
            for r in rows {
                var upd: [String: Any] = [
                    "logs/\(r.key)": [
                        "value": "Test_\(r.n)", "n": r.n, "platform": "ios", "appState": r.appState,
                        "deviceId": uid, "clientTime": r.clientTime,
                        "timestamp": ServerValue.timestamp(), "gapSeconds": r.gap,
                    ] as [String: Any],
                    "meta/lastN": r.n,
                    "meta/lastWriteAt": ServerValue.timestamp(),
                    "meta/platform": "ios",
                ]
                if let t = store.fcmToken { upd["meta/fcmToken"] = t }
                if let t = store.voipToken { upd["meta/voipToken"] = t }
                upd["meta/lowPowerMode"] = Degradation.shared.lowPower
                upd["meta/bgRefresh"] = Degradation.shared.bgRefresh
                upd["meta/locationAlways"] = LocationKeepAlive.shared.isAlways
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                ref.updateChildValues(upd) { err, _ in ok = (err == nil); sem.signal() }
                if sem.wait(timeout: .now() + Config.writeTimeout) == .timedOut || !ok { return }
                store.delete(r.seq)
                store.tokensDirty = false
            }
            rows = store.peek(50)
        }
        if store.tokensDirty {
            var meta: [String: Any] = ["platform": "ios", "lowPowerMode": Degradation.shared.lowPower,
                                       "bgRefresh": Degradation.shared.bgRefresh,
                                       "locationAlways": LocationKeepAlive.shared.isAlways]
            if let t = store.fcmToken { meta["fcmToken"] = t }
            if let t = store.voipToken { meta["voipToken"] = t }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            ref.child("meta").updateChildValues(meta) { err, _ in ok = (err == nil); sem.signal() }
            if sem.wait(timeout: .now() + Config.writeTimeout) == .success && ok { store.tokensDirty = false }
        }
    }

    /// Flush queued records inside a background task (used when connectivity returns or flags change).
    func flushSoon() {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask(withName: "sync-flush") { app.endBackgroundTask(bg); bg = .invalid }
            self.workQueue.async {
                if self.store.pending() > 0 || self.store.tokensDirty { self.flush() }
                DispatchQueue.main.async { if bg != .invalid { app.endBackgroundTask(bg) } }
            }
        }
    }

    /// Offline layer: the moment any network path appears, flush whatever is queued.
    private func startNetworkMonitor() {
        guard !monitorStarted else { return }
        monitorStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let was = self.online
            self.online = path.status == .satisfied
            if self.online && !was { self.flushSoon() }
        }
        monitor.start(queue: DispatchQueue(label: "sync.net"))
    }

    // MARK: - Layer lifecycle (call on main)

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// Start every layer. `initialState`, when given, triggers an immediate tag-specific write.
    func startAll(initialState: String? = nil) {
        onMain {
            self.store.running = true
            self.configureFirebase()
            self.startNetworkMonitor()
            Degradation.shared.start()
            self.restartLayers()
            VoipPushHandler.shared.register()
            UIApplication.shared.registerForRemoteNotifications() // silent FCM push (layer 6)
            if self.configured { Messaging.messaging().token { t, _ in if let t { self.saveFcmToken(t) } } }
            if !self.observing {
                self.observing = true
                NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                       object: nil, queue: .main) { _ in
                    if self.store.running { self.restartLayers() }
                }
            }
            self.writeTick(initialState ?? (UIApplication.shared.applicationState == .active ? "foreground" : "background"))
            self.reconcile()
        }
    }

    /// Re-arm layers 1-3 + timer + BG tasks; called on every wake.
    func restartLayers() {
        onMain {
            guard self.store.running else { return }
            LocationKeepAlive.shared.start()
            SilentAudio.shared.start()
            self.startTimer()
            BGTasks.schedule()
            Degradation.shared.notifyIfDegraded()
        }
    }

    /// Light wake hook (no location restart, so location callbacks cannot recurse).
    func touch() {
        onMain {
            guard self.store.running else { return }
            SilentAudio.shared.start()
            self.startTimer()
            BGTasks.schedule()
        }
    }

    func stopAll() {
        onMain {
            self.store.running = false
            self.timer?.invalidate(); self.timer = nil
            LocationKeepAlive.shared.stop()
            SilentAudio.shared.stop()
            BGTasks.cancel()
        }
    }

    private func startTimer() {
        guard timer == nil || !(timer!.isValid) else { return }
        // Native 60s timer on the .common run loop mode so it also fires while the UI is tracking.
        let t = Timer(timeInterval: Config.tick, repeats: true) { [weak self] _ in
            let s = UIApplication.shared.applicationState == .active ? "foreground" : "background"
            self?.writeTick(s)
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
