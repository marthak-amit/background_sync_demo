import BackgroundTasks

/// Layer 7: BGAppRefreshTask + BGProcessingTask, rescheduled on every run.
enum BGTasks {
    /// Must be called before application(_:didFinishLaunchingWithOptions:) returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Config.refreshTaskId, using: nil) { handle($0) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Config.processingTaskId, using: nil) { handle($0) }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: Config.refreshTaskId)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        let processing = BGProcessingTaskRequest(identifier: Config.processingTaskId)
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        processing.requiresNetworkConnectivity = false
        processing.requiresExternalPower = false
        for req in [refresh as BGTaskRequest, processing as BGTaskRequest] {
            do { try BGTaskScheduler.shared.submit(req) }
            catch { NSLog("[Sync] BGTask submit failed (%@): %@", req.identifier, error.localizedDescription) }
        }
    }

    static func cancel() { BGTaskScheduler.shared.cancelAllTaskRequests() }

    private static func handle(_ task: BGTask) {
        schedule() // reschedule first so the chain survives a crash
        var finished = false
        task.expirationHandler = {
            if !finished { finished = true; task.setTaskCompleted(success: false) }
        }
        guard SyncStore.shared.running else { finished = true; task.setTaskCompleted(success: true); return }
        SyncManager.shared.restartLayers()
        SyncManager.shared.writeTick("bg_task") {
            if !finished { finished = true; task.setTaskCompleted(success: true) }
        }
    }
}
