import Foundation
import KuriCore
import SQLite3

/// A minimal wrapper over the system SQLite library.
///
/// Not thread-safe on its own: `Store` owns one and serializes access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens (or creates) the database at `path`. Use ":memory:" for tests.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw KuriError.database(message)
        }
        try execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements that take no parameters.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw KuriError.database(message)
        }
    }

    /// Runs a statement with parameters, discarding any rows.
    func run(_ sql: String, _ values: SQLValue...) throws {
        let statement = try prepare(sql, values)
        while try statement.step() {}
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: SQLValue..., map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        var results: [T] = []
        while try statement.step() {
            results.append(try map(Row(statement: statement)))
        }
        return results
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws { try query("PRAGMA user_version") { $0.int(0) }.first ?? 0 }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> Statement {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else {
            throw KuriError.database("\(lastError) — in: \(sql)")
        }
        let statement = Statement(raw: raw, db: handle)
        for (index, value) in values.enumerated() {
            try statement.bind(value, at: Int32(index + 1))
        }
        return statement
    }
}

enum SQLValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)

    static func optional(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func optional(_ value: Int?) -> SQLValue { value.map { .int($0) } ?? .null }
    static func date(_ value: Date) -> SQLValue { .double(value.timeIntervalSince1970) }
    static func optional(_ value: Date?) -> SQLValue { value.map { .date($0) } ?? .null }
    static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString.lowercased()) }
    static func optional(_ value: UUID?) -> SQLValue { value.map { .uuid($0) } ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
}

/// SQLite copies bound strings and blobs immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
    fileprivate let raw: OpaquePointer
    private let db: OpaquePointer?

    fileprivate init(raw: OpaquePointer, db: OpaquePointer?) {
        self.raw = raw
        self.db = db
    }

    deinit {
        sqlite3_finalize(raw)
    }

    fileprivate func bind(_ value: SQLValue, at index: Int32) throws {
        let result: Int32 = switch value {
        case .null: sqlite3_bind_null(raw, index)
        case .int(let v): sqlite3_bind_int64(raw, index, Int64(v))
        case .double(let v): sqlite3_bind_double(raw, index, v)
        case .text(let v): sqlite3_bind_text(raw, index, v, -1, SQLITE_TRANSIENT)
        case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(raw, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        }
        guard result == SQLITE_OK else { throw KuriError.database(String(cString: sqlite3_errmsg(db))) }
    }

    /// Advances to the next row. Returns `false` when done.
    fileprivate func step() throws -> Bool {
        switch sqlite3_step(raw) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw KuriError.database(String(cString: sqlite3_errmsg(db)))
        }
    }
}

struct Row {
    fileprivate let statement: Statement

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement.raw, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement.raw, column)) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement.raw, column) }

    func string(_ column: Int32) -> String {
        sqlite3_column_text(statement.raw, column).map { String(cString: $0) } ?? ""
    }
    func optionalString(_ column: Int32) -> String? { isNull(column) ? nil : string(column) }

    func bool(_ column: Int32) -> Bool { int(column) != 0 }
    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }
    func optionalDate(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }

    func uuid(_ column: Int32) -> UUID { UUID(uuidString: string(column)) ?? UUID() }
    func optionalUUID(_ column: Int32) -> UUID? { optionalString(column).flatMap(UUID.init(uuidString:)) }
}
