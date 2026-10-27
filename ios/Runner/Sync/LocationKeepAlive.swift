import CoreLocation

/// Layer 1 (continuous location keep-alive) + layer 4a/4b (significant changes + 100 m region relaunch).
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAlive()

    private let mgr = CLLocationManager()
    private var lastLocation: CLLocation?
    private var regionCenter: CLLocation?

    var status: CLAuthorizationStatus { mgr.authorizationStatus }
    var isAlways: Bool { status == .authorizedAlways }
    var monitoringRegion: Bool { mgr.monitoredRegions.contains { $0.identifier == Config.regionId } }

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        mgr.distanceFilter = kCLDistanceFilterNone
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.activityType = .other
    }

    func requestAlways() { mgr.requestAlwaysAuthorization() }

    func start() {
        if status == .notDetermined || status == .authorizedWhenInUse { mgr.requestAlwaysAuthorization() }
        mgr.allowsBackgroundLocationUpdates = true
        mgr.showsBackgroundLocationIndicator = true
        mgr.startUpdatingLocation()
        mgr.startMonitoringSignificantLocationChanges() // 4a: relaunch after kill
        armRegion()                                      // 4b: re-armed on every wake
    }

    func stop() {
        mgr.stopUpdatingLocation()
        mgr.stopMonitoringSignificantLocationChanges()
        for r in mgr.monitoredRegions where r.identifier == Config.regionId { mgr.stopMonitoring(for: r) }
        mgr.allowsBackgroundLocationUpdates = false
        regionCenter = nil
    }

    /// Register a 100 m circular region around the current location; leaving it relaunches a killed app.
    func armRegion() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard let loc = mgr.location ?? lastLocation else { mgr.requestLocation(); return }
        for r in mgr.monitoredRegions where r.identifier == Config.regionId { mgr.stopMonitoring(for: r) }
        let region = CLCircularRegion(center: loc.coordinate, radius: Config.regionRadius, identifier: Config.regionId)
        region.notifyOnExit = true
        region.notifyOnEntry = false
        mgr.startMonitoring(for: region)
        regionCenter = loc
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        if SyncStore.shared.running { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        if regionCenter == nil || loc.distance(from: regionCenter!) > 50 || !monitoringRegion { armRegion() }
        // Location callbacks are a free wake-up: make sure the rest of the stack is alive too.
        SyncManager.shared.touch()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        armRegion()
        SyncManager.shared.touch()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Sync] location error: %@", error.localizedDescription)
    }
}
