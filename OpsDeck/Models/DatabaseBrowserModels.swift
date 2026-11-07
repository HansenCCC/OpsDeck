import Foundation

// MARK: - Database browser (Navicat-lite) models
//
// The browser talks to a running database through a `DatabaseQueryEngine`. The
// first engine (`CLIDatabaseEngine`) shells out to the server's `mysql`/`psql`
// clients over the existing SSH channel and parses their batch output; a future
// native-driver engine (MySQLNIO / PostgresNIO over an SSH tunnel) can conform
// to the same protocol without touching the UI. Everything here is dialect- and
// transport-agnostic.

/// SQL dialect the browser speaks. MariaDB reuses the MySQL client/dialect.
enum DBDialect: String, CaseIterable, Identifiable, Sendable, Equatable, Codable {
    case mysql
    case postgres

    var id: String { rawValue }

    /// The gridable dialect for a detected database, or nil for non-SQL targets
    /// (Redis is key/value — a different UI, not part of the table browser).
    static func from(_ kind: DatabaseKind) -> DBDialect? {
        switch kind {
        case .mysql, .mariadb: return .mysql
        case .postgresql: return .postgres
        case .redis: return nil
        }
    }

    var defaultPort: Int { self == .mysql ? 3306 : 5432 }

    var displayName: String { self == .mysql ? "MySQL / MariaDB" : "PostgreSQL" }

    var systemDatabases: Set<String> {
        self == .mysql
            ? ["information_schema", "performance_schema", "mysql", "sys"]
            : ["postgres", "template0", "template1"]
    }
}

/// Optional login for a database target. When nil, the engine falls back to the
/// server's admin/socket auth (`sudo mysql` / `sudo -u postgres psql`), matching
/// the legacy read-only inspect. When present, credentials are passed to the CLI
/// client via a mode-600 options file (`--defaults-extra-file`) or the `PGPASSWORD`
/// environment variable — never on argv (ps-visible) and never into logs.
struct DBCredential: Sendable, Equatable, Codable {
    var username: String
    var password: String
    /// Where the client connects. Usually 127.0.0.1 (loopback on the server).
    var host: String = "127.0.0.1"
    /// nil → dialect default (3306 / 5432).
    var port: Int?

    var isEmpty: Bool { username.isEmpty && password.isEmpty }
}

enum DBConnectionSource: String, Sendable, Equatable, Codable {
    case detected
    case manual
}

/// One database endpoint reachable from the selected SSH server. Non-secret
/// fields are persisted locally; the password is stored separately in Keychain
/// under this profile's stable id.
struct DBConnectionProfile: Identifiable, Sendable, Equatable, Codable {
    var id: String
    var name: String
    var dialect: DBDialect
    var host: String
    var port: Int
    var username: String
    var source: DBConnectionSource

    var endpoint: String { "\(host):\(port)" }

    static func detected(_ target: DatabaseTarget) -> DBConnectionProfile? {
        guard let dialect = DBDialect.from(target.kind) else { return nil }
        return DBConnectionProfile(
            id: "detected-\(target.kind.rawValue)",
            name: target.kind.displayName,
            dialect: dialect,
            host: "127.0.0.1",
            port: dialect.defaultPort,
            username: "",
            source: .detected
        )
    }
}

/// User input for CREATE DATABASE. A dedicated role is optional. The password
/// is transient and is never written to UserDefaults or logs.
struct DBCreateDatabaseRequest: Sendable, Equatable {
    var name: String
    var username: String?
    var password: String?
    var mysqlCharacterSet: String?
    var mysqlAccountHost: String? = nil

