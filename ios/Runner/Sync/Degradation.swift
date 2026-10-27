import UIKit
import UserNotifications

/// Low Power Mode / Background App Refresh off / location downgraded cannot be overridden by an app.
/// What we can do: keep every layer that does NOT depend on them running (location, audio, VoIP),
/// tell the user immediately with a local notification, and report the state to Firebase (meta.*)
/// so the server-side watchdog and operators can see it.
final class Degradation {
    static let shared = Degradation()

    private(set) var lowPower = false
    private(set) var bgRefresh = true
    private var lastAlert = Date.distantPast
    private var started = false
    private let notifId = "sync-degraded"

    /// Call on main.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in self.changed() }
        nc.addObserver(forName: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil, queue: .main) { _ in self.changed() }
    }

    func refresh() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        bgRefresh = UIApplication.shared.backgroundRefreshStatus == .available
    }

    private func changed() {
        refresh()
        SyncManager.shared.flushSoon() // push the new meta.* flags
        notifyIfDegraded(force: true)
    }

    func problems() -> [String] {
        var p: [String] = []
        if lowPower { p.append("Turn off Low Power Mode") }
        if !bgRefresh { p.append("Turn on Background App Refresh") }
        if !LocationKeepAlive.shared.isAlways { p.append("Set Location access to Always") }
        return p
    }

    /// Throttled to one alert per 30 min unless the state just changed.
    func notifyIfDegraded(force: Bool = false) {
        guard SyncStore.shared.running else { return }
        refresh()
        let p = problems()
        let center = UNUserNotificationCenter.current()
        if p.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: [notifId])
            return
        }
        guard force || Date().timeIntervalSince(lastAlert) > 30 * 60 else { return }
        lastAlert = Date()
        let c = UNMutableNotificationContent()
        c.title = "Background sync may be interrupted"
        c.body = p.joined(separator: ". ") + "."
        c.sound = .default
        center.add(UNNotificationRequest(identifier: notifId, content: c, trigger: nil))
    }
}
