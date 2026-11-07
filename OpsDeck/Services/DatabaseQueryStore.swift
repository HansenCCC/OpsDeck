import Foundation

/// Small UserDefaults-backed store for local query drafts/history/favorites.
/// Keys are scoped to one SSH host and one database connection.
struct DatabaseQueryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(hostID: UUID, connectionID: String) -> DBQueryWorkspaceSnapshot {
        guard let data = defaults.data(forKey: key(hostID: hostID, connectionID: connectionID)),
              let decoded = try? JSONDecoder().decode(DBQueryWorkspaceSnapshot.self, from: data) else {
            let tab = DBQueryTab()
            return DBQueryWorkspaceSnapshot(tabs: [tab], selectedTabID: tab.id, history: [], favorites: [])
        }
        let tabs = decoded.tabs.isEmpty ? [DBQueryTab()] : decoded.tabs
        let selected = tabs.contains(where: { $0.id == decoded.selectedTabID }) ? decoded.selectedTabID : tabs.first?.id
        return DBQueryWorkspaceSnapshot(
            tabs: Array(tabs.prefix(12)),
            selectedTabID: selected,
            history: Array(decoded.history.prefix(100)),
            favorites: Array(decoded.favorites.prefix(100))
        )
    }

    func save(_ snapshot: DBQueryWorkspaceSnapshot, hostID: UUID, connectionID: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(hostID: hostID, connectionID: connectionID))
    }

    func clear(hostID: UUID, connectionID: String) {
        defaults.removeObject(forKey: key(hostID: hostID, connectionID: connectionID))
    }

    private func key(hostID: UUID, connectionID: String) -> String {
        let safeID = connectionID.data(using: .utf8)?.base64EncodedString() ?? connectionID
        return "database-query-workspace-\(hostID.uuidString)-\(safeID)"
    }
}