    var createsUser: Bool {
        guard let username else { return false }
        return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DBCreateDatabasePlan: Sendable, Equatable {
    var statements: [String]
    var previewStatements: [String]
}

enum DBColumnWidthPolicy {
    static func initialWidth(name: String, dataType: String?, sampleValues: [String]) -> Double {
        let type = dataType?.lowercased() ?? ""
        let loweredName = name.lowercased()
        if type.contains("bool") || type.contains("tinyint(1)") { return 88 }
        if type.contains("int") || type.contains("decimal") || type.contains("numeric")
            || loweredName == "id" || loweredName.hasSuffix("_id") { return 104 }
        if type.contains("date") || type.contains("time") || loweredName.hasSuffix("_at") { return 176 }
        if type.contains("json") || type.contains("text") || type.contains("blob")
            || loweredName.contains("url") || loweredName.contains("path") { return 280 }
        let headerWidth = Double(name.count * 7 + 36)
        let sampleWidth = sampleValues.prefix(30).reduce(0.0) { width, value in
            max(width, Double(min(value.count, 34) * 7 + 24))
        }
        return min(260, max(120, max(headerWidth, sampleWidth)))
    }
}

/// One column's shape, from `information_schema`. `isPrimaryKey` drives which
/// columns key row edits/deletes (P2).
struct DBColumnInfo: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var dataType: String
    var nullable: Bool
    var isPrimaryKey: Bool
    var defaultValue: String?
}

/// One table in the current database, with cheap size/row estimates for the tree.
struct DBTableInfo: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var estimatedRows: Int?
    var sizeMB: Double?
}

/// A lightweight, in-memory copy of one connection's navigator tree. Query
/// results and credentials deliberately stay out of this snapshot: it exists
/// only so switching connections does not visually collapse the previous tree.
struct DBNavigatorSnapshot: Sendable, Equatable {
    var databases: [String] = []
    var selectedDatabase: String?
    var tablesByDatabase: [String: [DBTableInfo]] = [:]
}

struct DBNavigatorDatabaseKey: Hashable, Sendable {
    var connectionID: String
    var database: String
}

/// Selection and disclosure are independent in a Finder-style outline. This
/// pure state is intentionally testable: activating connection B must never
/// implicitly collapse connection A.
struct DBNavigatorExpansionState: Sendable, Equatable {
    private(set) var expandedConnectionIDs: Set<String> = []
    private(set) var expandedDatabaseKeys: Set<DBNavigatorDatabaseKey> = []

    func isConnectionExpanded(_ connectionID: String) -> Bool {
        expandedConnectionIDs.contains(connectionID)
    }

    func isDatabaseExpanded(connectionID: String, database: String) -> Bool {
        expandedDatabaseKeys.contains(DBNavigatorDatabaseKey(connectionID: connectionID, database: database))
    }

    mutating func activateConnection(_ connectionID: String) {
        expandedConnectionIDs.insert(connectionID)
    }

    mutating func toggleConnection(_ connectionID: String) {
        if expandedConnectionIDs.contains(connectionID) {
            expandedConnectionIDs.remove(connectionID)
        } else {
            expandedConnectionIDs.insert(connectionID)
        }
    }

    mutating func activateDatabase(connectionID: String, database: String) {
        expandedConnectionIDs.insert(connectionID)
        expandedDatabaseKeys.insert(DBNavigatorDatabaseKey(connectionID: connectionID, database: database))
    }

    mutating func toggleDatabase(connectionID: String, database: String) {
        let key = DBNavigatorDatabaseKey(connectionID: connectionID, database: database)
        if expandedDatabaseKeys.contains(key) {
            expandedDatabaseKeys.remove(key)
        } else {
            expandedConnectionIDs.insert(connectionID)
            expandedDatabaseKeys.insert(key)
        }
    }

    mutating func retainConnections(_ connectionIDs: Set<String>) {
        expandedConnectionIDs.formIntersection(connectionIDs)
        expandedDatabaseKeys = expandedDatabaseKeys.filter { connectionIDs.contains($0.connectionID) }
    }
}

/// A query result. Every cell is an optional string; `nil` means SQL NULL. The
/// CLI engine yields text for all values (a native engine could carry typed
/// values later without changing this shape). `affectedRows` is set for write
/// statements; `truncated` means the page/limit clipped the result.
struct DBResultSet: Sendable, Equatable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var affectedRows: Int?
    var truncated: Bool = false
    var elapsed: TimeInterval = 0
    var transportElapsed: TimeInterval = 0
    var parseElapsed: TimeInterval = 0
    var responseBytes: Int = 0

    var isEmpty: Bool { rows.isEmpty && columns.isEmpty }
    var rowCount: Int { rows.count }
}

