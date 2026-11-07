import AppKit
import SwiftUI

struct HostSidebar: View {
    @EnvironmentObject private var appState: AppState
    @State private var hostPendingDelete: HostProfile?
    @State private var manuallyCollapsedHostIDs: Set<UUID> = []
    @State private var showsGroupManager = false
    @State private var sshConfigPreview: SSHConfigImportPreview?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
                .padding(.horizontal, Theme.Space.sm)

            if appState.hosts.isEmpty {
                emptyState
            } else {
                // Native List gives macOS's built-in drag-to-reorder animation
                // (rows part to make room, spring back) for free via `.onMove`
                // — no drag handles or edit mode, just drag a row.
                List(selection: selectionBinding) {
                    ForEach(groupedSections, id: \.id) { section in
                        Section {
                            let items = sidebarItems(for: section)
                            ForEach(items) { item in
                                switch item {
                                case .host(let host):
                                    HostRow(
                                        host: host,
                                        showsDatabaseDisclosure: appState.connectionState(for: host.id) == .connected,
                                        isDatabaseExpanded: isShowingDatabaseServices(for: host),
                                        onToggleDatabaseDisclosure: {
                                            toggleDatabaseServices(for: host)
                                        }
                                    )
                                        .tag(host.id)
                                        .contextMenu { hostContextMenu(host) }
                                case .databaseServices(let hostID):
                                    if let session = appState.session(for: hostID) {
                                        DatabaseServicesSidebarSection(session: session)
                                            .moveDisabled(true)
                                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 8))
                                            .listRowSeparator(.hidden)
                                            .listRowBackground(Color.clear)
                                    }
                                }
                            }
                            .onMove { from, to in
                                moveSidebarItems(items, in: section, from: from, to: to)
                            }
                        } header: {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(Theme.Font.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Color.textTertiary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            SidebarFooter()
                .padding(.horizontal, Theme.Space.sm)
                .padding(.bottom, Theme.Space.sm)
        }
        .padding(.vertical, Theme.Space.md)
        .foregroundStyle(Theme.Color.textPrimary)
        .alert("删除服务器？", isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                if let host = hostPendingDelete { appState.deleteHost(host) }
                hostPendingDelete = nil
            }
            Button("取消", role: .cancel) { hostPendingDelete = nil }
        } message: {
            Text("将删除「\(hostPendingDelete?.name ?? "")」及其保存的 SSH 凭证，此操作不可撤销。")
        }
        .alert("无法导入 SSH Config", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showsGroupManager) {
            HostGroupManagerView()
                .environmentObject(appState)
        }
        .sheet(item: $sshConfigPreview) { preview in
            SSHConfigImportView(preview: preview)
                .environmentObject(appState)
        }
        .onAppear {
            syncConnectedHosts(connectedHostIDs)
        }
        .onChange(of: connectedHostIDs) { _, newIDs in
            syncConnectedHosts(newIDs)
        }
    }

    private var connectedHostIDs: Set<UUID> {
        Set(appState.hosts.compactMap { host in
            appState.connectionState(for: host.id) == .connected ? host.id : nil
        })
    }

    private func isShowingDatabaseServices(for host: HostProfile) -> Bool {
        connectedHostIDs.contains(host.id)
            && !manuallyCollapsedHostIDs.contains(host.id)
    }

    private func syncConnectedHosts(_ newIDs: Set<UUID>) {
        // A manual collapse belongs to the current live connection only. Once a
        // host disconnects, the override is discarded so its next connection
        // expands again by default.
        manuallyCollapsedHostIDs.formIntersection(newIDs)

        for hostID in newIDs where !manuallyCollapsedHostIDs.contains(hostID) {
            loadDatabaseServicesIfNeeded(for: hostID)
        }
    }

    private func toggleDatabaseServices(for host: HostProfile) {
        guard connectedHostIDs.contains(host.id) else { return }
        if isShowingDatabaseServices(for: host) {
            _ = withAnimation(.easeOut(duration: 0.18)) {
                manuallyCollapsedHostIDs.insert(host.id)
            }
            return
        }

        _ = withAnimation(.easeOut(duration: 0.18)) {
            manuallyCollapsedHostIDs.remove(host.id)
        }
        loadDatabaseServicesIfNeeded(for: host.id)
    }

    private func loadDatabaseServicesIfNeeded(for hostID: UUID) {
        guard let session = appState.session(for: hostID),
              !session.hasLoadedDatabases,
              !session.isDatabasesLoading else { return }
        session.refreshDatabases()
    }

    private func sidebarItems(for section: HostSidebarSection) -> [HostSidebarItem] {
        section.hosts.flatMap { host in
            var items: [HostSidebarItem] = [.host(host)]
            if isShowingDatabaseServices(for: host) {
                items.append(.databaseServices(host.id))
            }
            return items
        }
    }

