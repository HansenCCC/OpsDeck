import Foundation

// MARK: - Database browser state (isolated observable)
//
// All of the Navicat-lite browser's per-host state lives here, on its own
// `ObservableObject`, NOT on `ServerSession`. This isolation is deliberate and
// load-bearing: the browser mutates 6–8 published properties per table load /
// page turn, and when these lived on `ServerSession` every mutation re-evaluated
// every one of the ~60 views observing the session (sidebar, inspector, tool
// rail, …), pinning the main thread in AppKit/SwiftUI layout for seconds.
// Only the database views observe this object, so browser churn re-renders the
// browser alone. Mutation stays on `ServerSession` (`db*` methods), which owns
// the SSH context; this class is state + derived accessors only.
@MainActor
final class DBBrowserState: ObservableObject {
    /// The DB target currently open in the browser (nil = show the target list).
    @Published var dbBrowserTarget: DatabaseTarget?
    @Published var dbConnections: [DBConnectionProfile] = []
    @Published var dbSelectedConnectionID: String?
    /// In-memory credential for the selected connection; persisted only in Keychain.
    @Published var dbCredential: DBCredential?
    /// Drives the credential sheet (auth failed / user wants to change login).
    @Published var dbShowCredentialSheet = false
    @Published var dbDatabases: [String] = []
    @Published var dbSelectedDatabase: String?
    @Published var dbTables: [DBTableInfo] = []
    @Published var dbSelectedTable: String?
    @Published var dbColumns: [DBColumnInfo] = []
    @Published var dbRows = DBResultSet()
    @Published var dbPage = 0
    @Published var dbPageSize = 50
    @Published var dbOrderBy: String?
    @Published var dbAscending = true
    @Published var dbNavigatorIsLoading = false
    @Published var dbRowsIsLoading = false
    @Published var dbError: String?
    @Published var dbTab: DBBrowserTab = .data
    @Published var dbFilterColumn: String?
    @Published var dbFilterOperation: DBFilterOperation = .equals
    @Published var dbAppliedFilter: DBFilter?
    @Published var dbRowsVersion = 0
    @Published var dbSQLText = ""
    @Published var dbSQLResult: DBResultSet?
    @Published var dbSQLResultVersion = 0
    @Published var dbSQLError: String?
    @Published var dbSQLRunning = false
    @Published var dbQueryTabs: [DBQueryTab] = [DBQueryTab()]
    @Published var dbSelectedQueryTabID: UUID?
    @Published var dbQueryHistory: [DBSavedQuery] = []
    @Published var dbQueryFavorites: [DBSavedQuery] = []
    // Selection, staged edits, and the write awaiting confirmation.
    @Published var dbSelectedRows: Set<Int> = []
    @Published var dbStagedChanges: [DBStagedCellChange] = []
    @Published var dbPendingWrite: DBWriteRequest?
    @Published var dbShowInsertSheet = false
    @Published var dbWriteRunning = false
    @Published var dbWriteError: String?
    @Published var dbShowCreateDatabaseSheet = false
    @Published var dbCreateRunning = false
    @Published var dbColumnLayoutVersion = 0

    // Non-published bookkeeping (tasks, caches, pagination cursors). Internal so
    // `ServerSession`'s db* methods can drive them; not observed by any view.
    /// One foreground navigator/data read at a time. Generation checks prevent a
    /// stale response from replacing a newer database or table selection.
    var dbLoadTask: Task<Void, Never>?
    var dbLoadGeneration = 0
    var dbSQLTask: Task<Void, Never>?
    var dbSQLGeneration = 0
    var dbPageCursors: [DBPageCursor] = []
    var dbTableCache: [String: [DBTableInfo]] = [:]
    var dbColumnCache: [String: (loadedAt: Date, value: [DBColumnInfo])] = [:]
    var dbNavigatorSnapshots: [String: DBNavigatorSnapshot] = [:]
    var dbPerformanceEvents: [DBPerformanceEvent] = []

    // Derived accessors the views read.
    var dbIsLoading: Bool { dbNavigatorIsLoading || dbRowsIsLoading }
    var dbSelectedConnection: DBConnectionProfile? {
        dbConnections.first { $0.id == dbSelectedConnectionID }
    }
    /// Primary-key columns of the current table; row edits/deletes key on these.
    var dbPrimaryKeyColumns: [String] { dbColumns.filter { $0.isPrimaryKey }.map(\.name) }
    /// Rows can only be safely edited/deleted when a primary key exists.
    var dbCanEditRows: Bool { !dbPrimaryKeyColumns.isEmpty }
}
