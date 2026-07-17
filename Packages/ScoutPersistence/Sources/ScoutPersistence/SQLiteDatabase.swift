import CSQLite
import Foundation

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, busyTimeoutMilliseconds: Int32) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not allocate a database handle"
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteEventStoreError.sqlite(
                SQLiteFailure(code: result, message: message)
            )
        }
        handle = opened

        let timeoutResult = sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            let failure = failure(code: timeoutResult)
            sqlite3_close_v2(opened)
            handle = nil
            throw SQLiteEventStoreError.sqlite(failure)
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var isOpen: Bool { handle != nil }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close_v2(handle)
        guard result == SQLITE_OK else {
            throw SQLiteEventStoreError.sqlite(failure(code: result))
        }
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        let handle = try requiredHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
                sqlite3_free(errorMessage)
            } else {
                message = String(cString: sqlite3_errmsg(handle))
            }
            throw SQLiteEventStoreError.sqlite(
                SQLiteFailure(code: result, message: message)
            )
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        let handle = try requiredHandle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteEventStoreError.sqlite(failure(code: result))
        }
        return statement
    }

    func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteEventStoreError.sqlite(failure(code: result))
        }
        return result
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransientDestructor)
        }
        try requireBinding(result)
    }

    func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        try requireBinding(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransientDestructor
            )
        }
        try requireBinding(result)
    }

    func bindNull(to index: Int32, in statement: OpaquePointer) throws {
        try requireBinding(sqlite3_bind_null(statement, index))
    }

    func text(at column: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }

    func int64(at column: Int32, in statement: OpaquePointer) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func data(at column: Int32, in statement: OpaquePointer) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    func finalize(_ statement: OpaquePointer) {
        sqlite3_finalize(statement)
    }

    func changes() throws -> Int {
        Int(sqlite3_changes(try requiredHandle()))
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteEventStoreError.storeClosed }
        return handle
    }

    private func failure(code: Int32) -> SQLiteFailure {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite store is closed"
        return SQLiteFailure(code: code, message: message)
    }

    private func requireBinding(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteEventStoreError.sqlite(failure(code: result))
        }
    }
}

extension SQLiteDatabase {
    func querySingleInt(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        defer { finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return int64(at: 0, in: statement)
    }

    func querySingleText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }
}
