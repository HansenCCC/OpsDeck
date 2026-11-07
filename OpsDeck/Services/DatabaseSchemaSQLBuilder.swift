import Foundation

enum DatabaseSchemaSQLBuilderError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case invalidType
    case invalidPassword

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value): return String(localized: "名称“\(value)”不符合数据库标识符规则。")
        case .invalidType: return String(localized: "请输入有效的数据类型，例如 VARCHAR(255)、BIGINT 或 TEXT。")
        case .invalidPassword: return String(localized: "密码不能为空。")
        }
    }
}

/// Conservative SQL generation for the deliberately small DDL surface exposed
/// by the UI. Identifiers are both validated and dialect-quoted; arbitrary SQL
/// remains available in the query editor behind its normal confirmation gate.
struct DatabaseSchemaSQLBuilder {
    func createTable(dialect: DBDialect, database: String, table: String, firstColumn: String, dataType: String) throws -> String {
        let target = try tableTarget(dialect: dialect, database: database, table: table)
        let column = try identifier(firstColumn, dialect: dialect)
        let type = try safeType(dataType)
        return "CREATE TABLE \(target) (\(column) \(type) NOT NULL PRIMARY KEY);"
    }

    func dropDatabase(dialect: DBDialect, database: String) throws -> String {
        "DROP DATABASE \(try identifier(database, dialect: dialect));"
    }

    func renameTable(dialect: DBDialect, database: String, table: String, newName: String) throws -> String {
        let old = try tableTarget(dialect: dialect, database: database, table: table)
        let new = try identifier(newName, dialect: dialect)
        if dialect == .mysql {
            return "RENAME TABLE \(old) TO \(try tableTarget(dialect: dialect, database: database, table: newName));"
        }
        return "ALTER TABLE \(old) RENAME TO \(new);"
    }

    func dropTable(dialect: DBDialect, database: String, table: String) throws -> String {
        "DROP TABLE \(try tableTarget(dialect: dialect, database: database, table: table));"
    }

    func addColumn(dialect: DBDialect, database: String, table: String, column: String, dataType: String, nullable: Bool) throws -> String {
        let target = try tableTarget(dialect: dialect, database: database, table: table)
        return "ALTER TABLE \(target) ADD COLUMN \(try identifier(column, dialect: dialect)) \(try safeType(dataType))\(nullable ? "" : " NOT NULL");"
    }

    func modifyColumn(dialect: DBDialect, database: String, table: String, column: String, dataType: String, nullable: Bool) throws -> String {
        let target = try tableTarget(dialect: dialect, database: database, table: table)
        let col = try identifier(column, dialect: dialect)
        let type = try safeType(dataType)
        if dialect == .mysql {
            return "ALTER TABLE \(target) MODIFY COLUMN \(col) \(type)\(nullable ? " NULL" : " NOT NULL");"
        }
        let nullability = nullable ? "DROP NOT NULL" : "SET NOT NULL"
        return "ALTER TABLE \(target) ALTER COLUMN \(col) TYPE \(type);\nALTER TABLE \(target) ALTER COLUMN \(col) \(nullability);"
    }

    func dropColumn(dialect: DBDialect, database: String, table: String, column: String) throws -> String {
        "ALTER TABLE \(try tableTarget(dialect: dialect, database: database, table: table)) DROP COLUMN \(try identifier(column, dialect: dialect));"
    }

    func addIndex(dialect: DBDialect, database: String, table: String, index: String, columns: [String], unique: Bool) throws -> String {
        guard !columns.isEmpty else { throw DatabaseSchemaSQLBuilderError.invalidIdentifier("") }
        let fields = try columns.map { try identifier($0, dialect: dialect) }.joined(separator: ", ")
        return "CREATE \(unique ? "UNIQUE " : "")INDEX \(try identifier(index, dialect: dialect)) ON \(try tableTarget(dialect: dialect, database: database, table: table)) (\(fields));"
    }

    func dropIndex(dialect: DBDialect, database: String, table: String, index: String) throws -> String {
        let name = try identifier(index, dialect: dialect)
        if dialect == .mysql {
            return "DROP INDEX \(name) ON \(try tableTarget(dialect: dialect, database: database, table: table));"
        }
        return "DROP INDEX \(name);"
    }

