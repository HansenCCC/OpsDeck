import AppKit
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var appState: AppState

    /// The session for the currently-selected host. Injected into the per-host
    /// subtrees (workspace / inspector / terminal / per-host sheets) as a second
    /// `@EnvironmentObject`; when the selected host changes, `activeSession`
    /// returns a different instance and SwiftUI re-subscribes the subtree — this
    /// is the "switch tabs without disconnecting" swap. `nil` only when no host
    /// is configured/selected.
    private var session: ServerSession? { appState.activeSession }

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar()
            Divider().overlay(Theme.Color.separator)

            VSplitView {
                HStack(spacing: 0) {
                    HostSidebar()
                        .frame(width: 252)
                        .background(Theme.Color.sidebarBackground)

                    Divider().overlay(Theme.Color.separator)

                    HSplitView {
                        Group {
                            if let session {
                                ServerWorkspace()
                                    .environmentObject(session)
                                    .environmentObject(session.dbState)
                            } else {
                                NoActiveHostPlaceholder()
                            }
                        }
                        .frame(minWidth: 500)
                        .background(Theme.Color.surface)

                        if appState.isInspectorVisible, let session {
                            InspectorPanel()
                                .environmentObject(session)
                                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                                .background(Theme.Color.surface)
                        }
                    }
                }
                .frame(minHeight: 300)
                .layoutPriority(1)

                if appState.isTerminalVisible, let session {
                    TerminalPanel()
                        .environmentObject(session)
                        .frame(
                            minHeight: AppState.minTerminalPanelHeight,
                            idealHeight: AppState.defaultTerminalPanelHeight,
                            maxHeight: AppState.maxTerminalPanelHeight
                        )
                        .layoutPriority(1)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Theme.Color.appBackground)
        .background(WindowCloseToHideInstaller())
        .background(EndEditingOnClickMonitor())
        .sheet(item: hostEditorBinding) { draft in
            HostEditorView(draft: draft)
                .environmentObject(appState)
        }
        .sheet(item: hostKeyChallengeBinding) { challenge in
            HostKeyTrustView(challenge: challenge)
                .environmentObject(appState)
        }
        .sheet(item: remoteTextDocumentBinding) { _ in
            if let session {
                RemoteTextEditorView()
                    .environmentObject(appState)
                    .environmentObject(session)
            }
        }
        .sheet(item: runbookPlanBinding) { plan in
            if let session {
                ExecutionPlanSheet(plan: plan)
                    .environmentObject(appState)
                    .environmentObject(session)
            }
        }
        .sheet(item: runbookResultBinding) { run in
            if let session {
                RunbookResultSheet(run: run)
                    .environmentObject(appState)
                    .environmentObject(session)
            }
        }
        .alert(appState.dangerousAction?.title ?? String(localized: "确认操作"), isPresented: dangerousActionBinding) {
            Button(appState.dangerousAction?.confirmTitle ?? String(localized: "确认"), role: .destructive) {
                appState.confirmDangerousAction()
            }
            Button("取消", role: .cancel) {
                appState.cancelDangerousAction()
            }
        } message: {
            Text(appState.dangerousAction?.message ?? "")
        }
    }

    private var hostEditorBinding: Binding<HostEditorDraft?> {
        Binding(
            get: { appState.hostEditorDraft },
            set: { appState.hostEditorDraft = $0 }
        )
    }

    private var hostKeyChallengeBinding: Binding<KnownHostChallenge?> {
        Binding(
            get: { appState.hostEditorDraft == nil ? appState.pendingHostKeyChallenge : nil },
            set: { value in
                if value == nil, appState.hostEditorDraft == nil { appState.rejectPendingHostKey() }
            }
        )
    }

    private var remoteTextDocumentBinding: Binding<RemoteTextDocument?> {
        Binding(
            get: { appState.remoteTextDocument },
            set: { appState.remoteTextDocument = $0 }
        )
    }

    private var dangerousActionBinding: Binding<Bool> {
        Binding(
            get: { appState.dangerousAction != nil },
            set: { isPresented in
                if !isPresented {
                    appState.cancelDangerousAction()
                }
            }
        )
    }

    private var runbookPlanBinding: Binding<RunbookPlan?> {
        Binding(
            get: { appState.pendingRunbookPlan },
            set: { appState.pendingRunbookPlan = $0 }
        )
    }

    private var runbookResultBinding: Binding<RunbookRun?> {
        Binding(
            get: { appState.selectedRunbookRun },
            set: { appState.selectedRunbookRun = $0 }
        )
    }
}

/// Shown in the workspace area when no host is selected (e.g. before any server
/// has been added). Session-dependent panes require a `ServerSession`, so when
/// there is none we render this instead of injecting one.
private struct NoActiveHostPlaceholder: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ContentUnavailableView {
            Label("连接你的服务器", systemImage: "server.rack")
        } description: {
            Text("浏览、上传和编辑远端文件，需要时直接打开真实 SSH 终端。")
        } actions: {
            VStack(spacing: Theme.Space.sm) {
                Button {
                    appState.openNewHostEditor()
                } label: {
                    Label("添加第一台服务器", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.Color.accent)

                Label("SSH 凭据安全保存在本机 Keychain，OpsDeck 不会经过云端中转。", systemImage: "lock.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowCloseToHideInstaller: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowCloseInstallerView {
        WindowCloseInstallerView()
    }

    func updateNSView(_: WindowCloseInstallerView, context _: Context) {}
}

private final class WindowCloseInstallerView: NSView {
    private static let frameAutosaveName = "OpsDeckMainWindowFrame"
    private var closeDelegate: CloseToHideWindowDelegate?
    private weak var installedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI can attach this representable while AppKit is already laying
        // out the hosting view. Changing the window frame synchronously from
        // that stack triggers AppKit's layout-recursion warning, so install the
        // first-launch sizing and delegate on the next main-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard let window, installedWindow !== window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("OpsDeckMainWindow")
        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restoredFrame, let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            window.setContentSize(WorkspaceWindowSizing.mainContentSize(for: visibleFrame))
            window.center()
        }
        let delegate = CloseToHideWindowDelegate(previousDelegate: window.delegate)
        window.delegate = delegate
        closeDelegate = delegate
        installedWindow = window
    }
}

