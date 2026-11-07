import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let dbGridPerformanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.hansen.opsdeck",
    category: "DatabasePerformance"
)

// MARK: - Database browser (Navicat-lite workspace)
//
// Master/detail over a running database: left = tables in the selected database,
// right = tabs for Data (paged, sortable grid), Structure (columns), and a SQL
// runner. Observable state lives on `DBBrowserState` (`db`) so browser churn
// re-renders only these views; mutations go through `session`'s db* methods,
// which drive the `DatabaseQueryEngine` and its previewed, transactional writes.

/// A cell the user is editing (drives the edit sheet).
struct DBEditingCell: Identifiable, Equatable {
    var id: String { "\(rowIndex)#\(column)" }
    var rowIndex: Int
    var column: String
    var currentValue: String?
}

private struct DBConnectionEditorContext: Identifiable {
    let id = UUID()
    var profile: DBConnectionProfile?
}

enum DBSchemaAction: Identifiable, Equatable {
    case createTable(database: String)
    case dropDatabase(String)
    case renameTable(database: String, table: String)
    case dropTable(database: String, table: String)
    case addColumn
    case modifyColumn(DBColumnInfo)
    case dropColumn(DBColumnInfo)
    case addIndex
    case dropIndex

    var id: String {
        switch self {
        case .createTable(let database): return "create-table-\(database)"
        case .dropDatabase(let database): return "drop-db-\(database)"
        case .renameTable(let database, let table): return "rename-\(database)-\(table)"
        case .dropTable(let database, let table): return "drop-table-\(database)-\(table)"
        case .addColumn: return "add-column"
        case .modifyColumn(let column): return "modify-column-\(column.name)"
        case .dropColumn(let column): return "drop-column-\(column.name)"
        case .addIndex: return "add-index"
        case .dropIndex: return "drop-index"
        }
    }
}

