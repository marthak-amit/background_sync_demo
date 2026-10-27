import UIKit
import Network
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

/// The single write path. Every layer (timer, location, audio, PushKit, silent FCM, BGTask, relaunch)
/// calls `writeTick`; user posts go through `submitPost`. Both only touch the local queue first, so nothing
/// depends on the network. Flutter never touches this.
///
/// Firestore: devices/{deviceId} (meta fields), devices/{deviceId}/logs/{id}, devices/{deviceId}/posts/{id}
/// Images:    Supabase Storage bucket, object devices/{deviceId}/{postId}.jpg; the public URL is stored in the post doc
final class SyncManager {
    static let shared = SyncManager()

    private let store = SyncStore.shared
    /// Fast, serial: counter + enqueue only. Never blocked by the network.
    private let tickQueue = DispatchQueue(label: "sync.tick")
    /// Serial: all network work (can take up to ~2 min for an upload).
    private let flushQueue = DispatchQueue(label: "sync.flush")
    private let tickLock = NSLock()
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
        // Offline persistence (Firestore's own cache, in addition to our SQLite outbox).
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
        configured = true
        startNetworkMonitor()
    }

    private func db() -> Firestore { Firestore.firestore() }

    /// Blocking; call only from a background queue. Returns the anonymous uid (= deviceId).
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

    /// Runs `body`, which must call its callback exactly once; true only if it reported success in time.
    private func waitFor(_ timeout: TimeInterval, _ body: (@escaping (Bool) -> Void) -> Void) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        body { ok = $0; sem.signal() }
        return sem.wait(timeout: .now() + timeout) == .success && ok
    }

    /// Reconcile local counter with devices/{id}.lastN using a transaction (max of both).
    func reconcile() {
        flushQueue.async {
            guard self.online, let uid = self.ensureUid() else { return }
            let ref = self.db().document("devices/\(uid)")
            let sem = DispatchSemaphore(value: 0)
            self.db().runTransaction({ tx, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try tx.getDocument(ref) } catch let e as NSError { errPtr?.pointee = e; return nil }
                let remote = (snap.data()?["lastN"] as? NSNumber)?.int64Value ?? 0
                let merged = max(remote, self.store.lastN)
                tx.setData(["lastN": merged], forDocument: ref, merge: true)
                return merged
            }) { result, _ in
                if let m = (result as? NSNumber)?.int64Value {
                    self.tickLock.lock()
                    if m > self.store.lastN { self.store.lastN = m }
                    self.tickLock.unlock()
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + Config.writeTimeout)
        }
    }

    func saveFcmToken(_ t: String) { store.fcmToken = t; flushSoon() }
    func saveVoipToken(_ t: String) { store.voipToken = t; flushSoon() }

    // MARK: - writeTick

    /// Each write is wrapped in beginBackgroundTask / endBackgroundTask (layer 3).
    /// - waitForFlush: false for the timer, so a slow upload can never delay the next tick.
    func writeTick(_ appState: String, waitForFlush: Bool = true, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask(withName: "sync-write") { app.endBackgroundTask(bg); bg = .invalid }
            let finish = { DispatchQueue.main.async { if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid } } }
            self.tickQueue.async {
                self.recordTick(appState)
                if !waitForFlush { DispatchQueue.main.async { completion?() } }
                // Even a deduped wake is a free chance to push queued data (posts, offline backlog).
                self.flushQueue.async {
                    self.flushAll()
                    if waitForFlush { DispatchQueue.main.async { completion?() } }
                    finish()
                }
            }
        }
    }

    /// Counter + local queue only: no network.
    private func recordTick(_ appState: String) {
        guard configured, store.running else { return }
        tickLock.lock(); defer { tickLock.unlock() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let prev = store.lastWriteAt
        if prev != 0 && now >= prev && now - prev < Config.dedupeMs {
            NSLog("[Sync] skip %@: last write %llds ago", appState, (now - prev) / 1000)
            return
        }
        let n = store.lastN + 1
        let gap: Int64 = prev == 0 ? 0 : max(0, (now - prev) / 1000)
        store.lastN = n
        store.lastWriteAt = now
        store.lastAppState = appState
        store.enqueue(QueuedRecord(seq: 0, key: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                                   n: n, appState: appState, clientTime: now, gap: gap))
        NSLog("[Sync] tick Test_%lld (%@) gap=%llds", n, appState, gap)
    }

    // MARK: - User posts

    /// Queue a post (text + optional image file). Works offline: flushed as soon as a network exists.
    func submitPost(text: String, srcPath: String?) {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var dest: String?
        if let src = srcPath, !src.isEmpty {
            let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("outbox")
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = dir.appendingPathComponent("\(id).jpg") // app-private copy: survives the picker cache being purged
                try? FileManager.default.removeItem(at: f)
                if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: f)) != nil { dest = f.path }
            }
        }
        store.addPost(id: id, text: text, imagePath: dest, clientTime: Int64(Date().timeIntervalSince1970 * 1000))
        flushSoon()
    }

    // MARK: - Flushing (all on flushQueue)

    /// Flush queued data inside a background task (connectivity returned, post submitted, token changed).
    func flushSoon() {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask(withName: "sync-flush") { app.endBackgroundTask(bg); bg = .invalid }
            self.flushQueue.async {
                self.flushAll()
                DispatchQueue.main.async { if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid } }
            }
        }
    }

    private func flushAll() {
        guard configured, store.pending() > 0 || store.tokensDirty else { return }
        guard online else { return } // offline: stays queued; the path monitor / next tick retries
        guard let uid = ensureUid() else { return }
        guard flushLogs(uid), flushPosts(uid) else { return }
        pushMetaIfDirty(uid)
        NSLog("[Sync] flush done pending=%d", store.pending())
    }

    private func metaFields(n: Int64?) -> [String: Any] {
        var m: [String: Any] = [
            "platform": "ios",
            "lowPowerMode": Degradation.shared.lowPower,
            "bgRefresh": Degradation.shared.bgRefresh,
            "locationAlways": LocationKeepAlive.shared.isAlways,
        ]
        if let n { m["lastN"] = n; m["lastWriteAt"] = FieldValue.serverTimestamp() } // only heartbeats bump lastWriteAt
        if let t = store.fcmToken { m["fcmToken"] = t }
        if let t = store.voipToken { m["voipToken"] = t }
        return m
    }

    /// Heartbeat rows, oldest first; stops at the first failure so ordering is preserved.
    private func flushLogs(_ uid: String) -> Bool {
        let device = db().document("devices/\(uid)")
        var rows = store.peek(50)
        while !rows.isEmpty {
            for r in rows {
                let rec: [String: Any] = [
                    "value": "Test_\(r.n)", "n": r.n, "platform": "ios", "appState": r.appState,
                    "deviceId": uid, "clientTime": r.clientTime,
                    "timestamp": FieldValue.serverTimestamp(), "gapSeconds": r.gap,
                ]
                let batch = db().batch()
                batch.setData(rec, forDocument: device.collection("logs").document(r.key)) // fixed id: retries are idempotent
                batch.setData(metaFields(n: r.n), forDocument: device, merge: true)
                guard waitFor(Config.writeTimeout, { done in batch.commit { done($0 == nil) } }) else { return false }
                store.delete(r.seq)
                store.tokensDirty = false
            }
            rows = store.peek(50)
        }
        return true
    }

    /// Posts: upload the image to Supabase Storage, then write the Firestore document holding the image link.
    private func flushPosts(_ uid: String) -> Bool {
        for p in store.pendingPosts() {
            var url = p.uploadedUrl
            let path = "devices/\(uid)/\(p.id).jpg"
            if let ip = p.imagePath, url == nil {
                if FileManager.default.fileExists(atPath: ip) {
                    guard SupabaseUploader.isConfigured else {
                        NSLog("[Sync] Supabase not configured (SupabaseConfig.swift): post %@ stays queued", p.id)
                        continue
                    }
                    guard let l = SupabaseUploader.upload(fileURL: URL(fileURLWithPath: ip), objectPath: path) else { return false }
                    url = l
                    store.setPostUrl(p.id, l) // never re-upload once the object exists
                } else {
                    url = "" // source file vanished: sync the text on its own
                }
            }
            let hasImage = !(url ?? "").isEmpty
            var doc: [String: Any] = [
                "text": p.text, "clientTime": p.clientTime, "timestamp": FieldValue.serverTimestamp(),
                "deviceId": uid, "platform": "ios",
            ]
            if hasImage { doc["imagePath"] = "\(SupabaseConfig.bucket)/\(path)"; doc["imageUrl"] = url! }
            let ref = db().document("devices/\(uid)/posts/\(p.id)")
            guard waitFor(Config.writeTimeout, { done in ref.setData(doc) { done($0 == nil) } }) else { return false }
            if let ip = p.imagePath { try? FileManager.default.removeItem(atPath: ip) }
            store.deletePost(p.id)
            NSLog("[Sync] post %@ synced", p.id)
        }
        return true
    }

    /// Token / flag changes with nothing else queued.
    private func pushMetaIfDirty(_ uid: String) {
        guard store.tokensDirty else { return }
        let ref = db().document("devices/\(uid)")
        if waitFor(Config.writeTimeout, { done in ref.setData(self.metaFields(n: nil), merge: true) { done($0 == nil) } }) {
            store.tokensDirty = false
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
            self?.writeTick(s, waitForFlush: false)
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
