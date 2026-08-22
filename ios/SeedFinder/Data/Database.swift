import Foundation
import SQLite3

/// Minimal read-only SQLite wrapper over the C API.
///
/// Deliberately no third-party dependency. The app makes a handful of query
/// shapes against a database it ships with, so a package would add resolution
/// time, binary size and a supply-chain surface to save perhaps eighty lines.
///
/// Everything here is `nonisolated` and the type is an `actor`, so queries run
/// off the main actor and cannot block a frame.
actor Database {
    enum Failure: Error, LocalizedError {
        case cannotOpen(String)
        case badStatement(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let p): return "Could not open the species database at \(p)"
            case .badStatement(let m): return "Query failed: \(m)"
            }
        }
    }

    private var handle: OpaquePointer?
    /// Compiled statements are reused across calls; preparing SQL is the single
    /// largest avoidable cost in a query this small.
    private var cache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var db: OpaquePointer?
        // READONLY because the bundle is not writable, and NOMUTEX because the
        // actor already serialises access.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw Failure.cannotOpen(path)
        }
        handle = db
        // 256 MB of address space, not resident memory: pages fault in only as
        // queries touch them, which is what makes a cold start cheap.
        sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size=-8000", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
    }

    deinit {
        for (_, stmt) in cache { sqlite3_finalize(stmt) }
        if let handle { sqlite3_close_v2(handle) }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = cache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.badStatement(String(cString: sqlite3_errmsg(handle)))
        }
        cache[sql] = stmt
        return stmt
    }

    /// Run `sql` and map each row with `row`.
    func query<T>(_ sql: String, _ args: [Value] = [], row: (Row) -> T) throws -> [T] {
        let stmt = try statement(sql)
        for (i, arg) in args.enumerated() { arg.bind(to: stmt, at: Int32(i + 1)) }
        var out: [T] = []
        // Reserving is worth it: a 100 km query returns several hundred rows and
        // the default growth pattern reallocates repeatedly.
        out.reserveCapacity(256)
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(Row(stmt))) }
        sqlite3_reset(stmt)
        return out
    }

    func scalar(_ sql: String, _ args: [Value] = []) throws -> String? {
        try query(sql, args) { $0.string(0) }.first ?? nil
    }

    enum Value {
        case int(Int)
        case double(Double)
        case text(String)

        func bind(to stmt: OpaquePointer, at i: Int32) {
            switch self {
            case .int(let v): sqlite3_bind_int64(stmt, i, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v):
                // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string
                // need not outlive the call.
                sqlite3_bind_text(stmt, i, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
    }

    /// Thin column reader. Valid only for the duration of the mapping closure.
    struct Row {
        private let stmt: OpaquePointer
        init(_ stmt: OpaquePointer) { self.stmt = stmt }

        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int(stmt, i) != 0 }

        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        func intOrNil(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : int(i)
        }

        func doubleOrNil(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : double(i)
        }
    }
}
