import AppKit
import SwiftUI

/// Unified systemd service list (start/stop/restart/enable), now a workbench
/// module ("系统服务") in the 工具 page rather than a top-level tab — it manages
/// the same apps the other modules do, so it lives alongside them.
private struct ServicesWorkbenchPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                ServiceUnitsSection()
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
#if DEBUG
            if ScreenshotRenderer.isEnabled {
                return
            }
#endif
            guard session.connectionStatus == .connected else { return }
            if session.serviceUnits.isEmpty && !session.isServicesLoading {
                session.refreshServices()
            }
        }
    }
}

/// Nginx management, now a workbench module in the 工具 page (peer to Docker /
/// 数据库). Start/stop stays on the 服务 page; this focuses on config & sites.
private struct NginxWorkbenchPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                NginxManagerSection()
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.environment["OPSDECK_NGINX_INACTIVE_PREVIEW"] == "1" {
                return
            }
#endif
            guard session.connectionStatus == .connected else { return }
            if session.nginxSnapshot == nil && !session.isNginxLoading {
                session.refreshNginx()
            }
            if session.serviceUnits.isEmpty && !session.isServicesLoading {
                session.refreshServices()
            }
        }
    }
}

struct LogsWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            OpsWorkspaceToolbar(
                title: String(localized: "日志"),
                systemImage: "doc.text.magnifyingglass",
                isLoading: session.isLogSourcesLoading || session.isLogPreviewLoading,
                refreshAction: session.refreshLogSources
            )
            Divider().overlay(Theme.Color.separator)

            if let error = displayedOperationsError {
                OpsStatusBanner(message: error)
                Divider().overlay(Theme.Color.separator)
            }

            HStack(spacing: 0) {
                LogSourceSidebar()
                    .frame(width: 260)
                    .clipped()
                Divider().overlay(Theme.Color.separator)
                LogPreviewPane(searchText: $searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Theme.Color.surface)
        .onAppear {
#if DEBUG
            if ScreenshotRenderer.isEnabled {
                return
            }
#endif
            guard session.connectionStatus == .connected else { return }
            if session.logSources.isEmpty && !session.isLogSourcesLoading {
                session.refreshLogSources()
            }
        }
        .onDisappear { session.stopLogFollow() }
    }

    private var displayedOperationsError: String? {
#if DEBUG
        if ScreenshotRenderer.isEnabled { return nil }
#endif
        return session.operationsError
    }
}

struct ToolsWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var dismissedFailureRunID: UUID?
    @State private var moduleSearchText = ""

    private var currentModule: WorkbenchModule {
        WorkbenchRegistry.module(id: session.selectedWorkbenchModuleID)
    }

    /// The current module's most recent failed non-install operation (if not
    /// dismissed), used to show an in-context retry banner in place of the plain
    /// global error string. Install failures are shown by the pane's empty-state card.
    private var failedOperationRun: RunbookRun? {
        guard case .failed(let run) = session.moduleActivity(session.selectedWorkbenchModuleID),
              run.kind != .install,
              run.id != dismissedFailureRunID
        else { return nil }
        return run
    }

    var body: some View {
        HStack(spacing: 0) {
            moduleRail
                .frame(minWidth: 170, idealWidth: 184, maxWidth: 220)
                .background(Theme.Color.sidebarBackground)

            Divider().overlay(Theme.Color.separator)

            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.sm) {
                    Label(currentModule.title, systemImage: currentModule.systemImage)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Color.textPrimary)

                    Spacer()

                    ZStack {
                        if currentModule.isBusy(session) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 16, height: 16)

                    ToolEnvironmentSummary()
                        .frame(maxWidth: 240)

                    Button {
                        currentModule.refresh(session)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        (session.connectionStatus != .connected && currentModule.needsConnection)
                            || currentModule.isBusy(session)
                    )
                    .help("刷新")
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 44)
                .background(Theme.Color.toolbarBackground)

                Divider().overlay(Theme.Color.separator)

                if let run = failedOperationRun {
                    OpsModuleErrorBanner(
                        run: run,
                        onRetry: { session.retryRun(run) },
                        onDetails: { session.showRunDetail(run) },
                        onDismiss: {
                            dismissedFailureRunID = run.id
                            session.clearOperationsError()
                        }
                    )
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    Divider().overlay(Theme.Color.separator)
                } else if let error = displayedOperationsError {
                    OpsStatusBanner(message: error)
                    Divider().overlay(Theme.Color.separator)
                }

                if currentModule.needsConnection && session.connectionStatus != .connected {
                    WorkbenchDisconnectedPlaceholder(moduleTitle: currentModule.title)
                } else {
                    currentModule.makeView()
                }
            }
        }
        .background(Theme.Color.surface)
        .onAppear {
#if DEBUG
            guard !ScreenshotRenderer.isEnabled else { return }
#endif
            session.app.refreshToolCatalog()
            session.refreshDeploymentTemplates()
        }
        .onChange(of: session.selectedWorkbenchModuleID) { _, newID in
#if DEBUG
            guard !ScreenshotRenderer.isEnabled else { return }
#endif
            session.clearOperationsError()
            // 切到某个 module 时主动重采它的状态，避免看到上次的旧快照
            // （比如刚在安装器装完 certbot，再回到 SSL 证书应显示已安装）。
            let module = WorkbenchRegistry.module(id: newID)
            guard !module.needsConnection || session.connectionStatus == .connected else { return }
            guard !module.isBusy(session) else { return }
            module.refresh(session)
        }
    }

    private var displayedOperationsError: String? {
#if DEBUG
        if ScreenshotRenderer.isEnabled { return nil }
#endif
        return session.operationsError
    }

    private var moduleRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textTertiary)
                TextField("搜索运维模块", text: $moduleSearchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.caption)
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 36)
            Divider().overlay(Theme.Color.separator)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(WorkbenchGroup.allCases) { group in
                        let modules = filteredModules(in: group)
                        if !modules.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName.uppercased())
                                    .font(Theme.Font.tiny.weight(.semibold))
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .padding(.horizontal, Theme.Space.sm)
                                ForEach(modules, id: \.id) { module in
                                    WorkbenchRailItem(
                                        title: module.title,
                                        systemImage: module.systemImage,
                                        isSelected: module.id == session.selectedWorkbenchModuleID,
                                        badge: module.badge(session)
                                    ) {
                                        session.selectedWorkbenchModuleID = module.id
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.sm)
            }
        }
    }

    private func filteredModules(in group: WorkbenchGroup) -> [WorkbenchModule] {
        WorkbenchRegistry.modules.filter { module in
            module.group == group
                && (moduleSearchText.isEmpty
                    || module.title.localizedCaseInsensitiveContains(moduleSearchText))
        }
    }
}

private struct WorkbenchRailItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: WorkbenchBadge? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.Color.accent : Theme.Color.textSecondary)
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                Spacer(minLength: 0)
                badgeView
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row)
                    .fill(isSelected ? Theme.Color.rowSelected : SwiftUI.Color.clear)
            )
            .padding(.horizontal, Theme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? String(localized: "已选择") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .dot(let color):
            Circle().fill(color).frame(width: 7, height: 7)
        case .count(let value, let color):
            Text("\(value)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color))
        case nil:
            EmptyView()
        }
    }
}

private struct WorkbenchDisconnectedPlaceholder: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let moduleTitle: String

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if session.connectionStatus == .connecting {
                ProgressView()
                    .controlSize(.large)
                Text("正在连接服务器…")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.Color.textTertiary)
                Text("未连接服务器")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("连接后可查看和管理「\(moduleTitle)」。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)

                if appState.selectedHost != nil {
                    Button {
                        appState.connectSelectedHost()
                    } label: {
                        Label("连接", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Theme.Space.xs)
                } else {
                    Text("请先在左侧选择一台服务器。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }

                if case let .failed(message) = session.connectionStatus {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }
}

private struct ToolEnvironmentSummary: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "shippingbox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textTertiary)
            Text(summary)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        guard let profile = session.serverProfile else {
            return String(localized: "连接后扫描工具路径")
        }
        return String(localized: "\(profile.packageManager.displayName) · \(profile.username ?? String(localized: "未知用户")) · 已检测 \(profile.installedTools.count) 个")
    }
}

struct AuditWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        VStack(spacing: 0) {
            OpsWorkspaceToolbar(
                title: String(localized: "巡检"),
                systemImage: "checkmark.shield",
                isLoading: session.isAuditLoading,
                refreshAction: session.refreshAuditFindings
            )
            Divider().overlay(Theme.Color.separator)

            if let error = session.operationsError {
                OpsStatusBanner(message: error)
                Divider().overlay(Theme.Color.separator)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    AuditSummaryStrip()
                    AuditFindingsList()
                }
                .padding(Theme.Space.md)
            }
        }
        .background(Theme.Color.surface)
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.auditFindings.isEmpty && !session.isAuditLoading {
                session.refreshAuditFindings()
            }
        }
    }
}

private struct ServiceUnitsSection: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @State private var searchText = ""
    @State private var filter: ServiceUnitFilter = .all
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            OpsSectionHeader(
                title: "服务",
                detail: serviceSectionDetail
            )

            HStack(spacing: Theme.Space.sm) {
                TextField("搜索服务", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("状态", selection: $filter) {
                    ForEach(ServiceUnitFilter.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .padding(.horizontal, Theme.Space.xs)

            if session.isServicesLoading && session.serviceUnits.isEmpty {
                OpsSkeletonRows()
            } else if usesUnsupportedInitSystem {
                OpsEmptyState(
                    systemImage: "switch.2",
                    title: String(localized: "暂不支持 \(session.serverProfile?.initSystem.displayName ?? String(localized: "当前")) 服务管理"),
                    detail: "当前服务列表和操作支持 systemd；工具安装仍会按服务器的服务管理器生成验证步骤。"
                )
            } else if session.serviceUnits.isEmpty {
                OpsEmptyState(
                    systemImage: "switch.2",
                    title: session.connectionStatus == .connected ? String(localized: "没有发现常见服务") : String(localized: "连接后显示服务"),
                    detail: "已完成扫描，但没有发现 Nginx、Docker、Redis、PostgreSQL、MySQL 等受支持的 systemd 服务。"
                )
            } else if filteredUnits.isEmpty {
                OpsEmptyState(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "没有匹配的服务",
                    detail: "调整搜索词或状态筛选。"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredUnits) { unit in
                        ServiceUnitRow(unit: unit)
                        Divider().overlay(Theme.Color.separator.opacity(0.45))
                    }
                }
                .background(Theme.Color.surface)
            }
        }
    }

    private var filteredUnits: [ServiceUnit] {
        session.serviceUnits.filter { unit in
            let matchesSearch = searchText.isEmpty
                || unit.name.localizedCaseInsensitiveContains(searchText)
                || unit.description.localizedCaseInsensitiveContains(searchText)
            return matchesSearch && filter.includes(unit)
        }
    }

    private var usesUnsupportedInitSystem: Bool {
        guard let initSystem = session.serverProfile?.initSystem else { return false }
        return initSystem != .systemd && initSystem != .unknown
    }

    private var serviceSectionDetail: String {
        if usesUnsupportedInitSystem {
            return session.serverProfile?.initSystem.displayName ?? String(localized: "不支持")
        }
        return session.serviceUnits.isEmpty ? String(localized: "未发现受支持服务") : String(localized: "\(session.serviceUnits.count) 个服务")
    }
}

private enum ServiceUnitFilter: String, CaseIterable, Identifiable {
    case all, running, stopped, failed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return String(localized: "全部")
        case .running: return String(localized: "运行中")
        case .stopped: return String(localized: "已停止")
        case .failed: return String(localized: "失败")
        }
    }
    func includes(_ unit: ServiceUnit) -> Bool {
        switch self {
        case .all: return true
        case .running: return unit.activeState == "active"
        case .stopped: return unit.activeState == "inactive"
        case .failed: return unit.activeState == "failed"
        }
    }
}

private struct ServiceUnitRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let unit: ServiceUnit

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: serviceIcon)
                .foregroundStyle(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(unit.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(unit.description.isEmpty ? unit.subState : unit.description)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            OpsStatusPill(text: unit.activeState, color: statusColor)
            Text(unit.unitFileState)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 92, alignment: .trailing)

            Menu {
                ForEach(ServiceAction.allCases) { action in
                    Button(action.displayName) {
                        session.requestServiceAction(action, service: unit)
                    }
                }
                Divider()
                Button {
                    session.openServiceLogs(unit)
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(ServiceAction.allCases) { action in
                Button(action.displayName) {
                    session.requestServiceAction(action, service: unit)
                }
            }
            Divider()
            Button("查看日志") {
                session.openServiceLogs(unit)
            }
        }
    }

    private var serviceIcon: String {
        unit.activeState == "active" ? "checkmark.circle.fill" : "circle"
    }

    private var statusColor: SwiftUI.Color {
        switch unit.activeState {
        case "active":
            return Theme.Color.success
        case "failed":
            return Theme.Color.danger
        case "inactive":
            return Theme.Color.textTertiary
        default:
            return Theme.Color.warning
        }
    }
}