private final class CloseToHideWindowDelegate: NSObject, NSWindowDelegate {
    private weak var previousDelegate: NSWindowDelegate?

    init(previousDelegate: NSWindowDelegate?) {
        self.previousDelegate = previousDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return previousDelegate?.responds(to: selector) == true || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true {
            return previousDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

private struct MainToolbar: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsActivityCenter = false

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            identity

            Spacer(minLength: Theme.Space.md)

            endpointStrip

            Spacer(minLength: Theme.Space.md)

            actions
        }
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, Theme.Space.sm)
        .frame(height: 52)
        .background(Theme.Color.toolbarBackground)
    }

    // MARK: Identity — app/host name + inline connection status

    private var identity: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.currentHostName)
                    .font(Theme.Font.windowTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(appState.connectionStatus.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
    }

    // MARK: Current target — endpoint · remote path (secondary, subtle)

    @ViewBuilder private var endpointStrip: some View {
        if let endpoint = appState.selectedHost?.endpoint {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 11))
                Text(endpoint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if appState.connectionStatus == .connected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text(appState.remoteDirectoryPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textTertiary)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Color.surfaceRaised.opacity(0.5)))
        }
    }

    // MARK: Global actions — connection, terminal, activity, inspector

    private var actions: some View {
        HStack(spacing: Theme.Space.sm) {
            if appState.selectedHost != nil {
                connectButton
                terminalButton

                Divider().frame(height: 18)

                ToolbarIconButton(systemName: "clock.arrow.circlepath", help: String(localized: "活动中心")) {
                    showsActivityCenter.toggle()
                }
                .popover(isPresented: $showsActivityCenter, arrowEdge: .bottom) {
                    ActivityCenterPopover()
                        .environmentObject(appState)
                        .frame(width: 360, height: 360)
                }

                ToolbarIconButton(
                    systemName: "sidebar.right",
                    help: appState.isInspectorVisible ? String(localized: "隐藏检查器") : String(localized: "显示检查器")
                ) {
                    appState.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }

    @ViewBuilder private var connectButton: some View {
        if appState.connectionStatus == .connected {
            Button {
                appState.disconnectSelectedHost()
            } label: {
                Label("断开", systemImage: "link.badge.minus")
            }
        } else {
            Button {
                appState.connectSelectedHost()
            } label: {
                Label("连接", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(appState.selectedHost == nil || appState.connectionStatus == .connecting)
        }
    }

    private var terminalButton: some View {
        Button {
            appState.toggleTerminal()
        } label: {
            Label("终端", systemImage: "terminal")
        }
        .tint(appState.isTerminalVisible ? Theme.Color.accent : nil)
        .keyboardShortcut("`", modifiers: [.control])
        .disabled(appState.connectionStatus != .connected)
        .help(appState.connectionStatus == .connected
            ? String(localized: "显示/隐藏终端 (⌃`)")
            : String(localized: "连接服务器后打开终端"))
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .disconnected:
            return Theme.Color.textTertiary.opacity(0.5)
        case .connecting:
            return Theme.Color.accent
        case .connected:
            return Theme.Color.success
        case .warning:
            return Theme.Color.warning
        case .failed:
            return Theme.Color.danger
        }
    }
}

private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ActivityCenterPopover: View {
    @EnvironmentObject private var appState: AppState

    private var hasActivity: Bool {
        appState.activeRunbookRun != nil
            || !appState.transferTasks.isEmpty
            || !appState.commandRuns.isEmpty
            || !appState.operationNotices.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("活动中心", systemImage: "clock.arrow.circlepath")
                    .font(Theme.Font.sectionTitle)
                Spacer()
                if let run = appState.activeRunbookRun {
                    Button("查看") { appState.selectedRunbookRun = run }
                        .controlSize(.small)
                }
            }
            .padding(Theme.Space.md)
            Divider()

            if hasActivity {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                        if let run = appState.activeRunbookRun {
                            activityRow(
                                icon: "checklist",
                                title: run.title,
                                detail: run.progressDescription,
                                tint: Theme.Color.accent
                            )
                        }
                        ForEach(appState.transferTasks.prefix(4)) { task in
                            activityRow(
                                icon: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc",
                                title: (task.remotePath as NSString).lastPathComponent,
                                detail: "\(task.direction.displayName) · \(task.status.displayName)",
                                tint: task.status == .failed ? Theme.Color.danger : Theme.Color.textSecondary
                            )
                        }
                        ForEach(appState.commandRuns.prefix(4)) { run in
                            activityRow(
                                icon: "terminal",
                                title: run.command,
                                detail: run.exitCode == 0 ? String(localized: "命令完成") : String(localized: "命令失败 · exit \(run.exitCode)"),
                                tint: run.exitCode == 0 ? Theme.Color.success : Theme.Color.danger
                            )
                        }
                        ForEach(appState.operationNotices.prefix(4)) { notice in
                            activityRow(
                                icon: notice.systemImage,
                                title: notice.title,
                                detail: notice.detail ?? notice.date.formatted(date: .omitted, time: .shortened),
                                tint: Theme.Color.textSecondary
                            )
                        }
                    }
                    .padding(Theme.Space.md)
                }
            } else {
                ContentUnavailableView(
                    "暂无活动",
                    systemImage: "clock",
                    description: Text("传输、命令和执行计划会集中显示在这里。")
                )
            }
        }
        .background(Theme.Color.surface)
    }

    private func activityRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.bodyMedium)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EndEditingOnClickMonitor: NSViewRepresentable {
    func makeNSView(context _: Context) -> EndEditingMonitorView {
        EndEditingMonitorView()
    }

    func updateNSView(_: EndEditingMonitorView, context _: Context) {}
}

