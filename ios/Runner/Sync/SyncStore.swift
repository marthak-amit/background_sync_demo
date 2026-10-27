import Foundation
import SQLite3

struct QueuedRecord {
    let seq: Int64
    let key: String
    let n: Int64
    let appState: String
    let clientTime: Int64
    let gap: Int64
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local persistence: counter / timestamps in UserDefaults, offline write queue in SQLite.
final class SyncStore {
    static let shared = SyncStore()

    private let d = UserDefaults.standard
    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let path = dir?.appendingPathComponent("sync_queue.sqlite").path ?? ":memory:"
        if sqlite3_open(path, &db) == SQLITE_OK {
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS queue(seq INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL,
                n INTEGER NOT NULL, app_state TEXT NOT NULL, client_time INTEGER NOT NULL, gap INTEGER NOT NULL)
                """, nil, nil, nil)
        }
    }

    private func setInt(_ v: Int64, _ k: String) { d.set(Int(v), forKey: k); d.synchronize() }

    var lastN: Int64 { get { Int64(d.integer(forKey: "lastN")) } set { setInt(newValue, "lastN") } }
    var lastWriteAt: Int64 { get { Int64(d.integer(forKey: "lastWriteAt")) } set { setInt(newValue, "lastWriteAt") } }
    /// True while the user wants sync on. Every layer checks this first.
    var running: Bool { get { d.bool(forKey: "running") } set { d.set(newValue, forKey: "running"); d.synchronize() } }
    var deviceId: String? { get { d.string(forKey: "deviceId") } set { d.set(newValue, forKey: "deviceId") } }
    var lastAppState: String { get { d.string(forKey: "lastAppState") ?? "-" } set { d.set(newValue, forKey: "lastAppState") } }
    var tokensDirty: Bool { get { d.bool(forKey: "tokensDirty") } set { d.set(newValue, forKey: "tokensDirty") } }
    var fcmToken: String? {
        get { d.string(forKey: "fcmToken") }
        set { d.set(newValue, forKey: "fcmToken"); d.set(true, forKey: "tokensDirty") }
    }
    var voipToken: String? {
        get { d.string(forKey: "voipToken") }
        set { d.set(newValue, forKey: "voipToken"); d.set(true, forKey: "tokensDirty") }
    }

    func enqueue(_ r: QueuedRecord) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO queue(key,n,app_state,client_time,gap) VALUES(?,?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, r.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(st, 2, r.n)
        sqlite3_bind_text(st, 3, r.appState, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(st, 4, r.clientTime)
        sqlite3_bind_int64(st, 5, r.gap)
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    func peek(_ limit: Int) -> [QueuedRecord] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        var out: [QueuedRecord] = []
        sqlite3_prepare_v2(db, "SELECT seq,key,n,app_state,client_time,gap FROM queue ORDER BY seq ASC LIMIT \(limit)", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(QueuedRecord(
                seq: sqlite3_column_int64(st, 0),
                key: String(cString: sqlite3_column_text(st, 1)),
                n: sqlite3_column_int64(st, 2),
                appState: String(cString: sqlite3_column_text(st, 3)),
                clientTime: sqlite3_column_int64(st, 4),
                gap: sqlite3_column_int64(st, 5)))
        }
        sqlite3_finalize(st)
        return out
    }

    func delete(_ seq: Int64) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM queue WHERE seq=\(seq)", nil, nil, nil)
    }

    func pending() -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        var n = 0
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM queue", -1, &st, nil)
        if sqlite3_step(st) == SQLITE_ROW { n = Int(sqlite3_column_int(st, 0)) }
        sqlite3_finalize(st)
        return n
    }
}