private struct NginxManagerSection: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @State private var showingNewSite = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            OpsSectionHeader(title: "Nginx 配置与站点", detail: nginxDetail)

            if session.nginxSnapshot?.isInstalled == true {
                Text("启停/重启请到「系统服务」模块；此处专注于查看与编辑 Nginx 配置与站点。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xxs)
            }

            if session.isNginxLoading && session.nginxSnapshot?.isInstalled != true {
                OpsSkeletonRows()
            } else if let snapshot = session.nginxSnapshot, snapshot.isInstalled {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: nginxServiceRunning ? "checkmark.circle.fill" : "network")
                            .foregroundStyle(nginxStatusColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.version ?? "Nginx")
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.Color.textPrimary)
                                .lineLimit(1)
                            Text(snapshot.configPath ?? String(localized: "未识别主配置路径"))
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        OpsStatusPill(text: nginxServiceStatusText, color: nginxStatusColor)
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .frame(height: 44)

                    // Actions live on their own horizontally-scrollable row so the
                    // labeled buttons never clip on a narrow Tools pane.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) {
                            if !nginxServiceRunning,
                               let service = session.serviceUnits.first(where: { $0.name == "nginx" }) {
                                Button {
                                    session.requestServiceAction(.start, service: service)
                                } label: {
                                    Label("启动", systemImage: "play.fill")
                                }
                                .controlSize(.small)
                                .help("启动 Nginx")
                            }
                            Button {
                                session.openRemoteTextPath(snapshot.configPath ?? "/etc/nginx/nginx.conf", title: "nginx.conf", validator: .nginx)
                            } label: {
                                Label("编辑主配置", systemImage: "pencil")
                            }
                            .controlSize(.small)
                            .help(snapshot.configPath == nil ? String(localized: "未自动识别路径，将尝试打开 /etc/nginx/nginx.conf") : (snapshot.configPath ?? ""))
                            Button {
                                session.requestNginxValidate()
                            } label: {
                                Label("校验", systemImage: "checkmark.seal")
                            }
                            .controlSize(.small)
                            .help("仅执行 nginx -t 语法检查，不重载")
                            Button {
                                showingNewSite = true
                            } label: {
                                Label("新建站点", systemImage: "plus.rectangle.on.folder")
                            }
                            .controlSize(.small)
                            .help("填表单新建站点：反代/静态，可一键启用并申请 SSL")
                            .disabled(session.connectionStatus != .connected)
                            .sheet(isPresented: $showingNewSite) {
                                NginxNewSiteForm()
                                    .environmentObject(appState)
                                    .environmentObject(session)
                            }
                            Button {
                                session.requestNginxTestAndReload()
                            } label: {
                                Label("测试并重载", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.small)
                            .disabled(nginxServiceState != nil && !nginxServiceRunning)
                        }
                        .padding(.horizontal, Theme.Space.sm)
                    }
                    .frame(height: 42)

                    Divider().overlay(Theme.Color.separator.opacity(0.45))

                    if snapshot.sites.isEmpty {
                        Text("Nginx 已安装，但未发现独立的 sites-enabled 或 conf.d 配置；站点配置也可能直接写在 nginx.conf 中。")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                            .padding(Theme.Space.sm)
                    } else {
                        ForEach(snapshot.sites) { site in
                            NginxConfigRow(site: site)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }

                    if !snapshot.certificateHints.isEmpty {
                        Text("证书：\(Array(snapshot.certificateHints.prefix(3)).formatted(.list(type: .and, width: .narrow)))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.horizontal, Theme.Space.sm)
                            .padding(.vertical, Theme.Space.xs)
                    }
                }
            } else {
                WorkbenchEmptyOrActivity(moduleID: "nginx", failedTitle: String(localized: "安装失败")) {
                    OpsEmptyState(
                        systemImage: "network.slash",
                        title: "未检测到 Nginx",
                        detail: "可以在工具页生成安装计划，或先确认当前服务器使用的是 Caddy/Apache。"
                    ) {
                        if let nginx = appState.toolCatalog.first(where: { $0.id == "nginx" }) {
                            Button {
                                session.requestInstallTool(nginx)
                            } label: {
                                Label("安装 Nginx", systemImage: "plus.circle")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var nginxDetail: String {
        guard let snapshot = session.nginxSnapshot else { return String(localized: "未加载") }
        if !snapshot.isInstalled {
            return String(localized: "未安装")
        }
        let state = nginxServiceRunning ? String(localized: "运行中") : String(localized: "已安装 · \(nginxServiceStatusText)")
        return snapshot.sites.isEmpty ? String(localized: "\(state) · 0 个独立配置") : String(localized: "\(state) · \(snapshot.sites.count) 个配置")
    }

    private var nginxServiceState: String? {
        session.serviceUnits.first(where: { $0.name == "nginx" })?.activeState
            ?? session.serverProfile?.service(named: "nginx")?.activeState
    }

    private var nginxServiceRunning: Bool {
        nginxServiceState == "active"
    }

    private var nginxServiceStatusText: String {
        switch nginxServiceState {
        case "active":
            return String(localized: "运行中")
        case "inactive":
            return String(localized: "未运行")
        case "failed":
            return String(localized: "启动失败")
        case .some(let state):
            return state
        case nil:
            return String(localized: "状态未知")
        }
    }

    private var nginxStatusColor: SwiftUI.Color {
        switch nginxServiceState {
        case "active":
            return Theme.Color.success
        case "failed":
            return Theme.Color.danger
        default:
            return Theme.Color.warning
        }
    }
}

private struct NginxConfigRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let site: NginxSiteConfig

    /// Only Debian/Ubuntu sites-available entries can be toggled via a symlink;
    /// conf.d files are always active and have no enable/disable concept.
    private var canToggle: Bool { site.path.contains("/sites-available/") }

    private func edit() {
        session.openRemoteTextPath(site.path, title: site.name, byteCount: site.byteCount.map(UInt64.init), validator: .nginx)
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(site.path)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            OpsStatusPill(
                text: site.enabled ? String(localized: "已启用") : String(localized: "未启用"),
                color: site.enabled ? Theme.Color.success : Theme.Color.textTertiary
            )
            if let byteCount = site.byteCount {
                Text(ByteCountFormatter.opsSizeFormatter.string(fromByteCount: byteCount))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            if canToggle {
                Button {
                    session.requestNginxSiteEnabled(site: site, enable: !site.enabled)
                } label: {
                    Image(systemName: site.enabled ? "pause.circle" : "play.circle")
                }
                .buttonStyle(.borderless)
                .help(site.enabled ? String(localized: "停用站点") : String(localized: "启用站点"))
                .disabled(session.connectionStatus != .connected)
            }
            Button {
                edit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑配置")
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 38)
        .contentShape(Rectangle())
        .contextMenu {
            Button("编辑配置") { edit() }
            if canToggle {
                if site.enabled {
                    Button("停用站点") { session.requestNginxSiteEnabled(site: site, enable: false) }
                } else {
                    Button("启用站点") { session.requestNginxSiteEnabled(site: site, enable: true) }
                }
            }
            Button("申请 SSL 证书") {
                session.requestSiteSSL(domains: [domainGuess], staging: false)
            }
        }
    }

    /// Best-effort domain from the site file name (we name site files `<domain>.conf`).
    /// The runbook preview shows the exact certbot command for the user to confirm.
    private var domainGuess: String {
        site.name.hasSuffix(".conf") ? String(site.name.dropLast(5)) : site.name
    }
}

private struct LogSourceSidebar: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        VStack(spacing: 0) {
            if session.isLogSourcesLoading && session.logSources.isEmpty {
                OpsSkeletonRows()
            } else if session.logSources.isEmpty {
                OpsEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: session.connectionStatus == .connected ? String(localized: "没有发现可读日志源") : String(localized: "连接后发现日志"),
                    detail: session.connectionStatus == .connected
                        ? String(localized: "扫描已完成，但当前用户没有发现可读取的 journal、Nginx、Docker 或常见 /var/log 日志。")
                        : String(localized: "会查找 journal、Nginx、Docker 和常见 /var/log 文件。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.logSources) { source in
                            LogSourceRow(source: source, isSelected: session.selectedLogSourceID == source.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    session.selectLogSource(source)
                                }
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
        }
        .background(Theme.Color.surface)
    }
}

private struct LogSourceRow: View {
    let source: LogSource
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: iconName)
                .foregroundStyle(isSelected ? selectedText : Theme.Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(isSelected ? selectedText : Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(source.detail)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(isSelected ? selectedText.opacity(0.8) : Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 42)
        .background(OpsSelectionBackground(isSelected: isSelected))
    }

    private var iconName: String {
        switch source.kind {
        case .file:
            return "doc.text"
        case .journal:
            return "list.bullet.rectangle"
        case .docker:
            return "shippingbox"
        }
    }

    private var selectedText: SwiftUI.Color {
        SwiftUI.Color(nsColor: .selectedMenuItemTextColor)
    }
}

private struct LogPreviewPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Binding var searchText: String
    @State private var wrapsLines = true
    @State private var autoScrolls = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSource?.title ?? String(localized: "选择日志源"))
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Color.textPrimary)
                            .lineLimit(1)
                        Text(selectedSource?.detail ?? String(localized: "左侧选择一个日志源后查看最近内容"))
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Button {
                        session.refreshSelectedLogSource()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSource == nil || session.isLogPreviewLoading)
                    .help("刷新日志")
                    Button {
                        session.copyLogPreview()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.logPreview.isEmpty)
                    .help("复制日志")
                    Button {
                        session.exportLogPreview()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.logPreview.isEmpty)
                    .help("导出日志")

                    Picker("行数", selection: $session.logLineLimit) {
                        Text("200 行").tag(200)
                        Text("500 行").tag(500)
                        Text("1000 行").tag(1_000)
                    }
                    .labelsHidden()
                    .frame(width: 76)
                    .help("实时日志初始行数")

                    Button {
                        session.isLogFollowing ? session.stopLogFollow() : session.startLogFollow()
                    } label: {
                        Label(session.isLogFollowing ? "停止" : "实时", systemImage: session.isLogFollowing ? "stop.fill" : "dot.radiowaves.left.and.right")
                    }
                    .controlSize(.small)
                    .disabled(selectedSource == nil)

                    Button {
                        session.toggleLogFollowPause()
                    } label: {
                        Image(systemName: session.isLogFollowPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!session.isLogFollowing)
                    .help(session.isLogFollowPaused ? "继续显示实时日志" : "暂停显示实时日志")
                    .accessibilityLabel(session.isLogFollowPaused ? "继续实时日志" : "暂停实时日志")
                }

                TextField("搜索当前日志", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedSource == nil)

                HStack(spacing: Theme.Space.md) {
                    Toggle("自动换行", isOn: $wrapsLines)
                    Toggle("自动滚动", isOn: $autoScrolls)
                    Spacer()
                    if session.isLogFollowing {
                        Label(session.isLogFollowPaused ? "已暂停显示" : "正在实时跟随", systemImage: session.isLogFollowPaused ? "pause.circle" : "record.circle")
                            .font(Theme.Font.caption)
                            .foregroundStyle(session.isLogFollowPaused ? Theme.Color.warning : Theme.Color.success)
                    }
                }
                .toggleStyle(.checkbox)
                .font(Theme.Font.caption)
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 104)
            .background(Theme.Color.toolbarBackground)

            Divider().overlay(Theme.Color.separator)

            if selectedSource == nil, session.isLogSourcesLoading {
                OpsEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "正在发现日志源",
                    detail: "正在检查 journal、Nginx、Docker 和 /var/log。"
                )
            } else if session.isLogPreviewLoading && session.logPreview.isEmpty {
                OpsLoadingState(title: String(localized: "正在读取日志"))
            } else if previewText.isEmpty {
                OpsEmptyState(
                    systemImage: "doc.plaintext",
                    title: emptyPreviewTitle,
                    detail: emptyPreviewDetail
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView(wrapsLines ? .vertical : [.vertical, .horizontal]) {
                        Text(previewText)
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !wrapsLines, vertical: true)
                            .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
                            .padding(Theme.Space.md)
                        Color.clear.frame(height: 1).id("log-end")
                    }
                    .onChange(of: session.logPreview) { _, _ in
                        guard autoScrolls, !session.isLogFollowPaused else { return }
                        proxy.scrollTo("log-end", anchor: .bottom)
                    }
                }
                .background(Theme.Color.surface)
            }
        }
    }

    private var selectedSource: LogSource? {
        session.logSources.first { $0.id == session.selectedLogSourceID }
    }

    private var previewText: String {
        let value = session.logPreview
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return value }
        return value
            .split(whereSeparator: \.isNewline)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private var emptyPreviewTitle: String {
        if !session.logPreview.isEmpty {
            return String(localized: "没有匹配结果")
        }
        return selectedSource == nil ? String(localized: "选择日志源") : String(localized: "日志暂时为空")
    }

    private var emptyPreviewDetail: String {
        if !session.logPreview.isEmpty {
            return String(localized: "换一个搜索词试试。")
        }
        if selectedSource != nil {
            return String(localized: "日志源读取成功，但目前没有内容；这不代表服务或日志功能异常。")
        }
        return String(localized: "从左侧选择日志源后查看最近内容。")
    }
}

// MARK: - Workbench module adapter
//
// Each managed app/tool is a lightweight adapter: it declares how it appears in
// the 工具 workbench (id/title/icon), whether it needs a live connection, how to
// refresh and whether it's busy, and it renders its OWN specialized view. The
// registry is the single place to add a new tool — no enum/switch to edit.

enum WorkbenchBadge: Equatable {
    case dot(SwiftUI.Color)
    case count(Int, SwiftUI.Color)
}

@MainActor
protocol WorkbenchModule {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    var group: WorkbenchGroup { get }
    var needsConnection: Bool { get }
    func isBusy(_ session: ServerSession) -> Bool
    func refresh(_ session: ServerSession)
    /// Optional status indicator shown on the nav rail (e.g. Docker down, Fail2ban bans).
    func badge(_ session: ServerSession) -> WorkbenchBadge?
    func makeView() -> AnyView
}

extension WorkbenchModule {
    var group: WorkbenchGroup {
        switch id {
        case "services", "installer", "mirror", "shellpath": return .system
        case "nginx", "caddy", "certbot": return .web
        case "docker", "database", "pm2": return .applications
        case "firewall", "fail2ban", "cron": return .security
        case "deployment": return .presets
        default: return .system
        }
    }
    var needsConnection: Bool { true }
    func isBusy(_ session: ServerSession) -> Bool { false }
    func refresh(_ session: ServerSession) {}
    func badge(_ session: ServerSession) -> WorkbenchBadge? { nil }
}

enum WorkbenchGroup: String, CaseIterable, Identifiable {
    case system
    case web
    case applications
    case security
    case presets

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "系统")
        case .web: return String(localized: "Web 与证书")
        case .applications: return String(localized: "应用与数据")
        case .security: return String(localized: "安全与计划")
        case .presets: return String(localized: "部署")
        }
    }
}

@MainActor
enum WorkbenchRegistry {
    // Grouped by domain: lifecycle → entry → web(+SSL) → container → database →
    // runtime → security → schedule → deploy.
    static let modules: [WorkbenchModule] = [
        ServicesModule(),
        InstallerModule(),
        MirrorModule(),
        ShellPathModule(),
        NginxModule(),
        CaddyModule(),
        CertbotModule(),
        DockerModule(),
        DatabaseModule(),
        PM2Module(),
        FirewallModule(),
        Fail2banModule(),
        CronModule(),
        DeploymentModule()
    ]

    static func module(id: String) -> WorkbenchModule {
        modules.first { $0.id == id } ?? modules[0]
    }
}

private struct ServicesModule: WorkbenchModule {
    let id = "services"
    let title = String(localized: "系统服务")
    let systemImage = "switch.2"
    func isBusy(_ session: ServerSession) -> Bool { session.isServicesLoading }
    func refresh(_ session: ServerSession) { session.refreshServices() }
    func makeView() -> AnyView { AnyView(ServicesWorkbenchPane()) }
}

private struct InstallerModule: WorkbenchModule {
    let id = "installer"
    let title = String(localized: "安装器")
    let systemImage = "shippingbox"
    var needsConnection: Bool { false }
    func isBusy(_ session: ServerSession) -> Bool { session.isServerProfileLoading }
    func refresh(_ session: ServerSession) {
        session.app.refreshToolCatalog()
        session.refreshServerProfile()
    }
    func makeView() -> AnyView { AnyView(InstallerCatalogPane()) }
}

private struct MirrorModule: WorkbenchModule {
    let id = "mirror"
    let title = String(localized: "镜像源")
    let systemImage = "globe.asia.australia"
    func isBusy(_ session: ServerSession) -> Bool { session.isMirrorLoading }
    func refresh(_ session: ServerSession) { session.refreshMirror() }
    func makeView() -> AnyView { AnyView(MirrorPane()) }
}

private struct ShellPathModule: WorkbenchModule {
    let id = "shellpath"
    let title = "Shell / PATH"
    let systemImage = "curlybraces.square"
    func isBusy(_ session: ServerSession) -> Bool { session.isShellPathLoading }
    func refresh(_ session: ServerSession) { session.refreshShellPath() }
    func makeView() -> AnyView { AnyView(ShellPathPane()) }
}

private struct NginxModule: WorkbenchModule {
    let id = "nginx"
    let title = "Nginx"
    let systemImage = "server.rack"
    func isBusy(_ session: ServerSession) -> Bool { session.isNginxLoading }
    func refresh(_ session: ServerSession) {
        session.refreshNginx()
        session.refreshServices()
    }
    func makeView() -> AnyView { AnyView(NginxWorkbenchPane()) }
}

private struct DockerModule: WorkbenchModule {
    let id = "docker"
    let title = "Docker"
    let systemImage = "shippingbox.fill"
    func isBusy(_ session: ServerSession) -> Bool { session.isDockerLoading }
    func refresh(_ session: ServerSession) { session.refreshDockerContainers() }
    func badge(_ session: ServerSession) -> WorkbenchBadge? {
        guard let snapshot = session.dockerSnapshot, snapshot.isInstalled else { return nil }
        return snapshot.daemonReachable ? nil : .dot(Theme.Color.danger)
    }
    func makeView() -> AnyView { AnyView(DockerContainersPane()) }
}

private struct DatabaseModule: WorkbenchModule {
    let id = "database"
    let title = String(localized: "数据库")
    let systemImage = "cylinder.split.1x2"
    func isBusy(_ session: ServerSession) -> Bool { session.isDatabasesLoading }
    func refresh(_ session: ServerSession) { session.refreshDatabases() }
    func makeView() -> AnyView { AnyView(DatabasesPane()) }
}

private struct FirewallModule: WorkbenchModule {
    let id = "firewall"
    let title = String(localized: "防火墙")
    let systemImage = "lock.shield"
    func isBusy(_ session: ServerSession) -> Bool { session.isFirewallLoading }
    func refresh(_ session: ServerSession) { session.refreshFirewall() }
    func makeView() -> AnyView { AnyView(FirewallPane()) }
}

private struct PM2Module: WorkbenchModule {
    let id = "pm2"
    let title = "PM2"
    let systemImage = "cpu"
    func isBusy(_ session: ServerSession) -> Bool { session.isPM2Loading }
    func refresh(_ session: ServerSession) { session.refreshPM2() }
    func makeView() -> AnyView { AnyView(PM2Pane()) }
}

private struct CertbotModule: WorkbenchModule {
    let id = "certbot"
    let title = String(localized: "SSL 证书")
    let systemImage = "checkmark.seal"
    func isBusy(_ session: ServerSession) -> Bool { session.isCertbotLoading }
    func refresh(_ session: ServerSession) { session.refreshCertificates() }
    func makeView() -> AnyView { AnyView(CertbotPane()) }
}

private struct CaddyModule: WorkbenchModule {
    let id = "caddy"
    let title = "Caddy"
    let systemImage = "server.rack"
    func isBusy(_ session: ServerSession) -> Bool { session.isCaddyLoading }
    func refresh(_ session: ServerSession) { session.refreshCaddy() }
    func makeView() -> AnyView { AnyView(CaddyPane()) }
}

private struct Fail2banModule: WorkbenchModule {
    let id = "fail2ban"
    let title = "Fail2ban"
    let systemImage = "hand.raised"
    func isBusy(_ session: ServerSession) -> Bool { session.isFail2banLoading }
    func refresh(_ session: ServerSession) { session.refreshFail2ban() }
    func badge(_ session: ServerSession) -> WorkbenchBadge? {
        guard let snapshot = session.fail2banSnapshot else { return nil }
        let banned = snapshot.jails.reduce(0) { $0 + $1.currentlyBanned }
        return banned > 0 ? .count(banned, Theme.Color.warning) : nil
    }
    func makeView() -> AnyView { AnyView(Fail2banPane()) }
}

private struct CronModule: WorkbenchModule {
    let id = "cron"
    let title = String(localized: "定时任务")
    let systemImage = "clock.arrow.circlepath"
    func isBusy(_ session: ServerSession) -> Bool { session.isCronLoading }
    func refresh(_ session: ServerSession) { session.refreshCron() }
    func makeView() -> AnyView { AnyView(CronPane()) }
}

private struct DeploymentModule: WorkbenchModule {
    let id = "deployment"
    let title = String(localized: "一键部署")
    let systemImage = "square.stack.3d.up"
    var needsConnection: Bool { false }
    func refresh(_ session: ServerSession) {
        session.app.refreshToolCatalog()
        if session.connectionStatus == .connected {
            session.refreshServerProfile()
        }
    }
    func makeView() -> AnyView { AnyView(DeploymentPane()) }
}