private final class EndEditingMonitorView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let hitView = window.contentView?.hitTest(event.locationInWindow)
            if hitView?.isInsideTextInput != true {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}

private extension NSView {
    var isInsideTextInput: Bool {
        if self is NSTextView || self is NSTextField {
            return true
        }
        return superview?.isInsideTextInput ?? false
    }
}

private struct ServerWorkspace: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceModeBar()
            Divider().overlay(Theme.Color.separator)

            if let run = appState.activeRunbookRun {
                ActiveRunbookProgressBar(run: run)
                Divider().overlay(Theme.Color.separator)
            }

            switch appState.selectedWorkspaceMode {
            case .files:
                FileWorkspace()
            case .tools:
                ToolsWorkspaceView()
            case .logs:
                LogsWorkspaceView()
            case .audit:
                AuditWorkspaceView()
            case .history:
                OperationHistoryWorkspace()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActiveRunbookProgressBar: View {
    @EnvironmentObject private var appState: AppState

    let run: RunbookRun

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Theme.Space.xs) {
                    Text(run.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(run.progressDescription)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                    RunbookElapsedText(run: run)
                }

                HStack(spacing: Theme.Space.sm) {
                    ProgressView(
                        value: Double(run.completedStepCount),
                        total: Double(max(run.steps.count, 1))
                    )
                    .progressViewStyle(.linear)

                    Text(activityDetail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 340, alignment: .leading)
                }
            }

            Spacer(minLength: Theme.Space.sm)

            Button {
                appState.selectedRunbookRun = run
            } label: {
                Label("实时日志", systemImage: "text.alignleft")
            }
            .controlSize(.small)
            .help("查看当前步骤和实时安装日志")

            Button {
                appState.cancelActiveRunbook()
            } label: {
                Label("取消", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .help("停止当前远端命令，并把执行计划标记为已取消")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 64)
        .background(Theme.Color.accentSoft.opacity(0.45))
    }

    private var activityDetail: String {
        guard let step = run.currentStep else { return String(localized: "正在准备执行") }
        let lastLine = step.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        if let lastLine {
            return "\(step.title) · \(lastLine)"
        }
        return step.title
    }
}

struct RunbookElapsedText: View {
    let run: RunbookRun

    var body: some View {
        if run.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                text
            }
        } else {
            text
        }
    }

    private var text: some View {
        Text("· \(formattedDuration)")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textTertiary)
            .monospacedDigit()
    }

    private var formattedDuration: String {
        let seconds = max(Int(run.duration), 0)
        if seconds >= 60 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return "\(seconds) \(String(localized: "秒"))"
    }
}

private struct WorkspaceModeBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ViewThatFits(in: .horizontal) {
                Picker("工作区", selection: $appState.selectedWorkspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 460)

                Picker("工作区", selection: $appState.selectedWorkspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170, alignment: .leading)
            }

            Spacer()

            if let profile = appState.serverProfile {
                Label(profile.packageManager.displayName, systemImage: "shippingbox")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 42)
        .background(Theme.Color.toolbarBackground)
    }
}

private enum OperationHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case failures
    case runbooks
    case commands
    case transfers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "全部记录")
        case .failures: return String(localized: "失败与警告")
        case .runbooks: return String(localized: "执行计划")
        case .commands: return String(localized: "命令")
        case .transfers: return String(localized: "传输")
        }
    }
}

