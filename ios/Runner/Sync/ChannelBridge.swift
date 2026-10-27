import Flutter
import UIKit
import CoreLocation
import FirebaseDatabase

/// Flutter = UI only. MethodChannel `sync/control` + EventChannel `sync/logs` mirror the Android contract.
final class ChannelBridge: NSObject, FlutterStreamHandler {
    static let shared = ChannelBridge()

    private var query: DatabaseQuery?
    private var handle: UInt?

    func setup(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "sync/control", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "start": SyncManager.shared.startAll(); result(true)
            case "stop": SyncManager.shared.stopAll(); result(true)
            case "status": result(Self.status())
            case "permissions": result(Self.permissions())
            case "fix": Self.fix(call.arguments as? String ?? ""); result(true)
            default: result(FlutterMethodNotImplemented)
            }
        }
        FlutterEventChannel(name: "sync/logs", binaryMessenger: messenger).setStreamHandler(self)
    }

    private static func status() -> [String: Any] {
        let s = SyncStore.shared
        func layer(_ n: String, _ ok: Bool) -> [String: Any] { ["name": n, "ok": ok] }
        let loc = LocationKeepAlive.shared
        return [
            "running": s.running, "n": s.lastN, "lastWriteAt": s.lastWriteAt,
            "lastAppState": s.lastAppState, "pending": s.pending(),
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

    // MARK: FlutterStreamHandler (live last-30 list)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        DispatchQueue.global().async {
            guard let uid = SyncManager.shared.ensureUid() else { return }
            DispatchQueue.main.async {
                let q = Database.database().reference(withPath: "devices/\(uid)/logs").queryOrderedByKey().queryLimited(toLast: 30)
                self.query = q
                self.handle = q.observe(.value) { snap in
                    var rows: [[String: Any]] = []
                    for c in snap.children {
                        if let s = c as? DataSnapshot, let m = s.value as? [String: Any] { rows.append(m) }
                    }
                    rows.sort { (($0["n"] as? NSNumber)?.int64Value ?? 0) > (($1["n"] as? NSNumber)?.int64Value ?? 0) }
                    events(rows)
                }
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let q = query, let h = handle { q.removeObserver(withHandle: h) }
        query = nil; handle = nil
        return nil
    }
}
