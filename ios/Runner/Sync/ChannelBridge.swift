import Flutter
import UIKit
import CoreLocation
import FirebaseFirestore

/// Flutter = UI only. MethodChannel `sync/control` + EventChannel `sync/logs` mirror the Android contract.
final class ChannelBridge: NSObject {
    static let shared = ChannelBridge()

    // Held strongly: FlutterEventChannel keeps its handler weakly.
    private let logsStream = QueryStream(sub: "logs", field: "n")
    private let postsStream = QueryStream(sub: "posts", field: "clientTime")

    func setup(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "sync/control", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "start": SyncManager.shared.startAll(); result(true)
            case "stop": SyncManager.shared.stopAll(); result(true)
            case "status": result(Self.status())
            case "permissions": result(Self.permissions())
            case "submitPost":
                let a = call.arguments as? [String: Any] ?? [:]
                let text = ((a["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let path = a["path"] as? String
                if text.isEmpty && (path ?? "").isEmpty {
                    result(FlutterError(code: "empty", message: "Nothing to post", details: nil))
                } else {
                    SyncManager.shared.submitPost(text: text, srcPath: path)
                    result(true)
                }
            case "fix": Self.fix(call.arguments as? String ?? ""); result(true)
            default: result(FlutterMethodNotImplemented)
            }
        }
        FlutterEventChannel(name: "sync/logs", binaryMessenger: messenger).setStreamHandler(logsStream)
        FlutterEventChannel(name: "sync/posts", binaryMessenger: messenger).setStreamHandler(postsStream)
    }

    private static func status() -> [String: Any] {
        let s = SyncStore.shared
        func layer(_ n: String, _ ok: Bool) -> [String: Any] { ["name": n, "ok": ok] }
        let loc = LocationKeepAlive.shared
        return [
            "running": s.running, "n": s.lastN, "lastWriteAt": s.lastWriteAt,
            "lastAppState": s.lastAppState, "pending": s.pending(),
            "outbox": s.pendingPosts().map { p -> [String: Any] in
                ["id": p.id, "text": p.text, "imagePath": p.imagePath as Any, "clientTime": p.clientTime]
            },
            "layers": [
                layer("1 Continuous location (Always)", s.running && loc.isAlways),
                layer("2 Silent audio loop", Config.AUDIO_ENABLED && SilentAudio.shared.isPlaying),
                layer("3 Native 60s timer + bg task wrap", SyncManager.shared.timerActive),
                layer("4 Significant-change + 100 m region", loc.monitoringRegion),
                layer("5 VoIP PushKit", Config.VOIP_ENABLED && VoipPushHandler.shared.hasToken),
                layer("6 Silent FCM push", s.fcmToken != nil),
                layer("7 BGAppRefresh / BGProcessing", s.running),
            ],
        ]
    }

    private static func item(_ id: String, _ label: String, _ ok: Bool, _ hint: String) -> [String: Any] {
        ["id": id, "label": label, "ok": ok, "hint": hint]
    }

    private static func permissions() -> [[String: Any]] {
        let app = UIApplication.shared
        return [
            item("location", "Location: Always", LocationKeepAlive.shared.isAlways,
                 "Settings > Location > Always (needed for the keep-alive + kill relaunch)"),
            item("bgRefresh", "Background App Refresh", app.backgroundRefreshStatus == .available,
                 "Settings > General > Background App Refresh > ON for this app"),
            item("lowPower", "Low Power Mode off", !ProcessInfo.processInfo.isLowPowerModeEnabled,
                 "Low Power Mode suspends background activity: turn it off"),
            item("push", "Push token (silent FCM)", SyncStore.shared.fcmToken != nil,
                 "Needs a real device with Push Notifications capability + APNs key in Firebase"),
            item("voip", "VoIP token", !Config.VOIP_ENABLED || VoipPushHandler.shared.hasToken,
                 "Needs a real device; token appears after first launch"),
        ]
    }

    private static func fix(_ id: String) {
        if id == "location", LocationKeepAlive.shared.status == .notDetermined
            || LocationKeepAlive.shared.status == .authorizedWhenInUse {
            LocationKeepAlive.shared.requestAlways(); return
        }
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Live last-30 Firestore query (includes local pending writes, so it also works offline).
final class QueryStream: NSObject, FlutterStreamHandler {
    private let sub: String
    private let field: String
    private var reg: ListenerRegistration?

    init(sub: String, field: String) { self.sub = sub; self.field = field }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        DispatchQueue.global().async {
            guard let uid = SyncManager.shared.ensureUid() else { return }
            DispatchQueue.main.async {
                self.reg = Firestore.firestore().collection("devices/\(uid)/\(self.sub)")
                    .order(by: self.field, descending: true).limit(to: 30)
                    .addSnapshotListener(includeMetadataChanges: true) { snap, err in
                        guard let snap, err == nil else {
                            events(FlutterError(code: "firestore", message: err?.localizedDescription, details: nil)); return
                        }
                        events(snap.documents.map { Self.plain($0) })
                    }
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        reg?.remove(); reg = nil
        return nil
    }

    private static func plain(_ d: QueryDocumentSnapshot) -> [String: Any] {
        var m: [String: Any] = [:]
        for (k, v) in d.data(with: .estimate) {
            if let t = v as? Timestamp { m[k] = Int64(t.dateValue().timeIntervalSince1970 * 1000) } else { m[k] = v }
        }
        m["id"] = d.documentID
        m["pendingWrite"] = d.metadata.hasPendingWrites
        return m
    }
}