    func createUser(dialect: DBDialect, username: String, host: String, password: String) throws -> (sql: String, preview: String) {
        guard !password.isEmpty else { throw DatabaseSchemaSQLBuilderError.invalidPassword }
        let redacted = "••••••••"
        if dialect == .mysql {
            let account = try mysqlAccount(username: username, host: host)
            return ("CREATE USER IF NOT EXISTS \(account) IDENTIFIED BY \(literal(password));",
                    "CREATE USER IF NOT EXISTS \(account) IDENTIFIED BY \(literal(redacted));")
        }
        let role = try identifier(username, dialect: dialect)
        return ("CREATE ROLE \(role) LOGIN PASSWORD \(literal(password));",
                "CREATE ROLE \(role) LOGIN PASSWORD \(literal(redacted));")
    }

    func changePassword(dialect: DBDialect, username: String, host: String, password: String) throws -> (sql: String, preview: String) {
        guard !password.isEmpty else { throw DatabaseSchemaSQLBuilderError.invalidPassword }
        let redacted = "••••••••"
        if dialect == .mysql {
            let account = try mysqlAccount(username: username, host: host)
            return ("ALTER USER \(account) IDENTIFIED BY \(literal(password));",
                    "ALTER USER \(account) IDENTIFIED BY \(literal(redacted));")
        }
        let role = try identifier(username, dialect: dialect)
        return ("ALTER ROLE \(role) PASSWORD \(literal(password));",
                "ALTER ROLE \(role) PASSWORD \(literal(redacted));")
    }

    func grant(dialect: DBDialect, database: String, username: String, host: String, preset: DBPrivilegePreset) throws -> String {
        let db = try identifier(database, dialect: dialect)
        if dialect == .mysql {
            let privileges: String
            switch preset {
            case .readOnly: privileges = "SELECT, SHOW VIEW"
            case .readWrite: privileges = "SELECT, INSERT, UPDATE, DELETE, SHOW VIEW"
            case .all: privileges = "ALL PRIVILEGES"
            }
            return "GRANT \(privileges) ON \(db).* TO \(try mysqlAccount(username: username, host: host));"
        }
        let role = try identifier(username, dialect: dialect)
        switch preset {
        case .readOnly:
            return "GRANT CONNECT ON DATABASE \(db) TO \(role);\nGRANT USAGE ON SCHEMA public TO \(role);\nGRANT SELECT ON ALL TABLES IN SCHEMA public TO \(role);"
        case .readWrite:
            return "GRANT CONNECT ON DATABASE \(db) TO \(role);\nGRANT USAGE ON SCHEMA public TO \(role);\nGRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \(role);\nGRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \(role);"
        case .all:
            return "GRANT ALL PRIVILEGES ON DATABASE \(db) TO \(role);\nGRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \(role);\nGRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \(role);"
        }
    }

    private func tableTarget(dialect: DBDialect, database: String, table: String) throws -> String {
        let tableName = try identifier(table, dialect: dialect)
        return dialect == .mysql ? "\(try identifier(database, dialect: dialect)).\(tableName)" : tableName
    }

    private func identifier(_ raw: String, dialect: DBDialect) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z_][A-Za-z0-9_$]{0,63}$"#, options: .regularExpression) != nil else {
            throw DatabaseSchemaSQLBuilderError.invalidIdentifier(value)
        }
        return dialect == .mysql ? "`\(value)`" : "\"\(value)\""
    }

    private func safeType(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !value.isEmpty,
              value.range(of: #"^[A-Z][A-Z0-9_ ]*(\([0-9 ,]+\))?(\[\])?$"#, options: .regularExpression) != nil else {
            throw DatabaseSchemaSQLBuilderError.invalidType
        }
        return value
    }

    private func mysqlAccount(username: String, host: String) throws -> String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
            throw DatabaseSchemaSQLBuilderError.invalidIdentifier(user)
        }
        guard accountHost.range(of: #"^[A-Za-z0-9_.:%-]{1,255}$"#, options: .regularExpression) != nil else {
            throw DatabaseSchemaSQLBuilderError.invalidIdentifier(accountHost)
        }
        return "\(literal(user))@\(literal(accountHost))"
    }

    private func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