/// Full operation history belongs in the primary workspace: the inspector keeps
/// the latest few entries for awareness, while this surface supports filtering,
/// selection and complete metadata without compressing the file/log workbench.
private struct OperationHistoryWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession

    @State private var searchText = ""
    @State private var filter: OperationHistoryFilter = .all
    @State private var selectedRecordID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                TextField("搜索操作、命令或路径", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Picker("筛选", selection: $filter) {
                    ForEach(OperationHistoryFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                Spacer()
                Text(String(localized: "\(filteredRecords.count) 条"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Button {
                    try? appState.refreshOperationHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新操作日志")
                .accessibilityLabel("刷新操作日志")
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 44)
            .background(Theme.Color.toolbarBackground)

            Divider()

            if filteredRecords.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? String(localized: "暂无操作日志") : String(localized: "没有匹配的操作"), systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(searchText.isEmpty
                        ? String(localized: "文件传输、终端命令和运维执行计划会显示在这里。")
                        : String(localized: "尝试更换关键词或筛选条件。"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedRecordID) {
                        ForEach(filteredRecords) { record in
                            OperationHistoryListRow(record: record)
                                .tag(record.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 480)

                    Group {
                        if let selectedRecord {
                            OperationHistoryDetail(record: selectedRecord)
                                .environmentObject(appState)
                                .environmentObject(session)
                        } else {
                            ContentUnavailableView(
                                String(localized: "选择一条记录"),
                                systemImage: "sidebar.right",
                                description: Text(String(localized: "查看目标、状态、耗时和完整输出。"))
                            )
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if appState.hasMoreOperationHistory {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        appState.loadMoreOperationHistory()
                    } label: {
                        if appState.isLoadingMoreOperationHistory {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("加载更多", systemImage: "chevron.down")
                        }
                    }
                    .controlSize(.small)
                    .disabled(appState.isLoadingMoreOperationHistory)
                    Spacer()
                }
                .frame(height: 36)
            }
        }
        .onAppear {
            if selectedRecordID == nil {
                selectedRecordID = filteredRecords.first?.id
            }
        }
        .onChange(of: filter) { _, _ in repairSelection() }
        .onChange(of: searchText) { _, _ in repairSelection() }
    }

    private var allRecords: [OperationRecord] {
        OperationRecord.collect(from: appState)
            .filter { $0.belongs(to: appState.selectedHost?.id) }
    }

    private var filteredRecords: [OperationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRecords.filter { record in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .failures: matchesFilter = record.isFailure
            case .runbooks: matchesFilter = record.category == .runbook
            case .commands: matchesFilter = record.category == .command
            case .transfers: matchesFilter = record.category == .transfer
            }
            return matchesFilter && (query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedRecord: OperationRecord? {
        guard let selectedRecordID else { return nil }
        return filteredRecords.first { $0.id == selectedRecordID }
    }

    private func repairSelection() {
        if selectedRecord == nil {
            selectedRecordID = filteredRecords.first?.id
        }
    }
}

private struct OperationHistoryListRow: View {
    let record: OperationRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: record.icon)
                .foregroundStyle(record.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(Theme.Font.bodyMedium)
                    .lineLimit(1)
                Text(record.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(2)
                Text(record.date.formatted(date: .abbreviated, time: .standard))
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            Spacer(minLength: Theme.Space.xs)
            if record.isFailure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.warning)
                    .accessibilityLabel("失败或警告")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OperationHistoryDetail: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let record: OperationRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(alignment: .top) {
                    Image(systemName: record.icon)
                        .font(.system(size: 24))
                        .foregroundStyle(record.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(Theme.Font.windowTitle)
                            .textSelection(.enabled)
                        Text(record.subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                    Button {
                        copy(record.copyText)
                    } label: {
                        Label("复制详情", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }

                Divider()
                detailContent
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch record {
        case .notice(let notice):
            detailRow("时间", notice.date.formatted(date: .long, time: .standard))
            if let detail = notice.detail, !detail.isEmpty {
                detailBlock("详情", detail)
            }
        case .transfer(let task):
            detailRow("状态", task.status.displayName)
            detailRow("方向", task.direction.displayName)
            detailRow("远端路径", task.remotePath)
            detailRow("本地路径", task.localPath)
            detailRow("进度", task.progress.formatted(.percent.precision(.fractionLength(0))))
            if let error = task.errorMessage, !error.isEmpty { detailBlock("错误", error) }
        case .command(let run):
            detailRow("退出码", "\(run.exitCode)")
            detailRow("耗时", String(format: "%.2f s", run.duration))
            detailBlock("命令", run.command)
            if !run.stdoutPreview.isEmpty { detailBlock("标准输出", run.stdoutPreview) }
            if !run.stderrPreview.isEmpty { detailBlock("错误输出", run.stderrPreview) }
            Button {
                appState.pasteCommandRun(run)
            } label: {
                Label("粘贴到终端", systemImage: "terminal")
            }
            .controlSize(.small)
        case .runbook(let run):
            detailRow("状态", run.status.displayName)
            detailRow("风险", run.risk.displayName)
            detailRow("耗时", String(format: "%.2f s", run.duration))
            detailRow("步骤", "\(run.completedStepCount) / \(run.steps.count)")
            if let failure = run.failureSummary { detailBlock("失败原因", failure) }
            Button {
                appState.selectedRunbookRun = run
            } label: {
                Label("查看完整执行详情", systemImage: "checklist")
            }
            .controlSize(.small)
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(Theme.Font.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailBlock(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(Theme.Font.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Color.surfaceRaised))
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct InspectorPanel: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack {
                    Label("服务器概览", systemImage: "gauge.with.dots.needle.67percent")
                        .font(Theme.Font.sectionTitle)
                    Spacer()
                    Button {
                        appState.copyDiagnosticLog()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("复制诊断日志")
                    .accessibilityLabel("复制诊断日志")

                    Button {
                        appState.exportDiagnosticLog()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("导出诊断日志")
                    .accessibilityLabel("导出诊断日志")

                    Button {
                        appState.refreshServerOverview()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.connectionStatus != .connected)
                    .help("刷新服务器画像和状态")
                    .accessibilityLabel("刷新服务器画像和状态")
                }

                if let snapshot = appState.serverStatus {
                    InspectorSection(title: String(localized: "服务器状态")) {
                        ServerMetricsOverview(snapshot: snapshot)
                        Text("更新于 \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                }

                InspectorSection(title: appState.selectedWorkspaceMode.displayName) {
                    contextualSummary
                }

                InspectorSection(title: String(localized: "连接")) {
                    KeyValueRow(label: String(localized: "服务器"), value: appState.currentHostName)
                    if let endpoint = appState.selectedHost?.endpoint {
                        KeyValueRow(label: String(localized: "地址"), value: endpoint)
                    }
                    KeyValueRow(label: String(localized: "状态"), value: appState.connectionStatus.label)
                    if let summary = appState.connectionSummary, !summary.isEmpty {
                        Text(summary)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(3)
                    }
                    if appState.connectionStatus != .connected, appState.selectedHost != nil {
                        Button {
                            appState.connectSelectedHost()
                        } label: {
                            Label("连接", systemImage: "link")
                        }
                        .controlSize(.small)
                    }
                }

                InspectorSection(title: String(localized: "服务器画像")) {
                    ServerProfileSummaryView()
                }

                // Merge + sort once per render; `operationRecords` and
                // `canLoadMoreOperationRecords` both derive from it, and computing
                // it three times per body showed up in CPU burst samples.
                let allRecords = allOperationRecords
                let operationRecords = allRecords.prefix(appState.operationHistoryDisplayLimit)
                let canLoadMoreOperationRecords = allRecords.count > appState.operationHistoryDisplayLimit
                    || appState.hasMoreOperationHistory
                InspectorSection(title: String(localized: "操作记录")) {
                    Button {
                        appState.selectedWorkspaceMode = .history
                    } label: {
                        Label("打开操作日志", systemImage: "clock.arrow.circlepath")
                    }
                    .controlSize(.small)
                    if operationRecords.isEmpty {
                        EmptyInspectorText(String(localized: "暂无操作记录"))
                    } else {
                        ForEach(operationRecords) { record in
                            OperationRecordRow(record: record)
                        }
                        if canLoadMoreOperationRecords {
                            Button {
                                appState.loadMoreOperationHistory()
                            } label: {
                                HStack(spacing: Theme.Space.xs) {
                                    if appState.isLoadingMoreOperationHistory {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    Text(appState.isLoadingMoreOperationHistory ? String(localized: "正在加载更多") : String(localized: "加载更多"))
                                        .font(Theme.Font.tiny)
                                }
                                .foregroundStyle(Theme.Color.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Space.xs)
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.isLoadingMoreOperationHistory)
                            // NOTE: no `.onAppear { loadMoreOperationHistory() }` here.
                            // On macOS onAppear fires when the button enters the view
                            // tree (not when scrolled into view), so auto-loading here
                            // formed a feedback loop: load-more mutates @Published →
                            // the whole window rebuilds → the button re-appears →
                            // onAppear fires again, pinning the main thread until all
                            // history was exhausted. "加载更多" is a manual tap instead.
                        } else if appState.operationHistoryDisplayLimit > 10 {
                            Text("已加载全部")
                                .font(Theme.Font.tiny)
                                .foregroundStyle(Theme.Color.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Space.xs)
                        }
                    }
                }
            }
            .padding(Theme.Space.lg)
            .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    @ViewBuilder
    private var contextualSummary: some View {
        switch appState.selectedWorkspaceMode {
        case .files:
            if session.selectedRemoteFiles.isEmpty {
                KeyValueRow(label: String(localized: "路径"), value: session.remoteDirectoryPath)
                EmptyInspectorText(String(localized: "选择文件后显示详情"))
            } else if session.selectedRemoteFiles.count > 1 {
                KeyValueRow(label: String(localized: "已选择"), value: String(localized: "\(session.selectedRemoteFiles.count) 项"))
            } else if let item = session.selectedRemoteFile {
                KeyValueRow(label: String(localized: "名称"), value: item.name)
                KeyValueRow(label: String(localized: "类型"), value: item.isDirectory ? String(localized: "文件夹") : String(localized: "文件"))
                KeyValueRow(label: String(localized: "权限"), value: item.permissionsText)
                KeyValueRow(label: String(localized: "路径"), value: item.path)
            }
        case .tools:
            let module = WorkbenchRegistry.module(id: session.selectedWorkbenchModuleID)
            KeyValueRow(label: String(localized: "模块"), value: module.title)
            KeyValueRow(label: String(localized: "状态"), value: module.isBusy(session) ? String(localized: "正在刷新") : String(localized: "就绪"))
        case .logs:
            if let source = session.logSources.first(where: { $0.id == session.selectedLogSourceID }) {
                KeyValueRow(label: String(localized: "来源"), value: source.title)
                KeyValueRow(label: String(localized: "位置"), value: source.detail)
            } else {
                EmptyInspectorText(String(localized: "选择日志来源后显示详情"))
            }
        case .audit:
            let dangerCount = session.auditFindings.filter { $0.severity == .danger }.count
            let warningCount = session.auditFindings.filter { $0.severity == .warning }.count
            KeyValueRow(label: String(localized: "高风险"), value: "\(dangerCount)")
            KeyValueRow(label: String(localized: "警告"), value: "\(warningCount)")
            if session.auditFindings.isEmpty {
                EmptyInspectorText(session.isAuditLoading ? String(localized: "正在巡检") : String(localized: "尚未运行巡检"))
            }
        case .history:
            let records = allOperationRecords.filter { $0.belongs(to: appState.selectedHost?.id) }
            KeyValueRow(label: String(localized: "当前服务器"), value: appState.currentHostName)
            KeyValueRow(label: String(localized: "已加载"), value: String(localized: "\(records.count) 条记录"))
            EmptyInspectorText(String(localized: "在主工作区筛选并查看完整操作详情"))
        }
    }

    private var allOperationRecords: [OperationRecord] {
        OperationRecord.collect(from: appState)
    }
}

private struct ServerProfileSummaryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isServerProfileLoading {
            HStack(spacing: Theme.Space.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("正在识别服务器")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        } else if let profile = appState.serverProfile {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                KeyValueRow(label: String(localized: "系统"), value: profile.osName ?? String(localized: "未识别"))
                KeyValueRow(label: String(localized: "架构"), value: profile.architecture ?? String(localized: "未识别"))
                KeyValueRow(label: String(localized: "用户"), value: userText(profile))
                KeyValueRow(label: String(localized: "权限"), value: profile.sudoStatus.displayName)
                KeyValueRow(label: String(localized: "包管理"), value: profile.packageManager.displayName)
                KeyValueRow(label: "Init", value: profile.initSystem.displayName)
                if !toolSummary(profile).isEmpty {
                    KeyValueRow(label: String(localized: "工具"), value: toolSummary(profile))
                }
                if !serviceSummary(profile).isEmpty {
                    KeyValueRow(label: String(localized: "服务"), value: serviceSummary(profile))
                }
                Text("更新于 \(profile.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                Button {
                    appState.selectedWorkspaceMode = .tools
                } label: {
                    Label("查看已安装工具", systemImage: "wrench.and.screwdriver")
                }
                .controlSize(.small)
            }
        } else if let error = appState.serverProfileError {
            Text(error)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if appState.connectionStatus == .connected {
            Button {
                appState.refreshServerProfile()
            } label: {
                Label("识别服务器", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
        } else {
            EmptyInspectorText(String(localized: "连接后显示系统和工具信息"))
        }
    }

    private func userText(_ profile: ServerProfileSnapshot) -> String {
        guard let username = profile.username else { return String(localized: "未识别") }
        if let userID = profile.userID {
            return "\(username) · uid \(userID)"
        }
        return username
    }

    private func toolSummary(_ profile: ServerProfileSnapshot) -> String {
        profile.installedTools
            .prefix(6)
            .map(\.name)
            .formatted(.list(type: .and, width: .narrow))
    }

    private func serviceSummary(_ profile: ServerProfileSnapshot) -> String {
        profile.installedServices
            .prefix(4)
            .map { "\($0.name) \($0.activeState ?? "unknown")" }
            .formatted(.list(type: .and, width: .narrow))
    }
}

private enum OperationRecord: Identifiable {
    case notice(AppOperationNotice)
    case transfer(TransferTask)
    case command(CommandRun)
    case runbook(RunbookRun)

    var id: String {
        switch self {
        case .notice(let notice):
            return "notice-\(notice.id.uuidString)"
        case .transfer(let task):
            return "transfer-\(task.id.uuidString)"
        case .command(let run):
            return "command-\(run.id.uuidString)"
        case .runbook(let run):
            return "runbook-\(run.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .notice(let notice):
            return notice.date
        case .transfer(let task):
            return task.startedAt
        case .command(let run):
            return run.startedAt
        case .runbook(let run):
            return run.startedAt
        }
    }

    enum Category: Equatable {
        case notice
        case transfer
        case command
        case runbook
    }

    var category: Category {
        switch self {
        case .notice: return .notice
        case .transfer: return .transfer
        case .command: return .command
        case .runbook: return .runbook
        }
    }

    var title: String {
        switch self {
        case .notice(let notice): return notice.title
        case .transfer(let task): return (task.remotePath as NSString).lastPathComponent
        case .command(let run): return run.command
        case .runbook(let run): return run.title
        }
    }

    var subtitle: String {
        switch self {
        case .notice(let notice): return notice.detail ?? String(localized: "应用操作")
        case .transfer(let task):
            if task.status == .failed, let error = task.errorMessage, !error.isEmpty {
                return "\(task.direction.displayName)\(String(localized: "失败")) · \(error)"
            }
            return "\(task.direction.displayName) · \(task.status.displayName)"
        case .command(let run):
            return run.exitCode == 0
                ? "\(String(localized: "命令")) · \(String(format: "%.2fs", run.duration))"
                : "\(String(localized: "命令失败")) · exit \(run.exitCode)"
        case .runbook(let run): return run.failureSummary ?? "\(String(localized: "计划")) · \(run.status.displayName)"
        }
    }

    var icon: String {
        switch self {
        case .notice(let notice): return notice.systemImage
        case .transfer(let task): return task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc"
        case .command: return "terminal"
        case .runbook: return "checklist"
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .notice(let notice):
            switch notice.level {
            case .info: return Theme.Color.textSecondary
            case .success: return Theme.Color.success
            case .warning: return Theme.Color.warning
            }
        case .transfer(let task): return task.status == .succeeded ? Theme.Color.success : Theme.Color.warning
        case .command(let run): return run.exitCode == 0 ? Theme.Color.textSecondary : Theme.Color.danger
        case .runbook(let run):
            return run.status == .succeeded ? Theme.Color.success : (run.status == .failed ? Theme.Color.danger : Theme.Color.warning)
        }
    }

    var isFailure: Bool {
        switch self {
        case .notice(let notice): return notice.level == .warning
        case .transfer(let task): return task.status == .failed || task.status == .cancelled
        case .command(let run): return run.exitCode != 0
        case .runbook(let run): return run.status == .failed || run.status == .cancelled
        }
    }

    var searchableText: String {
        switch self {
        case .notice(let notice): return "\(notice.title) \(notice.detail ?? "")"
        case .transfer(let task): return "\(task.localPath) \(task.remotePath) \(task.errorMessage ?? "")"
        case .command(let run): return "\(run.command) \(run.stdoutPreview) \(run.stderrPreview)"
        case .runbook(let run): return "\(run.title) \(run.failureSummary ?? "") \(run.combinedOutput)"
        }
    }

    var copyText: String {
        "\(title)\n\(subtitle)\n\(date.formatted(date: .long, time: .standard))\n\(searchableText)"
    }

    func belongs(to hostID: UUID?) -> Bool {
        guard let hostID else { return true }
        switch self {
        case .notice(let notice): return notice.hostID == nil || notice.hostID == hostID
        case .transfer(let task): return task.hostID == hostID
        case .command(let run): return run.hostID == hostID
        case .runbook(let run): return run.hostID == hostID
        }
    }

    @MainActor
    static func collect(from appState: AppState) -> [OperationRecord] {
        let active = appState.activeRunbookRun.map { [OperationRecord.runbook($0)] } ?? []
        let notices = appState.operationNotices
            .filter {
                !$0.title.hasPrefix("开始执行计划：")
                    && !$0.title.hasPrefix("计划完成：")
                    && !$0.title.hasPrefix("计划失败：")
            }
            .map(OperationRecord.notice)
        let transfers = appState.transferTasks.map(OperationRecord.transfer)
        let commands = appState.commandRuns.map(OperationRecord.command)
        let runbooks = appState.runbookRuns.map(OperationRecord.runbook)
        return (active + notices + transfers + commands + runbooks)
            .sorted { $0.date > $1.date }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                content()
            }
        }
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyInspectorText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textTertiary)
    }
}

private struct TransferHistoryRow: View {
    let task: TransferTask

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                .foregroundStyle(task.status == .succeeded ? Theme.Color.success : Theme.Color.warning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((task.remotePath as NSString).lastPathComponent)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text("\(task.direction.displayName) · \(task.status.displayName)")
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            Spacer()
        }
    }
}

private struct OperationRecordRow: View {
    @EnvironmentObject private var appState: AppState
    let record: OperationRecord

    var body: some View {
        switch record {
        case .notice(let notice):
            row(
                icon: notice.systemImage,
                tint: noticeTint(notice.level),
                title: notice.title,
                subtitle: notice.detail ?? String(localized: "应用操作"),
                time: notice.date.formatted(date: .omitted, time: .shortened)
            )
        case .transfer(let task):
            row(
                icon: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc",
                tint: task.status == .succeeded ? Theme.Color.success : Theme.Color.warning,
                title: (task.remotePath as NSString).lastPathComponent,
                subtitle: transferSubtitle(task),
                time: task.startedAt.formatted(date: .omitted, time: .shortened)
            )
        case .command(let run):
            Button {
                appState.pasteCommandRun(run)
            } label: {
                row(
                    icon: "terminal",
                    tint: run.exitCode == 0 ? Theme.Color.textSecondary : Theme.Color.danger,
                    title: run.command,
                    subtitle: commandSubtitle(run),
                    time: run.startedAt.formatted(date: .omitted, time: .shortened)
                )
            }
            .buttonStyle(.plain)
            .help("粘贴到终端输入栏")
        case .runbook(let run):
            Button {
                appState.selectedRunbookRun = run
            } label: {
                row(
                    icon: "checklist",
                    tint: run.status == .succeeded ? Theme.Color.success : (run.status == .failed ? Theme.Color.danger : Theme.Color.warning),
                    title: run.title,
                    subtitle: runbookSubtitle(run),
                    time: run.startedAt.formatted(date: .omitted, time: .shortened),
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
            .help("查看执行详情")
        }
    }

    private func transferSubtitle(_ task: TransferTask) -> String {
        if task.status == .failed, let error = task.errorMessage, !error.isEmpty {
            return "\(task.direction.displayName)\(String(localized: "失败")) · \(error)"
        }
        return "\(task.direction.displayName) · \(task.status.displayName)"
    }

    private func runbookSubtitle(_ run: RunbookRun) -> String {
        if let failureSummary = run.failureSummary {
            return failureSummary
        }
        return "\(String(localized: "计划")) · \(run.status.displayName)"
    }

    private func commandSubtitle(_ run: CommandRun) -> String {
        guard run.exitCode != 0 else {
            return "\(String(localized: "命令")) · \(String(format: "%.2fs", run.duration))"
        }
        let output = run.stderrPreview.isEmpty ? run.stdoutPreview : run.stderrPreview
        let detail = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        if let detail {
            return "\(String(localized: "命令失败")) · exit \(run.exitCode) · \(detail)"
        }
        return "\(String(localized: "命令失败")) · exit \(run.exitCode)"
    }

    private func noticeTint(_ level: AppOperationNotice.Level) -> SwiftUI.Color {
        switch level {
        case .info:
            return Theme.Color.textSecondary
        case .success:
            return Theme.Color.success
        case .warning:
            return Theme.Color.warning
        }
    }

    private func row(
        icon: String,
        tint: SwiftUI.Color,
        title: String,
        subtitle: String,
        time: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(icon == "terminal" ? Theme.Font.monoSmall : Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(showsDisclosure ? 2 : 1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                Text(time)
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
        }
        .padding(.vertical, showsDisclosure ? Theme.Space.xxs : 2)
        .contentShape(Rectangle())
    }
}

private struct ServerMetricsOverview: View {
    let snapshot: ServerStatusSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            ServerMetricRing(
                title: String(localized: "负载"),
                progress: snapshot.normalizedLoad,
                valueText: snapshot.loadAverage.map { String(format: "%.1f", $0) }
            )
            ServerMetricRing(
                title: String(localized: "内存"),
                progress: snapshot.memoryUsedPercent,
                valueText: snapshot.memoryUsedPercent.map { "\(Int(($0 * 100).rounded()))%" }
            )
            ServerMetricRing(
                title: String(localized: "磁盘"),
                progress: snapshot.diskUsedPercent,
                valueText: snapshot.diskUsedPercent.map { "\(Int(($0 * 100).rounded()))%" }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ServerMetricRing: View {
    let title: String
    let progress: Double?
    let valueText: String?

    private var normalizedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var tint: Color {
        guard progress != nil else { return Theme.Color.textTertiary }
        if normalizedProgress >= 0.9 { return Theme.Color.danger }
        if normalizedProgress >= 0.7 { return Theme.Color.warning }
        return Theme.Color.success
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ZStack {
                Circle()
                    .stroke(Theme.Color.separator.opacity(0.35), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: normalizedProgress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(valueText ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(progress == nil ? Theme.Color.textTertiary : Theme.Color.textPrimary)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 54, height: 54)

            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText ?? String(localized: "暂无数据"))
        .animation(.easeOut(duration: 0.25), value: normalizedProgress)
    }
}

private struct TerminalPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsSnippetManager = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                ViewThatFits(in: .horizontal) {
                    Label("终端", systemImage: "terminal")
                        .font(Theme.Font.sectionTitle)
                    Image(systemName: "terminal")
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(appState.terminalTabs) { tab in
                            TerminalTabButton(tab: tab)
                        }
                    }
                }
                Spacer()
                if appState.selectedTerminalTabID != nil {
                    ViewThatFits(in: .horizontal) {
                        Label(appState.activeTerminalWorkingDirectory, systemImage: "folder")
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220)
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                    .help(appState.activeTerminalWorkingDirectory)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(appState.activeTerminalStatusLabel == TerminalSessionStatus.disconnected.label ? Theme.Color.warning : Theme.Color.success)
                        .frame(width: 6, height: 6)
                    Text(appState.activeTerminalStatusLabel)
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(Theme.Color.textTertiary)
                Button {
                    TerminalResponderActions.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedTerminalTabID == nil)
                .help("搜索终端输出 (⌘F)")
                .accessibilityLabel("搜索终端输出")
                Menu {
                    if appState.snippets.isEmpty {
                        Text("暂无命令片段")
                    } else {
                        Section("插入") {
                            ForEach(appState.snippets.prefix(12)) { snippet in
                                Button(snippet.title) {
                                    appState.sendStringToActiveTerminal(snippet.command)
                                }
                            }
                        }
                        Section("执行") {
                            ForEach(appState.snippets.prefix(12)) { snippet in
                                Button(snippet.title) {
                                    appState.runSnippet(snippet)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("管理命令片段…") { showsSnippetManager = true }
                } label: {
                    Image(systemName: "text.quote")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("命令片段")
                .accessibilityLabel("命令片段")
                .sheet(isPresented: $showsSnippetManager) {
                    CommandSnippetManagerView()
                        .environmentObject(appState)
                }
                Menu {
                    Button("新建终端（登录 shell）") {
                        appState.openTerminalTabForSelectedHost()
                    }
                    if let shells = appState.shellPathSnapshot?.shells, !shells.isEmpty {
                        Divider()
                        Section("用指定 shell 打开") {
                            ForEach(shells) { shell in
                                Button(shell.name + (shell.isLogin ? String(localized: "（默认）") : "")) {
                                    appState.openTerminalTabForShell(shell.path)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    appState.openTerminalTabForSelectedHost()
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .disabled(appState.connectionStatus != .connected)
                .help("打开终端（点箭头可选 shell）")
                .accessibilityLabel("打开终端")
                Button {
                    appState.reconnectActiveTerminalTab()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedHost == nil || appState.connectionStatus == .connecting)
                .help("重新连接")
                .accessibilityLabel("重新连接终端")
                Menu {
                    Section("显示") {
                        Button("增大字体") { appState.increaseTerminalFontSize() }
                            .disabled(appState.terminalFontSize >= TerminalFontPreference.allowedRange.upperBound)
                        Button("减小字体") { appState.decreaseTerminalFontSize() }
                            .disabled(appState.terminalFontSize <= TerminalFontPreference.allowedRange.lowerBound)
                        Button("恢复默认字号") { appState.resetTerminalFontSize() }
                    }
                    Divider()
                    Text(String(localized: "字号 \(Int(appState.terminalFontSize)) pt · \(appState.activeTerminalSizeLabel)"))
                    Button("清除终端显示") {
                        appState.clearActiveTerminalTranscript()
                    }
                    .disabled(appState.selectedTerminalTabID == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("终端显示选项")
                Button {
                    appState.isTerminalVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭终端面板 (⌃`)")
                .accessibilityLabel("关闭终端面板")
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 34)
            .background(Theme.Color.terminalChrome)

            VStack(spacing: 0) {
                if let tabID = appState.selectedTerminalTabID {
                    terminalContent(tabID: tabID)
                } else {
                    VStack(spacing: Theme.Space.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 28, weight: .regular))
                        Text("连接服务器后打开终端")
                            .font(Theme.Font.bodyMedium)
                    }
                    .foregroundStyle(Theme.Color.terminalText.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.Color.terminalBackground)
        }
        .contextMenu {
            Button("复制") {
                TerminalResponderActions.copy()
            }
            Button {
                TerminalResponderActions.paste()
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            Button("全选") {
                TerminalResponderActions.selectAll()
            }
            Divider()
            Button("搜索…") {
                TerminalResponderActions.showFind()
            }
            Button("清除终端显示") {
                appState.clearActiveTerminalTranscript()
            }
        }
    }

    @ViewBuilder
    private func terminalContent(tabID: UUID) -> some View {
#if DEBUG
        if ScreenshotRenderer.isEnabled {
            Text(String(decoding: appState.activeTerminalOutputBytes, as: UTF8.self))
                .font(.system(size: appState.terminalFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Color.terminalText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.Color.terminalBackground)
        } else {
            liveTerminal(tabID: tabID)
        }
#else
        liveTerminal(tabID: tabID)
#endif
    }

    private func liveTerminal(tabID: UUID) -> some View {
        TerminalViewRepresentable(
            tabID: tabID,
            outputBytes: appState.activeTerminalOutputBytes,
            fontSize: appState.terminalFontSize,
            onInput: { bytes in
                appState.sendBytesToTerminal(bytes, tabID: tabID)
            },
            onResize: { columns, rows, pixelWidth, pixelHeight in
                appState.updateTerminalViewport(
                    tabID: tabID,
                    columns: columns,
                    rows: rows,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
            },
            onTitleChange: { title in
                appState.updateTerminalTitle(title, tabID: tabID)
            },
            onCurrentDirectoryChange: { directory in
                appState.updateTerminalWorkingDirectory(directory, tabID: tabID)
            }
        )
    }
}

private struct TerminalTabButton: View {
    @EnvironmentObject private var appState: AppState
    let tab: TerminalSessionTab

    var body: some View {
        HStack(spacing: 4) {
            Button {
                appState.selectTerminalTab(tab)
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tab.status == .disconnected ? Theme.Color.warning : Theme.Color.success)
                        .frame(width: 6, height: 6)
                    Text(tab.title)
                        .lineLimit(1)
                }
                .font(Theme.Font.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tab.title)，\(tab.status.label)")
            .accessibilityAddTraits(appState.selectedTerminalTabID == tab.id ? .isSelected : [])

            Button {
                appState.closeTerminalTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("关闭 \(tab.title)")
            .accessibilityLabel("关闭终端标签 \(tab.title)")
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 3)
        .background(appState.selectedTerminalTabID == tab.id ? Theme.Color.rowSelected : SwiftUI.Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("设置页暂未打开。")
            .font(Theme.Font.body)
            .padding(Theme.Space.xl)
    }
}

#Preview {
    MainWindow()
        .environmentObject(AppState())
}