struct DatabaseBrowserView: View {
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState
    @State private var editingCell: DBEditingCell?
    @State private var navigatorSearchText = ""
    @State private var exportError: String?
    @State private var connectionEditorContext: DBConnectionEditorContext?
    @State private var connectionToDelete: DBConnectionProfile?
    @State private var navigatorExpansion = DBNavigatorExpansionState()
    @State private var navigatorWidth: CGFloat = {
        if ProcessInfo.processInfo.environment["OPSDECK_SCREENSHOT_MODE"] == "1" { return 240 }
        let saved = UserDefaults.standard.double(forKey: "database-navigator-width")
        return min(420, max(190, saved > 0 ? saved : 240))
    }()
    @State private var navigatorDragStartWidth: CGFloat?
    @AppStorage("database-navigator-visible") private var navigatorVisible = true
    @AppStorage("database-show-system-databases") private var showsSystemDatabases = false
    @State private var schemaAction: DBSchemaAction?
    @State private var showsUserManagement = false
    // Filter text is view-local so typing doesn't broadcast a session-wide
    // objectWillChange; it is committed to the session only on "apply".
    @State private var filterValue = ""
    @FocusState private var filterIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            if let error = db.dbError, !db.dbShowCredentialSheet {
                dbErrorBanner(error)
            }
            if let exportError {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Color.warning)
                    Text(exportError).font(Theme.Font.caption).foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    Button { self.exportError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help(String(localized: "关闭错误提示"))
                        .accessibilityLabel(String(localized: "关闭错误提示"))
                }
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.warning.opacity(0.10)))
            }
            HStack(spacing: 0) {
                if navigatorVisible {
                    databaseNavigator
                        .frame(width: navigatorWidth)
                    navigatorDivider
                }
                detail
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.surface)
        .sheet(isPresented: $db.dbShowCredentialSheet) {
            DBCredentialSheet(
                dialect: dialect,
                initial: db.dbCredential,
                allowsAdminConnection: db.dbSelectedConnection?.source == .detected
            ) { cred in
                session.dbApplyCredential(cred)
            } onCancel: {
                db.dbShowCredentialSheet = false
            }
            .environmentObject(session)
            .environmentObject(db)
        }
        .sheet(isPresented: $db.dbShowInsertSheet) {
            DBInsertSheet(fields: session.dbInsertFields()) { fields in
                session.dbRequestInsert(fields)
            } onCancel: {
                db.dbShowInsertSheet = false
            }
            .environmentObject(session)
            .environmentObject(db)
        }
        .sheet(item: $editingCell) { cell in
            DBCellEditSheet(cell: cell) { newValue, isNull in
                session.dbRequestUpdateCell(rowIndex: cell.rowIndex, column: cell.column, newValue: newValue, isNull: isNull)
                editingCell = nil
            } onCancel: {
                editingCell = nil
            }
        }
        .sheet(item: $db.dbPendingWrite) { req in
            DBWriteConfirmSheet(request: req,
                                onConfirm: { session.dbConfirmPendingWrite() },
                                onCancel: { session.dbCancelPendingWrite() })
            .environmentObject(session)
            .environmentObject(db)
        }
        .sheet(item: $connectionEditorContext) { context in
            DBConnectionEditorSheet(
                profile: context.profile,
                initialCredential: context.profile.flatMap { session.dbStoredCredential(for: $0) }
            )
            .environmentObject(session)
            .environmentObject(db)
        }
        .sheet(isPresented: $db.dbShowCreateDatabaseSheet) {
            DBCreateDatabaseSheet()
                .environmentObject(session)
                .environmentObject(db)
        }
        .sheet(item: $schemaAction) { action in
            DBSchemaActionSheet(action: action)
                .environmentObject(session)
                .environmentObject(db)
        }
        .sheet(isPresented: $showsUserManagement) {
            DBUserManagementSheet()
                .environmentObject(session)
                .environmentObject(db)
        }
        .alert(
            String(localized: "删除数据库连接？"),
            isPresented: Binding(
                get: { connectionToDelete != nil },
                set: { if !$0 { connectionToDelete = nil } }
            ),
            presenting: connectionToDelete
        ) { profile in
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "删除"), role: .destructive) {
                session.dbDeleteConnection(profile)
                connectionToDelete = nil
            }
        } message: { profile in
            Text(String(localized: "将从本机删除连接“\(profile.name)”及其 Keychain 密码，不会删除服务器上的数据库。"))
        }
        .onAppear {
            syncNavigatorExpansion()
        }
        .onChange(of: db.dbSelectedConnectionID) { _, connectionID in
            guard let connectionID else { return }
            navigatorExpansion.activateConnection(connectionID)
        }
        .onChange(of: db.dbSelectedDatabase) { _, database in
            guard let connectionID = db.dbSelectedConnectionID, let database else { return }
            navigatorExpansion.activateDatabase(connectionID: connectionID, database: database)
        }
        .onChange(of: db.dbConnections.map(\.id)) { _, connectionIDs in
            navigatorExpansion.retainConnections(Set(connectionIDs))
        }
    }

    private var dialect: DBDialect { db.dbSelectedConnection?.dialect ?? .mysql }

    private var navigatorDivider: some View {
        Rectangle()
            .fill(Theme.Color.separator.opacity(0.65))
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = navigatorDragStartWidth ?? navigatorWidth
                        if navigatorDragStartWidth == nil { navigatorDragStartWidth = start }
                        navigatorWidth = min(420, max(190, start + value.translation.width))
                    }
                    .onEnded { _ in
                        navigatorDragStartWidth = nil
                        UserDefaults.standard.set(Double(navigatorWidth), forKey: "database-navigator-width")
                    }
            )
            .onTapGesture(count: 2) {
                navigatorWidth = 240
                UserDefaults.standard.set(240.0, forKey: "database-navigator-width")
            }
            .accessibilityLabel(String(localized: "调整数据库导航宽度"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: navigatorWidth = min(420, navigatorWidth + 20)
                case .decrement: navigatorWidth = max(190, navigatorWidth - 20)
                @unknown default: break
                }
                UserDefaults.standard.set(Double(navigatorWidth), forKey: "database-navigator-width")
            }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            fullHeader
            compactHeader
        }
    }

    private var fullHeader: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                session.closeDatabaseBrowser()
            } label: {
                Label(String(localized: "关闭"), systemImage: "xmark")
            }
            .controlSize(.small)
            .help(String(localized: "关闭数据库窗口"))

            Button {
                navigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .controlSize(.small)
            .help(navigatorVisible ? String(localized: "隐藏数据库导航") : String(localized: "显示数据库导航"))
            .accessibilityLabel(navigatorVisible ? String(localized: "隐藏数据库导航") : String(localized: "显示数据库导航"))

            if let connection = db.dbSelectedConnection {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(Theme.Color.accent)
                Text(connection.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(connection.endpoint)
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.Color.textTertiary)
                if let database = db.dbSelectedDatabase {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text(database)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                    if let table = db.dbSelectedTable {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Color.textTertiary)
                        Text(table)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            if db.dbNavigatorIsLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()

            Menu {
                Button {
                    if let database = db.dbSelectedDatabase {
                        schemaAction = .createTable(database: database)
                    }
                } label: {
                    Label(String(localized: "创建表…"), systemImage: "tablecells.badge.ellipsis")
                }
                .disabled(db.dbSelectedDatabase == nil)
                Button {
                    showsUserManagement = true
                } label: {
                    Label(String(localized: "用户与权限…"), systemImage: "person.badge.key")
                }
                .disabled(db.dbSelectedConnection == nil)
            } label: {
                Label(String(localized: "管理"), systemImage: "ellipsis.circle")
            }
            .controlSize(.small)

            Button {
                db.dbShowCredentialSheet = true
            } label: {
                Label(db.dbCredential == nil ? String(localized: "登录凭证") : String(localized: "已设凭证"),
                      systemImage: db.dbCredential == nil ? "key" : "key.fill")
            }
            .controlSize(.small)
            .help(String(localized: "为浏览器设置数据库账号/密码；留空则用服务器管理员(socket)连接"))
            .disabled(db.dbNavigatorIsLoading || !db.dbStagedChanges.isEmpty)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: Theme.Space.xs) {
            Button { session.closeDatabaseBrowser() } label: {
                Image(systemName: "xmark")
            }
            .help(String(localized: "关闭数据库窗口"))
            .accessibilityLabel(String(localized: "关闭数据库窗口"))

            Button { navigatorVisible.toggle() } label: {
                Image(systemName: "sidebar.leading")
            }
            .help(navigatorVisible ? String(localized: "隐藏数据库导航") : String(localized: "显示数据库导航"))
            .accessibilityLabel(navigatorVisible ? String(localized: "隐藏数据库导航") : String(localized: "显示数据库导航"))

            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(Theme.Color.accent)
            Text(db.dbSelectedTable ?? db.dbSelectedDatabase ?? db.dbSelectedConnection?.name ?? String(localized: "数据库"))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            if db.dbNavigatorIsLoading { ProgressView().controlSize(.small) }
            Spacer(minLength: Theme.Space.xs)

            Menu {
                Button(String(localized: "创建表…")) {
                    if let database = db.dbSelectedDatabase { schemaAction = .createTable(database: database) }
                }
                .disabled(db.dbSelectedDatabase == nil)
                Button(String(localized: "用户与权限…")) { showsUserManagement = true }
                    .disabled(db.dbSelectedConnection == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help(String(localized: "数据库管理"))
            .accessibilityLabel(String(localized: "数据库管理"))

            Button { db.dbShowCredentialSheet = true } label: {
                Image(systemName: db.dbCredential == nil ? "key" : "key.fill")
            }
            .help(String(localized: "数据库登录凭证"))
            .accessibilityLabel(String(localized: "数据库登录凭证"))
            .disabled(db.dbNavigatorIsLoading || !db.dbStagedChanges.isEmpty)
        }
        .controlSize(.small)
    }

    // MARK: Database navigator

    private var databaseNavigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "数据库导航"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Menu {
                    Button {
                        connectionEditorContext = DBConnectionEditorContext(profile: nil)
                    } label: {
                        Label(String(localized: "添加数据库连接"), systemImage: "link.badge.plus")
                    }
                    Button {
                        db.dbShowCreateDatabaseSheet = true
                    } label: {
                        Label(String(localized: "创建数据库"), systemImage: "plus.circle")
                    }
                    .disabled(db.dbSelectedConnection == nil || db.dbNavigatorIsLoading)
                    Divider()
                    Toggle(String(localized: "显示系统数据库"), isOn: $showsSystemDatabases)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(String(localized: "数据库操作"))
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 32)
            Divider().overlay(Theme.Color.separator.opacity(0.45))

            TextField(String(localized: "搜索连接、数据库或表"), text: $navigatorSearchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(Theme.Space.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredConnections) { connection in
                        connectionNode(connection)
                    }
                    if db.dbConnections.isEmpty {
                        navigatorMessage(
                            db.dbNavigatorIsLoading ? String(localized: "正在连接…") : String(localized: "没有数据库连接")
                        )
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.surfaceRaised)
    }

    private var filteredConnections: [DBConnectionProfile] {
        let query = navigatorSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return db.dbConnections }
        return db.dbConnections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(query)
                || connection.endpoint.localizedCaseInsensitiveContains(query)
                || databases(for: connection).contains { database in
                    database.localizedCaseInsensitiveContains(query)
                        || tables(for: database, connection: connection).contains {
                            $0.name.localizedCaseInsensitiveContains(query)
                        }
                }
        }
    }

    @ViewBuilder
    private func connectionNode(_ connection: DBConnectionProfile) -> some View {
        let selected = db.dbSelectedConnectionID == connection.id
        let expanded = navigatorExpansion.isConnectionExpanded(connection.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    toggleConnectionDisclosure(connection)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(width: 24, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? String(localized: "收起数据库服务") : String(localized: "展开数据库服务"))

                Button {
                    activateConnection(connection)
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.caption)
                            .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(connection.name)
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.Color.textPrimary)
                                .lineLimit(1)
                            Text(connection.endpoint)
                                .font(Theme.Font.tiny.monospacedDigit())
                                .foregroundStyle(Theme.Color.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if connection.source == .manual {
                            Text(String(localized: "已保存"))
                                .font(Theme.Font.tiny)
                                .foregroundStyle(Theme.Color.textTertiary)
                        }
                    }
                    .padding(.trailing, Theme.Space.xs)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, Theme.Space.xs)
            .background(selected ? Theme.Color.accent.opacity(0.10) : .clear)
            .contextMenu {
                if connection.source == .manual {
                    Button(String(localized: "编辑连接…")) {
                        connectionEditorContext = DBConnectionEditorContext(profile: connection)
                    }
                    Button(String(localized: "删除连接…"), role: .destructive) {
                        connectionToDelete = connection
                    }
                } else {
                    Button(String(localized: "设置登录凭证…")) {
                        db.dbShowCredentialSheet = true
                    }
                }
                if selected {
                    Divider()
                    Button(String(localized: "创建数据库…")) {
                        db.dbShowCreateDatabaseSheet = true
                    }
                }
            }

            if expanded {
                let visible = visibleDatabases(for: connection)
                if selected && db.dbNavigatorIsLoading && databases(for: connection).isEmpty {
                    navigatorMessage(String(localized: "正在读取数据库…"))
                } else if visible.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        navigatorMessage(
                            navigatorSearchText.isEmpty ? String(localized: "此连接没有可显示的数据库") : String(localized: "没有匹配的数据库或表")
                        )
                        if navigatorSearchText.isEmpty && selected {
                            Button(String(localized: "创建数据库")) {
                                db.dbShowCreateDatabaseSheet = true
                            }
                            .controlSize(.small)
                            .padding(.leading, 38)
                        }
                    }
                } else {
                    ForEach(visible, id: \.self) { database in
                        databaseNode(database, connection: connection)
                    }
                }
            }
        }
    }

    private func databases(for connection: DBConnectionProfile) -> [String] {
        if connection.id == db.dbSelectedConnectionID {
            if !db.dbDatabases.isEmpty || !db.dbNavigatorIsLoading {
                return db.dbDatabases
            }
        }
        return db.dbNavigatorSnapshots[connection.id]?.databases ?? []
    }

    private func selectedDatabase(for connection: DBConnectionProfile) -> String? {
        if connection.id == db.dbSelectedConnectionID {
            if db.dbSelectedDatabase != nil || !db.dbNavigatorIsLoading {
                return db.dbSelectedDatabase
            }
        }
        return db.dbNavigatorSnapshots[connection.id]?.selectedDatabase
    }

    private func tables(for database: String, connection: DBConnectionProfile) -> [DBTableInfo] {
        if connection.id == db.dbSelectedConnectionID {
            if db.dbSelectedDatabase == database,
               !db.dbTables.isEmpty || !db.dbNavigatorIsLoading {
                return db.dbTables
            }
            if let cached = db.dbTableCache[database] {
                return cached
            }
        }
        return db.dbNavigatorSnapshots[connection.id]?.tablesByDatabase[database] ?? []
    }

    private func visibleDatabases(for connection: DBConnectionProfile) -> [String] {
        let query = navigatorSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDatabase = selectedDatabase(for: connection)
        return databases(for: connection).filter { database in
            let visibleByKind = showsSystemDatabases
                || !connection.dialect.systemDatabases.contains(database)
                || database == selectedDatabase
            guard visibleByKind else { return false }
            guard !query.isEmpty else { return true }
            return database.localizedCaseInsensitiveContains(query)
                || tables(for: database, connection: connection).contains {
                    $0.name.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private func filteredTables(for database: String, connection: DBConnectionProfile) -> [DBTableInfo] {
        let source = tables(for: database, connection: connection)
        let query = navigatorSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func databaseNode(_ database: String, connection: DBConnectionProfile) -> some View {
        let selected = db.dbSelectedConnectionID == connection.id && db.dbSelectedDatabase == database
        let expanded = navigatorExpansion.isDatabaseExpanded(connectionID: connection.id, database: database)
        let visibleTables = filteredTables(for: database, connection: connection)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    toggleDatabaseDisclosure(database, connection: connection)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(width: 24, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? String(localized: "收起数据库服务") : String(localized: "展开数据库服务"))

                Button {
                    activateDatabase(database, connection: connection)
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "cylinder")
                            .font(.caption)
                            .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textTertiary)
                        Text(database)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Color.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !(selected && db.dbNavigatorIsLoading) {
                            Text("\(tables(for: database, connection: connection).count)")
                                .font(Theme.Font.tiny.monospacedDigit())
                                .foregroundStyle(Theme.Color.textTertiary)
                        }
                    }
                    .padding(.trailing, Theme.Space.xs)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 24)
            .background(selected ? Theme.Color.rowHover : .clear)
            .contextMenu {
                if selected {
                    Button(String(localized: "创建表…")) {
                        schemaAction = .createTable(database: database)
                    }
                    Button(String(localized: "用户与权限…")) { showsUserManagement = true }
                    Divider()
                    Button(String(localized: "删除数据库…"), role: .destructive) {
                        schemaAction = .dropDatabase(database)
                    }
                }
                Button(String(localized: "刷新")) {
                    navigatorExpansion.activateDatabase(connectionID: connection.id, database: database)
                    session.dbSelectConnection(connection.id, preferredDatabase: database)
                    if selected {
                        session.dbLoadDatabases(preferredDatabase: database)
                    }
                }
            }

            if expanded {
                if selected && db.dbNavigatorIsLoading && tables(for: database, connection: connection).isEmpty {
                    navigatorMessage(String(localized: "正在读取表…"), leading: 58)
                } else if visibleTables.isEmpty {
                    navigatorMessage(
                        navigatorSearchText.isEmpty ? String(localized: "此库没有表") : String(localized: "没有匹配的表"),
                        leading: 58
                    )
                } else {
                    ForEach(visibleTables) { table in
                        tableRow(table, database: database, connection: connection)
                    }
                }
            }
        }
    }

    private func tableRow(
        _ table: DBTableInfo,
        database: String,
        connection: DBConnectionProfile
    ) -> some View {
        let selected = db.dbSelectedConnectionID == connection.id
            && db.dbSelectedDatabase == database
            && db.dbSelectedTable == table.name
        return Button {
            activateTable(table, database: database, connection: connection)
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "tablecells")
                    .font(.caption)
                    .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    if let rows = table.estimatedRows {
                        Text(String(localized: "≈\(rows) 行"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 58)
            .padding(.trailing, Theme.Space.xs)
            .frame(height: 34)
            .background(selected ? Theme.Color.accent.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "打开")) {
                activateTable(table, database: database, connection: connection)
            }
            if db.dbSelectedConnectionID == connection.id && db.dbSelectedDatabase == database {
                Divider()
                Button(String(localized: "重命名表…")) {
                    schemaAction = .renameTable(database: database, table: table.name)
                }
                Button(String(localized: "删除表…"), role: .destructive) {
                    schemaAction = .dropTable(database: database, table: table.name)
                }
            }
        }
    }

    private func activateTable(_ table: DBTableInfo, database: String, connection: DBConnectionProfile) {
        navigatorExpansion.activateDatabase(connectionID: connection.id, database: database)
        if db.dbSelectedConnectionID == connection.id, db.dbSelectedDatabase == database {
            session.dbSelectTable(table.name)
        } else {
            session.dbSelectConnection(connection.id, preferredDatabase: database, preferredTable: table.name)
        }
    }

    private func syncNavigatorExpansion() {
        guard let connectionID = db.dbSelectedConnectionID else { return }
        navigatorExpansion.activateConnection(connectionID)
        if let database = db.dbSelectedDatabase {
            navigatorExpansion.activateDatabase(connectionID: connectionID, database: database)
        }
    }

    private func activateConnection(_ connection: DBConnectionProfile) {
        navigatorExpansion.activateConnection(connection.id)
        session.dbSelectConnection(connection.id)
    }

    private func toggleConnectionDisclosure(_ connection: DBConnectionProfile) {
        let wasExpanded = navigatorExpansion.isConnectionExpanded(connection.id)
        navigatorExpansion.toggleConnection(connection.id)
        if !wasExpanded,
           connection.id != db.dbSelectedConnectionID,
           db.dbNavigatorSnapshots[connection.id] == nil {
            session.dbSelectConnection(connection.id)
        }
    }

    private func activateDatabase(_ database: String, connection: DBConnectionProfile) {
        navigatorExpansion.activateDatabase(connectionID: connection.id, database: database)
        if db.dbSelectedConnectionID == connection.id {
            if db.dbSelectedDatabase != database {
                session.dbSelectDatabase(database)
            }
        } else {
            session.dbSelectConnection(connection.id, preferredDatabase: database)
        }
    }

    private func toggleDatabaseDisclosure(_ database: String, connection: DBConnectionProfile) {
        let wasExpanded = navigatorExpansion.isDatabaseExpanded(connectionID: connection.id, database: database)
        navigatorExpansion.toggleDatabase(connectionID: connection.id, database: database)
        guard !wasExpanded else { return }
        let hasCachedTables = db.dbNavigatorSnapshots[connection.id]?.tablesByDatabase[database] != nil
            || (connection.id == db.dbSelectedConnectionID && db.dbTableCache[database] != nil)
        if !hasCachedTables {
            activateDatabase(database, connection: connection)
        }
    }

    private func navigatorMessage(_ text: String, leading: CGFloat = 12) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textTertiary)
            .padding(.leading, leading)
            .padding(.vertical, Theme.Space.xs)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Picker("", selection: $db.dbTab) {
                ForEach(DBBrowserTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            switch db.dbTab {
            case .sql:
                DBSQLRunnerView()
            case .data:
                if db.dbSelectedTable == nil { selectTableEmptyState } else { dataTab }
            case .structure:
                if db.dbSelectedTable == nil {
                    selectTableEmptyState
                } else {
                    DBStructureView(columns: db.dbColumns) { schemaAction = $0 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectTableEmptyState: some View {
        OpsEmptyState(systemImage: "tablecells",
                      title: String(localized: "选择左侧的表"),
                      detail: String(localized: "选中一张表可查看数据与结构；SQL 标签可直接查询当前数据库。"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Button { session.dbPrevPage() } label: { Image(systemName: "chevron.left") }
                    .controlSize(.small)
                    .help(String(localized: "上一页"))
                    .accessibilityLabel(String(localized: "上一页"))
                    .disabled(db.dbPage == 0 || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                Text(String(localized: "第 \(db.dbPage + 1) 页"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Button { session.dbNextPage() } label: { Image(systemName: "chevron.right") }
                    .controlSize(.small)
                    .help(String(localized: "下一页"))
                    .accessibilityLabel(String(localized: "下一页"))
                    .disabled(!db.dbRows.truncated || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                Text(String(localized: "本页 \(db.dbRows.rows.count) 行"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Picker("", selection: Binding(get: { db.dbPageSize }, set: { session.dbSetPageSize($0) })) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 68)
                .help(String(localized: "每页行数"))
                .disabled(!db.dbStagedChanges.isEmpty)
                Spacer()
                if !db.dbStagedChanges.isEmpty {
                    Text(String(localized: "\(db.dbStagedChanges.count) 处待应用"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.accent)
                    Button(String(localized: "撤销")) { session.dbDiscardStagedChanges() }
                        .controlSize(.small)
                    Button(String(localized: "应用")) { session.dbRequestApplyStagedChanges() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button { importCSV() } label: {
                        Label(String(localized: "导入 CSV"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(db.dbColumns.isEmpty || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                    Button { exportCurrentPage() } label: {
                        Label(String(localized: "导出本页 CSV"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(db.dbRows.columns.isEmpty || db.dbRowsIsLoading)
                } label: {
                    Label(String(localized: "导入/导出"), systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
                .labelStyle(.iconOnly)
                .help(String(localized: "导入/导出"))
                .accessibilityLabel(String(localized: "导入/导出"))
                Button { db.dbShowInsertSheet = true } label: {
                    Label(String(localized: "新增行"), systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(db.dbSelectedTable == nil || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                if db.dbCanEditRows {
                    Button(role: .destructive) { session.dbRequestDeleteSelected() } label: {
                        Label(String(localized: "删除选中 (\(db.dbSelectedRows.count))"), systemImage: "trash")
                    }
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
                    .help(String(localized: "删除选中 (\(db.dbSelectedRows.count))"))
                    .accessibilityLabel(String(localized: "删除选中 (\(db.dbSelectedRows.count))"))
                    .disabled(db.dbSelectedRows.isEmpty || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                }
                if db.dbRowsIsLoading {
                    Button { session.dbStopRowsLoad() } label: { Image(systemName: "stop.fill") }
                        .controlSize(.small)
                        .help(String(localized: "停止查询"))
                        .accessibilityLabel(String(localized: "停止查询"))
                } else {
                    Button { session.dbReloadRows() } label: { Image(systemName: "arrow.clockwise") }
                        .controlSize(.small)
                        .help(String(localized: "刷新"))
                        .accessibilityLabel(String(localized: "刷新数据"))
                        .disabled(!db.dbStagedChanges.isEmpty)
                }
                Menu {
                    Button(String(localized: "恢复自动列宽")) {
                        DBColumnLayoutStore.remove(layoutID: gridLayoutID)
                        db.dbColumnLayoutVersion += 1
                    }
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                }
                .controlSize(.small)
                .help(String(localized: "列显示选项"))
                .accessibilityLabel(String(localized: "列显示选项"))
            }
            filterBar
            if !db.dbCanEditRows && db.dbSelectedTable != nil && !db.dbRows.columns.isEmpty {
                Text(String(localized: "该表没有主键,不能安全地按行编辑/删除;仍可新增行或用 SQL 标签操作。"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }
            DBDataGridView(
                columns: db.dbRows.columns,
                rows: db.dbRows.rows,
                sortColumn: db.dbOrderBy,
                ascending: db.dbAscending,
                columnTypes: Dictionary(uniqueKeysWithValues: db.dbColumns.map { ($0.name, $0.dataType) }),
                layoutID: gridLayoutID,
                layoutVersion: db.dbColumnLayoutVersion,
                dataVersion: db.dbRowsVersion,
                stagedCells: Set(db.dbStagedChanges.map(\.id)),
                onSort: { session.dbSort(by: $0) },
                selection: db.dbCanEditRows ? $db.dbSelectedRows : nil,
                onEditCell: db.dbCanEditRows && !db.dbRowsIsLoading ? { rowIndex, column, value in
                    editingCell = DBEditingCell(rowIndex: rowIndex, column: column, currentValue: value)
                } : nil
            )
            .overlay {
                if db.dbRowsIsLoading && db.dbRows.columns.isEmpty {
                    ProgressView(String(localized: "正在加载数据…"))
                        .controlSize(.small)
                        .padding(Theme.Space.sm)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                }
            }
            Button("") { filterIsFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                    .accessibilityHidden(true)
            gridStatusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var gridLayoutID: String {
        [
            session.host.id.uuidString,
            db.dbSelectedConnectionID ?? "connection",
            db.dbSelectedDatabase ?? "database",
            db.dbSelectedTable ?? "table"
        ].joined(separator: "|")
    }

    private var gridStatusBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(String(localized: "\(db.dbRows.rows.count) 行 · \(db.dbRows.columns.count) 列"))
            if !db.dbSelectedRows.isEmpty {
                Text(String(localized: "已选择 \(db.dbSelectedRows.count) 行"))
            }
            Spacer()
            if db.dbRows.elapsed > 0 {
                Text(queryMetrics(db.dbRows))
            }
            if db.dbRows.truncated {
                Text(String(localized: "还有更多数据"))
            }
        }
        .font(Theme.Font.caption.monospacedDigit())
        .foregroundStyle(Theme.Color.textTertiary)
        .frame(height: 22)
    }

    private var filterBar: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(db.dbAppliedFilter == nil ? Theme.Color.textTertiary : Theme.Color.accent)
            Picker("", selection: Binding(
                get: { db.dbFilterColumn ?? db.dbRows.columns.first ?? "" },
                set: { db.dbFilterColumn = $0 })) {
                    if db.dbRows.columns.isEmpty {
                        Text("—").tag("")
                    } else {
                        ForEach(db.dbRows.columns, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                .disabled(db.dbRows.columns.isEmpty || db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
            Picker("", selection: $db.dbFilterOperation) {
                ForEach(DBFilterOperation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 92)
            .disabled(db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
            TextField(String(localized: "筛选值"), text: $filterValue)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($filterIsFocused)
                .disabled(!db.dbFilterOperation.needsValue || db.dbRows.columns.isEmpty ||
                          db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
                .onSubmit { session.dbApplyFilter(value: filterValue) }
            Button(String(localized: "应用")) { session.dbApplyFilter(value: filterValue) }
                .controlSize(.small)
                .disabled(db.dbRows.columns.isEmpty ||
                          (db.dbFilterOperation.needsValue && filterValue.isEmpty) ||
                          db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
            Button(String(localized: "清除")) {
                filterValue = ""
                session.dbClearFilter()
            }
                .controlSize(.small)
                .disabled((db.dbAppliedFilter == nil && filterValue.isEmpty) ||
                          db.dbRowsIsLoading || !db.dbStagedChanges.isEmpty)
        }
        // A new table (or database) clears any server-reset filter's local text.
        .onChange(of: db.dbSelectedTable) { filterValue = "" }
    }

    private func queryMetrics(_ result: DBResultSet) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(result.responseBytes), countStyle: .file)
        return String(format: String(localized: "%.2f 秒 · %@"), result.elapsed, bytes)
    }

    private func exportCurrentPage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(db.dbSelectedTable ?? "data").csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = DBCSVEncoder.encode(columns: db.dbRows.columns, rows: db.dbRows.rows)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= 2_000_000 else {
                exportError = String(localized: "CSV 文件超过 2 MB，请拆分后重试。")
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            session.dbRequestImportCSV(try DBCSVDecoder.decode(text))
            exportError = nil
        } catch {
            exportError = String(localized: "导入失败：\(error.localizedDescription)")
        }
    }

    private func dbErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Color.warning)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(String(localized: "设置凭证")) { db.dbShowCredentialSheet = true }
                .controlSize(.small)
        }
        .padding(Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.warning.opacity(0.10)))
    }
}

// MARK: - Data grid

private enum DBColumnLayoutStore {
    private static let prefix = "database-column-widths-"

    static func widths(layoutID: String?) -> [String: CGFloat] {
        guard let layoutID,
              let raw = UserDefaults.standard.dictionary(forKey: prefix + layoutID) else { return [:] }
        return raw.reduce(into: [:]) { result, item in
            if let number = item.value as? NSNumber {
                result[item.key] = CGFloat(number.doubleValue)
            }
        }
    }

    static func save(_ widths: [String: CGFloat], layoutID: String?) {
        guard let layoutID else { return }
        UserDefaults.standard.set(
            widths.mapValues { Double($0) },
            forKey: prefix + layoutID
        )
    }

    static func remove(layoutID: String?) {
        guard let layoutID else { return }
        UserDefaults.standard.removeObject(forKey: prefix + layoutID)
    }
}

struct DBDataGridView: View {
    let columns: [String]
    let rows: [[String?]]
    var sortColumn: String?
    var ascending: Bool
    var columnTypes: [String: String] = [:]
    var layoutID: String? = nil
    var layoutVersion: Int = 0
    var dataVersion: Int
    var stagedCells: Set<String> = []
    var onSort: ((String) -> Void)?
    var selection: Binding<Set<Int>>? = nil
    var onEditCell: ((Int, String, String?) -> Void)? = nil

    var body: some View {
        // The grid is ALWAYS in the tree; the empty state is an overlay, never a
        // structural replacement. Every table load first clears the result set
        // (columns == []), and an `if/else` here flipped the branch — destroying
        // the whole NSScrollView/NSTableView (with hundreds of cell views) and
        // rebuilding it when rows arrived. That AppKit teardown/rebuild, twice
        // per table click, was the multi-second 100%-CPU layout storm captured
        // in the burst samples (`setDocumentView:`/`_setWindow:` mid-burst).
        DBNativeDataGrid(
            columns: columns,
            rows: rows,
            sortColumn: sortColumn,
            ascending: ascending,
            columnTypes: columnTypes,
            layoutID: layoutID,
            layoutVersion: layoutVersion,
            dataVersion: dataVersion,
            stagedCells: stagedCells,
            onSort: onSort,
            selection: selection,
            onEditCell: onEditCell
        )
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .overlay {
            if columns.isEmpty {
                OpsEmptyState(systemImage: "tablecells",
                              title: String(localized: "无数据"),
                              detail: String(localized: "这张表没有可显示的行,或查询未返回列。"))
            }
        }
    }
}

/// Grid cell label. Frame-managed (no Auto Layout), so its intrinsic size is
/// meaningless — and crucially, it must NOT invalidate intrinsic size on text
/// changes. A plain NSTextField invalidates on every `stringValue` set, which
/// dirties window constraints; each dirty frame makes NSWindow's constraint
/// pass call `NSHostingView.minSize()`, which re-measures the ENTIRE SwiftUI
/// window tree (`ViewGraph.sizeThatFits`). During scrolls/loads the table
/// configures cells continuously → full-tree re-measure at display rate →
/// the sustained 100% CPU captured in the burst samples.
private final class DBCellTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func invalidateIntrinsicContentSize() {}
}

/// AppKit's table view reuses only the visible cells. The former nested
/// `VStack/HStack` materialized every cell in a page, which made a 200 × 40
/// result create thousands of SwiftUI views before the first frame appeared.
private struct DBNativeDataGrid: NSViewRepresentable {
    let columns: [String]
    let rows: [[String?]]
    var sortColumn: String?
    var ascending: Bool
    var columnTypes: [String: String]
    var layoutID: String?
    var layoutVersion: Int
    var dataVersion: Int
    var stagedCells: Set<String>
    var onSort: ((String) -> Void)?
    var selection: Binding<Set<Int>>?
    var onEditCell: ((Int, String, String?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        tableView.rowHeight = 28
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.backgroundColor = .clear
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = selection != nil
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Never auto-hide: when content size sits near the clip boundary,
        // AppKit's show-scroller → content shrinks → hide-scroller → content
        // grows cycle re-layouts every frame and pins a core.
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.tableView = tableView
        let started = DispatchTime.now().uptimeNanoseconds
        context.coordinator.syncColumns()
        context.coordinator.syncSort()
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        dbGridPerformanceLogger.notice(
            "OPSDECK_DB_PERF phase=grid-initial ui_ms=\(elapsedMilliseconds) rows=\(rows.count) columns=\(columns.count)"
        )
        return scrollView
    }

    /// Size purely from SwiftUI's proposal, NEVER from the scroll view's own
    /// fitting size. Without this override SwiftUI measures the NSScrollView,
    /// whose answer depends on its document (table) content; content changes
    /// then feed back into layout and can oscillate — the AppKit layout storm
    /// captured in the CPU-burst samples. Proposal-driven sizing cuts that
    /// feedback edge: the grid always fills whatever the layout offers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 520)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let oldParent = context.coordinator.parent
        let columnsChanged = oldParent.columns != columns
        let layoutChanged = oldParent.layoutID != layoutID || oldParent.layoutVersion != layoutVersion
        let rowsChanged = oldParent.dataVersion != dataVersion
        let stagedRowsChanged = oldParent.stagedCells != stagedCells
            || !oldParent.stagedCells.isEmpty || !stagedCells.isEmpty
        context.coordinator.parent = self
        tableView.allowsMultipleSelection = selection != nil
        if columnsChanged || layoutChanged {
            context.coordinator.syncColumns()
        }
        if columnsChanged || rowsChanged {
            let started = DispatchTime.now().uptimeNanoseconds
            let canReloadStagedRows = !columnsChanged && rowsChanged && stagedRowsChanged
                && oldParent.rows.count == rows.count
            let phase: String
            if canReloadStagedRows {
                let changedRows = context.coordinator.rowIndexes(
                    in: oldParent.stagedCells.union(stagedCells)
                )
                tableView.reloadData(
                    forRowIndexes: changedRows,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
                phase = "grid-partial-reload"
            } else {
                tableView.reloadData()
                phase = "grid-full-reload"
            }
            let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            dbGridPerformanceLogger.notice(
                "OPSDECK_DB_PERF phase=\(phase, privacy: .public) ui_ms=\(elapsedMilliseconds) rows=\(rows.count) columns=\(columns.count)"
            )
        }
        context.coordinator.syncSelection()
        context.coordinator.syncSort()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("DBNativeDataCell")
        private static let previewCharacterLimit = 2_048

        var parent: DBNativeDataGrid
        weak var tableView: NSTableView?
        private var isSyncingSelection = false
        private var isSyncingSort = false
        private var isSyncingColumns = false

        init(parent: DBNativeDataGrid) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let columnIndex = sourceColumnIndex(tableColumn),
                  parent.rows.indices.contains(row) else { return nil }
            let values = parent.rows[row]
            let value = values.indices.contains(columnIndex) ? values[columnIndex] : nil
            let cell = reusableCell(in: tableView)
            configure(cell, value: value, isStaged: parent.stagedCells.contains("\(row)#\(parent.columns[columnIndex])"))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView, let selection = parent.selection else { return }
            selection.wrappedValue = Set(tableView.selectedRowIndexes)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            parent.selection != nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncingSort,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let columnIndex = Int(key.replacingOccurrences(of: "column-", with: "")),
                  parent.columns.indices.contains(columnIndex) else { return }
            parent.onSort?(parent.columns[columnIndex])
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !isSyncingColumns, let tableView else { return }
            let widths = tableView.tableColumns.reduce(into: [String: CGFloat]()) { result, column in
                guard let index = sourceColumnIndex(column), parent.columns.indices.contains(index) else { return }
                result[parent.columns[index]] = column.width
            }
            DBColumnLayoutStore.save(widths, layoutID: parent.layoutID)
        }

        @objc func didDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            let visibleColumn = sender.clickedColumn
            guard row >= 0, visibleColumn >= 0,
                  sender.tableColumns.indices.contains(visibleColumn),
                  let column = sourceColumnIndex(sender.tableColumns[visibleColumn]),
                  parent.rows.indices.contains(row), parent.columns.indices.contains(column) else { return }
            let values = parent.rows[row]
            let value = values.indices.contains(column) ? values[column] : nil
            parent.onEditCell?(row, parent.columns[column], value)
        }

        func syncColumns() {
            guard let tableView else { return }
            isSyncingColumns = true
            defer { isSyncingColumns = false }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            let storedWidths = DBColumnLayoutStore.widths(layoutID: parent.layoutID)
            for (index, name) in parent.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("db-column-\(index)"))
                column.title = name
                column.width = storedWidths[name] ?? automaticWidth(for: index, name: name)
                column.minWidth = 80
                column.maxWidth = 600
                column.resizingMask = .userResizingMask
                if parent.onSort != nil {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: "column-\(index)", ascending: true)
                }
                tableView.addTableColumn(column)
            }
        }

        private func automaticWidth(for index: Int, name: String) -> CGFloat {
            let values = parent.rows.prefix(30).compactMap { row -> String? in
                guard row.indices.contains(index) else { return nil }
                return row[index]
            }
            return CGFloat(DBColumnWidthPolicy.initialWidth(
                name: name,
                dataType: parent.columnTypes[name],
                sampleValues: values
            ))
        }

        func syncSelection() {
            guard let tableView else { return }
            let desired = IndexSet(parent.selection?.wrappedValue.filter(parent.rows.indices.contains) ?? [])
            guard tableView.selectedRowIndexes != desired else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func syncSort() {
            guard let tableView else { return }
            let desired: [NSSortDescriptor]
            if let sortColumn = parent.sortColumn,
               let index = parent.columns.firstIndex(of: sortColumn),
               parent.onSort != nil {
                desired = [NSSortDescriptor(key: "column-\(index)", ascending: parent.ascending)]
            } else {
                desired = []
            }
            guard tableView.sortDescriptors != desired else { return }
            isSyncingSort = true
            tableView.sortDescriptors = desired
            isSyncingSort = false
        }

        func rowIndexes(in cells: Set<String>) -> IndexSet {
            IndexSet(cells.compactMap { cell in
                guard let separator = cell.firstIndex(of: "#") else { return nil }
                return Int(cell[..<separator])
            }.filter(parent.rows.indices.contains))
        }

        private func sourceColumnIndex(_ column: NSTableColumn) -> Int? {
            Int(column.identifier.rawValue.replacingOccurrences(of: "db-column-", with: ""))
        }

        private func reusableCell(in tableView: NSTableView) -> NSTableCellView {
            if let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? NSTableCellView {
                return cell
            }
            // Frame + autoresizing, NOT Auto Layout: with ~40 columns × ~20
            // visible rows, per-cell constraints put thousands of constraints
            // into the layout engine and dominated the window's layout passes.
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 168, height: 28))
            cell.identifier = Self.cellIdentifier
            cell.autoresizesSubviews = true
            let textField = DBCellTextField(labelWithString: "")
            textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            // 8pt side insets inside the 168×28 starting bounds; `.width` keeps
            // both insets as the table resizes the cell to the column width.
            textField.frame = NSRect(x: 8, y: 6, width: 152, height: 16)
            textField.autoresizingMask = [.width]
            cell.textField = textField
            cell.addSubview(textField)
            return cell
        }

        private func configure(_ cell: NSTableCellView, value: String?, isStaged: Bool) {
            guard let textField = cell.textField else { return }
            let baseFont = NSFont.monospacedSystemFont(ofSize: 11, weight: isStaged ? .semibold : .regular)
            guard let value else {
                textField.stringValue = "NULL"
                textField.textColor = isStaged ? .controlAccentColor : .tertiaryLabelColor
                textField.font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                cell.toolTip = nil
                return
            }
            let prefix = value.prefix(Self.previewCharacterLimit + 1)
            let wasTruncated = prefix.endIndex != value.endIndex
            textField.stringValue = wasTruncated
                ? String(prefix.prefix(Self.previewCharacterLimit)) + "…"
                : (value.isEmpty ? " " : value)
            textField.textColor = isStaged ? .controlAccentColor : .labelColor
            textField.font = baseFont
            cell.toolTip = wasTruncated
                ? String(localized: "内容过长，表格仅显示前 2,048 个字符。")
                : (value.count > 80 ? value : nil)
        }
    }
}

// MARK: - Structure

struct DBStructureView: View {
    let columns: [DBColumnInfo]
    let onAction: (DBSchemaAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(String(localized: "表结构"))
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Button { onAction(.addColumn) } label: {
                    Label(String(localized: "新增列"), systemImage: "plus")
                }
                Menu {
                    Button(String(localized: "新增普通/唯一索引…")) { onAction(.addIndex) }
                    Button(String(localized: "删除索引…"), role: .destructive) { onAction(.dropIndex) }
                } label: {
                    Label(String(localized: "索引"), systemImage: "list.bullet.indent")
                }
                .controlSize(.small)
            }
            if columns.isEmpty {
                OpsEmptyState(systemImage: "list.bullet.rectangle",
                              title: String(localized: "无列信息"),
                              detail: String(localized: "未能读取到该表的列定义。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(columns) { col in
                            HStack(spacing: Theme.Space.sm) {
                            Image(systemName: col.isPrimaryKey ? "key.fill" : "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(col.isPrimaryKey ? Theme.Color.warning : Theme.Color.textTertiary)
                                .frame(width: 18)
                            Text(col.name)
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text(col.dataType)
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.textSecondary)
                            Spacer()
                            if !col.nullable {
                                OpsStatusPill(text: "NOT NULL", color: Theme.Color.textTertiary)
                            }
                            if let def = col.defaultValue, !def.isEmpty {
                                Text(String(localized: "默认 \(def)"))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .lineLimit(1)
                            }
                            }
                            .padding(.horizontal, Theme.Space.md)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(String(localized: "修改列…")) { onAction(.modifyColumn(col)) }
                                Button(String(localized: "删除列…"), role: .destructive) { onAction(.dropColumn(col)) }
                            }
                            Divider().overlay(Theme.Color.separator.opacity(0.35))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SQL runner

struct DBSQLRunnerView: View {
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState

    // Editor text is view-local so keystrokes don't fire a shared object's
    // objectWillChange (which would re-render every observer).
    // It is synced to the shared state only on appear/disappear and at execute time.
    @State private var sqlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            queryToolbar
            HStack {
                Text(db.dbSelectedDatabase.map { String(localized: "当前库：\($0)") } ?? String(localized: "未选择数据库"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer()
                Button {
                    session.dbToggleFavorite(sql: sqlText)
                } label: {
                    Label(
                        isFavorite ? String(localized: "取消收藏") : String(localized: "收藏查询"),
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
                .labelStyle(.iconOnly)
                .help(isFavorite ? String(localized: "取消收藏") : String(localized: "收藏查询"))
                .accessibilityLabel(isFavorite ? String(localized: "取消收藏") : String(localized: "收藏查询"))
                .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextEditor(text: $sqlText)
                .font(Theme.Font.monoSmall)
                .frame(minHeight: 110, idealHeight: 140, maxHeight: 180)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).stroke(Theme.Color.separator.opacity(0.4)))
            HStack {
                Text(String(localized: "只读查询直接出结果；写操作会真正执行,请谨慎。"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer()
                if db.dbSQLRunning { ProgressView().controlSize(.small) }
                if db.dbSQLRunning {
                    Button { session.dbStopSQL() } label: {
                        Label(String(localized: "停止"), systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        session.dbRunSQL(sqlText)
                    } label: {
                        Label(String(localized: "执行"), systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let err = db.dbSQLError {
                Text(err)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = db.dbSQLResult {
                HStack(spacing: Theme.Space.sm) {
                    Text(String(localized: "返回 \(result.rowCount) 行"))
                    Text(String(format: String(localized: "%.2f 秒"), result.elapsed))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.responseBytes), countStyle: .file))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                if result.columns.isEmpty {
                    Text(String(localized: "执行成功,无返回结果集。"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.success)
                } else {
                    DBDataGridView(
                        columns: result.columns,
                        rows: result.rows,
                        sortColumn: nil,
                        ascending: true,
                        dataVersion: db.dbSQLResultVersion,
                        onSort: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if db.dbSQLResult == nil && db.dbSQLError == nil {
                OpsEmptyState(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "等待执行查询"),
                    detail: String(localized: "结果会填充下方可用空间；写入与结构语句会先显示 SQL 确认。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Restore any draft (switching tabs) and preserve it when leaving.
        .onAppear { sqlText = selectedTab?.sql ?? db.dbSQLText }
        .onChange(of: db.dbSelectedQueryTabID) { _, _ in
            sqlText = selectedTab?.sql ?? ""
        }
        .onDisappear { session.dbUpdateCurrentQueryDraft(sqlText) }
    }

    private var selectedTab: DBQueryTab? {
        db.dbQueryTabs.first { $0.id == db.dbSelectedQueryTabID }
    }

    private var isFavorite: Bool {
        let value = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && db.dbQueryFavorites.contains { $0.sql == value }
    }

    private var queryToolbar: some View {
        HStack(spacing: Theme.Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(db.dbQueryTabs) { tab in
                        HStack(spacing: 2) {
                            Button {
                                session.dbSelectQueryTab(tab.id, currentSQL: sqlText)
                            } label: {
                                Text(tab.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 150)
                            }
                            .buttonStyle(.plain)
                            if db.dbQueryTabs.count > 1 {
                                Button {
                                    session.dbCloseQueryTab(tab.id, currentSQL: sqlText)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "关闭查询标签"))
                            }
                        }
                        .padding(.leading, Theme.Space.xs)
                        .padding(.trailing, 2)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(tab.id == db.dbSelectedQueryTabID ? Theme.Color.accent.opacity(0.16) : Theme.Color.surfaceRaised)
                        )
                    }
                }
            }
            Button {
                session.dbNewQueryTab(currentSQL: sqlText)
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "新建查询标签"))
            .accessibilityLabel(String(localized: "新建查询标签"))
            .disabled(db.dbQueryTabs.count >= 12)

            queryMenu(title: String(localized: "历史"), systemImage: "clock.arrow.circlepath", items: db.dbQueryHistory) {
                session.dbClearQueryHistory()
            }
            queryMenu(title: String(localized: "收藏"), systemImage: "star", items: db.dbQueryFavorites) {
                session.dbClearQueryFavorites()
            }
        }
    }

    private func queryMenu(
        title: String,
        systemImage: String,
        items: [DBSavedQuery],
        onClear: @escaping () -> Void
    ) -> some View {
        Menu {
            if items.isEmpty {
                Text(String(localized: "暂无记录"))
            } else {
                ForEach(items.prefix(20)) { query in
                    Button(query.title) {
                        sqlText = query.sql
                        session.dbUseSavedQuery(query)
                    }
                }
                Divider()
                Button(String(localized: "清除全部"), role: .destructive) { onClear() }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .controlSize(.small)
    }
}

// MARK: - Basic schema management

private struct DBSchemaActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState

    let action: DBSchemaAction
    @State private var name = ""
    @State private var columnName = "id"
    @State private var dataType = "BIGINT"
    @State private var nullable = true
    @State private var indexColumns = ""
    @State private var unique = false
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label(title, systemImage: isDestructive ? "exclamationmark.triangle.fill" : "tablecells")
                .font(Theme.Font.windowTitle)
                .foregroundStyle(isDestructive ? Theme.Color.danger : Theme.Color.textPrimary)

            Form {
                switch action {
                case .createTable:
                    TextField(String(localized: "表名"), text: $name)
                    TextField(String(localized: "首列名称"), text: $columnName)
                    TextField(String(localized: "首列类型"), text: $dataType)
                case .renameTable(_, let table):
                    LabeledContent(String(localized: "当前表"), value: table)
                    TextField(String(localized: "新表名"), text: $name)
                case .addColumn:
                    TextField(String(localized: "列名"), text: $name)
                    TextField(String(localized: "数据类型"), text: $dataType)
                    Toggle(String(localized: "允许 NULL"), isOn: $nullable)
                case .modifyColumn(let column):
                    LabeledContent(String(localized: "列"), value: column.name)
                    TextField(String(localized: "数据类型"), text: $dataType)
                    Toggle(String(localized: "允许 NULL"), isOn: $nullable)
                case .addIndex:
                    TextField(String(localized: "索引名"), text: $name)
                    TextField(String(localized: "列（逗号分隔）"), text: $indexColumns)
                    Toggle(String(localized: "唯一索引"), isOn: $unique)
                case .dropIndex:
                    TextField(String(localized: "要删除的索引名"), text: $name)
                case .dropDatabase(let target), .dropTable(_, let target):
                    LabeledContent(String(localized: "目标"), value: target)
                    TextField(String(localized: "输入目标名称以确认"), text: $confirmation)
                case .dropColumn(let column):
                    LabeledContent(String(localized: "目标"), value: column.name)
                    TextField(String(localized: "输入列名以确认"), text: $confirmation)
                }
            }
            .formStyle(.grouped)

            Text(String(localized: "提交后仍会显示完整 SQL 预览；确认前不会修改服务器。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)

            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "生成 SQL")) {
                    dismiss()
                    DispatchQueue.main.async { submit() }
                }
                .buttonStyle(.borderedProminent)
                .tint(isDestructive ? Theme.Color.danger : Theme.Color.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 520)
        .onAppear { seedFields() }
    }

    private var title: String {
        switch action {
        case .createTable: return String(localized: "创建表")
        case .dropDatabase: return String(localized: "删除数据库")
        case .renameTable: return String(localized: "重命名表")
        case .dropTable: return String(localized: "删除表")
        case .addColumn: return String(localized: "新增列")
        case .modifyColumn: return String(localized: "修改列")
        case .dropColumn: return String(localized: "删除列")
        case .addIndex: return String(localized: "新增索引")
        case .dropIndex: return String(localized: "删除索引")
        }
    }

    private var isDestructive: Bool {
        switch action {
        case .dropDatabase, .dropTable, .dropColumn, .dropIndex, .modifyColumn: return true
        default: return false
        }
    }

    private var canSubmit: Bool {
        switch action {
        case .createTable:
            return !name.isEmpty && !columnName.isEmpty && !dataType.isEmpty
        case .renameTable:
            return !name.isEmpty
        case .addColumn:
            return !name.isEmpty && !dataType.isEmpty
        case .modifyColumn:
            return !dataType.isEmpty
        case .addIndex:
            return !name.isEmpty && !indexColumns.isEmpty
        case .dropIndex:
            return !name.isEmpty
        case .dropDatabase(let target), .dropTable(_, let target):
            return confirmation == target
        case .dropColumn(let column):
            return confirmation == column.name
        }
    }

    private func seedFields() {
        switch action {
        case .renameTable(_, let table): name = table
        case .modifyColumn(let column):
            dataType = column.dataType
            nullable = column.nullable
        default: break
        }
        if indexColumns.isEmpty {
            indexColumns = db.dbPrimaryKeyColumns.first ?? db.dbColumns.first?.name ?? ""
        }
    }

    private func submit() {
        switch action {
        case .createTable:
            session.dbRequestCreateTable(name: name, firstColumn: columnName, dataType: dataType)
        case .dropDatabase(let database):
            session.dbRequestDropDatabase(database)
        case .renameTable(_, let table):
            session.dbRequestRenameTable(table, to: name)
        case .dropTable(_, let table):
            session.dbRequestDropTable(table)
        case .addColumn:
            session.dbRequestAddColumn(name: name, dataType: dataType, nullable: nullable)
        case .modifyColumn(let column):
            session.dbRequestModifyColumn(name: column.name, dataType: dataType, nullable: nullable)
        case .dropColumn(let column):
            session.dbRequestDropColumn(column.name)
        case .addIndex:
            let columns = indexColumns.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            session.dbRequestAddIndex(name: name, columns: columns, unique: unique)
        case .dropIndex:
            session.dbRequestDropIndex(name)
        }
    }
}

private enum DBUserAction: String, CaseIterable, Identifiable {
    case create
    case password
    case grant

    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: return String(localized: "创建用户")
        case .password: return String(localized: "修改密码")
        case .grant: return String(localized: "授予权限")
        }
    }
}

private struct DBUserManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState

    @State private var action: DBUserAction = .create
    @State private var username = ""
    @State private var host = "localhost"
    @State private var password = ""
    @State private var privilege: DBPrivilegePreset = .readOnly

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label(String(localized: "用户与权限"), systemImage: "person.badge.key")
                .font(Theme.Font.windowTitle)
            Picker(String(localized: "操作"), selection: $action) {
                ForEach(DBUserAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Form {
                TextField(String(localized: "用户名"), text: $username)
                if db.dbSelectedConnection?.dialect == .mysql {
                    TextField(String(localized: "MySQL 主机范围"), text: $host)
                }
                if action == .create || action == .password {
                    SecureField(String(localized: "新密码"), text: $password)
                }
                if action == .grant {
                    Picker(String(localized: "数据库级权限"), selection: $privilege) {
                        ForEach(DBPrivilegePreset.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent(String(localized: "数据库"), value: db.dbSelectedDatabase ?? String(localized: "未选择"))
                }
            }
            .formStyle(.grouped)

            Text(String(localized: "仅提供常用数据库级权限。复杂角色、对象级授权和撤销请使用 SQL 标签。密码不会写入查询历史，预览中会被隐藏。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)

            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "生成 SQL")) {
                    dismiss()
                    DispatchQueue.main.async { submit() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 540)
    }

    private var canSubmit: Bool {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if db.dbSelectedConnection?.dialect == .mysql && host.isEmpty { return false }
        switch action {
        case .create, .password: return !password.isEmpty
        case .grant: return db.dbSelectedDatabase != nil
        }
    }

    private func submit() {
        switch action {
        case .create:
            session.dbRequestCreateUser(username: username, host: host, password: password)
        case .password:
            session.dbRequestChangeUserPassword(username: username, host: host, password: password)
        case .grant:
            session.dbRequestGrantUser(username: username, host: host, preset: privilege)
        }
    }
}

// MARK: - Connection editor

private struct DBConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ServerSession

    let profile: DBConnectionProfile?
    let initialCredential: DBCredential?

    @State private var profileID = UUID().uuidString
    @State private var name = ""
    @State private var dialect: DBDialect = .mysql
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(profile == nil ? String(localized: "添加数据库连接") : String(localized: "编辑数据库连接"))
                .font(Theme.Font.sectionTitle)
            Text(String(localized: "连接命令通过当前 SSH 服务器执行。地址应填写从该服务器可以访问的数据库地址，密码仅保存到本机 Keychain。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: Theme.Space.sm, verticalSpacing: Theme.Space.sm) {
                GridRow {
                    Text(String(localized: "名称")).gridColumnAlignment(.trailing)
                    TextField(String(localized: "例如：生产 MySQL"), text: $name)
                }
                GridRow {
                    Text(String(localized: "类型")).gridColumnAlignment(.trailing)
                    Picker("", selection: $dialect) {
                        ForEach(DBDialect.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(String(localized: "主机")).gridColumnAlignment(.trailing)
                    TextField("127.0.0.1", text: $host)
                }
                GridRow {
                    Text(String(localized: "端口")).gridColumnAlignment(.trailing)
                    TextField(String(dialect.defaultPort), text: $port)
                }
                GridRow {
                    Text(String(localized: "用户名")).gridColumnAlignment(.trailing)
                    TextField(dialect == .mysql ? "root" : "postgres", text: $username)
                }
                GridRow {
                    Text(String(localized: "密码")).gridColumnAlignment(.trailing)
                    SecureField("", text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)

            if let testMessage {
                Label(testMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(testSucceeded ? Theme.Color.success : Theme.Color.warning)
            }

            HStack {
                Button {
                    testConnection()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "测试连接"))
                    }
                }
                .disabled(!isValid || isTesting)
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "保存并连接")) {
                    guard let values = connectionValues else { return }
                    session.dbSaveConnection(values.profile, credential: values.credential)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isTesting)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .onAppear {
            guard let profile else { return }
            profileID = profile.id
            name = profile.name
            dialect = profile.dialect
            host = initialCredential?.host ?? profile.host
            port = String(initialCredential?.port ?? profile.port)
            username = initialCredential?.username ?? profile.username
            password = initialCredential?.password ?? ""
        }
        .onChange(of: dialect) { oldValue, newValue in
            if port.isEmpty || port == String(oldValue.defaultPort) {
                port = String(newValue.defaultPort)
            }
            testMessage = nil
        }
    }

    private var isValid: Bool { connectionValues != nil }

    private var connectionValues: (profile: DBConnectionProfile, credential: DBCredential)? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !trimmedUser.isEmpty,
              let parsedPort = Int(port), (1...65535).contains(parsedPort) else { return nil }
        let profile = DBConnectionProfile(
            id: profileID,
            name: trimmedName,
            dialect: dialect,
            host: trimmedHost,
            port: parsedPort,
            username: trimmedUser,
            source: .manual
        )
        let credential = DBCredential(
            username: trimmedUser,
            password: password,
            host: trimmedHost,
            port: parsedPort
        )
        return (profile, credential)
    }

    private func testConnection() {
        guard let values = connectionValues else { return }
        isTesting = true
        testMessage = nil
        Task {
            defer { isTesting = false }
            do {
                let count = try await session.dbTestConnection(values.profile, credential: values.credential)
                testSucceeded = true
                testMessage = String(localized: "连接成功，发现 \(count) 个数据库。")
            } catch {
                testSucceeded = false
                testMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Create database

private struct DBCreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState

    @State private var name = ""
    @State private var createsUser = false
    @State private var username = ""
    @State private var password = ""
    @State private var mysqlCharacterSet = "server-default"
    @State private var mysqlAccountHost = "localhost"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "创建数据库"))
                .font(Theme.Font.sectionTitle)
            if let connection = db.dbSelectedConnection {
                Text(String(localized: "将在 \(connection.name)（\(connection.endpoint)）上执行。"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

            Grid(alignment: .leading, horizontalSpacing: Theme.Space.sm, verticalSpacing: Theme.Space.sm) {
                GridRow {
                    Text(String(localized: "数据库名称")).gridColumnAlignment(.trailing)
                    TextField(String(localized: "数据库名称"), text: $name)
                }
                if db.dbSelectedConnection?.dialect == .mysql {
                    GridRow {
                        Text(String(localized: "字符集")).gridColumnAlignment(.trailing)
                        Picker("", selection: $mysqlCharacterSet) {
                            Text(String(localized: "服务器默认")).tag("server-default")
                            Text("utf8mb4").tag("utf8mb4")
                            Text("utf8").tag("utf8")
                        }
                        .labelsHidden()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Toggle(String(localized: "同时创建专用用户并授予此数据库全部权限"), isOn: $createsUser)
            if createsUser {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.sm, verticalSpacing: Theme.Space.sm) {
                    GridRow {
                        Text(String(localized: "用户名")).gridColumnAlignment(.trailing)
                        TextField(String(localized: "新用户名"), text: $username)
                    }
                    GridRow {
                        Text(String(localized: "密码")).gridColumnAlignment(.trailing)
                        SecureField("", text: $password)
                    }
                    if db.dbSelectedConnection?.dialect == .mysql {
                        GridRow {
                            Text(String(localized: "允许连接来源")).gridColumnAlignment(.trailing)
                            TextField("localhost", text: $mysqlAccountHost)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                if db.dbSelectedConnection?.dialect == .mysql {
                    Text(String(localized: "MySQL 用户来源默认为 localhost；远程数据库请填写当前 SSH 服务器在数据库侧的 IP 或明确的主机模式。"))
                        .font(Theme.Font.tiny)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                Text(String(localized: "创建成功后，专用用户会保存为新连接，密码仅进入本机 Keychain。"))
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

            Divider()
            Text(String(localized: "执行计划"))
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            if let plan {
                ScrollView {
                    Text(plan.previewStatements.map { $0 + ";" }.joined(separator: "\n"))
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
            } else if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(String(localized: "密码会在预览中隐藏，数据库命令按显示顺序执行。"))
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    createDatabase()
                } label: {
                    if db.dbCreateRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "创建"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan == nil || db.dbCreateRunning)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 540)
    }

    private var request: DBCreateDatabaseRequest {
        DBCreateDatabaseRequest(
            name: name,
            username: createsUser ? username : nil,
            password: createsUser ? password : nil,
            mysqlCharacterSet: mysqlCharacterSet == "server-default" ? nil : mysqlCharacterSet,
            mysqlAccountHost: createsUser && db.dbSelectedConnection?.dialect == .mysql
                ? mysqlAccountHost
                : nil
        )
    }

    private var plan: DBCreateDatabasePlan? {
        try? session.dbDatabaseCreationPlan(request)
    }

    private var validationMessage: String? {
        do {
            _ = try session.dbDatabaseCreationPlan(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func createDatabase() {
        errorMessage = nil
        Task {
            do {
                try await session.dbCreateDatabase(request)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Credential sheet

struct DBCredentialSheet: View {
    let dialect: DBDialect
    let initial: DBCredential?
    let allowsAdminConnection: Bool
    let onSave: (DBCredential?) -> Void
    let onCancel: () -> Void

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var host: String = "127.0.0.1"
    @State private var port: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "数据库登录"))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(String(localized: "填写数据库账号连接(经服务器本机)。留空则用管理员/ socket 方式连接。密码只用于连库,不会明文写入日志。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.sm, verticalSpacing: Theme.Space.sm) {
                GridRow {
                    Text(String(localized: "用户名")).gridColumnAlignment(.trailing)
                    TextField(dialect == .mysql ? "root" : "postgres", text: $username)
                }
                GridRow {
                    Text(String(localized: "密码")).gridColumnAlignment(.trailing)
                    SecureField("", text: $password)
                }
                GridRow {
                    Text(String(localized: "主机")).gridColumnAlignment(.trailing)
                    TextField("127.0.0.1", text: $host)
                }
                GridRow {
                    Text(String(localized: "端口")).gridColumnAlignment(.trailing)
                    TextField(String(dialect.defaultPort), text: $port)
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                if allowsAdminConnection {
                    Button(String(localized: "用管理员连接")) { onSave(nil) }
                        .help(String(localized: "清除凭证,改用服务器 socket/管理员方式"))
                }
                Spacer()
                Button(String(localized: "取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "连接")) {
                    var cred = DBCredential(username: username, password: password)
                    cred.host = host.isEmpty ? "127.0.0.1" : host
                    cred.port = Int(port)
                    onSave(cred.isEmpty ? nil : cred)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
        .onAppear {
            username = initial?.username ?? ""
            password = initial?.password ?? ""
            host = initial?.host ?? "127.0.0.1"
            port = initial?.port.map(String.init) ?? ""
        }
    }
}

// MARK: - Cell edit

struct DBCellEditSheet: View {
    let cell: DBEditingCell
    let onSave: (String?, Bool) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var isNull = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "编辑列 \(cell.column)"))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            Toggle(String(localized: "设为 NULL"), isOn: $isNull)
            TextEditor(text: $text)
                .font(Theme.Font.monoSmall)
                .frame(height: 100)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).stroke(Theme.Color.separator.opacity(0.4)))
                .opacity(isNull ? 0.4 : 1)
                .disabled(isNull)
            HStack {
                Spacer()
                Button(String(localized: "取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "暂存修改")) { onSave(isNull ? nil : text, isNull) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .onAppear {
            text = cell.currentValue ?? ""
            isNull = cell.currentValue == nil
        }
    }
}

// MARK: - Insert row

struct DBInsertSheet: View {
    let fields: [DBInsertField]
    let onInsert: ([DBInsertField]) -> Void
    let onCancel: () -> Void

    @State private var editFields: [DBInsertField] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "新增行"))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(String(localized: "勾选「默认」让数据库自动填(自增/默认值);勾「NULL」写空值;否则填入的文本作为值。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: Theme.Space.xs) {
                    ForEach($editFields) { $field in
                        HStack(spacing: Theme.Space.sm) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(field.column)
                                        .font(Theme.Font.bodyMedium)
                                        .foregroundStyle(Theme.Color.textPrimary)
                                    if field.isPrimaryKey {
                                        Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.Color.warning)
                                    }
                                }
                                Text(field.dataType)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Color.textTertiary)
                            }
                            .frame(width: 150, alignment: .leading)
                            TextField("", text: $field.text)
                                .textFieldStyle(.roundedBorder)
                                .font(Theme.Font.monoSmall)
                                .disabled(field.useDefault || field.isNull)
                                .opacity(field.useDefault || field.isNull ? 0.4 : 1)
                            Toggle(String(localized: "默认"), isOn: $field.useDefault)
                                .toggleStyle(.checkbox)
                            Toggle("NULL", isOn: $field.isNull)
                                .toggleStyle(.checkbox)
                                .disabled(!field.nullable)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button(String(localized: "取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "生成 SQL")) { onInsert(editFields) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 560)
        .onAppear { editFields = fields }
    }
}

// MARK: - Write confirm (shows generated SQL before it runs)

struct DBWriteConfirmSheet: View {
    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState
    let request: DBWriteRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: request.isDestructive ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .foregroundStyle(request.isDestructive ? Theme.Color.danger : Theme.Color.accent)
                Text(request.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(String(localized: "将执行以下 SQL:"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            ScrollView {
                Text(request.previewSQL ?? request.sql)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.sm)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
            if let error = db.dbWriteError {
                Text(error)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if db.dbWriteRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(db.dbWriteRunning)
                Button(request.isDestructive ? String(localized: "确认执行") : String(localized: "执行")) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(db.dbWriteRunning)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 520)
    }
}