    private func moveSidebarItems(
        _ items: [HostSidebarItem],
        in section: HostSidebarSection,
        from source: IndexSet,
        to destination: Int
    ) {
        let hostIDs = section.hosts.map(\.id)
        let sourceHostIndexes = IndexSet(source.compactMap { itemIndex in
            guard items.indices.contains(itemIndex),
                  case .host(let host) = items[itemIndex] else { return nil }
            return hostIDs.firstIndex(of: host.id)
        })
        guard !sourceHostIndexes.isEmpty else { return }

        let clampedDestination = min(max(destination, 0), items.count)
        let destinationHostIndex = items.prefix(clampedDestination).reduce(into: 0) { count, item in
            if case .host = item { count += 1 }
        }
        appState.moveHosts(hostIDs, from: sourceHostIndexes, to: destinationHostIndex)
    }

    /// List selection drives host switching. Setting selection routes through
    /// `selectHost` so the active session swaps (and terminal focus follows).
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { appState.selectedSidebarHostID },
            set: { newID in
                guard let id = newID,
                      let host = appState.hosts.first(where: { $0.id == id }) else { return }
                appState.selectHost(host)
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { hostPendingDelete != nil },
            set: { if !$0 { hostPendingDelete = nil } }
        )
    }

    @ViewBuilder
    private func hostContextMenu(_ host: HostProfile) -> some View {
        if appState.connectionState(for: host.id) == .connected {
            Button {
                appState.disconnectHost(host)
            } label: {
                Label("断开连接", systemImage: "bolt.slash")
            }
        } else {
            Button {
                appState.connectHost(host)
            } label: {
                Label("连接", systemImage: "bolt.fill")
            }
        }
        Button {
            appState.openTerminalForHost(host)
        } label: {
            Label("打开终端", systemImage: "terminal")
        }
        .disabled(appState.connectionState(for: host.id) != .connected)
        Button {
            appState.copyHostAddress(host)
        } label: {
            Label("复制地址", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            appState.editHost(host)
        } label: {
            Label("编辑服务器", systemImage: "pencil")
        }
        Menu("移动到分组") {
            Button("未分组") { appState.assignHost(host, to: nil) }
            Divider()
            ForEach(appState.groups) { group in
                Button {
                    appState.assignHost(host, to: group.id)
                } label: {
                    if host.groupID == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
        }
        Divider()
        Button(role: .destructive) {
            hostPendingDelete = host
        } label: {
            Label("删除服务器", systemImage: "trash")
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Label("服务器", systemImage: "server.rack")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    appState.openNewHostEditor()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("添加服务器")
                .accessibilityLabel("添加服务器")

                Menu {
                    Button {
                        appState.openNewHostEditor()
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                    Button {
                        chooseSSHConfig()
                    } label: {
                        Label("导入 SSH Config…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        showsGroupManager = true
                    } label: {
                        Label("管理分组…", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
    }

    private func chooseSSHConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "选择 SSH Config")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.nameFieldStringValue = "config"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try SSHConfigImportService().parse(url: url)
            sshConfigPreview = SSHConfigImportPreview(sourcePath: url.path(percentEncoded: false), entries: entries)
        } catch {
            importError = error.localizedDescription
        }
    }

    private var emptyState: some View {
        Spacer()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupedSections: [HostSidebarSection] {
        let groupsByID = Dictionary(uniqueKeysWithValues: appState.groups.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: appState.hosts) { host in
            host.groupID
        }

        var sections: [HostSidebarSection] = []
        for group in appState.groups {
            let hosts = grouped[group.id] ?? []
            if !hosts.isEmpty {
                sections.append(HostSidebarSection(id: group.id.uuidString, title: group.name, hosts: hosts))
            }
        }

        let ungrouped = grouped[nil] ?? []
        if !ungrouped.isEmpty || sections.isEmpty {
            // When there are no named groups the top "服务器" header already labels
            // the list, so the sole section is headerless.
            let title = sections.isEmpty ? "" : String(localized: "未分组")
            sections.append(HostSidebarSection(id: "ungrouped", title: title, hosts: ungrouped))
        }

        let missingGroupHosts = appState.hosts.filter { host in
            guard let groupID = host.groupID else { return false }
            return groupsByID[groupID] == nil
        }
        if !missingGroupHosts.isEmpty {
            sections.append(HostSidebarSection(id: "missing", title: String(localized: "其他"), hosts: missingGroupHosts))
        }

        return sections
    }
}

private struct HostSidebarSection {
    var id: String
    var title: String
    var hosts: [HostProfile]
}

private enum HostSidebarItem: Identifiable {
    case host(HostProfile)
    case databaseServices(UUID)

    var id: String {
        switch self {
        case .host(let host):
            return "host-\(host.id.uuidString)"
        case .databaseServices(let hostID):
            return "databases-\(hostID.uuidString)"
        }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                appState.openNewHostEditor()
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 18)
                    Text("添加服务器")
                        .font(Theme.Font.bodyMedium)
                    Spacer()
                }
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Space.sm)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.Color.surfaceRaised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .help("添加服务器")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.Color.surfaceRaised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .help("打开设置")
            .accessibilityLabel("打开设置")
        }
    }
}

private struct HostRow: View {
    @EnvironmentObject private var appState: AppState
    let host: HostProfile
    let showsDatabaseDisclosure: Bool
    let isDatabaseExpanded: Bool
    let onToggleDatabaseDisclosure: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Space.xs)

            if showsDatabaseDisclosure {
                Button(action: onToggleDatabaseDisclosure) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .rotationEffect(.degrees(isDatabaseExpanded ? 90 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(databaseDisclosureLabel)
                .accessibilityLabel(databaseDisclosureLabel)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(Theme.Color.surfaceRaised.opacity(0.8), lineWidth: 1)
            }
    }

    private var databaseDisclosureLabel: String {
        isDatabaseExpanded
            ? String(localized: "收起数据库服务")
            : String(localized: "展开数据库服务")
    }

    // Reflects THIS host's own live connection — independent of which host is
    // selected. With multi-server support a connected host you've switched away
    // from (but not disconnected) stays green; selection only changes the row
    // highlight, not the dot.
    private var statusColor: Color {
        switch appState.connectionState(for: host.id) {
        case .connected:
            return Theme.Color.success
        case .connecting:
            return Theme.Color.warning
        case .failed:
            return Theme.Color.danger
        default:
            // Not live now: only surface a past failure as a subtle hint.
            return host.lastStatus == "failed" ? Theme.Color.danger.opacity(0.6) : Theme.Color.textTertiary.opacity(0.55)
        }
    }

    private var subtitle: String {
        if let lastConnectedAt = host.lastConnectedAt {
            return "\(host.endpoint) · \(lastConnectedAt.formatted(date: .omitted, time: .shortened))"
        }
        return host.endpoint
    }
}

private struct DatabaseServicesSidebarSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: ServerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(width: 16)
                Text("数据库")
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer(minLength: Theme.Space.xs)
                if session.isDatabasesLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if !session.databases.isEmpty {
                    Text(verbatim: "\(session.databases.count)")
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.xxs)
            .frame(height: 22)

            if session.isDatabasesLoading && session.databases.isEmpty {
                DatabaseSidebarMessageRow(
                    title: String(localized: "正在检测数据库服务"),
                    systemImage: "ellipsis"
                )
            } else if session.hasLoadedDatabases && session.databases.isEmpty {
                DatabaseSidebarMessageRow(
                    title: String(localized: "未检测到数据库服务"),
                    systemImage: "cylinder.split.1x2"
                )
            } else if !session.hasLoadedDatabases {
                Button {
                    session.refreshDatabases()
                } label: {
                    DatabaseSidebarMessageRow(
                        title: String(localized: "重新检测数据库服务"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.plain)
            } else {
                ForEach(session.databases) { database in
                    DatabaseServiceSidebarRow(database: database) {
                        open(database)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func open(_ database: DatabaseTarget) {
        if appState.selectedSidebarHostID != session.host.id {
            appState.selectHost(session.host)
        }
        session.openWorkbenchModule("database")
        guard database.serviceInstalled,
              database.activeState == "active",
              DBDialect.from(database.kind) != nil else { return }
        session.openDatabaseBrowser(database)
    }
}

private struct DatabaseServiceSidebarRow: View {
    let database: DatabaseTarget
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "cylinder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(width: 16)
                Text(verbatim: database.kind.displayName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Theme.Space.xs)
                HStack(spacing: Theme.Space.xxs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(verbatim: statusText)
                        .font(Theme.Font.tiny)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(.horizontal, Theme.Space.xxs)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isHovering ? Theme.Color.rowHover : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(database.kind.displayName + " · " + statusText)
        .accessibilityLabel(database.kind.displayName + "，" + statusText)
    }

    private var statusText: String {
        guard database.serviceInstalled else { return String(localized: "客户端") }
        switch database.activeState {
        case "active": return String(localized: "运行中")
        case "inactive": return String(localized: "已停止")
        case "failed": return String(localized: "失败")
        default: return String(localized: "未知")
        }
    }

    private var statusColor: Color {
        guard database.serviceInstalled else { return Theme.Color.textTertiary }
        switch database.activeState {
        case "active": return Theme.Color.success
        case "failed": return Theme.Color.danger
        default: return Theme.Color.warning
        }
    }
}

private struct DatabaseSidebarMessageRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .regular))
                .frame(width: 16)
            Text(verbatim: title)
                .font(Theme.Font.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Color.textTertiary)
        .padding(.horizontal, Theme.Space.xxs)
        .frame(height: 32)
        .contentShape(Rectangle())
    }
}
