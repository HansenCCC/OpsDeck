import Foundation
import OSLog

// MARK: - Database query engine (Navicat-lite, P0)
//
// `DatabaseQueryEngine` is the transport-agnostic contract the browser UI talks
// to. `CLIDatabaseEngine` is the first implementation: it runs the server's own
// `mysql`/`psql` clients over the existing per-command SSH channel and parses
// their batch output. A native-driver engine (MySQLNIO / PostgresNIO over an SSH
// tunnel) can conform later without touching the UI.
//
// Safety posture:
//  • Credentials go to the client via a mode-600 `--defaults-extra-file` (MySQL)
//    or the `PGPASSWORD` env var (Postgres) — never on argv, never logged.
//  • Every script is base64-wrapped by SSHService and forced to `exit 0` with a
//    trailing `__OPSDECK_RC__=<n>` sentinel, so a non-zero client exit surfaces
//    as a readable error instead of Citadel throwing on the channel.
//  • Identifiers and string literals are escaped per dialect before interpolation.

/// The contract the browser depends on. Implementations may be CLI-over-SSH or
/// native-driver-over-tunnel.
protocol DatabaseQueryEngine: Sendable {
    func listDatabases(dialect: DBDialect, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [String]
    func listTables(dialect: DBDialect, database: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [DBTableInfo]
    func columns(dialect: DBDialect, database: String, table: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [DBColumnInfo]
    func selectRows(dialect: DBDialect, database: String, table: String, orderBy: String?, ascending: Bool, limit: Int, offset: Int, filter: DBFilter?, cursor: DBPageCursor?, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> DBResultSet
    func runSQL(dialect: DBDialect, database: String?, sql: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> DBResultSet
    func createDatabase(dialect: DBDialect, request: DBCreateDatabaseRequest, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws
    func databaseCreationPlan(dialect: DBDialect, request: DBCreateDatabaseRequest) throws -> DBCreateDatabasePlan
}

struct CLIDatabaseEngine: DatabaseQueryEngine {

    // Batch output framing. Control bytes (never present in text data) separate
    // Postgres fields/records so embedded tabs/newlines can't corrupt parsing.
    static let rcSentinel = "__OPSDECK_RC__="
    static let nullToken = "__OPSDECK_NULL__"
    static let fieldSep = "\u{01}"
    static let recordSep = "\u{02}"
    static let maxResponseSize = 4 * 1024 * 1024
    private static let performanceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.hansen.opsdeck",
        category: "DatabasePerformance"
    )

    // MARK: Public API

    func listDatabases(dialect: DBDialect, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [String] {
        let sql: String
        switch dialect {
        case .mysql: sql = "SHOW DATABASES"
        case .postgres: sql = "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        }
        let rs = try await query(dialect: dialect, sql: sql, database: nil, header: false,
                                 credential: credential, adminSudo: adminSudo, config: config, sshService: sshService)
        return rs.rows.compactMap { $0.first ?? nil }
    }

    func listTables(dialect: DBDialect, database: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [DBTableInfo] {
        let sql: String
        let db: String?
        switch dialect {
        case .mysql:
            db = nil
            sql = "SELECT table_name, table_rows, ROUND((data_length+index_length)/1024/1024,2) FROM information_schema.tables WHERE table_schema=\(litMySQL(database)) AND table_type='BASE TABLE' ORDER BY table_name"
        case .postgres:
            db = database
            sql = "SELECT c.relname, c.reltuples::bigint, ROUND(pg_total_relation_size(c.oid)/1024.0/1024,2) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY c.relname"
        }
        let rs = try await query(dialect: dialect, sql: sql, database: db, header: false,
                                 credential: credential, adminSudo: adminSudo, config: config, sshService: sshService)
        return rs.rows.compactMap { row in
            guard let name = row.first ?? nil, !name.isEmpty else { return nil }
            let rows = row.count > 1 ? (row[1].flatMap { Int($0) }) : nil
            let size = row.count > 2 ? (row[2].flatMap { Double($0) }) : nil
            return DBTableInfo(name: name, estimatedRows: rows, sizeMB: size)
        }
    }

    func columns(dialect: DBDialect, database: String, table: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> [DBColumnInfo] {
        let sql: String
        let db: String?
        switch dialect {
        case .mysql:
            db = nil
            sql = "SELECT column_name, column_type, is_nullable, column_key, column_default FROM information_schema.columns WHERE table_schema=\(litMySQL(database)) AND table_name=\(litMySQL(table)) ORDER BY ordinal_position"
        case .postgres:
            db = database
            sql = """
            SELECT c.column_name, c.data_type, c.is_nullable, \
            CASE WHEN pk.column_name IS NOT NULL THEN 'PRI' ELSE '' END, c.column_default \
            FROM information_schema.columns c \
            LEFT JOIN (SELECT kcu.column_name FROM information_schema.table_constraints tc \
            JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name \
            WHERE tc.table_name=\(litPG(table)) AND tc.constraint_type='PRIMARY KEY') pk \
            ON pk.column_name=c.column_name \
            WHERE c.table_name=\(litPG(table)) AND c.table_schema='public' ORDER BY c.ordinal_position
            """
        }
        let rs = try await query(dialect: dialect, sql: sql, database: db, header: false,
                                 credential: credential, adminSudo: adminSudo, config: config, sshService: sshService)
        return rs.rows.compactMap { row in
            guard let name = row.first ?? nil, !name.isEmpty else { return nil }
            let type = row.count > 1 ? (row[1] ?? "") : ""
            let nullable = row.count > 2 ? (row[2] == "YES") : true
            let isPK = row.count > 3 ? (row[3] == "PRI") : false
            let def = row.count > 4 ? row[4] : nil
            return DBColumnInfo(name: name, dataType: type, nullable: nullable, isPrimaryKey: isPK, defaultValue: def)
        }
    }

    func selectRows(dialect: DBDialect, database: String, table: String, orderBy: String?, ascending: Bool, limit: Int, offset: Int, filter: DBFilter?, cursor: DBPageCursor?, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> DBResultSet {
        let pageLimit = max(1, limit)
        let request = buildSelect(
            dialect: dialect, database: database, table: table, orderBy: orderBy,
            ascending: ascending, limit: pageLimit + 1, offset: offset,
            filter: filter, cursor: cursor
        )
        var rs = try await query(dialect: dialect, sql: request.sql, database: request.database, header: true,
                                 credential: credential, adminSudo: adminSudo, config: config, sshService: sshService)
        rs.truncated = rs.rows.count > pageLimit
        if rs.rows.count > pageLimit {
            rs.rows.removeSubrange(pageLimit...)
        }
        return rs
    }

    /// Pure SQL builder used by the live engine and offline smoke tests. A page
    /// cursor replaces OFFSET only when the caller has a stable single-column
    /// ordering key.
    func buildSelect(dialect: DBDialect, database: String, table: String, orderBy: String?, ascending: Bool, limit: Int, offset: Int, filter: DBFilter?, cursor: DBPageCursor?) -> (sql: String, database: String?) {
        let target = tableRef(dialect, database: database, table: table)
        let dir = ascending ? "ASC" : "DESC"
        var predicates: [String] = []
        if let filter {
            predicates.append(filterPredicate(dialect, filter))
        }
        if let cursor {
            let comparison = ascending ? ">" : "<"
            predicates.append("\(ident(dialect, cursor.column)) \(comparison) \(sqlValue(dialect, cursor.value, isNull: false))")
        }
        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        let orderClause = orderBy.map { " ORDER BY \(ident(dialect, $0)) \(dir)" } ?? ""
        let offsetClause = cursor == nil && offset > 0 ? " OFFSET \(offset)" : ""
        let sql = "SELECT * FROM \(target)\(whereClause)\(orderClause) LIMIT \(max(1, limit))\(offsetClause)"
        return (sql, dialect == .postgres ? database : nil)
    }

    func runSQL(dialect: DBDialect, database: String?, sql: String, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws -> DBResultSet {
        try await query(dialect: dialect, sql: sql, database: database, header: true,
                        credential: credential, adminSudo: adminSudo, config: config, sshService: sshService)
    }

    func createDatabase(dialect: DBDialect, request: DBCreateDatabaseRequest, config: SSHConnectionConfig, credential: DBCredential?, adminSudo: String, sshService: SSHService) async throws {
        let plan = try databaseCreationPlan(dialect: dialect, request: request)
        for statement in plan.statements {
            _ = try await query(
                dialect: dialect,
                sql: statement,
                database: nil,
                header: false,
                credential: credential,
                adminSudo: adminSudo,
                config: config,
                sshService: sshService
            )
        }
    }

    /// Pure, testable SQL plan. Each statement is executed separately because
    /// PostgreSQL does not permit CREATE DATABASE inside a transaction block.
    /// The preview mirrors execution but always redacts the optional role password.
    func databaseCreationPlan(dialect: DBDialect, request: DBCreateDatabaseRequest) throws -> DBCreateDatabasePlan {
        let database = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateIdentifier(
            database,
            label: String(localized: "数据库名称"),
            limit: dialect == .mysql ? .characters(64) : .utf8Bytes(63)
        )

        let username = request.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let username, !username.isEmpty {
            try validateIdentifier(
                username,
                label: String(localized: "用户名"),
                limit: dialect == .mysql ? .characters(32) : .utf8Bytes(63)
            )
            guard let password = request.password, !password.isEmpty else {
                throw DBEngineError.invalidInput(String(localized: "专用用户必须填写密码。"))
            }
            guard !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw DBEngineError.invalidInput(String(localized: "密码不能包含空字符。"))
            }
        }

        var statements: [String] = []
        var previews: [String] = []
        switch dialect {
        case .mysql:
            let charsetClause: String
            if let charset = request.mysqlCharacterSet, !charset.isEmpty {
                guard ["utf8mb4", "utf8"].contains(charset) else {
                    throw DBEngineError.invalidInput(String(localized: "不支持的 MySQL 字符集。"))
                }
                charsetClause = " CHARACTER SET \(charset)"
            } else {
                charsetClause = ""
            }
            let createDatabase = "CREATE DATABASE \(idMySQL(database))\(charsetClause)"
            statements.append(createDatabase)
            previews.append(createDatabase)
            if let username, !username.isEmpty, let password = request.password {
                let trimmedAccountHost = request.mysqlAccountHost?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let accountHost: String
                if let trimmedAccountHost, !trimmedAccountHost.isEmpty {
                    accountHost = trimmedAccountHost
                } else {
                    accountHost = "localhost"
                }
                try validateIdentifier(
                    accountHost,
                    label: String(localized: "允许连接来源"),
                    limit: .characters(255)
                )
                let account = "\(litMySQL(username))@\(litMySQL(accountHost))"
                let createUser = "CREATE USER \(account) IDENTIFIED BY \(litMySQL(password))"
                let previewUser = "CREATE USER \(account) IDENTIFIED BY '••••••••'"
                let grant = "GRANT ALL PRIVILEGES ON \(idMySQL(database)).* TO \(account)"
                statements.append(contentsOf: [createUser, grant])
                previews.append(contentsOf: [previewUser, grant])
            }
        case .postgres:
            if let username, !username.isEmpty, let password = request.password {
                let createRole = "CREATE ROLE \(idPG(username)) LOGIN PASSWORD \(litPG(password))"
                let previewRole = "CREATE ROLE \(idPG(username)) LOGIN PASSWORD '••••••••'"
                let createDatabase = "CREATE DATABASE \(idPG(database)) OWNER \(idPG(username))"
                statements.append(contentsOf: [createRole, createDatabase])
                previews.append(contentsOf: [previewRole, createDatabase])
            } else {
                let createDatabase = "CREATE DATABASE \(idPG(database))"
                statements.append(createDatabase)
                previews.append(createDatabase)
            }
        }
        return DBCreateDatabasePlan(statements: statements, previewStatements: previews)
    }

    // MARK: Execution

    private func query(dialect: DBDialect, sql: String, database: String?, header: Bool, credential: DBCredential?, adminSudo: String, config: SSHConnectionConfig, sshService: SSHService) async throws -> DBResultSet {
        let script: String
        switch dialect {
        case .mysql: script = mysqlScript(sql: sql, database: database, credential: credential, adminSudo: adminSudo, header: header)
        case .postgres: script = postgresScript(sql: sql, database: database, credential: credential, adminSudo: adminSudo, header: header)
        }
        let started = Date()
        let operation = Self.operationName(sql)
        let traceID = String(UUID().uuidString.prefix(8))
        Self.performanceLogger.notice(
            "OPSDECK_DB_PERF phase=query-start trace=\(traceID, privacy: .public) operation=\(operation, privacy: .public) dialect=\(dialect.rawValue, privacy: .public)"
        )
        let result: SSHCommandResult
        do {
            result = try await sshService.executeCommand(script, on: config, maxResponseSize: Self.maxResponseSize)
        } catch {
            Self.performanceLogger.error(
                "OPSDECK_DB_PERF phase=query-transport-error trace=\(traceID, privacy: .public) total_ms=\(Int(Date().timeIntervalSince(started) * 1_000))"
            )
            throw DBEngineError.queryFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        let (out, rc) = Self.splitSentinel(result.stdout)
        guard rc == 0 else {
            Self.performanceLogger.error(
                "OPSDECK_DB_PERF phase=query-server-error trace=\(traceID, privacy: .public) total_ms=\(Int(Date().timeIntervalSince(started) * 1_000)) exit=\(rc)"
            )
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DBEngineError.queryFailed(trimmed.isEmpty ? String(localized: "命令以退出码 \(rc) 失败。") : trimmed)
        }
        let parseStarted = Date()
        var rs: DBResultSet
        switch dialect {
        case .mysql: rs = Self.parseMySQL(out, hasHeader: header)
        case .postgres: rs = Self.parsePostgres(out, hasHeader: header)
        }
        rs.elapsed = Date().timeIntervalSince(started)
        rs.transportElapsed = result.duration
        rs.parseElapsed = Date().timeIntervalSince(parseStarted)
        rs.responseBytes = result.stdout.utf8.count
        Self.performanceLogger.notice(
            "OPSDECK_DB_PERF phase=query trace=\(traceID, privacy: .public) operation=\(operation, privacy: .public) dialect=\(dialect.rawValue, privacy: .public) total_ms=\(Int(rs.elapsed * 1_000)) transport_ms=\(Int(rs.transportElapsed * 1_000)) parse_ms=\(Int(rs.parseElapsed * 1_000)) bytes=\(rs.responseBytes) rows=\(rs.rows.count) columns=\(rs.columns.count)"
        )
        return rs
    }

    private static func operationName(_ sql: String) -> String {
        let firstToken = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { !$0.isWhitespace && $0 != ";" }
            .uppercased()
        let allowed = ["SELECT", "SHOW", "WITH", "EXPLAIN", "INSERT", "UPDATE", "DELETE", "START", "BEGIN", "SET"]
        return allowed.contains(firstToken) ? firstToken : "OTHER"
    }

    // MARK: Script builders

    /// - Note: `header == false` uses `--skip-column-names` so the caller-known
    ///   shape is preserved; `true` keeps the header row for the SQL runner/grid.
    func mysqlScript(sql: String, database: String?, credential: DBCredential?, adminSudo: String, header: Bool) -> String {
        let flags = header ? "--batch" : "--batch --skip-column-names"
        let dbArg = database.map { " -D " + OpsShell.quote($0) } ?? ""
        let sqlArg = " -e " + OpsShell.quote(sql)
        let sentinel = "printf '%s%s\\n' \(OpsShell.quote(Self.rcSentinel)) \"$RC\""
        if let c = credential, !c.isEmpty {
            let port = c.port ?? DBDialect.mysql.defaultPort
            let lines = ["[client]", "user=\(myCnfValue(c.username))", "password=\(myCnfValue(c.password))", "host=\(myCnfValue(c.host))", "port=\(port)"]
            let printfArgs = lines.map(OpsShell.quote).joined(separator: " ")
            return """
            CF="$(mktemp 2>/dev/null || echo "/tmp/opsdeck-$$.cnf")"
            chmod 600 "$CF" 2>/dev/null
            printf '%s\\n' \(printfArgs) > "$CF"
            mysql --defaults-extra-file="$CF" \(flags)\(dbArg)\(sqlArg) 2>&1
            RC=$?
            rm -f "$CF"
            \(sentinel)
            """
        }
        return """
        \(adminSudo)mysql \(flags)\(dbArg)\(sqlArg) 2>&1
        RC=$?
        \(sentinel)
        """
    }

    func postgresScript(sql: String, database: String?, credential: DBCredential?, adminSudo: String, header: Bool) -> String {
        let tuplesOnly = header ? "" : " -t"
        let common = " -v ON_ERROR_STOP=1 -A -F \(OpsShell.quote(Self.fieldSep)) -R \(OpsShell.quote(Self.recordSep)) -P null=\(OpsShell.quote(Self.nullToken)) -P footer=off --no-psqlrc\(tuplesOnly)"
        let sqlArg = " -c " + OpsShell.quote(sql)
        let sentinel = "printf '%s%s\\n' \(OpsShell.quote(Self.rcSentinel)) \"$RC\""
        if let c = credential, !c.isEmpty {
            let port = c.port ?? DBDialect.postgres.defaultPort
            let dbArg = " -d " + OpsShell.quote(database ?? "postgres")
            return """
            PGPASSWORD=\(OpsShell.quote(c.password)) psql\(common) -h \(OpsShell.quote(c.host)) -p \(port) -U \(OpsShell.quote(c.username))\(dbArg)\(sqlArg) 2>&1
            RC=$?
            \(sentinel)
            """
        }
        // Admin/peer auth as the postgres OS user (mirrors backupPlan). Even as
        // root we go through `sudo -u postgres` to land on the postgres role.
        let sudoWord = adminSudo.isEmpty ? "sudo " : adminSudo
        let dbArg = " -d " + OpsShell.quote(database ?? "postgres")
        return """
        \(sudoWord)-u postgres psql\(common) -U postgres\(dbArg)\(sqlArg) 2>&1
        RC=$?
        \(sentinel)
        """
    }

    // MARK: Parsing

    /// Split the `__OPSDECK_RC__=<n>` sentinel off the tail. Robust to embedded
    /// newlines in data (searches the marker, not lines).
    static func splitSentinel(_ raw: String) -> (out: String, rc: Int) {
        guard let r = raw.range(of: rcSentinel, options: .backwards) else { return (raw, -1) }
        let after = raw[r.upperBound...]
        let digits = after.prefix { $0.isNumber || $0 == "-" }
        let rc = Int(digits) ?? -1
        var out = String(raw[..<r.lowerBound])
        if out.hasSuffix("\n") { out.removeLast() }
        return (out, rc)
    }

    /// MySQL `--batch` output: tab-separated, rows on their own lines, special
    /// chars backslash-escaped, NULL rendered as the bare token `NULL`.
    static func parseMySQL(_ out: String, hasHeader: Bool) -> DBResultSet {
        if out.isEmpty { return DBResultSet() }
        var lines = out.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return DBResultSet() }
        var columns: [String] = []
        var start = 0
        if hasHeader {
            columns = lines[0].components(separatedBy: "\t").map(unescapeMySQL)
            start = 1
        }
        var rows: [[String?]] = []
        for i in start..<lines.count {
            let fields = lines[i].components(separatedBy: "\t")
            rows.append(fields.map { $0 == "NULL" ? nil : unescapeMySQL($0) })
        }
        return DBResultSet(columns: columns, rows: rows)
    }

    /// Postgres unaligned output with control-byte field/record separators and a
    /// NULL sentinel token. No un-escaping needed (control bytes never appear in
    /// text data).
    static func parsePostgres(_ out: String, hasHeader: Bool) -> DBResultSet {
        if out.isEmpty { return DBResultSet() }
        var records = out.components(separatedBy: recordSep)
        if records.last == "" { records.removeLast() }
        guard !records.isEmpty else { return DBResultSet() }
        var columns: [String] = []
        var start = 0
        if hasHeader {
            columns = records[0].components(separatedBy: fieldSep).map { $0 == nullToken ? "" : $0 }
            start = 1
        }
        var rows: [[String?]] = []
        for i in start..<records.count {
            let fields = records[i].components(separatedBy: fieldSep)
            rows.append(fields.map { $0 == nullToken ? nil : $0 })
        }
        return DBResultSet(columns: columns, rows: rows)
    }

    static func unescapeMySQL(_ field: String) -> String {
        guard field.contains("\\") else { return field }
        var result = ""
        var iterator = field.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\", let next = iterator.next() {
                switch next {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\\": result.append("\\")
                default: result.append(next)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    // MARK: Write SQL builders (P2)
    //
    // Pure, unit-testable statement construction. Every value is a quoted literal
    // (or NULL); rows are keyed on the primary key so an edit/delete can only ever
    // touch the intended row. NULL keys use `IS NULL`. The caller previews the SQL
    // before it runs.

    /// `UPDATE <table> SET <col> = <val> WHERE <pk = ...>`. `pk` is the row's
    /// primary-key column/value pairs (values as currently stored).
    func buildUpdate(dialect: DBDialect, database: String, table: String, pk: [(column: String, value: String?)], setColumn: String, value: String?, isNull: Bool) -> String {
        let ref = tableRef(dialect, database: database, table: table)
        let col = ident(dialect, setColumn)
        let val = sqlValue(dialect, value, isNull: isNull)
        return "UPDATE \(ref) SET \(col) = \(val) WHERE \(pkCondition(dialect, pk))"
    }

    /// `INSERT INTO <table> (cols) VALUES (vals)`. Only non-default fields are
    /// included, so the DB applies its own defaults / auto-increment.
    func buildInsert(dialect: DBDialect, database: String, table: String, fields: [DBInsertField]) -> String {
        let ref = tableRef(dialect, database: database, table: table)
        let used = fields.filter { !$0.useDefault }
        guard !used.isEmpty else {
            // All defaults: dialect-specific "insert a fully-default row".
            return dialect == .mysql ? "INSERT INTO \(ref) () VALUES ()" : "INSERT INTO \(ref) DEFAULT VALUES"
        }
        let cols = used.map { ident(dialect, $0.column) }.joined(separator: ", ")
        let vals = used.map { sqlValue(dialect, $0.text, isNull: $0.isNull) }.joined(separator: ", ")
        return "INSERT INTO \(ref) (\(cols)) VALUES (\(vals))"
    }

    /// `DELETE FROM <table> WHERE (row1 pk) OR (row2 pk) ...`. Each element is one
    /// row's primary-key pairs.
    func buildDelete(dialect: DBDialect, database: String, table: String, rows: [[(column: String, value: String?)]]) -> String {
        let ref = tableRef(dialect, database: database, table: table)
        let clauses = rows.map { "(\(pkCondition(dialect, $0)))" }.joined(separator: " OR ")
        return "DELETE FROM \(ref) WHERE \(clauses)"
    }

    private func tableRef(_ dialect: DBDialect, database: String, table: String) -> String {
        switch dialect {
        case .mysql: return "\(idMySQL(database)).\(idMySQL(table))"
        case .postgres: return idPG(table)
        }
    }

    private func ident(_ dialect: DBDialect, _ name: String) -> String {
        dialect == .mysql ? idMySQL(name) : idPG(name)
    }

    private func pkCondition(_ dialect: DBDialect, _ pk: [(column: String, value: String?)]) -> String {
        pk.map { pair in
            if let v = pair.value {
                return "\(ident(dialect, pair.column)) = \(sqlValue(dialect, v, isNull: false))"
            } else {
                return "\(ident(dialect, pair.column)) IS NULL"
            }
        }.joined(separator: " AND ")
    }

    private func filterPredicate(_ dialect: DBDialect, _ filter: DBFilter) -> String {
        let column = ident(dialect, filter.column)
        switch filter.operation {
        case .contains:
            let escaped = escapeLike(filter.value)
            let value = sqlValue(dialect, "%\(escaped)%", isNull: false)
            if dialect == .mysql {
                return "CAST(\(column) AS CHAR) LIKE \(value) ESCAPE '\\\\'"
            }
            return "CAST(\(column) AS TEXT) ILIKE \(value) ESCAPE E'\\\\'"
        case .equals:
            return "\(column) = \(sqlValue(dialect, filter.value, isNull: false))"
        case .notEquals:
            return "\(column) <> \(sqlValue(dialect, filter.value, isNull: false))"
        case .greaterThan:
            return "\(column) > \(sqlValue(dialect, filter.value, isNull: false))"
        case .lessThan:
            return "\(column) < \(sqlValue(dialect, filter.value, isNull: false))"
        case .isNull:
            return "\(column) IS NULL"
        case .isNotNull:
            return "\(column) IS NOT NULL"
        }
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private enum IdentifierLimit {
        case characters(Int)
        case utf8Bytes(Int)
    }

    private func validateIdentifier(_ value: String, label: String, limit: IdentifierLimit) throws {
        guard !value.isEmpty else {
            throw DBEngineError.invalidInput(String(localized: "\(label)不能为空。"))
        }
        switch limit {
        case .characters(let maximum):
            guard value.count <= maximum else {
                throw DBEngineError.invalidInput(String(localized: "\(label)过长，最多 \(maximum) 个字符。"))
            }
        case .utf8Bytes(let maximum):
            guard value.utf8.count <= maximum else {
                throw DBEngineError.invalidInput(String(localized: "\(label)过长，最多 \(maximum) 个 UTF-8 字节。"))
            }
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DBEngineError.invalidInput(String(localized: "\(label)不能包含控制字符。"))
        }
    }

    private func sqlValue(_ dialect: DBDialect, _ value: String?, isNull: Bool) -> String {
        if isNull || value == nil { return "NULL" }
        return dialect == .mysql ? litMySQL(value!) : litPG(value!)
    }

    // MARK: Escaping

    private func idMySQL(_ s: String) -> String { "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }
    private func idPG(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func litMySQL(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }
    private func litPG(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// MySQL option-file value: double-quoted with `\` and `"` escaped.
    private func myCnfValue(_ v: String) -> String {
        let e = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(e)\""
    }
}

enum DBCSVEncoder {
    static func encode(columns: [String], rows: [[String?]]) -> String {
        var lines = [columns.map(escape).joined(separator: ",")]
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            lines.append(columns.indices.map { index in
                guard row.indices.contains(index), let value = row[index] else { return "" }
                return escape(value)
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct DBCSVDocument: Equatable {
    var columns: [String]
    var rows: [[String]]
}

enum DBCSVDecoder {
    static func decode(_ text: String) throws -> DBCSVDocument {
        let characters = Array(text)
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        func appendRecord() {
            row.append(field)
            field = ""
            records.append(row)
            row = []
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r\n":
                    appendRecord()
                case "\r":
                    appendRecord()
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        guard !inQuotes else { throw DBCSVError.unclosedQuote }
        if !field.isEmpty || !row.isEmpty {
            appendRecord()
        }
        guard var columns = records.first, !columns.isEmpty else { throw DBCSVError.missingHeader }
        if columns[0].hasPrefix("\u{FEFF}") { columns[0].removeFirst() }
        guard columns.allSatisfy({ !$0.isEmpty }), Set(columns).count == columns.count else {
            throw DBCSVError.invalidHeader
        }
        let rows = records.dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) }
        guard rows.allSatisfy({ $0.count == columns.count }) else { throw DBCSVError.columnCount }
        return DBCSVDocument(columns: columns, rows: Array(rows))
    }
}

enum DBCSVError: LocalizedError {
    case missingHeader
    case invalidHeader
    case unclosedQuote
    case columnCount

    var errorDescription: String? {
        switch self {
        case .missingHeader: return String(localized: "CSV 缺少表头。")
        case .invalidHeader: return String(localized: "CSV 表头包含空列名或重复列名。")
        case .unclosedQuote: return String(localized: "CSV 存在未闭合的引号。")
        case .columnCount: return String(localized: "CSV 行的列数与表头不一致。")
        }
    }
}