/// Redacted timings kept in memory for the existing exported diagnostic log.
/// No SQL, database name, table name, host, or credentials are recorded.
struct DBPerformanceEvent: Sendable, Equatable {
    var capturedAt: Date
    var phase: String
    var totalMilliseconds: Int
    var transportMilliseconds: Int
    var parseMilliseconds: Int
    var responseBytes: Int
    var rows: Int
    var columns: Int

    var diagnosticLine: String {
        "OPSDECK_DB_PERF phase=\(phase) total_ms=\(totalMilliseconds) "
        + "transport_ms=\(transportMilliseconds) parse_ms=\(parseMilliseconds) "
        + "bytes=\(responseBytes) rows=\(rows) columns=\(columns)"
    }
}

/// One safe, server-side filter applied to the table grid. Keeping the first
/// version to a single predicate makes the generated SQL easy to inspect while
/// covering the common Navicat-style lookup workflow.
struct DBFilter: Sendable, Equatable {
    var column: String
    var operation: DBFilterOperation
    var value: String
}

enum DBFilterOperation: String, CaseIterable, Identifiable, Sendable {
    case contains
    case equals
    case notEquals
    case greaterThan
    case lessThan
    case isNull
    case isNotNull

    var id: String { rawValue }
    var needsValue: Bool { self != .isNull && self != .isNotNull }

    var title: String {
        switch self {
        case .contains: return String(localized: "包含")
        case .equals: return String(localized: "等于")
        case .notEquals: return String(localized: "不等于")
        case .greaterThan: return String(localized: "大于")
        case .lessThan: return String(localized: "小于")
        case .isNull: return String(localized: "为空")
        case .isNotNull: return String(localized: "不为空")
        }
    }
}

/// Start-after cursor for indexed pagination. It is intentionally limited to a
/// single non-null key; composite or custom sorts safely fall back to OFFSET.
struct DBPageCursor: Sendable, Equatable {
    var column: String
    var value: String
}

/// A single new-row field in the insert form. `useDefault` omits the column
/// from the INSERT (lets the DB apply its default / auto-increment); otherwise
/// `isNull` writes SQL NULL and `text` writes a quoted literal.
struct DBInsertField: Identifiable, Equatable {
    var id: String { column }
    var column: String
    var dataType: String
    var isPrimaryKey: Bool
    var nullable: Bool
    var text: String = ""
    var isNull: Bool = false
    var useDefault: Bool = false
}

/// A staged write awaiting the user's confirmation. The generated SQL is shown
/// verbatim before execution (nothing runs silently).
struct DBWriteRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    var title: String
    var sql: String
    var isDestructive: Bool
    var clearsStagedChanges: Bool = false
    var showsSQLResult: Bool = false
    /// Optional redacted SQL shown to the user (for password operations).
    var previewSQL: String? = nil
    /// Execute without selecting the current database (for DROP DATABASE etc.).
    var runsAtConnectionLevel: Bool = false
    /// Reload database/table metadata after successful DDL.
    var reloadsNavigator: Bool = false
    var preferredDatabaseAfter: String? = nil
}

/// A local-only query editor tab. SQL drafts never leave the Mac except when
/// the user explicitly executes them on the selected database connection.
struct DBQueryTab: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var sql: String = ""

    var title: String {
        let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? String(localized: "新查询") : String(firstLine.prefix(28))
    }
}

struct DBSavedQuery: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var sql: String
    var updatedAt = Date()

    var title: String {
        let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? String(localized: "未命名查询") : String(firstLine.prefix(48))
    }
}

struct DBQueryWorkspaceSnapshot: Codable, Equatable, Sendable {
    var tabs: [DBQueryTab]
    var selectedTabID: UUID?
    var history: [DBSavedQuery]
    var favorites: [DBSavedQuery]
}

