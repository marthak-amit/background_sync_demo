import Foundation

enum Config {
    static let tick: TimeInterval = 60
    /// Skip a write if the previous one was less than this long ago (shared by every wake path).
    static let dedupeMs: Int64 = 55_000
    static let writeTimeout: TimeInterval = 20
    static let uploadTimeout: TimeInterval = 100

    /// Layer 5 flag: PushKit VoIP wake via CallKit. On by default for this demo build.
    static let VOIP_ENABLED = true
    /// Layer 2 flag: silent looping audio keep-alive. On by default for this demo build.
    static let AUDIO_ENABLED = true

    // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskId = "com.demo.backgroundSyncDemo.refresh"
    static let processingTaskId = "com.demo.backgroundSyncDemo.processing"

    static let regionId = "sync-region"
    static let regionRadius: Double = 100
}
