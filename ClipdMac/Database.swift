import Foundation
import SQLCipher
import ClipdCore

enum SQLValue: Equatable {
    case text(String)
    case int(Int64)
    case blob(Data)
    case null
}

enum DatabaseError: Error {
    case open(String)
    case sql(String, String)
}

/// A thin wrapper over the SQLite C API. Executes SQL and maps rows. Makes no
/// decisions: the schema lives in Core and so does every query that is not a
/// literal.
final class Database {
    private var handle: OpaquePointer?

    init(path: String, key: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw DatabaseError.open(path)
        }
        handle = db

        // MUST be the first statement after opening. Anything before it and
        // SQLCipher writes plaintext.
        //
        // Rejected: sqlite3_key(). The C function is only declared when
        // SQLITE_HAS_CODEC is defined at the header level, which a binary
        // target does not do for its consumers, so it does not compile at all.
        //
        // The key is a hex string we generated, so doubling any quote is belt
        // and braces rather than a real escape concern.
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "PRAGMA key = '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.open("could not set key")
        }
        // Survives a crash without corrupting, and is faster.
        _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    deinit { close() }

    var userVersion: Int {
        guard let rows = try? query("PRAGMA user_version", []),
              case .int(let version)? = rows.first?["user_version"] else { return 0 }
        return Int(version)
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.sql(sql, message)
        }
    }

    /// Runs a statement with bound parameters. Every value the app stores goes
    /// through here. Rejected: string interpolation into SQL, which is how
    /// clipboard content containing a quote would corrupt or inject.
    func run(_ sql: String, _ bind: [SQLValue]) throws {
        _ = try query(sql, bind)
    }

    func query(_ sql: String, _ bind: [SQLValue]) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sql(sql, lastMessage())
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: SQLite copies the bytes. Without it, Swift may free
        // the buffer before the statement runs.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bind.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s):
                sqlite3_bind_text(stmt, index, s, -1, transient)
            case .int(let n):
                sqlite3_bind_int64(stmt, index, n)
            case .blob(let d):
                if d.isEmpty {
                    sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    _ = d.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(d.count), transient)
                    }
                }
            case .null:
                sqlite3_bind_null(stmt, index)
            }
        }

        var rows: [[String: SQLValue]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                // SQLITE_NOTADB here means a wrong key. Throwing rather than
                // returning an empty result matters: an empty history looks
                // exactly like data loss to the user.
                throw DatabaseError.sql(sql, lastMessage())
            }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_BLOB:
                    if let raw = sqlite3_column_blob(stmt, c) {
                        row[name] = .blob(Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, c))))
                    } else {
                        row[name] = .blob(Data())
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Applies every migration the file has not seen, one transaction each.
    func migrate() throws {
        let current = userVersion
        for migration in Schema.migrations(after: current) {
            try execute("BEGIN")
            do {
                for statement in migration.statements {
                    try execute(statement)
                }
                // user_version does not accept a bound parameter.
                try execute("PRAGMA user_version = \(migration.version)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func lastMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
    }
}