enum DBPrivilegePreset: String, CaseIterable, Identifiable, Sendable {
    case readOnly
    case readWrite
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .readOnly: return String(localized: "只读")
        case .readWrite: return String(localized: "读写")
        case .all: return String(localized: "全部权限")
        }
    }
}

enum DBSQLStatementKind: Equatable, Sendable {
    case readOnly
    case dataMutation
    case schemaOrPrivilegeMutation

    var requiresConfirmation: Bool { self != .readOnly }
    var isDestructive: Bool { self == .schemaOrPrivilegeMutation }

    static func classify(_ sql: String) -> DBSQLStatementKind {
        let normalized = stripLeadingComments(from: sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let tokens = normalized.split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }.map(String.init)
        guard let first = tokens.first else {
            return .readOnly
        }
        // Inspect the whole batch, not only its first statement. `SELECT 1;
        // DROP TABLE x` must not be classified as read-only. This intentionally
        // errs toward an extra confirmation if a keyword occurs in a literal.
        let schemaTokens: Set<String> = [
            "ALTER", "CREATE", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE",
            "VACUUM", "ANALYZE", "ATTACH", "DETACH", "SET", "RESET", "USE"
        ]
        if schemaTokens.contains(first) {
            return .schemaOrPrivilegeMutation
        }
        let dataTokens: Set<String> = [
            "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "CALL", "EXEC", "EXECUTE"
        ]
        if tokens.contains(where: dataTokens.contains) {
            return .dataMutation
        }
        if tokens.contains(where: schemaTokens.contains) {
            return .schemaOrPrivilegeMutation
        }
        switch first {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "PRAGMA", "VALUES":
            return .readOnly
        case "WITH":
            return .readOnly
        default:
            // Unknown verbs are not allowed to bypass confirmation. This covers
            // DDL, GRANT/REVOKE, maintenance commands and vendor extensions.
            return .schemaOrPrivilegeMutation
        }
    }

    private static func stripLeadingComments(from sql: String) -> String {
        var value = sql[...]
        while true {
            value = value.drop(while: { $0.isWhitespace })
            if value.hasPrefix("--") || value.hasPrefix("#") {
                guard let newline = value.firstIndex(of: "\n") else { return "" }
                value = value[value.index(after: newline)...]
                continue
            }
            if value.hasPrefix("/*"), let end = value.range(of: "*/") {
                value = value[end.upperBound...]
                continue
            }
            return String(value)
        }
    }
}

struct DBStagedCellChange: Identifiable, Sendable, Equatable {
    var id: String { "\(rowIndex)#\(column)" }
    var rowIndex: Int
    var column: String
    var originalValue: String?
    var newValue: String?
    var sql: String
}

/// Tabs in the table detail area of the browser.
enum DBBrowserTab: String, CaseIterable, Identifiable, Sendable {
    case data
    case structure
    case sql

    var id: String { rawValue }
    var title: String {
        switch self {
        case .data: return String(localized: "数据")
        case .structure: return String(localized: "结构")
        case .sql: return String(localized: "SQL")
        }
    }
    var systemImage: String {
        switch self {
        case .data: return "tablecells"
        case .structure: return "list.bullet.rectangle"
        case .sql: return "terminal"
        }
    }
}

enum DBEngineError: LocalizedError, Sendable, Equatable {
    /// The target isn't a SQL grid (e.g. Redis), or a feature isn't wired.
    case notSupported(String)
    /// The server-side client returned a non-zero exit — auth failure, bad SQL,
    /// connection refused. The associated text is the client's own message.
    case queryFailed(String)
    /// The client succeeded but its output couldn't be parsed as expected.
    case parse(String)
    /// A local validation error. No database command was sent.
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .notSupported(let m): return m
        case .queryFailed(let m): return m
        case .parse(let m): return String(localized: "解析数据库输出失败：\(m)")
        case .invalidInput(let m): return m
        }
    }
}
