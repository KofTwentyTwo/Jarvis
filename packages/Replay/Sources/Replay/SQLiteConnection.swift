import Foundation
import SQLite3

// SQLite's static destructor sentinels are not exported as Swift constants.
// We need SQLITE_TRANSIENT so SQLite copies the bound buffer (text/blob) —
// our caller's `Data` may be released before sqlite3_step reads it.
let SQLITE_STATIC_DESTRUCTOR = unsafeBitCast(0, to: sqlite3_destructor_type.self)
let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Hand-rolled SQLite3 wrapper.
///
/// Phase 7 will load the `sqlite-vec` extension (vector search for memory),
/// which requires `sqlite3_load_extension`. The mainline Swift package
/// `SQLite.swift` (Stephen Celis) statically blocks that API, so we own the
/// connection ourselves. This is intentional — see CLAUDE.md memory stack
/// section + research §11.
///
/// Concurrency: opens with `SQLITE_OPEN_FULLMUTEX` (serialized mode). The
/// `ReplayLog` actor is the sole writer in P4; `OrphanDetector` opens its own
/// connection at launch. `@unchecked Sendable` is safe because the only mutable
/// state is `OpaquePointer` and FULLMUTEX makes SQLite the synchronization
/// layer.
public final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let h = handle {
            sqlite3_close(h)
        }
    }

    /// Open (or create) a SQLite database at `url`.
    public static func open(
        at url: URL,
        flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    ) throws -> SQLiteConnection {
        var raw: OpaquePointer?
        let path = url.path
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        guard rc == SQLITE_OK, let h = raw else {
            let msg = raw.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = raw { sqlite3_close(h) }
            throw SQLiteError.openFailed(code: rc, message: msg)
        }
        return SQLiteConnection(handle: h)
    }

    /// Execute one or more SQL statements with no bindings (DDL, pragmas).
    public func execute(_ sql: String) throws {
        guard let h = handle else { throw SQLiteError.stepFailed(code: SQLITE_MISUSE, message: "closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let m = errMsg.flatMap { String(cString: $0) } ?? String(cString: sqlite3_errmsg(h))
            sqlite3_free(errMsg)
            throw SQLiteError.stepFailed(code: rc, message: m)
        }
        sqlite3_free(errMsg)
    }

    /// Execute a single statement with bindings. No rows returned.
    public func exec(_ sql: String, bindings: [SQLiteValue]) throws {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        try stmt.bindAll(bindings)
        _ = try stmt.step()
    }

    /// Execute a single SELECT, mapping every row via `map`.
    public func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteStatement) -> T
    ) throws -> [T] {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        try stmt.bindAll(bindings)
        var rows: [T] = []
        while try stmt.step() {
            rows.append(map(stmt))
        }
        return rows
    }

    public func beginTransaction() throws { try execute("BEGIN") }
    public func commit() throws { try execute("COMMIT") }
    public func rollback() throws { try execute("ROLLBACK") }

    /// Close the underlying handle. Safe to call multiple times.
    public func close() throws {
        guard let h = handle else { return }
        let rc = sqlite3_close(h)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(h))
            throw SQLiteError.closeFailed(code: rc, message: msg)
        }
        handle = nil
    }

    /// Closure-based accessor for the raw SQLite handle.
    ///
    /// The OpaquePointer cannot escape the closure (Swift's noescape
    /// inference + `body` is non-`@escaping`). Plan 07-01 uses this to call
    /// sqlite3_enable_load_extension + sqlite3_load_extension from
    /// MemoryStore without leaking the handle out of the connection actor's
    /// ownership boundary.
    ///
    /// - Throws: SQLiteError.stepFailed(SQLITE_MISUSE) if the handle is closed.
    public func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let h = handle else {
            throw SQLiteError.stepFailed(code: SQLITE_MISUSE, message: "closed")
        }
        return try body(h)
    }

    /// `sqlite3_errmsg` snapshot — for diagnostic logging on best-effort writes.
    public var lastErrorMessage: String {
        guard let h = handle else { return "<closed>" }
        return String(cString: sqlite3_errmsg(h))
    }

    fileprivate func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let h = handle else { throw SQLiteError.prepareFailed(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var raw: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &raw, nil)
        guard rc == SQLITE_OK, let s = raw else {
            let msg = String(cString: sqlite3_errmsg(h))
            throw SQLiteError.prepareFailed(code: rc, message: msg, sql: sql)
        }
        return SQLiteStatement(handle: s, parent: h)
    }
}

/// A bind-able value. Covers every SQL type our schema uses.
public enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// SQLite errors. Preserves the result code and `sqlite3_errmsg` snapshot so
/// callers can distinguish e.g. `SQLITE_CONSTRAINT_FOREIGNKEY` from
/// `SQLITE_BUSY` when needed.
public enum SQLiteError: Error, Sendable, Equatable {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(code: Int32)
    case closeFailed(code: Int32, message: String)
}

/// Wrapper around a prepared statement. Auto-finalized by `defer { stmt.finalize() }`
/// at every call site; a deinit-based finalize would race the connection close.
public final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let parent: OpaquePointer

    init(handle: OpaquePointer, parent: OpaquePointer) {
        self.handle = handle
        self.parent = parent
    }

    public func finalize() {
        if let h = handle {
            sqlite3_finalize(h)
            handle = nil
        }
    }

    @discardableResult
    public func step() throws -> Bool {
        guard let h = handle else { throw SQLiteError.stepFailed(code: SQLITE_MISUSE, message: "finalized") }
        let rc = sqlite3_step(h)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            let msg = String(cString: sqlite3_errmsg(parent))
            throw SQLiteError.stepFailed(code: rc, message: msg)
        }
    }

    public func reset() {
        if let h = handle { sqlite3_reset(h) }
    }

    public func bindAll(_ values: [SQLiteValue]) throws {
        guard let h = handle else { throw SQLiteError.bindFailed(code: SQLITE_MISUSE) }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null:
                rc = sqlite3_bind_null(h, idx)
            case .int(let n):
                rc = sqlite3_bind_int64(h, idx, n)
            case .real(let d):
                rc = sqlite3_bind_double(h, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(h, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(h, idx, 0)
                } else {
                    rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
                        guard let base = raw.baseAddress else { return SQLITE_OK }
                        return sqlite3_bind_blob(h, idx, base, Int32(raw.count), SQLITE_TRANSIENT_DESTRUCTOR)
                    }
                }
            }
            if rc != SQLITE_OK {
                throw SQLiteError.bindFailed(code: rc)
            }
        }
    }

    public func columnInt(at index: Int32) -> Int64 {
        guard let h = handle else { return 0 }
        return sqlite3_column_int64(h, index)
    }

    public func columnDouble(at index: Int32) -> Double {
        guard let h = handle else { return 0 }
        return sqlite3_column_double(h, index)
    }

    public func columnText(at index: Int32) -> String? {
        guard let h = handle else { return nil }
        guard let cstr = sqlite3_column_text(h, index) else { return nil }
        return String(cString: cstr)
    }

    public func columnBlob(at index: Int32) -> Data? {
        guard let h = handle else { return nil }
        let count = Int(sqlite3_column_bytes(h, index))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let raw = sqlite3_column_blob(h, index) else { return nil }
        return Data(bytes: raw, count: count)
    }

    public func columnIsNull(at index: Int32) -> Bool {
        guard let h = handle else { return true }
        return sqlite3_column_type(h, index) == SQLITE_NULL
    }
}