private enum ToolCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case base
    case web
    case runtime
    case container
    case database
    case security

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return String(localized: "全部")
        case .base:
            return ToolCategory.base.displayName
        case .web:
            return ToolCategory.web.displayName
        case .runtime:
            return ToolCategory.runtime.displayName
        case .container:
            return ToolCategory.container.displayName
        case .database:
            return ToolCategory.database.displayName
        case .security:
            return ToolCategory.security.displayName
        }
    }

    var category: ToolCategory? {
        switch self {
        case .all:
            return nil
        case .base:
            return .base
        case .web:
            return .web
        case .runtime:
            return .runtime
        case .container:
            return .container
        case .database:
            return .database
        case .security:
            return .security
        }
    }
}

private enum ToolStatusFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case notInstalled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return String(localized: "全部")
        case .installed: return String(localized: "已安装")
        case .notInstalled: return String(localized: "未安装")
        }
    }
}

private struct InstallerCatalogPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var selectedCategory: ToolCategoryFilter = .all
    @State private var selectedStatus: ToolStatusFilter = .all
    @State private var searchText = ""

    var body: some View {
        GeometryReader { proxy in
            let layout = ToolCatalogLayout(availableWidth: proxy.size.width)

            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.sm) {
                    Picker("工具分类", selection: $selectedCategory) {
                        ForEach(ToolCategoryFilter.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 108)

                    Picker("安装状态", selection: $selectedStatus) {
                        ForEach(ToolStatusFilter.allCases) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)

                    OpsSearchField(text: $searchText, placeholder: String(localized: "搜索工具"))
                        .frame(width: 170, height: 24)

                    Spacer()
                    Text(catalogSummary)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 42)
                .background(Theme.Color.toolbarBackground)

                Divider().overlay(Theme.Color.separator)

                ToolCatalogHeader(layout: layout)

                Divider().overlay(Theme.Color.separator)

                if filteredTools.isEmpty {
                    OpsEmptyState(
                        systemImage: "magnifyingglass",
                        title: "没有匹配的工具",
                        detail: "请更换分类或搜索关键词。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTools) { tool in
                                ToolCatalogRow(tool: tool, layout: layout)
                                Divider().overlay(Theme.Color.separator.opacity(0.45))
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredTools: [ToolDefinition] {
        let tools: [ToolDefinition]
        if let category = selectedCategory.category {
            tools = appState.toolCatalog.filter { $0.category == category }
        } else {
            tools = appState.toolCatalog
        }

        let statusTools: [ToolDefinition]
        switch selectedStatus {
        case .all:
            statusTools = tools
        case .installed:
            statusTools = tools.filter { $0.isInstalled(on: session.serverProfile) }
        case .notInstalled:
            statusTools = tools.filter { !$0.isInstalled(on: session.serverProfile) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedTools = query.isEmpty ? statusTools : statusTools.filter { tool in
            tool.name.localizedCaseInsensitiveContains(query)
                || tool.description.localizedCaseInsensitiveContains(query)
                || tool.binaryNames.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }

        return searchedTools.sorted { lhs, rhs in
            let lhsInstalled = lhs.isInstalled(on: session.serverProfile)
            let rhsInstalled = rhs.isInstalled(on: session.serverProfile)
            if lhsInstalled != rhsInstalled {
                return lhsInstalled && !rhsInstalled
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var catalogSummary: String {
        let installedCount = filteredTools.filter { $0.isInstalled(on: session.serverProfile) }.count
        return String(localized: "\(filteredTools.count) 项，\(installedCount) 项已安装")
    }
}

private struct ToolCatalogLayout {
    let pathWidth: CGFloat
    let statusWidth: CGFloat
    let actionWidth: CGFloat

    init(availableWidth: CGFloat) {
        let compact = availableWidth < 760
        pathWidth = compact ? 150 : 220
        statusWidth = compact ? 70 : 78
        actionWidth = compact ? 82 : 96
    }
}

private struct ToolCatalogHeader: View {
    let layout: ToolCatalogLayout

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("工具")
                .padding(.leading, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("安装位置")
                .frame(width: layout.pathWidth, alignment: .leading)
            Text("状态")
                .frame(width: layout.statusWidth, alignment: .leading)
            Text("操作")
                .frame(width: layout.actionWidth, alignment: .trailing)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Color.textTertiary)
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 26)
        .background(Theme.Color.toolbarBackground)
    }
}

private struct OpsSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.controlSize = .small
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context _: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}

private struct ToolCatalogRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let tool: ToolDefinition
    let layout: ToolCatalogLayout

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.xs) {
                    Text(tool.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                    if !installed, !missingDeps.isEmpty {
                        OpsStatusPill(text: String(localized: "需要 \(missingDeps.formatted(.list(type: .and, width: .narrow)))"), color: Theme.Color.warning)
                            .help("安装前会先自动安装依赖：\(missingDeps.formatted(.list(type: .and, width: .narrow)))")
                    }
                    if !installed, let worst = worstPreflight {
                        OpsStatusPill(
                            text: worst.title,
                            color: worst.severity == .blocker ? Theme.Color.danger : Theme.Color.warning
                        )
                        .help(blockingPreflight.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n\n"))
                    }
                    if installed, installedTool?.hasMultipleVersions == true,
                       let alt = installedTool?.alternatePaths, !alt.isEmpty {
                        OpsStatusPill(text: String(localized: "+\(alt.count) 版本"), color: Theme.Color.warning)
                            .help(String(localized: "检测到多个安装位置：\n") + alt.joined(separator: "\n"))
                    }
                }
                Text(toolSubtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let installedPath {
                    Button {
                        appState.copyToolPath(installedPath)
                    } label: {
                        HStack(spacing: Theme.Space.xxs) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9, weight: .regular))
                            Text(installedPath)
                                .font(Theme.Font.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制路径")
                } else {
                    Text("—")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .frame(width: layout.pathWidth, alignment: .leading)

            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10, weight: .medium))
                Text(statusText)
                    .font(Theme.Font.caption)
            }
            .foregroundStyle(statusColor)
            .frame(width: layout.statusWidth, alignment: .leading)

            Group {
                switch session.toolActivity(tool.id) {
                case .running(let run):
                    HStack(spacing: Theme.Space.xxs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(run.progressDescription)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                case .failed(let run):
                    HStack(spacing: Theme.Space.xxs) {
                        Button(String(localized: "重试")) { session.retryRun(run) }
                            .controlSize(.small)
                        Button {
                            session.showRunDetail(run)
                        } label: {
                            Image(systemName: "text.alignleft")
                        }
                        .buttonStyle(.borderless)
                        .help("查看详情")
                    }
                case .idle:
                    if installed {
                    Menu {
                        if let installedPath {
                            Button {
                                appState.copyToolPath(installedPath)
                            } label: {
                                Label("复制安装路径", systemImage: "doc.on.doc")
                            }
                            Divider()
                        }
                        Button {
                            session.requestInstallTool(tool)
                        } label: {
                            Label(
                                serviceNeedsAttention ? String(localized: "修复服务") : String(localized: "重新安装"),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        Divider()
                        if let reason = tool.uninstallPolicy.blockedReason {
                            Button {} label: {
                                Label("卸载已禁用", systemImage: "trash.slash")
                            }
                            .disabled(true)
                            .help(reason)
                        } else {
                            Button(role: .destructive) {
                                session.requestUninstallTool(tool)
                            } label: {
                                Label("卸载", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多操作")
                } else {
                    Button("安装") {
                        session.requestInstallTool(tool)
                    }
                    .controlSize(.small)
                }
                }
            }
            .frame(width: layout.actionWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 52)
        .contentShape(Rectangle())
        .contextMenu {
            if let installedPath {
                Button {
                    appState.copyToolPath(installedPath)
                } label: {
                    Label("复制安装路径", systemImage: "doc.on.doc")
                }
            }
            Button {
                session.requestInstallTool(tool)
            } label: {
                Label(
                    installed
                        ? (serviceNeedsAttention ? String(localized: "修复服务") : String(localized: "重新安装"))
                        : String(localized: "安装"),
                    systemImage: "list.bullet.clipboard"
                )
            }
        }
    }

    private var installed: Bool {
        installedTool != nil
    }

    private var installedTool: ServerToolPresence? {
        tool.installedTool(on: session.serverProfile)
    }

    /// When installed, prefer showing the detected version (e.g. "git version 2.43.0");
    /// otherwise fall back to the static description.
    private var toolSubtitle: String {
        if let version = installedTool?.version, !version.isEmpty {
            return version
        }
        return tool.description
    }

    private var installedPath: String? {
        installedTool?.path
    }

    private var managedServiceState: String? {
        if tool.id == "docker", let snapshot = session.dockerSnapshot, snapshot.isInstalled {
            return snapshot.daemonReachable ? "active" : "unreachable"
        }
        guard let serviceName = tool.managedServiceName else { return nil }
        return session.serverProfile?.service(named: serviceName)?.activeState
    }

    private var serviceNeedsAttention: Bool {
        installed && managedServiceState != nil && managedServiceState != "active"
    }

    private var statusText: String {
        guard installed else { return String(localized: "未安装") }
        guard tool.managedServiceName != nil else { return String(localized: "已安装") }
        switch managedServiceState {
        case "active":
            return String(localized: "运行中")
        case "failed", "unreachable":
            return String(localized: "异常")
        case .some(_):
            return String(localized: "未运行")
        case nil:
            return String(localized: "已安装")
        }
    }

    private var statusIcon: String {
        guard installed else { return "circle" }
        if managedServiceState == "active" || tool.managedServiceName == nil {
            return "checkmark.circle.fill"
        }
        return managedServiceState == "failed" || managedServiceState == "unreachable"
            ? "exclamationmark.circle.fill"
            : "pause.circle.fill"
    }

    private var statusColor: SwiftUI.Color {
        guard installed else { return Theme.Color.textTertiary }
        if managedServiceState == "failed" || managedServiceState == "unreachable" {
            return Theme.Color.danger
        }
        if tool.managedServiceName != nil && managedServiceState != "active" {
            return Theme.Color.warning
        }
        return Theme.Color.success
    }

    private var missingDeps: [String] {
        session.missingDependencies(for: tool)
    }

    /// Preflight findings worth a badge (blockers + warnings; info stays in the plan summary).
    private var blockingPreflight: [PreflightIssue] {
        session.preflightIssues(for: tool).filter { $0.severity != .info }
    }

    private var worstPreflight: PreflightIssue? {
        blockingPreflight.first(where: { $0.severity == .blocker }) ?? blockingPreflight.first
    }

    private var iconName: String {
        switch tool.category {
        case .base:
            return "hammer"
        case .web:
            return "network"
        case .runtime:
            return "curlybraces"
        case .container:
            return "shippingbox"
        case .database:
            return "cylinder.split.1x2"
        case .security:
            return "checkmark.shield"
        }
    }
}

private struct DockerContainersPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @State private var showsPullSheet = false
    @State private var showsRunSheet = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack {
                    OpsSectionHeader(
                        title: "容器",
                        detail: sectionDetail
                    )
                    Spacer()
                    if dockerServiceRunning {
                        Button {
                            showsPullSheet = true
                        } label: {
                            Label("拉取镜像", systemImage: "arrow.down.circle")
                        }
                        .controlSize(.small)
                        Button {
                            showsRunSheet = true
                        } label: {
                            Label("创建容器", systemImage: "plus")
                        }
                        .controlSize(.small)
                        Button {
                            session.requestDockerDiskUsage()
                        } label: {
                            Label("磁盘占用", systemImage: "internaldrive")
                        }
                        .controlSize(.small)
                        .help("docker system df（只读）")
                        Button(role: .destructive) {
                            session.requestDockerPrune()
                        } label: {
                            Label("清理", systemImage: "trash")
                        }
                        .controlSize(.small)
                        .help("docker system prune -f，清理无用资源")
                    }
                }
                if session.isDockerLoading && session.dockerContainers.isEmpty {
                    OpsSkeletonRows()
                } else if session.dockerContainers.isEmpty {
                    WorkbenchEmptyOrActivity(moduleID: "docker") {
                        OpsEmptyState(
                            systemImage: emptyStateIcon,
                            title: emptyStateTitle,
                            detail: emptyStateDetail
                        ) {
                            emptyStateActions
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(session.dockerContainers) { container in
                            DockerContainerRow(container: container)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                }

                if let images = session.dockerSnapshot?.images, !images.isEmpty {
                    OpsSectionHeader(title: "镜像", detail: String(localized: "\(images.count) 个镜像"))
                    VStack(spacing: 0) {
                        ForEach(images) { image in
                            DockerImageRow(image: image)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.environment["OPSDECK_DOCKER_READY_PREVIEW"] == "1" {
                return
            }
#endif
            guard session.connectionStatus == .connected else { return }
            if session.dockerContainers.isEmpty && !session.isDockerLoading {
                session.refreshDockerContainers()
            }
        }
        .sheet(isPresented: $showsPullSheet) {
            DockerPullSheet()
                .environmentObject(session)
        }
        .sheet(isPresented: $showsRunSheet) {
            DockerRunSheet()
                .environmentObject(session)
        }
    }

    @ViewBuilder
    private var emptyStateActions: some View {
        if !dockerInstalled,
           let docker = appState.toolCatalog.first(where: { $0.id == "docker" }) {
            Button {
                session.requestInstallTool(docker)
            } label: {
                Label("安装 Docker", systemImage: "plus.circle")
            }
            .controlSize(.small)
        } else if !dockerServiceRunning {
            HStack(spacing: Theme.Space.xs) {
                Button {
                    session.requestStartDockerService()
                } label: {
                    Label("启动 Docker", systemImage: "play.circle")
                }
                Button {
                    session.refreshDockerContainers()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .controlSize(.small)
        } else {
            Button {
                session.refreshDockerContainers()
            } label: {
                Label("刷新容器", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    private var dockerInstalled: Bool {
        session.dockerSnapshot?.isInstalled
            ?? (session.serverProfile?.tool(named: "docker")?.isInstalled == true)
    }

    private var dockerServiceRunning: Bool {
        session.dockerSnapshot?.daemonReachable
            ?? (session.serverProfile?.service(named: "docker")?.activeState == "active")
    }

    private var dockerServiceState: String? {
        session.serverProfile?.service(named: "docker")?.activeState
    }

    private var sectionDetail: String {
        if !dockerInstalled {
            return String(localized: "未安装")
        }
        if dockerServiceRunning {
            return session.dockerContainers.isEmpty ? String(localized: "daemon 可用 · 0 个容器") : String(localized: "daemon 可用 · \(session.dockerContainers.count) 个容器")
        }
        return String(localized: "已安装 · 服务\(dockerServiceState ?? String(localized: "状态未知"))")
    }

    private var emptyStateIcon: String {
        dockerInstalled && dockerServiceRunning ? "checkmark.circle" : "shippingbox"
    }

    private var emptyStateTitle: String {
        if !dockerInstalled {
            return String(localized: "尚未安装 Docker")
        }
        if dockerServiceRunning {
            return String(localized: "Docker 已就绪")
        }
        return String(localized: "Docker 服务未运行")
    }

    private var emptyStateDetail: String {
        if !dockerInstalled {
            return String(localized: "生成安装计划后会显示命令、执行进度和实时日志。")
        }
        if dockerServiceRunning {
            if let version = session.dockerSnapshot?.clientVersion, !version.isEmpty {
                return String(localized: "\(version)。Docker daemon 可以正常连接，当前服务器还没有创建容器。")
            }
            return String(localized: "Docker 已安装且 daemon 可以正常连接，当前服务器还没有创建容器。")
        }
        if let daemonError = session.dockerSnapshot?.daemonError, !daemonError.isEmpty {
            return String(localized: "Docker 客户端已安装，但 daemon 无法连接：\(daemonError)")
        }
        if let dockerServiceState {
            return String(localized: "Docker 客户端已安装，但服务状态为 \(dockerServiceState)。可以生成启动计划并查看实时日志。")
        }
        return String(localized: "Docker 客户端已安装，但尚未确认 daemon 状态。可以先刷新，或生成启动计划。")
    }
}

private struct DockerContainerRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let container: DockerContainerSummary
    @State private var showsExecSheet = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: container.status.localizedCaseInsensitiveContains("up") ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(container.status.localizedCaseInsensitiveContains("up") ? Theme.Color.success : Theme.Color.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(container.image)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(container.status)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .trailing)
            Menu {
                Button("启动") { session.requestDockerAction(.start, container: container) }
                Button("停止") { session.requestDockerAction(.stop, container: container) }
                Button("重启") { session.requestDockerAction(.restart, container: container) }
                Divider()
                Button("查看日志") { session.openDockerLogs(container) }
                Button("检查（只读）") { session.requestInspectDockerContainer(container) }
                Button("执行命令…") { showsExecSheet = true }
                Divider()
                Button(role: .destructive) {
                    session.requestRemoveDockerContainer(container)
                } label: {
                    Label("删除容器", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
        .sheet(isPresented: $showsExecSheet) {
            DockerExecSheet(container: container)
                .environmentObject(session)
        }
    }
}

private struct DockerPullSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""

    var body: some View {
        OperationInputSheet(
            title: String(localized: "拉取 Docker 镜像"),
            detail: String(localized: "例如 nginx:alpine 或 ghcr.io/org/app:latest"),
            confirmTitle: String(localized: "预览拉取计划"),
            isValid: !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            TextField("镜像:标签", text: $reference)
        } onConfirm: {
            let value = reference
            dismiss()
            DispatchQueue.main.async { session.requestDockerPull(reference: value) }
        }
    }
}

private struct DockerRunSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image = ""
    @State private var port = ""
    @State private var restartPolicy = "unless-stopped"

    var body: some View {
        OperationInputSheet(
            title: String(localized: "创建 Docker 容器"),
            detail: String(localized: "首版支持名称、镜像、单个端口映射和重启策略；卷和环境变量请在 SQL/终端之外使用 Compose。"),
            confirmTitle: String(localized: "预览创建计划"),
            isValid: !name.isEmpty && !image.isEmpty
        ) {
            TextField("容器名称", text: $name)
            TextField("镜像:标签", text: $image)
            TextField("端口映射，例如 8080:80", text: $port)
            Picker("重启策略", selection: $restartPolicy) {
                Text("unless-stopped").tag("unless-stopped")
                Text("always").tag("always")
                Text("on-failure").tag("on-failure")
                Text("不自动重启").tag("no")
            }
        } onConfirm: {
            let captured = (name, image, port, restartPolicy)
            dismiss()
            DispatchQueue.main.async {
                session.requestDockerRun(name: captured.0, image: captured.1, portMapping: captured.2, restartPolicy: captured.3)
            }
        }
    }
}

private struct DockerExecSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    let container: DockerContainerSummary
    @State private var command = ""

    var body: some View {
        OperationInputSheet(
            title: String(localized: "在 \(container.name) 中执行命令"),
            detail: String(localized: "命令通过 sh -lc 执行；完整内容会先出现在执行计划中。"),
            confirmTitle: String(localized: "预览执行计划"),
            isValid: !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            TextField("例如 ls -la /app", text: $command, axis: .vertical)
                .lineLimit(3...6)
                .font(Theme.Font.monoSmall)
        } onConfirm: {
            let value = command
            dismiss()
            DispatchQueue.main.async { session.requestDockerExec(container: container, command: value) }
        }
    }
}

private struct OperationInputSheet<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let detail: String
    let confirmTitle: String
    let isValid: Bool
    @ViewBuilder let fields: () -> Fields
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title).font(Theme.Font.windowTitle)
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.sm) { fields() }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 500)
        .background(Theme.Color.surface)
    }
}

private struct DockerImageRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let image: DockerImageSummary

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(image.id.prefix(12)))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(image.size)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
            Menu {
                Button(role: .destructive) {
                    session.requestRemoveDockerImage(image)
                } label: {
                    Label("删除镜像", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
    }
}

private struct DatabasesPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @EnvironmentObject private var db: DBBrowserState
    // The browser lives in its OWN window (see DatabaseBrowserWindow.swift), so
    // its heavy grid doesn't relayout the main window's tree on every scroll.
    // This pane always shows the target list; opening a target raises the window.
    @StateObject private var browserWindow = DatabaseBrowserWindowManager()
    @State private var managedRedis: DatabaseTarget? = ProcessInfo.processInfo.environment["OPSDECK_REDIS_MANAGER_PREVIEW"] == "1"
        ? RedisPreviewFixture.target
        : nil

    var body: some View {
        Group {
            if let redis = managedRedis {
                RedisManagerPane(database: redis) {
                    managedRedis = nil
                }
            } else {
                targetList
            }
        }
            .onChange(of: db.dbBrowserTarget) { _, target in
                browserWindow.sync(target: target, appState: appState, session: session)
            }
            .onAppear {
                browserWindow.sync(target: db.dbBrowserTarget, appState: appState, session: session)
            }
    }

    private var targetList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                OpsSectionHeader(
                    title: "数据库",
                    detail: databaseSectionDetail
                )
                HStack {
                    Button {
                        session.openDatabaseConnectionsWorkspace()
                    } label: {
                        Label(String(localized: "管理数据库连接"), systemImage: "link.badge.plus")
                    }
                    .controlSize(.small)
                    .help(String(localized: "添加或管理可通过当前 SSH 服务器访问的 MySQL/PostgreSQL 连接"))
                    Spacer()
                }
                if session.isDatabasesLoading && session.databases.isEmpty {
                    OpsSkeletonRows()
                } else if session.databases.isEmpty {
                    OpsEmptyState(
                        systemImage: "cylinder.split.1x2",
                        title: "未检测到已安装的数据库组件",
                        detail: "扫描已完成；可在安装器中为 PostgreSQL、MySQL 或 Redis 生成安装计划。"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(session.databases) { database in
                            DatabaseRow(database: database) {
                                managedRedis = database
                            }
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_STATES_PREVIEW"] == "1" {
                return
            }
#endif
            guard session.connectionStatus == .connected else { return }
            if !session.hasLoadedDatabases && !session.isDatabasesLoading {
                session.refreshDatabases()
            }
        }
    }

    private var databaseSectionDetail: String {
        guard !session.databases.isEmpty else { return String(localized: "未安装受支持组件") }
        let runningCount = session.databases.filter { $0.activeState == "active" }.count
        return String(localized: "\(session.databases.count) 个组件 · \(runningCount) 个运行中")
    }
}

private struct DatabaseRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let database: DatabaseTarget
    let onManageRedis: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: database.activeState == "active" ? "checkmark.circle.fill" : "cylinder.split.1x2")
                .foregroundStyle(statusColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(database.kind.displayName)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(database.version ?? database.serviceName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            OpsStatusPill(text: statusText, color: statusColor)
            if database.serviceInstalled && database.activeState == "active" {
                if DBDialect.from(database.kind) != nil {
                    Button {
                        session.openDatabaseBrowser(database)
                    } label: {
                        Label("浏览", systemImage: "tablecells")
                    }
                    .controlSize(.small)
                    .help("打开表浏览器：查看/查询数据、结构与执行 SQL")
                } else {
                    Button {
                        onManageRedis()
                    } label: {
                        Label("管理", systemImage: "list.bullet.rectangle")
                    }
                    .controlSize(.small)
                    .help("打开 Redis 运行概览与键空间管理")
                }
                Button {
                    session.requestDatabaseBackup(database)
                } label: {
                    Label("备份", systemImage: "externaldrive.badge.timemachine")
                }
                .controlSize(.small)
            } else if database.serviceInstalled {
                Button {
                    session.openWorkbenchModule("services")
                } label: {
                    Label("查看服务", systemImage: "switch.2")
                }
                .controlSize(.small)
            } else {
                Text("未检测到服务端")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
    }

    private var statusText: String {
        guard database.serviceInstalled else { return String(localized: "仅客户端") }
        switch database.activeState {
        case "active":
            return String(localized: "运行中")
        case "inactive":
            return String(localized: "未运行")
        case "failed":
            return String(localized: "启动失败")
        case .some(let state) where !state.isEmpty:
            return state
        default:
            return String(localized: "状态未知")
        }
    }

    private var statusColor: SwiftUI.Color {
        guard database.serviceInstalled else { return Theme.Color.textSecondary }
        switch database.activeState {
        case "active":
            return Theme.Color.success
        case "failed":
            return Theme.Color.danger
        default:
            return Theme.Color.warning
        }
    }
}

private struct RedisStringEditorContext: Identifiable {
    let id = UUID()
    var key: String?
    var value: String
    var preservesTTL: Bool
}

private struct RedisTTLEditorContext: Identifiable {
    let id = UUID()
    var key: String
    var currentTTL: Int
}

enum RedisPreviewFixture {
    static let target = DatabaseTarget(
        kind: .redis,
        serviceName: "redis-server",
        installed: true,
        serviceInstalled: true,
        activeState: "active",
        version: "redis-cli 7.0.15"
    )
    static let snapshot = RedisServerSnapshot(
        version: "7.0.15",
        mode: "standalone",
        uptimeDays: 42,
        connectedClients: 18,
        blockedClients: 0,
        usedMemory: "86.4M",
        peakMemory: "112.8M",
        maxMemory: "512.0M",
        maxMemoryPolicy: "allkeys-lru",
        totalConnections: 148_209,
        totalCommands: 9_824_517,
        keyspaceHits: 8_486_102,
        keyspaceMisses: 521_883,
        rdbLastSaveTime: Date().addingTimeInterval(-1_200),
        rdbLastSaveStatus: "ok",
        aofEnabled: true,
        persistenceBusy: false,
        configuredDatabaseCount: 16,
        databases: [
            RedisDatabaseSummary(index: 0, keyCount: 1_284, expiringKeyCount: 1_106, averageTTL: 840_000),
            RedisDatabaseSummary(index: 1, keyCount: 48, expiringKeyCount: 12, averageTTL: 3_600_000)
        ]
    )
    static let keys = [
        RedisKeySummary(name: "session:user:10428", type: "hash", ttlSeconds: 1_742, memoryBytes: 1_824),
        RedisKeySummary(name: "cache:api:dashboard:summary", type: "string", ttlSeconds: 284, memoryBytes: 4_096),
        RedisKeySummary(name: "queue:email:pending", type: "list", ttlSeconds: -1, memoryBytes: 12_288),
        RedisKeySummary(name: "ranking:weekly", type: "zset", ttlSeconds: 43_120, memoryBytes: 8_416),
        RedisKeySummary(name: "feature:enabled-users", type: "set", ttlSeconds: -1, memoryBytes: 3_104)
    ]
    static let detail = RedisKeyDetail(
        key: "session:user:10428",
        type: "hash",
        ttlSeconds: 1_742,
        logicalSize: 4,
        entries: [
            RedisKeyDetailEntry(id: "0", label: "user_id", value: "10428"),
            RedisKeyDetailEntry(id: "1", label: "role", value: "editor"),
            RedisKeyDetailEntry(id: "2", label: "last_seen", value: "2026-07-22T16:21:08Z"),
            RedisKeyDetailEntry(id: "3", label: "locale", value: "zh-CN")
        ]
    )
}

/// A bounded Redis workbench. It uses SCAN + cursor paging and loads only the
/// selected key's first values, so opening a large cache cannot reproduce the
/// unbounded CPU/layout work that the SQL browser previously suffered from.
private struct RedisManagerPane: View {
    @EnvironmentObject private var session: ServerSession
    let database: DatabaseTarget
    let onClose: () -> Void

    @State private var credential: RedisCredential?
    @State private var snapshot: RedisServerSnapshot?
    @State private var selectedDatabase = 0
    @State private var searchText = ""
    @State private var currentCursor = "0"
    @State private var nextCursor = "0"
    @State private var cursorHistory: [String] = []
    @State private var keys: [RedisKeySummary] = []
    @State private var selectedKey: String?
    @State private var keyDetail: RedisKeyDetail?
    @State private var errorMessage: String?
    @State private var isLoadingSnapshot = false
    @State private var isLoadingKeys = false
    @State private var isLoadingDetail = false
    @State private var detailRequestID: UUID?
    @State private var didLoad = false
    @State private var showsCredentialEditor = false
    @State private var stringEditor: RedisStringEditorContext?
    @State private var ttlEditor: RedisTTLEditorContext?
    @State private var keyPendingDeletion: String?
    @State private var isDeleting = false

    init(database: DatabaseTarget, onClose: @escaping () -> Void) {
        self.database = database
        self.onClose = onClose
        if ProcessInfo.processInfo.environment["OPSDECK_REDIS_MANAGER_PREVIEW"] == "1" {
            _snapshot = State(initialValue: RedisPreviewFixture.snapshot)
            _keys = State(initialValue: RedisPreviewFixture.keys)
            _selectedKey = State(initialValue: RedisPreviewFixture.detail.key)
            _keyDetail = State(initialValue: RedisPreviewFixture.detail)
            _didLoad = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if let errorMessage {
                errorBanner(errorMessage)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    overview
                    keyspace
                }
                .padding(Theme.Space.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.surface)
        .task {
            guard !didLoad else { return }
            didLoad = true
            credential = session.redisStoredCredential()
            await reloadAll()
        }
        .sheet(isPresented: $showsCredentialEditor) {
            RedisCredentialEditorSheet(initial: credential) { updated in
                credential = updated
                showsCredentialEditor = false
                Task { await reloadAll() }
            } onCancel: {
                showsCredentialEditor = false
            }
            .environmentObject(session)
        }
        .sheet(item: $stringEditor) { context in
            RedisStringEditorSheet(
                context: context,
                database: selectedDatabase,
                credential: credential
            ) {
                stringEditor = nil
                Task { await reloadKeys(resetPaging: true) }
            } onCancel: {
                stringEditor = nil
            }
            .environmentObject(session)
        }
        .sheet(item: $ttlEditor) { context in
            RedisTTLEditorSheet(
                context: context,
                database: selectedDatabase,
                credential: credential
            ) {
                ttlEditor = nil
                Task { await reloadKeys(resetPaging: false) }
            } onCancel: {
                ttlEditor = nil
            }
            .environmentObject(session)
        }
        .alert(
            String(localized: "删除 Redis 键？"),
            isPresented: Binding(
                get: { keyPendingDeletion != nil },
                set: { if !$0 { keyPendingDeletion = nil } }
            ),
            presenting: keyPendingDeletion
        ) { key in
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "删除"), role: .destructive) {
                deleteKey(key)
            }
            .disabled(isDeleting)
        } message: { key in
            Text(String(localized: "将从 Redis DB \(selectedDatabase) 永久删除“\(key)”。此操作没有自动备份，且无法撤销。"))
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            compactToolbar
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 52)
    }

    private var fullToolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: onClose) {
                Label(String(localized: "返回数据库列表"), systemImage: "chevron.left")
            }
            .controlSize(.small)
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Redis")
                    .font(Theme.Font.bodyMedium)
                Text(snapshot.map { String(localized: "\($0.totalKeyCount) 个键 · \($0.usedMemory ?? "—")") }
                    ?? String(localized: "正在读取运行信息"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button {
                showsCredentialEditor = true
            } label: {
                Label(credential == nil ? String(localized: "认证") : String(localized: "已认证"), systemImage: credential == nil ? "key" : "key.fill")
            }
            .controlSize(.small)
            .help(String(localized: "Redis ACL 用户名和密码仅保存在本机 Keychain"))
            Button {
                session.requestDatabaseBackup(database)
            } label: {
                Label(String(localized: "备份"), systemImage: "externaldrive.badge.timemachine")
            }
            .controlSize(.small)
            Button {
                session.openRedisLogs()
            } label: {
                Label(String(localized: "日志"), systemImage: "doc.text.magnifyingglass")
            }
            .controlSize(.small)
            Button {
                session.openWorkbenchModule("services")
            } label: {
                Label(String(localized: "服务"), systemImage: "switch.2")
            }
            .controlSize(.small)
            Button {
                Task { await reloadAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isLoadingSnapshot || isLoadingKeys)
            .help(String(localized: "刷新 Redis"))
            .accessibilityLabel(String(localized: "刷新 Redis"))
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
            }
            .controlSize(.small)
            .help(String(localized: "返回数据库列表"))
            .accessibilityLabel(String(localized: "返回数据库列表"))
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Redis").font(Theme.Font.bodyMedium)
                Text(snapshot.map { String(localized: "\($0.totalKeyCount) 个键 · \($0.usedMemory ?? "—")") } ?? String(localized: "正在读取运行信息"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button {
                showsCredentialEditor = true
            } label: {
                Image(systemName: credential == nil ? "key" : "key.fill")
            }
            .controlSize(.small)
            .help(credential == nil ? String(localized: "设置认证") : String(localized: "已认证"))
            .accessibilityLabel(credential == nil ? String(localized: "设置认证") : String(localized: "已认证"))
            Menu {
                Button {
                    session.requestDatabaseBackup(database)
                } label: {
                    Label(String(localized: "备份"), systemImage: "externaldrive.badge.timemachine")
                }
                Button {
                    session.openRedisLogs()
                } label: {
                    Label(String(localized: "日志"), systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    session.openWorkbenchModule("services")
                } label: {
                    Label(String(localized: "服务"), systemImage: "switch.2")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help(String(localized: "Redis 运维操作"))
            Button {
                Task { await reloadAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isLoadingSnapshot || isLoadingKeys)
            .help(String(localized: "刷新 Redis"))
            .accessibilityLabel(String(localized: "刷新 Redis"))
        }
    }

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            OpsSectionHeader(title: String(localized: "运行概览"), detail: snapshotStatusDetail)
            if isLoadingSnapshot && snapshot == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 68)
            } else if let snapshot {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: Theme.Space.lg)],
                    alignment: .leading,
                    spacing: Theme.Space.sm
                ) {
                    RedisMetric(label: String(localized: "版本"), value: snapshot.version ?? "—")
                    RedisMetric(label: String(localized: "内存"), value: snapshot.usedMemory ?? "—", detail: snapshot.maxMemory.map { String(localized: "上限 \($0)") })
                    RedisMetric(label: String(localized: "客户端"), value: "\(snapshot.connectedClients)", detail: snapshot.blockedClients > 0 ? String(localized: "\(snapshot.blockedClients) 个阻塞") : nil)
                    RedisMetric(label: String(localized: "命中率"), value: snapshot.hitRate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                    RedisMetric(label: String(localized: "运行时间"), value: String(localized: "\(snapshot.uptimeDays) 天"))
                    RedisMetric(label: String(localized: "累计命令"), value: snapshot.totalCommands.formatted())
                    RedisMetric(label: String(localized: "淘汰策略"), value: snapshot.maxMemoryPolicy ?? "—")
                    RedisMetric(
                        label: String(localized: "持久化"),
                        value: snapshot.persistenceBusy ? String(localized: "进行中") : String(localized: "就绪"),
                        detail: snapshot.aofEnabled ? "AOF + RDB" : "RDB"
                    )
                }
                .padding(.horizontal, Theme.Space.sm)
            }
        }
    }

    private var keyspace: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                OpsSectionHeader(title: String(localized: "键空间"), detail: String(localized: "每页最多 \(RedisManagerService.pageSize) 个键"))
                Spacer()
                Button {
                    stringEditor = RedisStringEditorContext(key: nil, value: "", preservesTTL: false)
                } label: {
                    Label(String(localized: "新增 String 键"), systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(snapshot == nil)
            }
            HStack(spacing: Theme.Space.sm) {
                Picker(String(localized: "逻辑数据库"), selection: $selectedDatabase) {
                    ForEach(databaseIndices, id: \.self) { index in
                        Text(databaseLabel(index)).tag(index)
                    }
                }
                .frame(width: 160)
                .onChange(of: selectedDatabase) { _, _ in
                    Task { await reloadKeys(resetPaging: true) }
                }
                TextField(String(localized: "搜索键名"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await reloadKeys(resetPaging: true) } }
                Button(String(localized: "搜索")) {
                    Task { await reloadKeys(resetPaging: true) }
                }
                .controlSize(.small)
                Button {
                    Task { await reloadKeys(resetPaging: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isLoadingKeys)
                .help(String(localized: "刷新当前键空间"))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    keyList
                        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 310, maxHeight: 430)
                    Divider()
                    keyDetailPanel
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 430, minHeight: 310, maxHeight: 430)
                }
                VStack(spacing: 0) {
                    keyList
                        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 320)
                    Divider()
                    keyDetailPanel
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 320)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).stroke(Theme.Color.separator.opacity(0.7)))
            pagination
        }
    }

    private var keyList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "键名")).frame(maxWidth: .infinity, alignment: .leading)
                Text(String(localized: "类型")).frame(width: 70, alignment: .leading)
                Text("TTL").frame(width: 74, alignment: .trailing)
                Text(String(localized: "内存")).frame(width: 70, alignment: .trailing)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 30)
            .background(Theme.Color.surfaceRaised)
            Divider()
            if isLoadingKeys && keys.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if keys.isEmpty {
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text(searchText.isEmpty ? String(localized: "此逻辑数据库暂无键") : String(localized: "没有匹配的键"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(keys) { key in
                            Button {
                                selectedKey = key.name
                                Task { await loadDetail(for: key.name) }
                            } label: {
                                RedisKeyRow(key: key, selected: selectedKey == key.name)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Theme.Color.separator.opacity(0.35))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var keyDetailPanel: some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = keyDetail {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.key)
                            .font(Theme.Font.mono)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text("\(detail.type) · \(detail.logicalSize.formatted())")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                    Menu {
                        if detail.type == "string" {
                            Button(String(localized: "编辑值")) {
                                stringEditor = RedisStringEditorContext(
                                    key: detail.key,
                                    value: detail.entries.first?.value ?? "",
                                    preservesTTL: detail.ttlSeconds > 0
                                )
                            }
                        }
                        Button(String(localized: "设置 TTL")) {
                            ttlEditor = RedisTTLEditorContext(key: detail.key, currentTTL: detail.ttlSeconds)
                        }
                        Divider()
                        Button(String(localized: "删除键"), role: .destructive) {
                            keyPendingDeletion = detail.key
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help(String(localized: "键操作"))
                }
                HStack(spacing: Theme.Space.xs) {
                    OpsStatusPill(text: detail.type, color: Theme.Color.accent)
                    Text(ttlLabel(detail.ttlSeconds))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ForEach(detail.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Color.textSecondary)
                                Text(entry.value)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if detail.entries.isEmpty {
                            Text(String(localized: "该类型暂不提供值预览，可在终端中使用 redis-cli 查看。"))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        if detail.isTruncated {
                            Text(String(localized: "仅显示前 100 项，避免大键阻塞界面。"))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Color.warning)
                        }
                    }
                }
            }
            .padding(Theme.Space.sm)
        } else {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.Color.textTertiary)
                Text(String(localized: "选择一个键查看值、TTL 和操作"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pagination: some View {
        HStack {
            Text(String(localized: "本页 \(keys.count) 个键"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            if isLoadingKeys { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                guard let previous = cursorHistory.popLast() else { return }
                currentCursor = previous
                Task { await loadKeys(cursor: previous) }
            } label: {
                Label(String(localized: "上一页"), systemImage: "chevron.left")
            }
            .controlSize(.small)
            .disabled(cursorHistory.isEmpty || isLoadingKeys)
            Button {
                guard nextCursor != "0" else { return }
                cursorHistory.append(currentCursor)
                currentCursor = nextCursor
                Task { await loadKeys(cursor: nextCursor) }
            } label: {
                Label(String(localized: "下一页"), systemImage: "chevron.right")
            }
            .controlSize(.small)
            .disabled(nextCursor == "0" || isLoadingKeys)
        }
    }

    private var databaseIndices: [Int] {
        Array(0..<(snapshot?.configuredDatabaseCount ?? 16))
    }

    private func databaseLabel(_ index: Int) -> String {
        let count = snapshot?.databases.first(where: { $0.index == index })?.keyCount ?? 0
        return "DB \(index) · \(count)"
    }

    private var snapshotStatusDetail: String {
        guard let snapshot else { return isLoadingSnapshot ? String(localized: "正在加载") : String(localized: "未加载") }
        let mode = snapshot.mode ?? String(localized: "单机")
        return "\(mode) · \(snapshot.totalConnections.formatted()) \(String(localized: "次连接"))"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Color.warning)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
                .textSelection(.enabled)
            Spacer()
            if message.localizedCaseInsensitiveContains("认证") || message.localizedCaseInsensitiveContains("auth") {
                Button(String(localized: "设置认证")) { showsCredentialEditor = true }
                    .controlSize(.small)
            }
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "关闭错误提示"))
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: 36)
        .background(Theme.Color.warning.opacity(0.10))
    }

    @MainActor
    private func reloadAll() async {
        guard !isLoadingSnapshot else { return }
        isLoadingSnapshot = true
        errorMessage = nil
        defer { isLoadingSnapshot = false }
        do {
            let loaded = try await session.redisLoadSnapshot(credential: credential)
            snapshot = loaded
            if !databaseIndices.contains(selectedDatabase) { selectedDatabase = 0 }
            await reloadKeys(resetPaging: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadKeys(resetPaging: Bool) async {
        if resetPaging {
            currentCursor = "0"
            nextCursor = "0"
            cursorHistory = []
        }
        await loadKeys(cursor: currentCursor)
    }

    @MainActor
    private func loadKeys(cursor: String) async {
        guard !isLoadingKeys else { return }
        isLoadingKeys = true
        errorMessage = nil
        selectedKey = nil
        keyDetail = nil
        detailRequestID = nil
        isLoadingDetail = false
        defer { isLoadingKeys = false }
        do {
            let pattern = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = try await session.redisScanKeys(
                database: selectedDatabase,
                cursor: cursor,
                pattern: pattern.isEmpty ? "*" : "*\(pattern)*",
                credential: credential
            )
            keys = page.keys
            nextCursor = page.nextCursor
        } catch {
            keys = []
            nextCursor = "0"
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadDetail(for key: String) async {
        let requestID = UUID()
        detailRequestID = requestID
        isLoadingDetail = true
        errorMessage = nil
        defer {
            if detailRequestID == requestID {
                isLoadingDetail = false
            }
        }
        do {
            let detail = try await session.redisLoadKeyDetail(
                database: selectedDatabase,
                key: key,
                credential: credential
            )
            guard detailRequestID == requestID, selectedKey == key else { return }
            keyDetail = detail
        } catch {
            guard detailRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteKey(_ key: String) {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false; keyPendingDeletion = nil }
            do {
                try await session.redisDeleteKey(database: selectedDatabase, key: key, credential: credential)
                await reloadKeys(resetPaging: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func ttlLabel(_ ttl: Int) -> String {
        if ttl == -1 { return String(localized: "永久") }
        if ttl == -2 { return String(localized: "已不存在") }
        return String(localized: "TTL \(ttl) 秒")
    }
}

private struct RedisMetric: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RedisKeyRow: View {
    let key: RedisKeySummary
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: iconName)
                    .foregroundStyle(Theme.Color.accent)
                    .frame(width: 16)
                Text(key.name)
                    .font(Theme.Font.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(key.type)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(ttlText)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 74, alignment: .trailing)
            Text(memoryText)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 34)
        .background(selected ? Theme.Color.rowSelected : SwiftUI.Color.clear)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch key.type {
        case "string": return "textformat"
        case "hash": return "number.square"
        case "list": return "list.number"
        case "set": return "square.stack.3d.up"
        case "zset": return "arrow.up.arrow.down"
        case "stream": return "waveform.path.ecg"
        default: return "key"
        }
    }

    private var ttlText: String {
        if key.ttlSeconds == -1 { return "∞" }
        if key.ttlSeconds < 0 { return "—" }
        return "\(key.ttlSeconds)s"
    }

    private var memoryText: String {
        guard let memory = key.memoryBytes else { return "—" }
        return ByteCountFormatter.opsSizeFormatter.string(fromByteCount: Int64(memory))
    }
}

private struct RedisCredentialEditorSheet: View {
    @EnvironmentObject private var session: ServerSession
    let initial: RedisCredential?
    let onSaved: (RedisCredential?) -> Void
    let onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "Redis 认证"))
                .font(Theme.Font.windowTitle)
            Text(String(localized: "适用于 requirepass 或 ACL。密码仅保存在本机 Keychain，不会进入命令历史和诊断导出。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(String(localized: "ACL 用户名（可选）"), text: $username)
                SecureField(String(localized: "密码"), text: $password)
            }
            .formStyle(.grouped)
            if let errorMessage {
                Text(errorMessage).font(Theme.Font.caption).foregroundStyle(Theme.Color.danger)
            }
            HStack {
                if initial != nil {
                    Button(String(localized: "清除认证"), role: .destructive) {
                        save(nil)
                    }
                }
                Spacer()
                Button(String(localized: "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "保存")) {
                    save(RedisCredential(username: username, password: password))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .onAppear {
            username = initial?.username ?? ""
            password = initial?.password ?? ""
        }
    }

    private func save(_ value: RedisCredential?) {
        do {
            try session.redisSaveCredential(value)
            onSaved(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RedisStringEditorSheet: View {
    @EnvironmentObject private var session: ServerSession
    let context: RedisStringEditorContext
    let database: Int
    let credential: RedisCredential?
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var key = ""
    @State private var value = ""
    @State private var preservesTTL = false
    @State private var showsConfirmation = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(context.key == nil ? String(localized: "新增 String 键") : String(localized: "编辑 String 值"))
                .font(Theme.Font.windowTitle)
            if showsConfirmation {
                Label(String(localized: "确认修改 Redis 数据"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.warning)
                Text(String(localized: "目标：DB \(database) · \(key)"))
                    .font(Theme.Font.body)
                Text("SET \(key) ••••••••")
                    .font(Theme.Font.monoSmall)
                    .textSelection(.enabled)
                    .padding(Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
                Text(String(localized: "值已隐藏且不会写入操作历史。此操作没有自动备份；同名键会被覆盖。"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            } else {
                TextField(String(localized: "键名"), text: $key)
                    .disabled(context.key != nil)
                Text(String(localized: "值"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                TextEditor(text: $value)
                    .font(Theme.Font.mono)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.Color.separator))
                if context.key != nil {
                    Toggle(String(localized: "保留当前 TTL"), isOn: $preservesTTL)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(Theme.Font.caption).foregroundStyle(Theme.Color.danger)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                if showsConfirmation {
                    Button(String(localized: "返回编辑")) { showsConfirmation = false }
                        .disabled(isSaving)
                    Button(String(localized: "确认保存")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                } else {
                    Button(String(localized: "继续")) { showsConfirmation = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(key.isEmpty)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 520)
        .onAppear {
            key = context.key ?? ""
            value = context.value
            preservesTTL = context.preservesTTL
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await session.redisSetString(
                    database: database,
                    key: key,
                    value: value,
                    preserveTTL: preservesTTL,
                    credential: credential
                )
                onSaved()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RedisTTLEditorSheet: View {
    @EnvironmentObject private var session: ServerSession
    let context: RedisTTLEditorContext
    let database: Int
    let credential: RedisCredential?
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var isPersistent = false
    @State private var secondsText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(String(localized: "设置 TTL"))
                .font(Theme.Font.windowTitle)
            Text("DB \(database) · \(context.key)")
                .font(Theme.Font.monoSmall)
                .textSelection(.enabled)
            Toggle(String(localized: "永久保留（移除 TTL）"), isOn: $isPersistent)
            TextField(String(localized: "过期秒数"), text: $secondsText)
                .disabled(isPersistent)
            Text(String(localized: "保存后立即生效。过期键会由 Redis 自动删除，此操作无法撤销。"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            if let errorMessage {
                Text(errorMessage).font(Theme.Font.caption).foregroundStyle(Theme.Color.danger)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(String(localized: "确认保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || (!isPersistent && Int(secondsText) == nil))
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .onAppear {
            isPersistent = context.currentTTL == -1
            secondsText = context.currentTTL > 0 ? "\(context.currentTTL)" : "3600"
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await session.redisSetTTL(
                    database: database,
                    key: context.key,
                    seconds: isPersistent ? nil : Int(secondsText),
                    credential: credential
                )
                onSaved()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Firewall pane

private enum FirewallRuleEditorMode: Identifiable {
    case add
    case edit(FirewallRule)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let r): return r.id.uuidString
        }
    }
    var editingRule: FirewallRule? {
        if case .edit(let r) = self { return r }
        return nil
    }
}

private struct FirewallPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var ruleEditor: FirewallRuleEditorMode?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                OpsSectionHeader(title: "防火墙", detail: detailText)

                if session.isFirewallLoading && (session.firewallSnapshot == nil || session.firewallSnapshot?.kind == FirewallKind.none) {
                    OpsSkeletonRows()
                } else if let snapshot = session.firewallSnapshot, snapshot.kind != .none {
                    statusBar(snapshot)
                    addRuleBar
                    rulesSection(snapshot)
                    rawFallback(snapshot)
                } else {
                    WorkbenchEmptyOrActivity(moduleID: "firewall", failedTitle: String(localized: "安装失败")) {
                        OpsEmptyState(
                            systemImage: "lock.shield",
                            title: "未检测到防火墙",
                            detail: "服务器上没有 UFW 或 firewalld。可在安装器中安装 UFW（Debian/Ubuntu）或 firewalld（RHEL/Fedora）。"
                        ) {
                            if let ufw = appState.toolCatalog.first(where: { $0.id == "ufw" }) {
                                Button {
                                    session.requestInstallTool(ufw)
                                } label: {
                                    Label("安装 UFW", systemImage: "plus.circle")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.firewallSnapshot == nil && !session.isFirewallLoading {
                session.refreshFirewall()
            }
        }
        .sheet(item: $ruleEditor) { mode in
            FirewallRuleEditor(editing: mode.editingRule)
                .environmentObject(appState)
                .environmentObject(session)
        }
    }

    private var addRuleBar: some View {
        HStack {
            Button {
                ruleEditor = .add
            } label: {
                Label("添加规则", systemImage: "plus")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    @ViewBuilder
    private func statusBar(_ snapshot: FirewallSnapshot) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "lock.shield")
                .foregroundStyle(snapshot.active ? Theme.Color.success : Theme.Color.warning)
            Text(snapshot.kind.displayName)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            OpsStatusPill(text: snapshot.active ? String(localized: "已启用") : String(localized: "未启用"), color: snapshot.active ? Theme.Color.success : Theme.Color.warning)
            Spacer()
            Toggle("禁ping", isOn: Binding(
                get: { snapshot.pingBlocked },
                set: { session.requestFirewallSetPingBlocked($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("丢弃 ICMP echo，服务器不再响应 ping")
            Button(snapshot.active ? String(localized: "禁用防火墙") : String(localized: "启用防火墙")) {
                session.requestFirewallToggle(enable: !snapshot.active)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func rulesSection(_ snapshot: FirewallSnapshot) -> some View {
        // One logical list (from `ufw show added`) whether active or not. When the
        // firewall is off, these rules are queued (待生效) and apply once enabled.
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            OpsSectionHeader(title: "端口规则", detail: snapshot.rules.isEmpty ? "" : String(localized: "\(snapshot.rules.count) 条"))
            if !snapshot.active && !snapshot.rules.isEmpty {
                Text("防火墙未启用——以下规则已添加但尚未生效，点「启用防火墙」后才会拦截/放行。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                    .padding(.horizontal, Theme.Space.sm)
            }
            if snapshot.rules.isEmpty {
                Text(snapshot.active
                        ? String(localized: "暂无规则。")
                        : String(localized: "防火墙未启用，暂无规则。添加的放行/拒绝规则会在这里列出，启用后才真正生效。"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(.horizontal, Theme.Space.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.rules) { rule in
                        FirewallRuleRow(rule: rule, pending: !snapshot.active, onEdit: { ruleEditor = .edit(rule) }) {
                            session.requestFirewallDeleteRuleSpec(rule.raw)
                        }
                        Divider().overlay(Theme.Color.separator.opacity(0.45))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rawFallback(_ snapshot: FirewallSnapshot) -> some View {
        DisclosureGroup("原始 ufw status 输出") {
            Text(snapshot.detail)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.xs)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Color.textSecondary)
    }

    private var detailText: String {
        guard let snapshot = session.firewallSnapshot else { return String(localized: "未加载") }
        if snapshot.kind == .none { return String(localized: "未安装") }
        let ping = snapshot.pingBlocked ? String(localized: " · 已禁ping") : ""
        let countLabel = snapshot.active ? String(localized: "\(snapshot.rules.count) 条规则") : String(localized: "\(snapshot.rules.count) 条待生效")
        return "\(snapshot.kind.displayName) · \(snapshot.active ? String(localized: "已启用") : String(localized: "未启用")) · \(countLabel)\(ping)"
    }
}

private struct FirewallRuleRow: View {
    let rule: FirewallRule
    var pending: Bool = false
    var onEdit: () -> Void = {}
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if pending {
                Text("待生效")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                    .lineLimit(1).fixedSize()
                    .frame(width: 48, alignment: .leading)
            } else {
                Circle()
                    .fill(Theme.Color.success)
                    .frame(width: 6, height: 6)
                    .frame(width: 48, alignment: .leading)
            }
            Text(rule.action.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(rule.action == .allow ? Theme.Color.success : Theme.Color.danger))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(portLabel)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(rule.direction.displayName)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                    if rule.isV6 {
                        Text("v6").font(Theme.Font.caption).foregroundStyle(Theme.Color.textTertiary)
                    }
                }
                Text("来源 \(rule.source)\(rule.comment.isEmpty ? "" : " · \(rule.comment)")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑此规则")
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除此规则")
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 44)
    }

    private var portLabel: String {
        let p = rule.port.isEmpty ? String(localized: "整机") : rule.port
        return rule.proto == "any" ? p : "\(p)/\(rule.proto)"
    }
}

/// Modal used for both adding and editing a firewall rule (宝塔-style). Editing an
/// existing rule maps to delete-then-add (UFW has no in-place edit).
/// Form-based new-site builder (宝塔-style): pick reverse-proxy or static, then
/// create → enable → optional SSL in one runbook.
private struct NginxNewSiteForm: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss

    @State private var domain = ""
    @State private var type: NginxSiteType = .reverseProxy
    @State private var upstreamPortText = "3000"
    @State private var staticRoot = ""
    @State private var createRoot = true
    @State private var enableNow = true
    @State private var requestSSL = false
    @State private var staging = false

    private var domains: [String] {
        domain.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }
    private var effectiveRoot: String {
        let trimmed = staticRoot.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "/var/www/\(domains.first ?? "site")" : trimmed
    }
    private var isValid: Bool {
        guard !domains.isEmpty else { return false }
        return type == .staticSite || Int(upstreamPortText) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("新建站点")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                label("域名（多个用空格分隔）")
                TextField("example.com www.example.com", text: $domain)
                    .textFieldStyle(.roundedBorder)

                Picker("类型", selection: $type) {
                    ForEach(NginxSiteType.allCases) { t in Text(t.displayName).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if type == .reverseProxy {
                    label("反向代理到本机端口")
                    TextField("3000", text: $upstreamPortText)
                        .textFieldStyle(.roundedBorder)
                } else {
                    label("网站根目录")
                    TextField(effectiveRoot, text: $staticRoot)
                        .textFieldStyle(.roundedBorder)
                    Toggle(isOn: $createRoot) {
                        Text("根目录不存在则自动创建").font(Theme.Font.caption)
                    }
                    .toggleStyle(.checkbox)
                }

                Toggle(isOn: $enableNow) {
                    Text("创建后立即启用").font(Theme.Font.caption)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $requestSSL) {
                    Text("创建后申请 SSL 证书（需域名已解析到本机、80 端口可达）").font(Theme.Font.caption)
                }
                .toggleStyle(.checkbox)

                if requestSSL {
                    Toggle(isOn: $staging) {
                        Text("先用测试证书（staging，不受速率限制，浏览器不信任）").font(Theme.Font.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    // Capture values, dismiss, then present the runbook next tick to
                    // avoid the sheet-over-sheet modal race.
                    let d = domains, ty = type, port = Int(upstreamPortText) ?? 3000
                    let root = effectiveRoot, cRoot = createRoot
                    let en = enableNow, ssl = requestSSL, stg = staging
                    dismiss()
                    DispatchQueue.main.async {
                        session.requestCreateNginxSite(domains: d, type: ty, upstreamPort: port, staticRoot: root, createRoot: cRoot, enable: en, requestSSL: ssl, staging: stg)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
    }

    @ViewBuilder private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.Color.textSecondary)
    }
}

private struct FirewallRuleEditor: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    let editing: FirewallRule?

    @State private var action: FirewallAction
    @State private var direction: FirewallDirection
    @State private var proto: String
    @State private var ports: String
    @State private var source: String
    @State private var comment: String

    init(editing: FirewallRule?) {
        self.editing = editing
        _action = State(initialValue: editing?.action ?? .allow)
        _direction = State(initialValue: editing?.direction ?? .inbound)
        _proto = State(initialValue: {
            guard let p = editing?.proto else { return "tcp" }
            return (p == "tcp" || p == "udp") ? p : "both"
        }())
        _ports = State(initialValue: editing?.port ?? "")
        _source = State(initialValue: {
            guard let s = editing?.source, s.lowercased() != "anywhere" else { return "" }
            return s
        }())
        _comment = State(initialValue: editing?.comment ?? "")
    }

    private var isValid: Bool { !ports.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(editing == nil ? String(localized: "添加端口规则") : String(localized: "编辑端口规则"))
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Divider().overlay(Theme.Color.separator)

            field(String(localized: "策略")) {
                Picker("", selection: $action) {
                    ForEach(FirewallAction.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            field(String(localized: "方向")) {
                Picker("", selection: $direction) {
                    ForEach(FirewallDirection.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            field(String(localized: "协议")) {
                Picker("", selection: $proto) {
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("TCP/UDP").tag("both")
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 140)
            }
            field(String(localized: "端口")) {
                TextField("如 8080 / 80,443 / 6000:6100", text: $ports).textFieldStyle(.roundedBorder)
            }
            field(String(localized: "来源")) {
                TextField("空=任意，如 203.0.113.7 或 10.0.0.0/24", text: $source).textFieldStyle(.roundedBorder)
            }
            field(String(localized: "备注")) {
                TextField("可为空", text: $comment).textFieldStyle(.roundedBorder)
            }

            Text("协议「TCP/UDP」表示两者都放行；端口支持单个、逗号多个、冒号范围。填「来源」即为按 IP 放行/封禁。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
            if editing != nil {
                Text("UFW 不能原地改规则，保存时会先删除旧规则再按新参数添加。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
            }

            Divider().overlay(Theme.Color.separator)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(editing == nil ? String(localized: "添加") : String(localized: "保存")) {
                    // Capture the field values, dismiss this editor sheet, then present
                    // the runbook on the next runloop tick. A window shows only one sheet;
                    // swapping the editor out and the runbook in within the same update can
                    // drop the incoming runbook sheet (same class as the save-over-sheet bug).
                    let editingRule = editing
                    let a = action, d = direction, p = proto, po = ports, s = source, c = comment
                    dismiss()
                    DispatchQueue.main.async {
                        if let editingRule {
                            session.requestFirewallEditRule(old: editingRule, action: a, direction: d, proto: p, ports: po, source: s, comment: c)
                        } else {
                            session.requestFirewallAddRule(action: a, direction: d, proto: p, ports: po, source: s, comment: c)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 440)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 48, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - PM2 pane

private struct PM2Pane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @State private var showsStartSheet = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    OpsSectionHeader(title: "PM2 进程", detail: detailText)
                    Spacer()
                    if session.pm2Snapshot?.installed == true {
                        Button {
                            showsStartSheet = true
                        } label: {
                            Label("启动应用", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }
                }

                if session.isPM2Loading && session.pm2Snapshot?.installed != true {
                    OpsSkeletonRows()
                } else if let snapshot = session.pm2Snapshot, snapshot.installed, !snapshot.processes.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(snapshot.processes) { process in
                            PM2ProcessRow(process: process)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                } else if session.pm2Snapshot?.installed == true {
                    OpsEmptyState(
                        systemImage: "cpu",
                        title: "PM2 已安装，但没有进程",
                        detail: "用 pm2 start 启动应用后会显示在这里。"
                    )
                } else {
                    WorkbenchEmptyOrActivity(moduleID: "pm2", failedTitle: String(localized: "安装失败")) {
                        OpsEmptyState(
                            systemImage: "cpu",
                            title: "未检测到 PM2",
                            detail: "PM2 用于常驻 Node 应用。可在安装器中安装（需要先有 Node）。"
                        ) {
                            if let pm2 = appState.toolCatalog.first(where: { $0.id == "pm2" }) {
                                Button {
                                    session.requestInstallTool(pm2)
                                } label: {
                                    Label("安装 PM2", systemImage: "plus.circle")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.pm2Snapshot == nil && !session.isPM2Loading {
                session.refreshPM2()
            }
        }
        .sheet(isPresented: $showsStartSheet) {
            PM2StartSheet()
                .environmentObject(session)
        }
    }

    private var detailText: String {
        guard let snapshot = session.pm2Snapshot else { return String(localized: "未加载") }
        if !snapshot.installed { return String(localized: "未安装") }
        let online = snapshot.processes.filter(\.isOnline).count
        return String(localized: "\(snapshot.processes.count) 个进程 · \(online) 个在线")
    }
}

private struct PM2StartSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scriptPath = ""
    @State private var workingDirectory = ""

    var body: some View {
        OperationInputSheet(
            title: String(localized: "用 PM2 启动应用"),
            detail: String(localized: "填写服务器上的绝对脚本路径。OpsDeck 会运行 pm2 start 并保存进程列表。"),
            confirmTitle: String(localized: "预览启动计划"),
            isValid: !name.isEmpty && scriptPath.hasPrefix("/")
        ) {
            TextField("应用名称", text: $name)
            TextField("脚本绝对路径，例如 /var/www/app/server.js", text: $scriptPath)
            TextField("工作目录（可选）", text: $workingDirectory)
        } onConfirm: {
            let captured = (name, scriptPath, workingDirectory)
            dismiss()
            DispatchQueue.main.async {
                session.requestPM2Start(name: captured.0, scriptPath: captured.1, workingDirectory: captured.2)
            }
        }
    }
}

private struct PM2ProcessRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let process: PM2Process

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: process.isOnline ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(process.isOnline ? Theme.Color.success : Theme.Color.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text("CPU \(process.cpu) · 内存 \(process.memory) · 重启 \(process.restarts) 次")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            OpsStatusPill(text: process.status, color: process.isOnline ? Theme.Color.success : Theme.Color.warning)
            Menu {
                Button("重启") { session.requestPM2Action(.restart, process: process) }
                Button("停止") { session.requestPM2Action(.stop, process: process) }
                Button("查看日志") { session.openPM2Logs(process) }
                Divider()
                Button(role: .destructive) {
                    session.requestPM2Delete(process)
                } label: {
                    Label("从 PM2 移除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
    }
}

// MARK: - Certbot / SSL pane

private struct CertbotPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    OpsSectionHeader(title: "SSL 证书", detail: detailText)
                    Spacer()
                    if session.certbotSnapshot?.installed == true {
                        Button {
                            session.requestCertRenew(certName: nil, dryRun: true)
                        } label: {
                            Label("测试续期", systemImage: "checkmark.seal")
                        }
                        .controlSize(.small)
                        .help("certbot renew --dry-run，只演练不签发")
                        Button {
                            session.requestCertRenew(certName: nil, dryRun: false)
                        } label: {
                            Label("续期全部", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }

                if session.certbotSnapshot?.installed == true {
                    CertObtainForm()
                }

                if session.isCertbotLoading && session.certbotSnapshot?.installed != true {
                    OpsSkeletonRows()
                } else if let snapshot = session.certbotSnapshot, snapshot.installed, !snapshot.certificates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(snapshot.certificates) { cert in
                            CertRow(cert: cert)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                } else if session.certbotSnapshot?.installed == true {
                    OpsEmptyState(
                        systemImage: "checkmark.seal",
                        title: "Certbot 已安装，但没有证书",
                        detail: "用 certbot --nginx 或 certbot certonly 申请证书后会显示在这里。"
                    )
                } else {
                    WorkbenchEmptyOrActivity(moduleID: "certbot", failedTitle: String(localized: "安装失败")) {
                        OpsEmptyState(
                            systemImage: "checkmark.seal",
                            title: "未检测到 Certbot",
                            detail: "Certbot 用于申请与续期 Let's Encrypt 免费证书。可在安装器中安装。"
                        ) {
                            if let certbot = appState.toolCatalog.first(where: { $0.id == "certbot" }) {
                                Button {
                                    session.requestInstallTool(certbot)
                                } label: {
                                    Label("安装 Certbot", systemImage: "plus.circle")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.certbotSnapshot == nil && !session.isCertbotLoading {
                session.refreshCertificates()
            }
        }
    }

    private var detailText: String {
        guard let snapshot = session.certbotSnapshot else { return String(localized: "未加载") }
        if !snapshot.installed { return String(localized: "未安装") }
        return String(localized: "\(snapshot.certificates.count) 张证书")
    }
}

private struct CertObtainForm: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var domain = ""
    @State private var method: CertbotMethod = .nginx
    @State private var email = ""
    @State private var staging = false
    @State private var cloudflareToken = ""

    private var connected: Bool { session.connectionStatus == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("申请新证书")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            TextField("域名（多个用空格分隔），如 test.example.com", text: $domain)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: Theme.Space.sm) {
                Picker("方式", selection: $method) {
                    ForEach(CertbotMethod.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                TextField("邮箱（可选，用于到期提醒）", text: $email)
                    .textFieldStyle(.roundedBorder)
            }

            Text(method.detail)
                .font(Theme.Font.tiny)
                .foregroundStyle(method == .dnsCloudflare ? Theme.Color.success : Theme.Color.textTertiary)

            if method == .dnsCloudflare {
                SecureField("Cloudflare API Token（权限 Zone.DNS:Edit）", text: $cloudflareToken)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Toggle(isOn: $staging) {
                    Text("测试证书（staging，不受速率限制）")
                        .font(Theme.Font.caption)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button {
                    let domains = domain.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                    session.requestObtainCert(domains: domains, method: method, email: email, staging: staging, cloudflareToken: method == .dnsCloudflare ? cloudflareToken : nil)
                } label: {
                    Label("申请证书", systemImage: "checkmark.seal.fill")
                }
                .controlSize(.small)
                .disabled(!connected || domain.trimmingCharacters(in: .whitespaces).isEmpty || (method == .dnsCloudflare && cloudflareToken.trimmingCharacters(in: .whitespaces).isEmpty))
            }

            Text(method.usesHTTP
                 ? String(localized: "前置：域名 DNS 指向本机公网 IP、80 端口开放。⚠️ 大陆未备案服务器 80 端口会被云厂商拦截（返回备案页），此时请改用「DNS 验证」。")
                 : String(localized: "前置：域名托管在 Cloudflare，已建好 API Token。DNS 验证不走 80 端口，大陆未备案也能签，且可保持橙色云代理。"))
                .font(Theme.Font.tiny)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
    }
}

private struct CertRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let cert: CertInfo

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "lock.doc")
                .foregroundStyle(expiryColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(cert.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(cert.domains)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let days = cert.validDays {
                OpsStatusPill(text: String(localized: "剩 \(days) 天"), color: expiryColor)
            }
            Menu {
                Button("测试续期") { session.requestCertRenew(certName: cert.name, dryRun: true) }
                Button("续期此证书") { session.requestCertRenew(certName: cert.name, dryRun: false) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 52)
    }

    private var expiryColor: SwiftUI.Color {
        guard let days = cert.validDays, let value = Int(days) else { return Theme.Color.textSecondary }
        if value <= 7 { return Theme.Color.danger }
        if value <= 30 { return Theme.Color.warning }
        return Theme.Color.success
    }
}

// MARK: - Caddy pane

private struct CaddyPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                OpsSectionHeader(title: "Caddy 配置", detail: detailText)
                if session.isCaddyLoading && session.caddySnapshot?.installed != true {
                    OpsSkeletonRows()
                } else if let snapshot = session.caddySnapshot, snapshot.installed {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(snapshot.active ? Theme.Color.success : Theme.Color.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.version ?? "Caddy")
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text(snapshot.configPath ?? String(localized: "未识别 Caddyfile 路径"))
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        OpsStatusPill(text: snapshot.active ? String(localized: "运行中") : String(localized: "未运行"), color: snapshot.active ? Theme.Color.success : Theme.Color.warning)
                        Button {
                            session.openCaddyConfig()
                        } label: {
                            Label("编辑 Caddyfile", systemImage: "pencil")
                        }
                        .controlSize(.small)
                        .disabled(snapshot.configPath == nil)
                        Button {
                            session.requestCaddyValidate()
                        } label: {
                            Label("校验", systemImage: "checkmark.seal")
                        }
                        .controlSize(.small)
                        Button {
                            session.requestCaddyReload()
                        } label: {
                            Label("重载", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .controlSize(.small)
                    }
                    .padding(Theme.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised)
                    )
                } else {
                    WorkbenchEmptyOrActivity(moduleID: "caddy", failedTitle: String(localized: "安装失败")) {
                        OpsEmptyState(
                            systemImage: "server.rack",
                            title: "未检测到 Caddy",
                            detail: "Caddy 是自动 HTTPS 的 Web 服务器。可在安装器中安装。"
                        ) {
                            if let caddy = appState.toolCatalog.first(where: { $0.id == "caddy" }) {
                                Button {
                                    session.requestInstallTool(caddy)
                                } label: {
                                    Label("安装 Caddy", systemImage: "plus.circle")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.caddySnapshot == nil && !session.isCaddyLoading {
                session.refreshCaddy()
            }
        }
    }

    private var detailText: String {
        guard let snapshot = session.caddySnapshot else { return String(localized: "未加载") }
        if !snapshot.installed { return String(localized: "未安装") }
        return snapshot.active ? String(localized: "运行中") : String(localized: "已安装 · 未运行")
    }
}

// MARK: - Fail2ban pane

private struct Fail2banPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                OpsSectionHeader(title: "Fail2ban", detail: detailText)
                if session.isFail2banLoading && session.fail2banSnapshot?.installed != true {
                    OpsSkeletonRows()
                } else if let snapshot = session.fail2banSnapshot, snapshot.installed {
                    if snapshot.jails.isEmpty {
                        OpsEmptyState(
                            systemImage: "hand.raised",
                            title: snapshot.active ? String(localized: "Fail2ban 运行中，无 jail") : String(localized: "Fail2ban 未运行"),
                            detail: "在 /etc/fail2ban/jail.local 配置 jail（如 sshd）后会显示在这里。"
                        )
                    } else {
                        ForEach(snapshot.jails) { jail in
                            Fail2banJailCard(jail: jail)
                        }
                    }
                } else {
                    WorkbenchEmptyOrActivity(moduleID: "fail2ban", failedTitle: String(localized: "安装失败")) {
                        OpsEmptyState(
                            systemImage: "hand.raised",
                            title: "未检测到 Fail2ban",
                            detail: "Fail2ban 通过分析日志封禁暴力破解 IP。可在安装器中安装。"
                        ) {
                            if let f2b = appState.toolCatalog.first(where: { $0.id == "fail2ban" }) {
                                Button {
                                    session.requestInstallTool(f2b)
                                } label: {
                                    Label("安装 Fail2ban", systemImage: "plus.circle")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.fail2banSnapshot == nil && !session.isFail2banLoading {
                session.refreshFail2ban()
            }
        }
    }

    private var detailText: String {
        guard let snapshot = session.fail2banSnapshot else { return String(localized: "未加载") }
        if !snapshot.installed { return String(localized: "未安装") }
        let banned = snapshot.jails.reduce(0) { $0 + $1.currentlyBanned }
        return String(localized: "\(snapshot.jails.count) 个 jail · 当前封禁 \(banned)")
    }
}

private struct Fail2banJailCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let jail: Fail2banJail

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(jail.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                OpsStatusPill(text: String(localized: "封禁 \(jail.currentlyBanned)"), color: jail.currentlyBanned > 0 ? Theme.Color.warning : Theme.Color.textTertiary)
                Spacer()
                Text("累计 \(jail.totalBanned)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            if jail.bannedIPs.isEmpty {
                Text("当前无封禁 IP")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            } else {
                ForEach(jail.bannedIPs, id: \.self) { ip in
                    HStack {
                        Text(ip)
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("解封") {
                            session.requestFail2banUnban(jail: jail.name, ip: ip)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised)
        )
    }
}

// MARK: - Cron pane

private struct CronPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    @State private var showsAddSheet = false
    @State private var editingJob: CronJob?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    OpsSectionHeader(title: "定时任务", detail: detailText)
                    Spacer()
                    Button {
                        showsAddSheet = true
                    } label: {
                        Label("新增任务", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                Text("展示用户 crontab 与系统 cron。当前用户任务可新增、编辑、禁用和删除；系统级任务保持只读。所有改动会先生成计划并输出完整 diff。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)

                if session.isCronLoading && session.cronSnapshot == nil {
                    OpsSkeletonRows()
                } else if let snapshot = session.cronSnapshot, !snapshot.jobs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(snapshot.jobs) { job in
                            HStack(alignment: .top, spacing: Theme.Space.sm) {
                                OpsStatusPill(
                                    text: job.enabled ? job.source : String(localized: "已禁用"),
                                    color: job.enabled ? Theme.Color.textTertiary : Theme.Color.warning
                                )
                                Text(job.line)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(job.enabled ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if job.source == "用户" {
                                    Menu {
                                        Button(String(localized: "编辑…")) { editingJob = job }
                                        Button(job.enabled ? String(localized: "禁用") : String(localized: "启用")) {
                                            session.requestSetCronJobEnabled(job, enabled: !job.enabled)
                                        }
                                        Divider()
                                        Button(String(localized: "删除…"), role: .destructive) {
                                            session.requestDeleteCronJob(job)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .frame(width: 24, height: 24)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .help(String(localized: "定时任务操作"))
                                    .accessibilityLabel(String(localized: "定时任务操作"))
                                }
                            }
                            .padding(.horizontal, Theme.Space.md)
                            .padding(.vertical, Theme.Space.sm)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised)
                    )
                } else {
                    OpsEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        title: "没有定时任务",
                        detail: "当前用户 crontab 和系统 cron 目录里没有发现启用的任务。"
                    )
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.cronSnapshot == nil && !session.isCronLoading {
                session.refreshCron()
            }
        }
        .sheet(isPresented: $showsAddSheet) {
            CronAddSheet()
                .environmentObject(session)
        }
        .sheet(item: $editingJob) { job in
            CronEditSheet(job: job)
                .environmentObject(session)
        }
    }

    private var detailText: String {
        guard let snapshot = session.cronSnapshot else { return String(localized: "未加载") }
        return String(localized: "\(snapshot.jobs.count) 个任务")
    }
}

private struct CronEditSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    let job: CronJob
    @State private var schedule: String
    @State private var command: String

    init(job: CronJob) {
        self.job = job
        let parts = job.line.split(maxSplits: 5, whereSeparator: \.isWhitespace).map(String.init)
        _schedule = State(initialValue: parts.prefix(5).joined(separator: " "))
        _command = State(initialValue: parts.count > 5 ? parts[5] : "")
    }

    var body: some View {
        OperationInputSheet(
            title: String(localized: "编辑用户定时任务"),
            detail: String(localized: "仅替换当前选中的完整行。若远端任务已变化，计划会停止而不是覆盖。"),
            confirmTitle: String(localized: "预览变更计划"),
            isValid: schedule.split(whereSeparator: \.isWhitespace).count == 5
                && !command.isEmpty && !command.contains("\n")
        ) {
            TextField("0 * * * *", text: $schedule)
                .font(Theme.Font.monoSmall)
            TextField(String(localized: "单行命令"), text: $command)
                .font(Theme.Font.monoSmall)
        } onConfirm: {
            let captured = (schedule, command)
            dismiss()
            DispatchQueue.main.async {
                session.requestEditCronJob(job, schedule: captured.0, command: captured.1)
            }
        }
    }
}

private struct CronAddSheet: View {
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var schedule = "0 * * * *"
    @State private var command = ""

    var body: some View {
        OperationInputSheet(
            title: String(localized: "新增用户定时任务"),
            detail: String(localized: "Cron 表达式必须是 5 段；命令只允许单行。系统级 cron 仍需在文件编辑器中受控修改。"),
            confirmTitle: String(localized: "预览写入计划"),
            isValid: schedule.split(whereSeparator: \.isWhitespace).count == 5
                && !command.isEmpty && !command.contains("\n")
        ) {
            TextField("任务备注", text: $label)
            TextField("0 * * * *", text: $schedule)
                .font(Theme.Font.monoSmall)
            TextField("单行命令", text: $command)
                .font(Theme.Font.monoSmall)
        } onConfirm: {
            let captured = (schedule, command, label)
            dismiss()
            DispatchQueue.main.async {
                session.requestAddCronJob(schedule: captured.0, command: captured.1, label: captured.2)
            }
        }
    }
}

// MARK: - Mirror pane 镜像源

private struct MirrorPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var provider: MirrorProvider = .aliyun

    private var connected: Bool { session.connectionStatus == .connected }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                OpsSectionHeader(title: "镜像源", detail: provider.applicabilityLabel)
                Text("装东西慢或失败，多半是源离服务器太远。国内服务器换国内镜像提速（本机在阿里云选阿里云最快，同内网）；海外服务器则选「官方源」直连上游，国内镜像反而会更慢。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.sm) {
                    Text("镜像提供商")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Picker("提供商", selection: $provider) {
                        ForEach(MirrorProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    OpsStatusPill(
                        text: provider.applicabilityLabel,
                        color: provider.isOfficial ? Theme.Color.accent : Theme.Color.success
                    )
                    Spacer()
                }

                VStack(spacing: 0) {
                    MirrorRow(title: String(localized: "apt 系统源"), current: session.mirrorSnapshot?.aptSource, hint: String(localized: "替换为\(provider.displayName)并 update"), action: { session.requestAptMirror(provider) }, disabled: !connected)
                    Divider().overlay(Theme.Color.separator.opacity(0.45))
                    MirrorRow(title: String(localized: "pip Python 源"), current: session.mirrorSnapshot?.pipIndex, hint: String(localized: "设为\(provider.displayName)"), action: { session.requestPipMirror(provider) }, disabled: !connected)
                    Divider().overlay(Theme.Color.separator.opacity(0.45))
                    MirrorRow(title: String(localized: "npm Node 源"), current: session.mirrorSnapshot?.npmRegistry, hint: provider.isOfficial ? String(localized: "恢复官方 registry.npmjs.org") : String(localized: "设为 npmmirror.com"), action: { session.requestNpmMirror(provider) }, disabled: !connected)
                    Divider().overlay(Theme.Color.separator.opacity(0.45))
                    MirrorRow(title: String(localized: "Docker 镜像加速"), current: session.mirrorSnapshot?.dockerMirrors, hint: provider.isOfficial ? String(localized: "清空镜像，直连 Docker Hub") : String(localized: "配置 daemon.json 并重启"), action: { session.requestDockerMirror(provider) }, disabled: !connected)
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))

                if !connected {
                    Text("连接服务器后可查看当前源并执行换源计划。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard connected else { return }
            if session.mirrorSnapshot == nil && !session.isMirrorLoading {
                session.refreshMirror()
            }
        }
    }
}

private struct MirrorRow: View {
    let title: String
    let current: String?
    let hint: String
    let action: () -> Void
    let disabled: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(current.map { String(localized: "当前：\($0)") } ?? hint)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(current != nil ? Theme.Color.textSecondary : Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("切换") { action() }
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 50)
    }
}

// MARK: - Shell & PATH pane

private struct ShellPathPane: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                if session.isShellPathLoading && session.shellPathSnapshot == nil {
                    OpsSkeletonRows()
                } else if let snapshot = session.shellPathSnapshot {
                    HStack {
                        OpsSectionHeader(title: "Shell", detail: String(localized: "登录 shell：\((snapshot.loginShell as NSString).lastPathComponent)"))
                        Spacer()
                        if snapshot.shells.contains(where: { $0.name == "zsh" }) {
                            if snapshot.ohMyZshInstalled {
                                Label("oh-my-zsh 已安装", systemImage: "checkmark.seal.fill")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Color.success)
                                    .help("已检测到 ~/.oh-my-zsh")
                            } else {
                                Button {
                                    session.requestInstallOhMyZsh()
                                } label: {
                                    Label("安装 oh-my-zsh", systemImage: "sparkles")
                                }
                                .controlSize(.small)
                                .disabled(session.connectionStatus != .connected)
                                .help("为 zsh 安装 oh-my-zsh 框架")
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(snapshot.shells) { shell in
                            HStack(spacing: Theme.Space.sm) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .frame(width: 20)
                                Text(shell.name)
                                    .font(Theme.Font.bodyMedium)
                                    .foregroundStyle(Theme.Color.textPrimary)
                                if shell.isLogin {
                                    OpsStatusPill(text: "默认", color: Theme.Color.success)
                                }
                                Text(shell.path)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("开终端") { appState.openTerminalTabForShell(shell.path) }
                                    .controlSize(.small)
                                    .disabled(session.connectionStatus != .connected)
                                if !shell.isLogin {
                                    Button("设为默认") { session.requestSetDefaultShell(shell) }
                                        .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, Theme.Space.md)
                            .frame(height: 46)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))

                    OpsSectionHeader(title: "PATH 体检", detail: String(localized: "对应 \((snapshot.loginShell as NSString).lastPathComponent) 的配置"))
                    Text("检测常见「用户目录」是否已在 PATH。缺失的可一键写入对应 shell 的配置文件（幂等，不会重复添加）。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(snapshot.candidates) { candidate in
                            HStack(spacing: Theme.Space.sm) {
                                Text(candidate.path)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if !candidate.exists {
                                    Text("目录不存在")
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(Theme.Color.textTertiary)
                                } else if candidate.inPath {
                                    OpsStatusPill(text: "已在 PATH", color: Theme.Color.success)
                                } else {
                                    OpsStatusPill(text: "缺失", color: Theme.Color.warning)
                                    Button("加入 PATH") {
                                        session.requestAddPath(dir: candidate.path, shellPath: snapshot.loginShell)
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, Theme.Space.md)
                            .frame(height: 44)
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))

                    if snapshot.shells.contains(where: { $0.name == "zsh" }) {
                        ZshPluginsSection(snapshot: snapshot)
                    }
                } else {
                    OpsEmptyState(
                        systemImage: "curlybraces.square",
                        title: session.connectionStatus == .connected ? String(localized: "点刷新扫描 Shell 与 PATH") : String(localized: "连接后可扫描"),
                        detail: "会检测可用 shell、当前登录 shell，以及常见工具目录是否在 PATH 中。"
                    )
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            guard session.connectionStatus == .connected else { return }
            if session.shellPathSnapshot == nil && !session.isShellPathLoading {
                session.refreshShellPath()
            }
        }
    }
}

// MARK: - zsh 插件增强

private struct ZshPluginsSection: View {
    @EnvironmentObject private var session: ServerSession
    let snapshot: ShellPathSnapshot
    @State private var checked: Set<String> = []
    @State private var didInit = false

    private let plugins = ShellPathService.zshPlugins
    private var omzInstalled: Bool { snapshot.ohMyZshInstalled }
    private var connected: Bool { session.connectionStatus == .connected }
    // Only plugins not already installed can be (usefully) part of a new install.
    private var selectable: [String] { plugins.map(\.id).filter { !snapshot.zshPluginsInstalled.contains($0) } }
    private var selected: [String] { plugins.map(\.id).filter { checked.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            OpsSectionHeader(title: String(localized: "zsh 插件"), detail: String(localized: "自动补全 / 语法高亮 / 目录跳转，一键装齐并写入 .zshrc"))
            if !omzInstalled {
                Text("这些是 oh-my-zsh 的自定义插件，请先在上方安装 oh-my-zsh。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(plugins) { plugin in
                    let installed = snapshot.zshPluginsInstalled.contains(plugin.id)
                    let enabled = snapshot.zshPluginsEnabled.contains(plugin.id)
                    HStack(spacing: Theme.Space.sm) {
                        Toggle("", isOn: Binding(
                            get: { checked.contains(plugin.id) },
                            set: { on in
                                if on { checked.insert(plugin.id) } else { checked.remove(plugin.id) }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!omzInstalled || installed)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Space.xs) {
                                Text(plugin.name)
                                    .font(Theme.Font.bodyMedium)
                                    .foregroundStyle(Theme.Color.textPrimary)
                                if plugin.needsSudo {
                                    OpsStatusPill(text: "需 sudo", color: Theme.Color.textTertiary)
                                }
                            }
                            Text(plugin.detail)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Color.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        if installed {
                            OpsStatusPill(text: enabled ? String(localized: "已启用") : String(localized: "已装未启用"),
                                          color: enabled ? Theme.Color.success : Theme.Color.warning)
                        } else if plugin.recommended {
                            OpsStatusPill(text: "推荐", color: Theme.Color.accent)
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .frame(height: 52)
                    if plugin.id != plugins.last?.id {
                        Divider().overlay(Theme.Color.separator.opacity(0.45))
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))

            HStack {
                Spacer()
                Button {
                    session.requestInstallZshPlugins(selected)
                } label: {
                    Label(String(localized: "安装并启用所选（\(selected.count)）"), systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(!connected || !omzInstalled || selected.isEmpty)
            }
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            // Pre-check recommended plugins that aren't installed yet.
            checked = Set(plugins.filter { $0.recommended && selectable.contains($0.id) }.map(\.id))
        }
    }
}

private struct DeploymentPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var showsToolPicker = false
    @State private var pendingToolIDs: [String]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                OpsSectionHeader(title: String(localized: "一键部署"), detail: String(localized: "勾选需要的组件，一次装齐（已安装的自动跳过）"))
                if session.connectionStatus != .connected {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "info.circle")
                        Text("连接服务器后即可部署；未连接时可先浏览与勾选。")
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                }

                Button {
                    showsToolPicker = true
                } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "checklist")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Color.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.Color.accentSoft))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("自选工具组合")
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text("从全部工具里自由勾选")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }

                        Spacer()

                        Text("\(appState.toolCatalog.count)")
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .frame(maxWidth: 720, minHeight: 68, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .stroke(Theme.Color.separator.opacity(0.55), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("从全部工具里自由勾选")
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            if appState.toolCatalog.isEmpty {
                appState.refreshToolCatalog()
            }
        }
        .sheet(isPresented: $showsToolPicker, onDismiss: deployPendingTools) {
            DeploymentToolPickerSheet { toolIDs in
                pendingToolIDs = toolIDs
                showsToolPicker = false
            }
            .environmentObject(appState)
            .environmentObject(session)
        }
    }

    private func deployPendingTools() {
        guard let toolIDs = pendingToolIDs else { return }
        pendingToolIDs = nil
        session.requestDeployTools(toolIDs)
    }
}

private struct DeploymentToolPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    @State private var searchText = ""

    let onDeploy: ([String]) -> Void

    private var filteredTools: [ToolDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = query.isEmpty ? appState.toolCatalog : appState.toolCatalog.filter { tool in
            tool.name.localizedCaseInsensitiveContains(query)
                || tool.description.localizedCaseInsensitiveContains(query)
                || tool.binaryNames.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        return tools.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                let lhsIndex = ToolCategory.allCases.firstIndex(of: lhs.category) ?? 0
                let rhsIndex = ToolCategory.allCases.firstIndex(of: rhs.category) ?? 0
                return lhsIndex < rhsIndex
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var groupedTools: [(ToolCategory, [ToolDefinition])] {
        ToolCategory.allCases.compactMap { category in
            let tools = filteredTools.filter { $0.category == category }
            return tools.isEmpty ? nil : (category, tools)
        }
    }

    private var selectedToolIDs: [String] {
        appState.toolCatalog.map(\.id).filter(checked.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "checklist")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Color.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.Color.accentSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text("自选工具组合")
                        .font(Theme.Font.sectionTitle)
                    Text("从全部工具里自由勾选")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("关闭")
                .accessibilityLabel("关闭")
            }
            .padding(Theme.Space.lg)

            HStack(spacing: Theme.Space.sm) {
                OpsSearchField(text: $searchText, placeholder: String(localized: "搜索工具"))
                    .frame(height: 26)
                Button("全选") { selectVisibleTools() }
                    .controlSize(.small)
                Button("清空") { checked.removeAll() }
                    .controlSize(.small)
                    .disabled(checked.isEmpty)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.md)

            Divider().overlay(Theme.Color.separator)

            if filteredTools.isEmpty {
                OpsEmptyState(
                    systemImage: "magnifyingglass",
                    title: "没有匹配的工具",
                    detail: "请更换分类或搜索关键词。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedTools, id: \.0) { category, tools in
                            Text(category.displayName)
                                .font(Theme.Font.caption.weight(.semibold))
                                .foregroundStyle(Theme.Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Space.lg)
                                .padding(.top, Theme.Space.md)
                                .padding(.bottom, Theme.Space.xs)

                            ForEach(tools) { tool in
                                DeploymentToolPickerRow(tool: tool, checked: $checked)
                                Divider()
                                    .overlay(Theme.Color.separator.opacity(0.45))
                                    .padding(.leading, 48)
                            }
                        }
                    }
                }
            }

            Divider().overlay(Theme.Color.separator)

            HStack(spacing: Theme.Space.sm) {
                if session.connectionStatus != .connected {
                    Label("连接服务器后即可部署；未连接时可先浏览与勾选。", systemImage: "info.circle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                } else {
                    Text(String(localized: "已选择 \(checked.count) 项"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onDeploy(selectedToolIDs)
                } label: {
                    Text("部署所选（\(checked.count)）")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty || session.connectionStatus != .connected)
            }
            .padding(Theme.Space.lg)
        }
        .frame(minWidth: 600, idealWidth: 660, minHeight: 560, idealHeight: 640)
    }

    private func selectVisibleTools() {
        checked.formUnion(filteredTools.lazy.filter { !$0.isInstalled(on: session.serverProfile) }.map(\.id))
    }
}

private struct DeploymentToolPickerRow: View {
    @EnvironmentObject private var session: ServerSession
    let tool: ToolDefinition
    @Binding var checked: Set<String>

    private var installed: Bool { tool.isInstalled(on: session.serverProfile) }

    var body: some View {
        Toggle(isOn: Binding(
            get: { checked.contains(tool.id) },
            set: { isChecked in
                if isChecked {
                    checked.insert(tool.id)
                } else {
                    checked.remove(tool.id)
                }
            }
        )) {
            HStack(spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(installed ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    Text(tool.description)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if installed {
                    OpsStatusPill(text: String(localized: "已装"), color: Theme.Color.success)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(installed)
        .padding(.horizontal, Theme.Space.lg)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }
}

private struct AuditSummaryStrip: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            AuditCountPill(title: String(localized: "安全"), count: count(.safe), color: Theme.Color.success)
            AuditCountPill(title: String(localized: "警告"), count: count(.warning), color: Theme.Color.warning)
            AuditCountPill(title: String(localized: "危险"), count: count(.danger), color: Theme.Color.danger)
            Spacer()
            if let profile = session.serverProfile {
                Text("\(profile.osName ?? String(localized: "未知系统")) · \(profile.packageManager.displayName)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func count(_ severity: AuditSeverity) -> Int {
        session.auditFindings.filter { $0.severity == severity }.count
    }
}

private struct AuditCountPill: View {
    let title: String
    let count: Int
    let color: SwiftUI.Color

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(count)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 24)
        .background(Theme.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

private struct AuditFindingsList: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            OpsSectionHeader(
                title: "巡检结果",
                detail: session.auditFindings.isEmpty ? String(localized: "未加载") : String(localized: "\(session.auditFindings.count) 项")
            )

            if session.isAuditLoading && session.auditFindings.isEmpty {
                OpsSkeletonRows()
            } else if session.auditFindings.isEmpty {
                OpsEmptyState(
                    systemImage: "checkmark.shield",
                    title: session.connectionStatus == .connected ? String(localized: "尚未巡检") : String(localized: "连接后执行巡检"),
                    detail: "巡检只读检查 SSH、安全工具、磁盘和服务状态。"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(session.auditFindings) { finding in
                        AuditFindingRow(finding: finding)
                        Divider().overlay(Theme.Color.separator.opacity(0.45))
                    }
                }
            }
        }
    }
}

private struct AuditFindingRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let finding: AuditFinding

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Text(finding.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                    OpsStatusPill(text: finding.severity.displayName, color: color)
                }
                Text(finding.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("证据：\(finding.evidence)")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if finding.fixPlan != nil {
                Button {
                    session.requestAuditFix(finding)
                } label: {
                    Label("修复计划", systemImage: "wrench.adjustable")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var iconName: String {
        switch finding.severity {
        case .safe:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "xmark.octagon.fill"
        }
    }

    private var color: SwiftUI.Color {
        switch finding.severity {
        case .safe:
            return Theme.Color.success
        case .warning:
            return Theme.Color.warning
        case .danger:
            return Theme.Color.danger
        }
    }
}

private struct OpsWorkspaceToolbar: View {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let refreshAction: () -> Void
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Label(title, systemImage: systemImage)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)
            Button {
                refreshAction()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(session.connectionStatus != .connected || isLoading)
            .help("刷新")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 44)
        .background(Theme.Color.toolbarBackground)
    }
}

private struct OpsSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(LocalizedStringKey(detail))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// Maps common command failures to a plain-language likely cause + fix. Keeps
/// the "not something we can fix automatically" errors actionable for the user.
enum OpsErrorHint {
    static func hint(for message: String) -> String? {
        let m = message.lowercased()
        if m.contains("statoverride") &&
            (m.contains("unknown system user") || m.contains("unknown system group")) {
            return String(localized: "dpkg 的 statoverride 仍引用已删除的系统用户或组。先备份并检查 /var/lib/dpkg/statoverride；确认相关服务已卸载后，用 sudo dpkg-statoverride --remove <路径> 逐条移除，再运行 sudo dpkg --configure -a 和 sudo apt-get -f install。OpsDeck 不会自动删除这些系统记录。")
        }
        if (m.contains("can't open config file") && m.contains("no such file or directory")) ||
            (m.contains("missing") && m.contains(" c /etc/")) {
            return String(localized: "服务配置文件缺失。若它属于 apt 软件包，重新运行安装计划；OpsDeck 会使用 --force-confmiss 只恢复缺失配置，不覆盖仍存在的自定义配置。")
        }
        if m.contains("no module named pip") {
            return String(localized: "系统未装 pip：sudo apt install -y python3-pip（uv 已改用官方脚本，无需 pip）")
        }
        if m.contains("unable to locate package") || m.contains("has no installation candidate") {
            return String(localized: "该包在当前软件源里没有：核对包名，或到「镜像源」换国内源后重试")
        }
        if m.contains("permission denied") && m.contains("docker") {
            return String(localized: "把当前用户加入 docker 组：sudo usermod -aG docker $USER（重新登录生效），或改用 sudo")
        }
        if m.contains("dpkg was interrupted") {
            return String(localized: "dpkg 上次执行被中断：先运行 sudo dpkg --configure -a，再运行 sudo apt-get -f install 后重试")
        }
        if m.contains("could not get lock") || m.contains("unable to acquire the dpkg frontend lock") {
            return String(localized: "apt/dpkg 被其他进程占用：等待系统更新结束后重试；不要删除仍被活跃进程持有的锁文件")
        }
        if m.contains("unmet dependencies") || m.contains("--fix-broken install") || m.contains("dependency problems") {
            return String(localized: "软件包依赖损坏：先运行 sudo apt-get -f install；若仍失败，再运行 sudo dpkg --configure -a")
        }
        if m.contains("no space left on device") {
            return String(localized: "磁盘空间或 inode 已满：先用 df -h 和 df -i 检查并释放空间，再运行 sudo dpkg --configure -a")
        }
        if m.contains("read-only file system") {
            return String(localized: "根文件系统为只读：先检查磁盘或文件系统错误并恢复可写状态，不要反复运行安装命令")
        }
        if m.contains("held broken packages") {
            return String(localized: "存在被保持或损坏的软件包：用 apt-mark showhold 和 apt-cache policy <包名> 检查，再修复依赖")
        }
        if m.contains("hash sum mismatch") || m.contains("failed to fetch") {
            return String(localized: "apt 下载或校验失败：重新运行 apt-get update；仍失败时检查网络、镜像源和代理")
        }
        if m.contains("no_pubkey") || (m.contains("repository") && m.contains("is not signed")) {
            return String(localized: "软件源签名或密钥无效：修复对应仓库的签名密钥或禁用该仓库，不要绕过签名校验")
        }
        if m.contains("access denied for user") {
            return String(localized: "数据库 root 需要密码或未启用 socket 认证：用 mysql -u root -p 手动连，或配置只读账号")
        }
        if m.contains("could not resolve host") || m.contains("temporary failure resolving") || m.contains("name or service not known") {
            return String(localized: "DNS/网络问题：检查网络连通性，或到「镜像源」换国内源")
        }
        if m.contains("connection refused") {
            return String(localized: "目标服务没在运行或端口不通")
        }
        if m.contains("npm: command not found") || m.contains("node: command not found") {
            return String(localized: "系统未安装 Node.js/npm：请先到「安装器」安装 Node.js，再安装依赖它的工具（如 PM2）")
        }
        if m.contains("sudo:") && m.contains("command not found") {
            // `sudo: X: command not found` = X isn't installed system-wide (or not in
            // root's sudo secure_path). The user-PATH doctor won't help here.
            return String(localized: "该命令未安装（或已装但不在 root 的 sudo 路径里）：先在「安装器」安装它本体或它依赖的组件")
        }
        if m.contains("command not found") || m.contains("未找到命令") {
            return String(localized: "命令未安装或不在 PATH：先在「安装器」安装该工具，或到「Shell / PATH」体检补全 PATH")
        }
        if m.contains("sudo: a password is required") || m.contains("a terminal is required") {
            return String(localized: "该账号 sudo 需要密码：给它配置免密 sudo，或改用 root 连接")
        }
        if m.contains("sub-process /usr/bin/dpkg returned an error code") {
            return String(localized: "dpkg 返回了通用失败：展开本步骤输出查找更早的 fatal/error 行，并运行 sudo dpkg --audit 检查包数据库")
        }
        return nil
    }

    static func copyText(for message: String) -> String {
        if let hint = hint(for: message) {
            return "\(message)\n" + String(localized: "可能原因/解决：") + hint
        }
        return message
    }
}

/// Error banner — click anywhere to copy the message (and its hint). No copy
/// icon by design; the whole banner is the affordance.
private struct OpsStatusBanner: View {
    let message: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(OpsErrorHint.copyText(for: message), forType: .string)
            copied = true
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Color.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                    if let hint = OpsErrorHint.hint(for: message) {
                        Text("可能原因 / 解决：\(hint)")
                            .font(Theme.Font.tiny)
                            .foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Theme.Space.xs)
                Text(copied ? String(localized: "已复制") : String(localized: "点击复制"))
                    .font(Theme.Font.tiny)
                    .foregroundStyle(copied ? Theme.Color.success : Theme.Color.textTertiary)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.accentSoft.opacity(0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击复制错误信息")
    }
}

struct OpsStatusPill: View {
    let text: String
    let color: SwiftUI.Color

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(Theme.Font.tiny.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: 18)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// Shown in a not-installed pane while a runbook is installing that tool, in place
/// of the idle "install" empty state.
private struct OpsInstallingCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let run: RunbookRun

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            ProgressView()
                .controlSize(.small)
            Text(run.title)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            HStack(spacing: Theme.Space.xs) {
                Text(run.progressDescription)
                RunbookElapsedText(run: run)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textSecondary)
            ProgressView(
                value: Double(run.completedStepCount),
                total: Double(max(run.steps.count, 1))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 260)
            Button {
                session.showRunDetail(run)
            } label: {
                Label("查看实时日志", systemImage: "text.alignleft")
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

/// Shown in a not-installed pane when the tool's most recent operation failed:
/// the reason plus retry / details, in place of the idle "install" empty state.
private struct OpsFailedCard: View {
    @EnvironmentObject private var session: ServerSession
    let run: RunbookRun
    var title: String = String(localized: "操作失败")
    let onRetry: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Color.danger)
            Text(LocalizedStringKey(title))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(run.failureSummary ?? run.title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.sm) {
                if session.hasPackageRecovery(for: run) {
                    Button {
                        session.requestPackageRecovery(for: run)
                    } label: {
                        Label("生成修复计划", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    onRetry()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                Button {
                    onDetails()
                } label: {
                    Label("查看详情", systemImage: "text.alignleft")
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

/// Wraps a pane's idle empty state, swapping in an installing / failed card when a
/// runbook is (or was last) acting on the module. Keeps the per-pane state branch
/// a one-liner instead of repeating the running/failed logic everywhere.
private struct WorkbenchEmptyOrActivity<Idle: View>: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let moduleID: String
    var failedTitle: String = String(localized: "操作失败")
    @ViewBuilder var idle: () -> Idle

    var body: some View {
        switch session.moduleActivity(moduleID) {
        case .running(let run):
            OpsInstallingCard(run: run)
        case .failed(let run):
            OpsFailedCard(
                run: run,
                title: failedTitle,
                onRetry: { session.retryRun(run) },
                onDetails: { session.showRunDetail(run) }
            )
        case .idle:
            idle()
        }
    }
}

/// Inline, dismissible failure banner for a non-install operation, shown in-pane
/// (in addition to the global error banner) so retry is close to where it failed.
private struct OpsModuleErrorBanner: View {
    @EnvironmentObject private var session: ServerSession
    let run: RunbookRun
    let onRetry: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Color.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(run.title)失败")
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(run.failureSummary ?? run.title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            HStack(spacing: Theme.Space.xs) {
                if session.hasPackageRecovery(for: run) {
                    Button { session.requestPackageRecovery(for: run) } label: {
                        Label("修复", systemImage: "wrench.and.screwdriver")
                    }
                    .help("生成可预览、可回滚的软件包恢复计划")
                }
                Button { onRetry() } label: { Label("重试", systemImage: "arrow.clockwise") }
                Button { onDetails() } label: { Label("详情", systemImage: "text.alignleft") }
                Button { onDismiss() } label: { Image(systemName: "xmark") }
            }
            .controlSize(.small)
            .labelStyle(.titleOnly)
        }
        .padding(Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(Theme.Color.danger.opacity(0.12))
        )
    }
}

struct OpsEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    init(
        systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Color.textTertiary)
            Text(LocalizedStringKey(title))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(LocalizedStringKey(detail))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

extension OpsEmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, detail: String) {
        self.init(systemImage: systemImage, title: title, detail: detail) {
            EmptyView()
        }
    }
}

private struct OpsLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OpsSkeletonRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Color.separator.opacity(0.55))
                        .frame(minWidth: 64, maxWidth: index.isMultiple(of: 2) ? 180 : 260)
                        .frame(height: 9)
                    Spacer(minLength: Theme.Space.xs)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Color.separator.opacity(0.35))
                        .frame(minWidth: 40, maxWidth: 90)
                        .frame(height: 9)
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 42)
                Divider().overlay(Theme.Color.separator.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct OpsSelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? SwiftUI.Color(nsColor: .selectedContentBackgroundColor) : SwiftUI.Color.clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }
}

private extension ByteCountFormatter {
    static let opsSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
