import Foundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct RemoteTransferProgress: Identifiable, Equatable {
    enum Kind: Equatable {
        case upload
        case download
        case compress
        case delete
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var completedUnitCount: Int
    var totalUnitCount: Int?
    var isFinished = false
    var canPause = false
    var canCancel = false
    var isPaused = false

    var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
    }
}

struct RemoteItemInfoSummary: Equatable, Sendable {
    var byteCount: Int64?
    var fileCount: Int
    var folderCount: Int
    var directChildCount: Int?
}

struct AppOperationNotice: Identifiable, Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case info
        case success
        case warning
    }

    let id: UUID
    let hostID: UUID?
    let title: String
    let detail: String?
    let systemImage: String
    let level: Level
    let date: Date

    init(
        id: UUID = UUID(),
        hostID: UUID?,
        title: String,
        detail: String? = nil,
        systemImage: String = "info.circle",
        level: Level = .info,
        date: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.level = level
        self.date = date
    }
}

struct RemoteDeleteEntry: Sendable {
    let path: String
    let isDirectory: Bool
}

enum HostKeyRetryContext {
    case connect(hostID: UUID)
    case testEditor(HostEditorDraft)
}

/// Keeps the inspector's window-level visibility preference deliberately small
/// and testable. A fresh install starts with the inspector hidden so the primary
/// workspace gets the available width; once the user toggles it, that explicit
/// choice wins on every later launch.
enum InspectorVisibilityPreference {
    static let key = "isInspectorVisible.v1"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    static func save(_ isVisible: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(isVisible, forKey: key)
    }
}

/// Shows the welcome/quick-start window once for each user-visible app
/// version. Build-number-only updates do not interrupt the user again.
enum WelcomePresentationPolicy {
    static let lastPresentedVersionKey = "lastPresentedWelcomeVersion.v1"

    static func currentMarketingVersion(in bundle: Bundle = .main) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func shouldPresent(
        version: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.string(forKey: lastPresentedVersionKey) != version
    }

    static func markPresented(
        version: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(version, forKey: lastPresentedVersionKey)
    }
}

enum TerminalFontPreference {
    static let key = "terminalFontSize.v1"
    static let defaultSize: CGFloat = 13
    static let allowedRange: ClosedRange<CGFloat> = 10...22

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return defaultSize }
        return min(max(defaults.double(forKey: key), allowedRange.lowerBound), allowedRange.upperBound)
    }

    static func save(_ size: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(min(max(size, allowedRange.lowerBound), allowedRange.upperBound), forKey: key)
    }
}

final class RemoteTransferControl {
    var isPaused = false
    var isCancelled = false

    func reset() {
        isPaused = false
        isCancelled = false
    }
}

@MainActor
final class AppState: ObservableObject {
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case warning(String)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:
                return String(localized: "未连接服务器")
            case .connecting:
                return String(localized: "正在连接")
            case .connected:
                return String(localized: "已连接")
            case .warning(let message):
                return message
            case .failed(let message):
                return message
            }
        }
    }

    @Published var currentHostName: String = "OpsDeck"
    @Published var selectedSidebarHostID: UUID? {
        didSet {
            guard selectedSidebarHostID != oldValue else { return }
            bindActiveSession()
        }
    }
    @Published var hosts: [HostProfile] = []
    @Published var groups: [HostGroup] = []
    @Published var snippets: [CommandSnippet] = []
    @Published var transferTasks: [TransferTask] = []
    @Published var commandRuns: [CommandRun] = []
    @Published var operationNotices: [AppOperationNotice] = []
    @Published private(set) var operationHistoryDisplayLimit = 10
    @Published private(set) var hasMoreOperationHistory = false
    @Published private(set) var isLoadingMoreOperationHistory = false
    @Published var storageError: String?
    @Published var proPromptMessage: String?
    @Published var hostEditorDraft: HostEditorDraft?
    @Published var hostEditorError: String?
    @Published var hostEditorTestMessage: String?
    @Published var isTestingHostEditorConnection = false
    @Published var pendingHostKeyChallenge: KnownHostChallenge?
    @Published private(set) var knownHostRecords: [KnownHostRecord] = []
    @Published private(set) var isTouchIDAvailable = false
    @Published private(set) var touchIDAvailabilityDetail = ""
    @Published var touchIDError: String?
    @Published var localRootDirectoryURL: URL?
    @Published var localDirectoryURL: URL?
    @Published var localFiles: [LocalFileItem] = []
    @Published var selectedLocalFileID: URL?
    @Published var isLocalFileLoading = false
    @Published var localFileError: String?
    @Published var selectedAppearanceMode: AppAppearanceMode = .system
    @Published var isInspectorVisible = InspectorVisibilityPreference.load() {
        didSet {
#if DEBUG
            guard ProcessInfo.processInfo.environment["OPSDECK_SCREENSHOT_MODE"] != "1" else { return }
#endif
            InspectorVisibilityPreference.save(isInspectorVisible)
        }
    }

    /// The terminal is opened on demand rather than docked permanently.
    @Published var isTerminalVisible = false
    @Published var terminalFontSize = TerminalFontPreference.load() {
        didSet { TerminalFontPreference.save(terminalFontSize) }
    }


    /// Toggle the terminal panel; opening it also spins up a tab if needed.
    func toggleTerminal() {
        if isTerminalVisible {
            isTerminalVisible = false
            return
        }
        guard let host = selectedHost, connectionStatus == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        isTerminalVisible = true
        if let tab = selectedTerminalTab, tab.hostID == host.id {
            if tab.status == .disconnected {
                reconnectActiveTerminalTab()
            }
        } else {
            openTerminalTabForSelectedHost()
        }
    }
    @Published var dangerousAction: DangerousActionRequest?
    @Published var toolCatalog: [ToolDefinition] = []
    @Published var guideTopics: [GuideTopic] = []
    @Published var deploymentTemplates: [DeploymentTemplate] = []
    @Published var terminalTabs: [TerminalSessionTab] = []
    @Published var selectedTerminalTabID: UUID?
    @Published var terminalCommand: String = ""
    @Published var terminalOutput: String = String(localized: "$ 请选择服务器并连接。\n")
    @Published var isTerminalRunning = false
    @Published var isShowingProUnlock = false
    @Published private(set) var isCheckingForAppUpdate = false
    @Published private(set) var appUpdateStatusMessage: String?

    static let minTerminalPanelHeight: CGFloat = 180
    static let defaultTerminalPanelHeight: CGFloat = 360
    static let maxTerminalPanelHeight: CGFloat = 520

    let credentialStore = CredentialStore()
    let knownHostStore = KnownHostStore.shared
    let localAuthenticationService = LocalAuthenticationService()
    let sshService = SSHService()
    /// Database queries use their own pooled SSH transport so stopping a slow
    /// query never tears down the terminal, file browser, or runbook channel.
    let databaseSSHService = SSHService()
    let sftpService = SFTPService()
    let localFileService = LocalFileService()
    let sessionManager = SSHSessionManager()
    let terminalService = TerminalService()
    let serverStatusService = ServerStatusService()
    let serverProfileService = ServerProfileService()
    let runbookService = RunbookService()
    let serviceManagerService = ServiceManagerService()
    let logDiscoveryService = LogDiscoveryService()
    let nginxManagerService = NginxManagerService()
    let installerCatalogService = InstallerCatalogService()
    let guideCatalogService = GuideCatalogService()
    let dockerManagerService = DockerManagerService()
    let databaseManagerService = DatabaseManagerService()
    let redisManagerService = RedisManagerService()
    /// CLI-over-SSH query engine for the database browser (Navicat-lite). Behind
    /// the `DatabaseQueryEngine` protocol so a native-driver engine can replace it.
    let databaseBrowser: DatabaseQueryEngine = CLIDatabaseEngine()
    let firewallService = FirewallService()
    let pm2Service = PM2Service()
    let certbotService = CertbotService()
    let caddyService = CaddyService()
    let fail2banService = Fail2banService()
    let cronService = CronService()
    let mirrorService = MirrorService()
    let shellPathService = ShellPathService()
    let deploymentTemplateService = DeploymentTemplateService()
    let securityAuditService = SecurityAuditService()
    let purchaseService = PurchaseService()
    let appUpdateService = AppUpdateService()
    let storage: StorageService
    let entitlements = EntitlementService()
    private(set) var settings: AppSettings?

    // MARK: - Per-host sessions
    //
    // One `ServerSession` per configured host. Deliberately NOT `@Published`:
    // it is mutated (get-or-create) from view-adjacent code paths, and a
    // published mutation during a SwiftUI body evaluation would trip
    // "Modifying state during view update". The dictionary's *contents* drive
    // the UI only indirectly — via `selectedSidebarHostID` (published) selecting
    // which session `activeSession` returns, and via the `objectWillChange`
    // bridge below re-publishing the active session's own changes.
    private var sessions: [UUID: ServerSession] = [:]
    private var activeSessionCancellable: AnyCancellable?

    /// Live connection status per host, mirrored from each host's session whenever
    /// its `connectionStatus` changes. Lets the sidebar show EVERY connected host
    /// as green — not just the selected one — so switching away from a connected
    /// server (without disconnecting) keeps its dot green. Updated only on the
    /// (infrequent) connection-status transition, so it churns rarely.
    @Published private(set) var connectionStates: [UUID: ConnectionStatus] = [:]

    /// The live connection status for a host (defaults to disconnected).
    func connectionState(for hostID: UUID) -> ConnectionStatus {
        connectionStates[hostID] ?? .disconnected
    }

    /// Called by a `ServerSession` when its connection status changes.
    func noteConnectionStatus(for hostID: UUID, _ status: ConnectionStatus) {
        connectionStates[hostID] = status
    }

    /// The session for the currently-selected sidebar host, or `nil` when no host
    /// is selected (e.g. no hosts configured yet). Pure lookup — never creates —
    /// so it is safe to read from a view body. Creation happens in
    /// `bindActiveSession()` (driven by `selectedSidebarHostID.didSet`).
    var activeSession: ServerSession? {
        guard let id = selectedSidebarHostID else { return nil }
        return sessions[id]
    }

    /// Existing per-host session lookup for server-scoped sidebar children.
    /// This never creates a session, so it is safe to call while rendering.
    func session(for hostID: UUID) -> ServerSession? {
        sessions[hostID]
    }

    /// Refresh each live session's `host` from the freshly-fetched `hosts`, and
    /// drop sessions whose host was deleted. Keeps display + config current after
    /// an edit without recreating the session (which would lose live state).
    private func syncSessionsWithHosts() {
        for (id, session) in sessions {
            if let host = hosts.first(where: { $0.id == id }) {
                session.host = host
            } else {
                sessions[id] = nil
                connectionStates[id] = nil
            }
        }
    }

    /// Get-or-create the session for `hostID`. Returns `nil` if no such host is
    /// known. Mutating `sessions` here is safe because the dict is not published.
    @discardableResult
    func ensureSession(for hostID: UUID) -> ServerSession? {
        if let existing = sessions[hostID] { return existing }
        guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
        let session = ServerSession(host: host, app: self)
        sessions[hostID] = session
        return session
    }

    /// Ensure the active session exists and re-publish its changes through
    /// `AppState` so views observing `appState` (during the phased migration,
    /// before they switch to `@EnvironmentObject var session`) still refresh when
    /// the active session mutates. Called whenever the selected host changes.
    private func bindActiveSession() {
        guard let id = selectedSidebarHostID, let session = ensureSession(for: id) else {
            activeSessionCancellable = nil
            return
        }
        activeSessionCancellable = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var didStart = false
    private var welcomeWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var isAppUpdateAlertPresented = false
    private let operationHistoryPageSize = 10
    private var terminalStreamTasks: [UUID: Task<Void, Never>] = [:]
    private let terminalTranscriptByteLimit = 2 * 1024 * 1024
    private var hostKeyRetryContext: HostKeyRetryContext?

    init() {
        do {
            storage = try StorageService()
        } catch {
            storage = try! StorageService(inMemory: true)
            storageError = String(localized: "本地数据库打开失败，当前使用临时存储。")
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        reload()
        refreshKnownHosts()
        refreshTouchIDAvailability()
        restoreLocalDirectory()
#if DEBUG
        if ScreenshotRenderer.isEnabled {
            ScreenshotRenderer.applyDemoState(to: self)
            if ScreenshotRenderer.renderMainViewIfRequested(appState: self) {
                NSApp.terminate(nil)
                return
            }
            if ScreenshotRenderer.renderIfRequested(appState: self) {
                NSApp.terminate(nil)
                return
            }
            if ScreenshotRenderer.captureEditorWindowIfRequested() {
                return
            }
            if ScreenshotRenderer.captureMainWindowIfRequested() {
                return
            }
        }
#endif
        showWelcomeIfNeeded()
        scheduleAutomaticAppUpdateCheck()
        Task {
            await refreshPurchaseEntitlements()
        }
    }

    private func showWelcomeIfNeeded() {
#if DEBUG
        guard !ScreenshotRenderer.isEnabled,
              ProcessInfo.processInfo.environment["OPSDECK_SMOKE_TEST"] == nil else { return }
#endif
        guard let version = WelcomePresentationPolicy.currentMarketingVersion(),
              WelcomePresentationPolicy.shouldPresent(version: version) else { return }
        WelcomePresentationPolicy.markPresented(version: version)
        showWelcomeGuide()
    }

    func showWelcomeGuide() {
        NSApp.activate(ignoringOtherApps: true)
        if let welcomeWindow {
            welcomeWindow.center()
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }

        let view = WelcomeView(
            onAddServer: { [weak self] in
                self?.welcomeWindow?.close()
                self?.showMainWindow()
                self?.openNewHostEditor()
                self?.checkForAppUpdateIfNeeded()
            },
            onClose: { [weak self] in
                self?.welcomeWindow?.close()
                self?.showMainWindow()
                self?.checkForAppUpdateIfNeeded()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "欢迎使用 OpsDeck")
        window.identifier = NSUserInterfaceItemIdentifier("OpsDeckWelcomeWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(WelcomeView.contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        welcomeWindow = window
    }

    func checkForAppUpdateIfNeeded() {
#if DEBUG
        guard !ScreenshotRenderer.isEnabled,
              ProcessInfo.processInfo.environment["OPSDECK_SMOKE_TEST"] == nil else { return }
#endif
        guard didStart,
              welcomeWindow?.isVisible != true,
              !isCheckingForAppUpdate,
              AppUpdatePolicy.shouldPerformAutomaticLookup() else { return }
        performAppUpdateCheck(isManual: false)
    }

    func checkForAppUpdateManually() {
        guard !isCheckingForAppUpdate else { return }
        performAppUpdateCheck(isManual: true)
    }

    private func scheduleAutomaticAppUpdateCheck() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkForAppUpdateIfNeeded()
        }
    }

    private func performAppUpdateCheck(isManual: Bool) {
        guard let currentVersion = WelcomePresentationPolicy.currentMarketingVersion() else {
            if isManual {
                appUpdateStatusMessage = String(localized: "无法读取当前版本。")
            }
            return
        }

        AppUpdatePolicy.recordLookupAttempt()
        isCheckingForAppUpdate = true
        if isManual {
            appUpdateStatusMessage = String(localized: "正在向 App Store 检查更新…")
        }

        Task { [weak self] in
            guard let self else { return }
            defer { isCheckingForAppUpdate = false }
            do {
                guard let release = try await appUpdateService.latestRelease(appID: Links.appStoreID) else {
                    if isManual {
                        appUpdateStatusMessage = String(localized: "暂时无法在 App Store 找到 OpsDeck。")
                    }
                    return
                }

                guard AppVersion.isNewer(release.version, than: currentVersion) else {
                    if isManual {
                        appUpdateStatusMessage = String(
                            format: String(localized: "当前已是最新版本（%@）。"),
                            currentVersion
                        )
                    }
                    return
                }

                appUpdateStatusMessage = String(
                    format: String(localized: "App Store 最新版本为 %@。"),
                    release.version
                )
                if isManual || AppUpdatePolicy.shouldPresent(
                    latestVersion: release.version,
                    currentVersion: currentVersion
                ) {
                    presentAppUpdateAlert(release: release, currentVersion: currentVersion)
                }
            } catch {
                if isManual {
                    appUpdateStatusMessage = String(localized: "无法检查更新，请稍后重试。")
                }
            }
        }
    }

    private func presentAppUpdateAlert(release: AppStoreRelease, currentVersion: String) {
        guard !isAppUpdateAlertPresented else { return }
        isAppUpdateAlertPresented = true
        AppUpdatePolicy.recordPresented(version: release.version)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "发现新版本")
        alert.informativeText = String(
            format: String(localized: "OpsDeck %@ 已可下载，你当前使用 %@。"),
            release.version,
            currentVersion
        )
        alert.addButton(withTitle: String(localized: "前往 App Store"))
        alert.addButton(withTitle: String(localized: "稍后提醒"))
        alert.addButton(withTitle: String(localized: "忽略此版本"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            isAppUpdateAlertPresented = false
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(release.storeURL ?? Links.appStoreProduct)
            case .alertThirdButtonReturn:
                AppUpdatePolicy.ignore(version: release.version)
                appUpdateStatusMessage = String(
                    format: String(localized: "已忽略版本 %@。"),
                    release.version
                )
            default:
                break
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    func showHelpGuide() {
        NSApp.activate(ignoringOtherApps: true)
        if let helpWindow {
            helpWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 920, height: 680)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "OpsDeck 使用指南")
        window.identifier = NSUserInterfaceItemIdentifier("OpsDeckHelpWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentView = NSHostingView(
            rootView: GuideWorkspaceView(session: activeSession).environmentObject(self)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        helpWindow = window
    }

    func toggleInspector() {
        isInspectorVisible.toggle()
    }

    private func showMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("OpsDeckMainWindow")
        }) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        do {
            try storage.removeLegacySampleDataIfNeeded()
            let fetchedSettings = try storage.fetchSettings()
            settings = fetchedSettings
            selectedAppearanceMode = fetchedSettings.appearanceMode
            applyAppearanceMode(fetchedSettings.appearanceMode)
            groups = try storage.fetchGroups()
            hosts = try storage.fetchHosts()
            snippets = try storage.fetchSnippets()
            try refreshOperationHistory()
            toolCatalog = installerCatalogService.catalog()
            refreshGuideTopics()
            deploymentTemplates = deploymentTemplateService.templates()
            syncSessionsWithHosts()
            selectedSidebarHostID = selectedSidebarHostID ?? hosts.first?.id
            // `didSet` fires only when the id actually changes; when it doesn't
            // (host merely edited), rebind explicitly so the active session's
            // refreshed `host` re-publishes.
            bindActiveSession()
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Switch which host the UI is showing. In the multi-session model this is a
    /// pure *swap*: it selects the host (the `selectedSidebarHostID.didSet`
    /// ensures/binds that host's `ServerSession`) and re-points the terminal
    /// focus to that host's tab. It does NOT disconnect, reset, or reload — each
    /// host's `ServerSession` retains its own live connection + state, so
    /// switching back and forth is instantaneous and non-destructive (like
    /// switching browser tabs). Connecting/loading happens lazily via
    /// `connectSelectedHost()` when the user connects.
    func selectHost(_ host: HostProfile) {
        selectedSidebarHostID = host.id
        currentHostName = host.name
        selectedTerminalTabID = liveTerminalTab(for: host.id)?.id
            ?? terminalTabs.first { $0.hostID == host.id }?.id
    }

    func canStartAddingHost() -> Bool {
        guard let settings else { return true }
        switch entitlements.canAddHost(currentHostCount: hosts.count, settings: settings) {
        case .allowed:
            proPromptMessage = nil
            return true
        case .needsPro(let message):
            proPromptMessage = message
            return false
        }
    }

    var isProUnlocked: Bool {
        guard let settings else { return false }
        return entitlements.isProUnlocked(settings: settings)
    }

    func openNewHostEditor() {
        guard canStartAddingHost() else { return }
        hostEditorError = nil
        hostEditorDraft = HostEditorDraft()
    }

    func editHost(_ host: HostProfile) {
        hostEditorError = nil
        hostEditorDraft = HostEditorDraft(host: host)
    }

    func closeHostEditor() {
        hostEditorDraft = nil
        hostEditorError = nil
        hostEditorTestMessage = nil
        isTestingHostEditorConnection = false
    }

    func saveHostDraft(_ draft: HostEditorDraft) {
        if let error = draft.validationError() {
            hostEditorError = error
            return
        }
        do {
            let saved = try storage.saveHostDraft(draft, credentialStore: credentialStore)
            closeHostEditor()
            reload()
            selectedSidebarHostID = saved.id
            currentHostName = saved.name
        } catch {
            hostEditorError = error.localizedDescription
        }
    }

    func deleteHost(_ host: HostProfile) {
        do {
            try storage.deleteHost(host, credentialStore: credentialStore)
            reload()
            if selectedSidebarHostID == host.id {
                selectedSidebarHostID = hosts.first?.id
                currentHostName = hosts.first?.name ?? "OpsDeck"
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    var selectedHost: HostProfile? {
        guard let selectedSidebarHostID else { return nil }
        return hosts.first { $0.id == selectedSidebarHostID }
    }

    /// Native List `.onMove` reorder within a section. `sectionHostIDs` is the
    /// section's hosts in current order; `source`/`destination` are the move. The
    /// reordered members are slotted back into their global positions and the full
    /// order is persisted.
    func moveHosts(_ sectionHostIDs: [UUID], from source: IndexSet, to destination: Int) {
        var reordered = sectionHostIDs
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != sectionHostIDs else { return }
        let sectionSet = Set(sectionHostIDs)
        var next = reordered.makeIterator()
        let newOrder = hosts.map(\.id).map { sectionSet.contains($0) ? (next.next() ?? $0) : $0 }
        do {
            try storage.persistHostOrder(newOrder)
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func createGroup(named name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try storage.createGroup(name: name)
            groups = try storage.fetchGroups()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func renameGroup(_ group: HostGroup, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try storage.renameGroup(group, name: name)
            groups = try storage.fetchGroups()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func deleteGroup(_ group: HostGroup) {
        do {
            try storage.deleteGroup(group)
            groups = try storage.fetchGroups()
            hosts = try storage.fetchHosts()
            syncSessionsWithHosts()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func assignHost(_ host: HostProfile, to groupID: UUID?) {
        do {
            try storage.assignHost(host, to: groupID)
            hosts = try storage.fetchHosts()
            syncSessionsWithHosts()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func importSSHConfig(_ entries: [SSHConfigEntry]) {
        var imported = 0
        var skipped = 0
        for entry in entries {
            if hosts.contains(where: {
                $0.host.caseInsensitiveCompare(entry.hostname) == .orderedSame
                    && $0.port == entry.port
                    && $0.username.caseInsensitiveCompare(entry.username) == .orderedSame
            }) {
                skipped += 1
                continue
            }
            var draft = HostEditorDraft()
            draft.name = entry.alias
            draft.host = entry.hostname
            draft.portText = String(entry.port)
            draft.username = entry.username
            if let privateKey = entry.privateKeyText {
                draft.authType = .privateKey
                draft.privateKeyText = privateKey
            } else {
                draft.authType = .password
            }
            do {
                _ = try storage.saveHostDraft(draft, credentialStore: credentialStore)
                imported += 1
            } catch {
                skipped += 1
            }
        }
        reload()
        recordOperationNotice(
            title: String(localized: "SSH Config 导入完成"),
            detail: String(localized: "已导入 \(imported) 台，跳过 \(skipped) 台"),
            systemImage: "square.and.arrow.down",
            level: skipped == 0 ? .success : .warning
        )
    }

    func createSnippet(title: String, command: String, group: String, requiresConfirmation: Bool) {
        do {
            try storage.createSnippet(title: title, command: command, group: group, requiresConfirmation: requiresConfirmation)
            snippets = try storage.fetchSnippets()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func updateSnippet(_ snippet: CommandSnippet, title: String, command: String, group: String, requiresConfirmation: Bool) {
        do {
            try storage.updateSnippet(snippet, title: title, command: command, group: group, requiresConfirmation: requiresConfirmation)
            snippets = try storage.fetchSnippets()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func deleteSnippet(_ snippet: CommandSnippet) {
        do {
            try storage.deleteSnippet(snippet)
            snippets = try storage.fetchSnippets()
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Per-host context-menu actions

    /// Connect a specific host (switches to it first, so its connect is the
    /// foreground one).
    func connectHost(_ host: HostProfile) {
        selectHost(host)
        ensureSession(for: host.id)?.connect()
    }

    /// Disconnect a specific host without needing to select it.
    func disconnectHost(_ host: HostProfile) {
        sessions[host.id]?.disconnect()
    }

    /// Open a terminal tab for a specific host (switches to it first).
    func openTerminalForHost(_ host: HostProfile) {
        selectHost(host)
        guard connectionState(for: host.id) == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        openTerminalTabForSelectedHost()
    }

    /// Copy `user@host:port` for a host to the clipboard.
    func copyHostAddress(_ host: HostProfile) {
        let address = "\(host.username)@\(host.host):\(host.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        recordOperationNotice(
            title: String(localized: "已复制服务器地址"),
            detail: address,
            systemImage: "doc.on.doc",
            level: .success
        )
    }

    /// Drag-to-reorder the sidebar: move `draggedID` to just before `targetID`
    /// and persist the new order. No-op if either host is missing or they're the
    /// same row.
    func moveHost(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        var ordered = hosts
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }) else { return }
        let moved = ordered.remove(at: from)
        guard let target = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.insert(moved, at: target)
        do {
            try storage.persistHostOrder(ordered.map(\.id))
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }


    var selectedLocalFile: LocalFileItem? {
        guard let selectedLocalFileID else { return nil }
        return localFiles.first { $0.id == selectedLocalFileID }
    }

    func testHostEditorConnection(_ draft: HostEditorDraft) {
        if let error = draft.validationError() {
            hostEditorError = error
            return
        }

        hostEditorError = nil
        hostEditorTestMessage = nil
        isTestingHostEditorConnection = true
        Task {
            defer { isTestingHostEditorConnection = false }
            do {
                try await authorizeSensitiveAccessIfNeeded()
                let config = try makeConnectionConfig(from: draft)
                let result = try await sshService.runConnectionTest(config: config)
                hostEditorTestMessage = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                if !presentHostKeyChallengeIfNeeded(error, retry: .testEditor(draft)) {
                    hostEditorError = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func presentHostKeyChallengeIfNeeded(_ error: Error, retry: HostKeyRetryContext) -> Bool {
        let challenge: KnownHostChallenge
        if case SSHServiceError.hostKeyTrustRequired(let value) = error {
            challenge = value
        } else if case SSHServiceError.hostKeyChanged(let value) = error {
            challenge = value
        } else {
            return false
        }
        hostKeyRetryContext = retry
        pendingHostKeyChallenge = challenge
        return true
    }

    func trustPendingHostKey() {
        guard let challenge = pendingHostKeyChallenge else { return }
        knownHostStore.trust(challenge)
        let retry = hostKeyRetryContext
        pendingHostKeyChallenge = nil
        hostKeyRetryContext = nil
        refreshKnownHosts()
        switch retry {
        case .connect(let hostID):
            ensureSession(for: hostID)?.connect()
        case .testEditor(let draft):
            testHostEditorConnection(draft)
        case nil:
            break
        }
    }

    func rejectPendingHostKey() {
        if let challenge = pendingHostKeyChallenge {
            knownHostStore.reject(challenge)
        }
        pendingHostKeyChallenge = nil
        hostKeyRetryContext = nil
    }

    func refreshKnownHosts() {
        knownHostRecords = knownHostStore.records()
    }

    func removeKnownHost(_ record: KnownHostRecord) {
        knownHostStore.remove(endpoint: record.endpoint)
        refreshKnownHosts()
    }

    func removeAllKnownHosts() {
        knownHostStore.removeAll()
        refreshKnownHosts()
    }

    /// Connect the currently-selected host. The actual connect flow lives on the
    /// host's own `ServerSession` (so it writes that host's state even if the user
    /// switches away mid-connect); this just routes to it.
    func connectSelectedHost() {
        guard let session = activeSession else {
            proPromptMessage = nil
            return
        }
        session.connect()
    }

    /// Disconnect the currently-selected host. Only that host's session is torn
    /// down; other connected hosts are unaffected.
    func disconnectSelectedHost() {
        activeSession?.disconnect()
    }

    var canNavigateToParentLocalDirectory: Bool {
        guard let root = localRootDirectoryURL,
              let current = localDirectoryURL,
              current != root else {
            return false
        }
        return current.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false))
    }

    func chooseLocalDirectory() {
        do {
            guard let selection = try localFileService.chooseDirectory() else { return }
            try storage.updateDefaultLocalDirectoryBookmark(selection.bookmarkData)
            settings?.defaultLocalDirectoryBookmark = selection.bookmarkData
            localRootDirectoryURL = selection.url
            loadLocalDirectory(selection.url)
        } catch {
            localFileError = error.localizedDescription
        }
    }

    func refreshLocalDirectory() {
        guard let directory = localDirectoryURL else { return }
        loadLocalDirectory(directory)
    }

    func openLocalFileItem(_ item: LocalFileItem) {
        selectedLocalFileID = item.id
        if item.isDirectory {
            loadLocalDirectory(item.url)
        } else {
            localFileService.revealInFinder(item.url)
        }
    }

    func selectLocalFileItem(_ item: LocalFileItem) {
        selectedLocalFileID = item.id
    }

    func navigateToParentLocalDirectory() {
        guard canNavigateToParentLocalDirectory,
              let current = localDirectoryURL else {
            return
        }
        loadLocalDirectory(current.deletingLastPathComponent())
    }

    private func restoreLocalDirectory() {
        guard let bookmark = settings?.defaultLocalDirectoryBookmark else { return }
        do {
            let selection = try localFileService.restoreDirectory(from: bookmark)
            localRootDirectoryURL = selection.url
            loadLocalDirectory(selection.url)
        } catch {
            localFileService.stopAccessingDirectory()
            localRootDirectoryURL = nil
            localDirectoryURL = nil
            localFiles = []
            localFileError = error.localizedDescription
        }
    }

    func loadLocalDirectory(_ directory: URL) {
        isLocalFileLoading = true
        defer { isLocalFileLoading = false }
        do {
            localFiles = try localFileService.listDirectory(at: directory)
            localDirectoryURL = directory
            localFileError = nil
        } catch {
            localFiles = []
            localFileError = error.localizedDescription
        }
    }









































    func runTerminalCommand() {
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        terminalCommand = ""
        requestRunTerminalCommand(command: command)
    }

    func pasteClipboardIntoActiveContext() {
        if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
            return
        }

        let pasteboard = NSPasteboard.general
        let fileURLs = fileURLsFromPasteboard(pasteboard)
        if !fileURLs.isEmpty {
            guard connectionStatus == .connected else {
                remoteFileError = String(localized: "请先连接服务器再粘贴上传。")
                return
            }
            fileURLs.forEach { activeSession?.uploadDroppedLocalFile($0) }
            return
        }

        if let image = NSImage(pasteboard: pasteboard) {
            guard connectionStatus == .connected else {
                remoteFileError = String(localized: "请先连接服务器再粘贴图片。")
                return
            }
            do {
                let url = try temporaryClipboardImageURL(for: image)
                activeSession?.uploadDroppedLocalFile(url)
            } catch {
                remoteFileError = error.localizedDescription
            }
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        sendStringToActiveTerminal(text)
    }

    /// Route Command-A to the focused text editor first; otherwise select every
    /// item in the active remote-file workspace. This keeps native text behavior
    /// while adding Finder-style Select All to SwiftUI file rows.
    func selectAllInActiveContext() {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
            return
        }
        if let session = activeSession,
           session.selectedWorkspaceMode == .files,
           !session.remoteFiles.isEmpty {
            session.selectAllRemoteFiles()
            return
        }
        NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
    }

    func pasteClipboardIntoTerminalCommand() {
        pasteClipboardIntoActiveContext()
    }

    func pasteCommandRun(_ run: CommandRun) {
        guard connectionStatus == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        if let host = selectedHost {
            if let existing = terminalTabs.last(where: { $0.hostID == host.id }) {
                selectedTerminalTabID = existing.id
            } else {
                openTerminalTabForSelectedHost()
            }
        }
        sendStringToActiveTerminal(run.command)
    }

    func runSnippet(_ snippet: CommandSnippet) {
        if snippet.requiresConfirmation {
            dangerousAction = DangerousActionRequest(kind: .runCommand(command: snippet.command, snippetID: snippet.id))
            return
        }
        requestRunTerminalCommand(command: snippet.command, snippetID: snippet.id)
    }

    func copyDiagnosticLog() {
        let log = makeDiagnosticLog()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log, forType: .string)
        recordOperationNotice(
            title: String(localized: "已复制诊断日志"),
            systemImage: "doc.on.doc",
            level: .success
        )
    }

    func copyRunbookDetails(_ run: RunbookRun) {
        let report = redactSensitiveStrings(run.diagnosticReport())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        recordOperationNotice(
            title: String(localized: "已复制执行详情"),
            detail: run.title,
            systemImage: "doc.on.doc",
            level: .success
        )
    }

    func copyToolPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        recordOperationNotice(
            title: String(localized: "已复制工具路径"),
            detail: path,
            systemImage: "doc.on.doc",
            level: .success
        )
    }

    func exportDiagnosticLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "OpsDeck-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeDiagnosticLog().write(to: url, atomically: true, encoding: .utf8)
            recordOperationNotice(
                title: String(localized: "已导出诊断日志"),
                detail: url.path(percentEncoded: false),
                systemImage: "square.and.arrow.up",
                level: .success
            )
            localFileService.revealInFinder(url)
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func makeDiagnosticLog() -> String {
        let formatter = ISO8601DateFormatter()
        let host = selectedHost
        var lines: [String] = [
            String(localized: "OpsDeck 诊断日志"),
            String(localized: "生成时间: \(formatter.string(from: Date()))"),
            "App: \(Bundle.main.bundleIdentifier ?? "OpsDeck") \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
            "",
            String(localized: "连接"),
            String(localized: "- 当前服务器: \(host?.name ?? String(localized: "未选择"))"),
            String(localized: "- 端点: \(host == nil ? String(localized: "未选择") : "<redacted-host>:\(host?.port ?? 22)")"),
            String(localized: "- 用户名: \(host == nil ? String(localized: "未选择") : "<redacted-user>")"),
            String(localized: "- 状态: \(connectionStatus.label)"),
            String(localized: "- 远端路径: \(remoteDirectoryPath)"),
            String(localized: "- 远端错误: \(redactSensitiveStrings(remoteFileError ?? String(localized: "无")))"),
            String(localized: "- 文本文件: \(remoteTextDocument?.path ?? String(localized: "未打开"))"),
            String(localized: "- 文本加载: \(remoteTextDocument.map { "\($0.loadedByteCount) bytes / \($0.content.count) characters" } ?? String(localized: "无"))"),
            String(localized: "- 文本错误: \(redactSensitiveStrings(remoteTextError ?? String(localized: "无")))"),
            String(localized: "- 存储错误: \(redactSensitiveStrings(storageError ?? String(localized: "无")))"),
            ""
        ]

        lines.append(String(localized: "最近传输"))
        if transferTasks.isEmpty {
            lines.append(String(localized: "- 无"))
        } else {
            for task in transferTasks.prefix(20) {
                let localName = (task.localPath as NSString).lastPathComponent
                let errorMessage = redactSensitiveStrings(task.errorMessage ?? String(localized: "无"))
                lines.append("- \(task.direction.displayName) \(task.status.displayName) remote=\(task.remotePath) local=\(localName) bytes=\(task.bytesTransferred) error=\(errorMessage)")
            }
        }

        lines.append("")
        lines.append(String(localized: "最近命令"))
        if commandRuns.isEmpty {
            lines.append(String(localized: "- 无"))
        } else {
            for run in commandRuns.prefix(20) {
                let command = redactSensitiveStrings(redactedCommand(run.command))
                lines.append("- \(formatter.string(from: run.startedAt)) \(command) duration=\(String(format: "%.2fs", run.duration)) exit=\(run.exitCode)")
            }
        }

        lines.append("")
        lines.append(String(localized: "最近 Runbook"))
        if runbookRuns.isEmpty {
            lines.append(String(localized: "- 无"))
        } else {
            for run in runbookRuns.prefix(20) {
                let error = redactSensitiveStrings(run.errorMessage ?? String(localized: "无"))
                lines.append("- \(formatter.string(from: run.startedAt)) \(run.title) status=\(run.status.displayName) duration=\(String(format: "%.2fs", run.duration)) error=\(error)")
            }
        }

        lines.append("")
        lines.append("OPSDECK_DB_PERF 最近数据库性能")
        if let events = activeSession?.dbState.dbPerformanceEvents, !events.isEmpty {
            for event in events.suffix(30) {
                lines.append("- \(formatter.string(from: event.capturedAt)) \(event.diagnosticLine)")
            }
        } else {
            lines.append(String(localized: "- 无"))
        }

        lines.append("")
        lines.append(String(localized: "终端输出（最近 12000 字符）"))
        lines.append(redactSensitiveStrings(String(activeTerminalOutput.suffix(12_000))))
        return lines.joined(separator: "\n")
    }

    private func redactSensitiveStrings(_ value: String) -> String {
        guard let host = selectedHost else { return value }
        var redacted = value
        if !host.host.isEmpty {
            redacted = redacted.replacingOccurrences(of: host.host, with: "<redacted-host>")
        }
        if !host.username.isEmpty {
            redacted = redacted.replacingOccurrences(of: host.username, with: "<redacted-user>")
        }
        return redacted
    }

    func confirmDangerousAction() {
        guard let request = dangerousAction else { return }
        dangerousAction = nil
        // The confirmation modal is global chrome, but every confirmed action must
        // execute against the host whose session CREATED the request — never
        // whatever host happens to be displayed now — so switching hosts while the
        // modal is open can't fire a destructive action at the wrong server.
        let session = request.hostID.flatMap { sessions[$0] } ?? activeSession
        switch request.kind {
        case .deleteRemote(let items):
            let detail = items.count == 1 ? (items.first?.path ?? "") : String(localized: "\(items.count) 个项目")
            appendTerminalLine(String(localized: "已确认删除：\(detail)"))
            session?.deleteRemoteFiles(items)
        case .createRemoteFile(let remotePath):
            guard let host = session?.host else { return }
            appendTerminalLine(String(localized: "已确认用空文件覆盖：\(remotePath)"))
            session?.performCreateRemoteFile(remotePath: remotePath, host: host)
        case .uploadOverwrite(let localURL, let byteSize, let remotePath):
            guard let host = session?.host else { return }
            appendTerminalLine(String(localized: "已确认覆盖：\(remotePath)"))
            session?.performUploadLocalItem(url: localURL, byteSize: byteSize, remotePath: remotePath, host: host)
        case .compressRemote(let items, let archivePath):
            let detail = items.count == 1 ? (items.first?.path ?? "") : String(localized: "\(items.count) 个项目")
            appendTerminalLine(String(localized: "已确认压缩：\(detail)"))
            session?.compressRemoteItems(items, archivePath: archivePath)
        case .saveRemoteText:
            guard let document = session?.remoteTextDocument else { return }
            appendTerminalLine(String(localized: "已确认保存远端文件：\(document.path)"))
            session?.performSaveRemoteTextDocument(document)
        case .runCommand(let command, let snippetID):
            appendTerminalLine(String(localized: "已确认执行命令"))
            runTerminalCommand(command: command, snippetID: snippetID, bypassConfirmation: true)
        }
    }

    // MARK: - Thin forwarders to the active session
    //
    // For non-view callers (AppDelegate ⌘R, ScreenshotRenderer, the smoke runner)
    // that historically drove these through `AppState`.

    /// ⌘R / menu refresh — refresh the active host's current workspace.
    func refreshCurrentWorkspace() { activeSession?.refreshCurrentWorkspace() }

    /// Toolbar overview refresh (kept on the facade so the always-present toolbar
    /// need not observe the session directly).
    func refreshServerOverview() { activeSession?.refreshServerOverview() }
    func refreshServerProfile() { activeSession?.refreshServerProfile() }

    /// Open a workbench module on the active session.
    func openWorkbenchModule(_ id: String) { activeSession?.openWorkbenchModule(id) }

    /// Re-collect the active session's current workbench-module data.
    func refreshCurrentWorkbenchModuleData(config: SSHConnectionConfig) async {
        await activeSession?.refreshCurrentWorkbenchModuleData(config: config)
    }

    func cancelActiveRunbook() {
        activeSession?.cancelActiveRunbook()
    }

    func cancelDangerousAction() {
        dangerousAction = nil
    }

    var activeTerminalOutput: String {
        guard let index = selectedTerminalTabIndex else {
            return terminalOutput
        }
        return terminalTabs[index].output
    }

    var activeTerminalOutputBytes: [UInt8] {
        guard let index = selectedTerminalTabIndex else {
            return Array(terminalOutput.utf8)
        }
        return terminalTabs[index].outputBytes
    }

    var activeTerminalStatusLabel: String {
        guard let index = selectedTerminalTabIndex else {
            return connectionStatus.label
        }
        return terminalTabs[index].status.label
    }

    var activeTerminalSizeLabel: String {
        guard let index = selectedTerminalTabIndex else {
            return "-- x --"
        }
        return "\(terminalTabs[index].columns) x \(terminalTabs[index].rows)"
    }

    var activeTerminalWorkingDirectory: String {
        selectedTerminalTab?.workingDirectory ?? "."
    }

    func increaseTerminalFontSize() {
        terminalFontSize = min(terminalFontSize + 1, TerminalFontPreference.allowedRange.upperBound)
    }

    func decreaseTerminalFontSize() {
        terminalFontSize = max(terminalFontSize - 1, TerminalFontPreference.allowedRange.lowerBound)
    }

    func resetTerminalFontSize() {
        terminalFontSize = TerminalFontPreference.defaultSize
    }

    /// Clears only the local scrollback. It does not send `clear` or mutate the
    /// remote shell, so the action is immediate and safe.
    func clearActiveTerminalTranscript() {
        guard let index = selectedTerminalTabIndex else { return }
        terminalTabs[index].output = ""
        terminalTabs[index].outputBytes = []
        terminalTabs[index].updatedAt = Date()
    }

    func openTerminalTabForSelectedHost() {
        guard let host = selectedHost else {
            appendTerminalLine(String(localized: "请先选择服务器。"))
            return
        }
        guard connectionStatus == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        isTerminalVisible = true
        if shellPathSnapshot == nil && !isShellPathLoading {
            activeSession?.refreshShellPath()
        }
        let existingCount = terminalTabs.filter { $0.hostID == host.id }.count
        let title = existingCount == 0 ? host.name : "\(host.name) #\(existingCount + 1)"
        let tab = TerminalSessionTab(
            hostID: host.id,
            title: title,
            output: String(localized: "正在打开 SSH Shell...\n"),
            status: .running,
            workingDirectory: remoteDirectoryPath
        )
        terminalTabs.append(tab)
        selectedTerminalTabID = tab.id
        startTerminalPTY(tabID: tab.id)
    }

    func changeTerminalToCurrentRemoteDirectory() {
        guard let host = selectedHost else {
            recordOperationNotice(
                title: String(localized: "无法切换终端目录"),
                detail: String(localized: "请先选择服务器"),
                systemImage: "exclamationmark.triangle",
                level: .warning
            )
            return
        }
        guard connectionStatus == .connected else {
            recordOperationNotice(
                title: String(localized: "无法切换终端目录"),
                detail: String(localized: "请先连接 \(host.name)"),
                systemImage: "exclamationmark.triangle",
                level: .warning
            )
            return
        }

        let path = remoteDirectoryPath
        guard let tab = terminalTabs.last(where: {
            $0.hostID == host.id && $0.status != .disconnected
        }) else {
            openTerminalTabForSelectedHost()
            recordOperationNotice(
                title: String(localized: "终端进入当前目录"),
                detail: path,
                systemImage: "terminal",
                level: .success
            )
            return
        }

        selectedTerminalTabID = tab.id
        setTerminalWorkingDirectory(path, tabID: tab.id)
        sendDirectoryChangeWhenTerminalIsReady(path: path, tabID: tab.id)
    }

    private func sendDirectoryChangeWhenTerminalIsReady(path: String, tabID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                guard let tab = self.terminalTabs.first(where: { $0.id == tabID }) else { return }
                if tab.status == .idle {
                    self.sendBytesToTerminal(Array("cd \(shellQuote(path))\n".utf8), tabID: tabID)
                    self.recordOperationNotice(
                        title: String(localized: "终端进入当前目录"),
                        detail: path,
                        systemImage: "terminal",
                        level: .success
                    )
                    return
                }
                if tab.status == .disconnected {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.recordOperationNotice(
                title: String(localized: "终端目录切换失败"),
                detail: String(localized: "终端尚未就绪"),
                systemImage: "exclamationmark.triangle",
                level: .warning
            )
        }
    }

    func selectTerminalTab(_ tab: TerminalSessionTab) {
        selectedTerminalTabID = tab.id
    }

    func closeTerminalTab(_ tab: TerminalSessionTab) {
        terminalStreamTasks[tab.id]?.cancel()
        terminalStreamTasks[tab.id] = nil
        Task {
            await terminalService.stopPTY(tabID: tab.id)
        }
        terminalTabs.removeAll { $0.id == tab.id }
        if selectedTerminalTabID == tab.id {
            selectedTerminalTabID = terminalTabs.last?.id
        }
    }

    func reconnectActiveTerminalTab() {
        guard let tab = selectedTerminalTab,
              connectionStatus == .connected else {
            connectSelectedHost()
            return
        }
        startTerminalPTY(tabID: tab.id, shouldClearTranscript: true)
    }

    func updateTerminalViewport(width: CGFloat, height: CGFloat) {
        guard let tabID = selectedTerminalTabID else { return }
        guard let index = selectedTerminalTabIndex else { return }
        let columns = max(40, Int(width / 7.2))
        let rows = max(6, Int(height / 17.0))
        guard terminalTabs[index].columns != columns || terminalTabs[index].rows != rows else { return }
        terminalTabs[index].columns = columns
        terminalTabs[index].rows = rows
        terminalTabs[index].updatedAt = Date()
        Task {
            await terminalService.resizePTY(
                tabID: tabID,
                columns: columns,
                rows: rows,
                pixelWidth: Int(width),
                pixelHeight: Int(height)
            )
        }
    }

    func updateTerminalViewport(
        tabID: UUID,
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let safeColumns = max(columns, 40)
        let safeRows = max(rows, 6)
        guard terminalTabs[index].columns != safeColumns || terminalTabs[index].rows != safeRows else { return }
        terminalTabs[index].columns = safeColumns
        terminalTabs[index].rows = safeRows
        terminalTabs[index].updatedAt = Date()
        Task {
            await terminalService.resizePTY(
                tabID: tabID,
                columns: safeColumns,
                rows: safeRows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    func sendBytesToTerminal(_ bytes: [UInt8], tabID: UUID) {
        guard terminalTabs.contains(where: { $0.id == tabID }) else { return }
        Task {
            do {
                try await terminalService.send(bytes, tabID: tabID)
            } catch {
                appendTerminalLine(error.localizedDescription, tabID: tabID)
                setTerminalStatus(.disconnected, tabID: tabID)
            }
        }
    }

    func sendStringToActiveTerminal(_ text: String) {
        guard connectionStatus == .connected,
              let tab = selectedTerminalTab,
              tab.status != .disconnected else {
            appendTerminalLine(String(localized: "请先打开终端。"))
            return
        }
        sendBytesToTerminal(Array(text.utf8), tabID: tab.id)
    }

    func updateTerminalTitle(_ title: String, tabID: UUID) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }
        terminalTabs[index].title = normalized
        terminalTabs[index].updatedAt = Date()
    }

    func updateTerminalWorkingDirectory(_ directory: String?, tabID: UUID) {
        guard let directory, !directory.isEmpty else { return }
        let normalized: String
        if directory.hasPrefix("file://"),
           let url = URL(string: directory) {
            normalized = url.path(percentEncoded: false)
        } else {
            normalized = directory
        }
        setTerminalWorkingDirectory(normalized, tabID: tabID)
    }










    func refreshToolCatalog() {
        toolCatalog = installerCatalogService.catalog()
        refreshGuideTopics()
    }

    func refreshGuideTopics() {
        let curated = guideCatalogService.topics()
        let catalog = toolCatalog.isEmpty ? installerCatalogService.catalog() : toolCatalog
        guideTopics = curated + guideCatalogService.toolTopics(from: catalog)
    }




















    // MARK: - Per-module operation activity (in-progress / failed-with-retry)


















    // MARK: Firewall







    // MARK: PM2





    // MARK: Certbot / SSL




    // MARK: Caddy





    // MARK: Fail2ban



    // MARK: Cron / 定时任务


    // MARK: Mirror 镜像源






    // MARK: Shell & PATH





    /// Open a new terminal tab that switches to the given shell via `exec`.
    func openTerminalTabForShell(_ shellPath: String) {
        guard let host = selectedHost else {
            appendTerminalLine(String(localized: "请先选择服务器。"))
            return
        }
        guard connectionStatus == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        isTerminalVisible = true
        let name = (shellPath as NSString).lastPathComponent
        let existingCount = terminalTabs.filter { $0.hostID == host.id }.count
        var tab = TerminalSessionTab(
            hostID: host.id,
            title: existingCount == 0 ? "\(host.name) · \(name)" : "\(host.name) · \(name) #\(existingCount + 1)",
            output: String(localized: "正在打开 \(name)...\n"),
            status: .running,
            workingDirectory: remoteDirectoryPath
        )
        tab.shellOverride = shellPath
        terminalTabs.append(tab)
        selectedTerminalTabID = tab.id
        startTerminalPTY(tabID: tab.id)
    }













    private func requestRunTerminalCommand(command: String, snippetID: UUID? = nil) {
        if SafetyService.shouldConfirmDangerousActions(settings: settings),
           SafetyService.isDangerousCommand(command) {
            dangerousAction = DangerousActionRequest(kind: .runCommand(command: command, snippetID: snippetID))
            return
        }
        runTerminalCommand(command: command, snippetID: snippetID, bypassConfirmation: false)
    }

    private func runTerminalCommand(command: String, snippetID: UUID? = nil, bypassConfirmation: Bool) {
        guard let host = selectedHost else {
            appendTerminalLine(String(localized: "请先选择服务器。"))
            return
        }
        guard connectionStatus == .connected else {
            appendTerminalLine(String(localized: "连接服务器后打开终端"))
            return
        }
        if selectedTerminalTab?.hostID != host.id {
            if let existing = terminalTabs.last(where: { $0.hostID == host.id }) {
                selectedTerminalTabID = existing.id
            } else {
                openTerminalTabForSelectedHost()
            }
        }
        if terminalTabs.isEmpty {
            openTerminalTabForSelectedHost()
        }
        guard let selectedTerminalTab, selectedTerminalTab.status != .disconnected else {
            appendTerminalLine(String(localized: "请重新连接后再执行命令。"))
            return
        }

        if !bypassConfirmation,
           SafetyService.shouldConfirmDangerousActions(settings: settings),
           SafetyService.isDangerousCommand(command) {
            dangerousAction = DangerousActionRequest(kind: .runCommand(command: command, snippetID: snippetID))
            return
        }

        sendStringToActiveTerminal(command + "\n")
        Task {
            _ = try? storage.recordCommandRun(
                hostID: host.id,
                snippetID: snippetID,
                command: command,
                stdout: "",
                duration: 0
            )
            try? refreshOperationHistory()
        }
    }


    func makeConnectionConfig(for host: HostProfile) throws -> SSHConnectionConfig {
        guard let credentialID = host.credentialID else { throw CredentialStoreError.notFound }
        let authentication: SSHAuthConfig
        switch host.authType {
        case .password:
            let password = try credentialStore.read(id: credentialID, kind: .password).value
            authentication = .password(username: host.username, password: password)
        case .privateKey:
            let key = try credentialStore.read(id: credentialID, kind: .privateKey).value
            let passphrase = try host.privateKeyPassphraseCredentialID.map {
                try credentialStore.read(id: $0, kind: .privateKeyPassphrase).value
            }
            authentication = .privateKey(username: host.username, key: key, passphrase: passphrase)
        }
        return SSHConnectionConfig(
            host: host.host,
            port: host.port,
            authentication: authentication
        )
    }

    private func makeConnectionConfig(from draft: HostEditorDraft) throws -> SSHConnectionConfig {
        guard let port = draft.port, (1...65535).contains(port) else { throw SSHServiceError.invalidPort }
        let existingHost = draft.editingHostID.flatMap { id in hosts.first(where: { $0.id == id }) }
        let authentication: SSHAuthConfig
        switch draft.authType {
        case .password:
            let password: String
            if draft.password.isEmpty,
               let existingHost,
               let credentialID = existingHost.credentialID {
                password = try credentialStore.read(id: credentialID, kind: .password).value
            } else {
                password = draft.password
            }
            authentication = .password(username: draft.username, password: password)
        case .privateKey:
            let key: String
            if draft.privateKeyText.isEmpty,
               let existingHost,
               let credentialID = existingHost.credentialID {
                key = try credentialStore.read(id: credentialID, kind: .privateKey).value
            } else {
                key = draft.privateKeyText
            }
            let passphrase: String?
            if !draft.privateKeyPassphrase.isEmpty {
                passphrase = draft.privateKeyPassphrase
            } else if let id = existingHost?.privateKeyPassphraseCredentialID {
                passphrase = try credentialStore.read(id: id, kind: .privateKeyPassphrase).value
            } else {
                passphrase = nil
            }
            authentication = .privateKey(username: draft.username, key: key, passphrase: passphrase)
        }
        return SSHConnectionConfig(
            host: draft.host,
            port: port,
            authentication: authentication
        )
    }

    func appendTerminalLine(_ line: String, tabID: UUID? = nil) {
        guard let tabID else {
            recordOperationNotice(from: line)
            return
        }

        if let index = terminalTabs.firstIndex(where: { $0.id == tabID }) {
            let terminalLine = terminalSafeNoticeLine(line)
            terminalTabs[index].output += terminalLine.text
            terminalTabs[index].outputBytes.append(contentsOf: terminalLine.bytes)
            trimTerminalTranscript(at: index)
            terminalTabs[index].updatedAt = Date()
        }
    }

    func recordOperationNotice(from message: String) {
        let parts = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let title = parts.first else { return }
        let remaining = parts.dropFirst()
        let detail = remaining.isEmpty ? nil : remaining.joined(separator: "\n")
        let isWarning = title.contains("失败")
            || title.contains("错误")
            || title.contains("取消")
            || title.contains("请先")
        recordOperationNotice(
            title: title,
            detail: detail,
            systemImage: isWarning ? "exclamationmark.triangle" : "checkmark.circle",
            level: isWarning ? .warning : .success
        )
    }

    func recordOperationNotice(
        title: String,
        detail: String? = nil,
        systemImage: String = "info.circle",
        level: AppOperationNotice.Level = .info
    ) {
        operationNotices.insert(
            AppOperationNotice(
                hostID: selectedHost?.id,
                title: title,
                detail: detail,
                systemImage: systemImage,
                level: level
            ),
            at: 0
        )
        if operationNotices.count > 100 {
            operationNotices.removeLast(operationNotices.count - 100)
        }
    }

    func loadMoreOperationHistory() {
        guard !isLoadingMoreOperationHistory else { return }
        isLoadingMoreOperationHistory = true
        let previousLimit = operationHistoryDisplayLimit
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.operationHistoryDisplayLimit = previousLimit + self.operationHistoryPageSize
            do {
                try self.refreshOperationHistory()
            } catch {
                self.operationHistoryDisplayLimit = previousLimit
                self.hasMoreOperationHistory = false
                self.storageError = error.localizedDescription
            }
            self.isLoadingMoreOperationHistory = false
        }
    }

    func refreshOperationHistory() throws {
        let fetchLimit = operationHistoryDisplayLimit + 1
        let transfers = try storage.fetchTransfers(limit: fetchLimit)
        let commands = try storage.fetchCommandRuns(limit: fetchLimit)
        hasMoreOperationHistory = transfers.count > operationHistoryDisplayLimit
            || commands.count > operationHistoryDisplayLimit
        transferTasks = Array(transfers.prefix(operationHistoryDisplayLimit))
        commandRuns = Array(commands.prefix(operationHistoryDisplayLimit))
    }

    private func terminalSafeNoticeLine(_ line: String) -> (text: String, bytes: [UInt8]) {
        let normalized = line
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        let displayText = "\n\(normalized)\n"
        let terminalText = "\r\n\(normalized.replacingOccurrences(of: "\n", with: "\r\n"))\r\n"
        return (displayText, Array(terminalText.utf8))
    }

    private func appendTerminalBytes(_ bytes: [UInt8], tabID: UUID) {
        guard !bytes.isEmpty,
              let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }
        terminalTabs[index].outputBytes.append(contentsOf: bytes)
        terminalTabs[index].output += String(decoding: bytes, as: UTF8.self)
        trimTerminalTranscript(at: index)
        terminalTabs[index].updatedAt = Date()
    }

    private func trimTerminalTranscript(at index: Int) {
        guard terminalTabs[index].outputBytes.count > terminalTranscriptByteLimit else { return }
        let overflow = terminalTabs[index].outputBytes.count - terminalTranscriptByteLimit
        terminalTabs[index].outputBytes.removeFirst(overflow)
        let clipped = terminalTabs[index].outputBytes
        terminalTabs[index].output = String(decoding: clipped, as: UTF8.self)
    }
























    func setAppearanceMode(_ mode: AppAppearanceMode) {
        do {
            try storage.updateAppearanceMode(mode)
            settings?.appearanceMode = mode
            selectedAppearanceMode = mode
            applyAppearanceMode(mode)
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func applyAppearanceMode(_ mode: AppAppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setConfirmDangerousActions(_ value: Bool) {
        do {
            try storage.updateSecuritySettings(confirmDangerousActions: value)
            settings?.confirmDangerousActions = value
        } catch {
            storageError = error.localizedDescription
        }
    }

    func setProtectWithTouchID(_ value: Bool) {
        touchIDError = nil
        if !value {
            localAuthenticationService.invalidateReuse()
            persistTouchIDProtection(false)
            return
        }
        Task {
            do {
                try await localAuthenticationService.authenticate(
                    reason: String(localized: "启用 Touch ID 以保护已保存的服务器凭据"),
                    force: true
                )
                persistTouchIDProtection(true)
            } catch {
                persistTouchIDProtection(false)
                touchIDError = error.localizedDescription
            }
        }
    }

    func refreshTouchIDAvailability() {
        let availability = localAuthenticationService.availability()
        isTouchIDAvailable = availability.available
        touchIDAvailabilityDetail = availability.detail
        if !availability.available, settings?.protectWithTouchID == true {
            persistTouchIDProtection(false)
        }
    }

    func authorizeSensitiveAccessIfNeeded() async throws {
        guard settings?.protectWithTouchID == true else { return }
        try await localAuthenticationService.authenticate(
            reason: String(localized: "连接服务器前验证身份")
        )
    }

    private func persistTouchIDProtection(_ value: Bool) {
        do {
            try storage.updateSecuritySettings(protectWithTouchID: value)
            settings?.protectWithTouchID = value
            objectWillChange.send()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func setDefaultDownloadMirrorPolicy(_ policy: DownloadMirrorPolicy) {
        do {
            try storage.updateDefaultDownloadMirrorPolicy(policy)
            settings?.downloadMirrorPolicy = policy
        } catch {
            storageError = error.localizedDescription
        }
    }

    func setAcmeEmail(_ email: String) {
        do {
            try storage.updateAcmeEmail(email)
            settings?.acmeEmail = email
        } catch {
            storageError = error.localizedDescription
        }
    }

    func clearHistory() {
        do {
            try storage.clearTransferAndCommandHistory()
            transferTasks = []
            commandRuns = []
            operationNotices = []
            operationHistoryDisplayLimit = operationHistoryPageSize
            hasMoreOperationHistory = false
            appendTerminalLine(String(localized: "已清空本机传输和命令历史。"))
        } catch {
            storageError = error.localizedDescription
        }
    }

    func purchasePro() {
        Task {
            do {
                if try await purchaseService.purchaseLifetime() {
                    try storage.updateProUnlocked(true)
                    settings?.isProUnlocked = true
                    isShowingProUnlock = false
                }
            } catch {
                purchaseService.lastMessage = error.localizedDescription
            }
        }
    }

    func restorePurchases() {
        Task {
            do {
                if try await purchaseService.restorePurchases() {
                    try storage.updateProUnlocked(true)
                    settings?.isProUnlocked = true
                    isShowingProUnlock = false
                }
            } catch {
                purchaseService.lastMessage = error.localizedDescription
            }
        }
    }

    private func refreshPurchaseEntitlements() async {
        let unlocked = await purchaseService.refreshEntitlements()
        guard unlocked else { return }
        do {
            try storage.updateProUnlocked(true)
            settings?.isProUnlocked = true
        } catch {
            storageError = error.localizedDescription
        }
    }
}

extension AppState {
    var selectedTerminalTabIndex: Int? {
        guard let selectedTerminalTabID else { return nil }
        return terminalTabs.firstIndex { $0.id == selectedTerminalTabID }
    }

    var selectedTerminalTab: TerminalSessionTab? {
        guard let index = selectedTerminalTabIndex else { return nil }
        return terminalTabs[index]
    }

    func markTerminalTabsDisconnected() {
        for index in terminalTabs.indices {
            terminalTabs[index].status = .disconnected
            terminalTabs[index].updatedAt = Date()
        }
    }

    private func liveTerminalTab(for hostID: UUID) -> TerminalSessionTab? {
        terminalTabs.first { tab in
            tab.hostID == hostID && tab.status != .disconnected
        }
    }

    func disconnectTerminalTabs(for hostID: UUID) {
        let tabIDs = terminalTabs
            .filter { $0.hostID == hostID }
            .map(\.id)
        for tabID in tabIDs {
            terminalStreamTasks[tabID]?.cancel()
            terminalStreamTasks[tabID] = nil
            Task {
                await terminalService.stopPTY(tabID: tabID)
            }
        }
        for index in terminalTabs.indices where terminalTabs[index].hostID == hostID {
            terminalTabs[index].status = .disconnected
            terminalTabs[index].updatedAt = Date()
        }
    }

    func startTerminalPTY(tabID: UUID, shouldClearTranscript: Bool = false) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }),
              let host = hosts.first(where: { $0.id == terminalTabs[index].hostID }) else {
            return
        }

        let config: SSHConnectionConfig
        do {
            config = try makeConnectionConfig(for: host)
        } catch {
            appendTerminalLine(error.localizedDescription, tabID: tabID)
            setTerminalStatus(.disconnected, tabID: tabID)
            return
        }

        terminalStreamTasks[tabID]?.cancel()
        terminalStreamTasks[tabID] = nil
        setTerminalStatus(.running, tabID: tabID)
        if shouldClearTranscript {
            terminalTabs[index].output = String(localized: "正在重新打开 SSH Shell...\n")
            terminalTabs[index].outputBytes = Array(terminalTabs[index].output.utf8)
        }

        let initialDirectory = terminalTabs[index].workingDirectory
        let columns = terminalTabs[index].columns
        let rows = terminalTabs[index].rows
        let shellOverride = terminalTabs[index].shellOverride
        terminalStreamTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            let stream = await terminalService.startPTY(
                tabID: tabID,
                config: config,
                initialDirectory: initialDirectory,
                shellOverride: shellOverride,
                columns: columns,
                rows: rows,
                pixelWidth: columns * 8,
                pixelHeight: rows * 16
            )
            for await event in stream {
                await MainActor.run {
                    self.handleTerminalPTYEvent(event, tabID: tabID)
                }
            }
        }
    }

    func handleTerminalPTYEvent(_ event: TerminalPTYEvent, tabID: UUID) {
        let hostID = terminalTabs.first { $0.id == tabID }?.hostID
        switch event {
        case .ready:
            setTerminalStatus(.idle, tabID: tabID)
        case .output(let bytes):
            appendTerminalBytes(bytes, tabID: tabID)
        case .closed:
            setTerminalStatus(.disconnected, tabID: tabID)
            updateSelectedHostConnectionAfterTerminalChange(hostID: hostID)
        case .failed(let message):
            appendTerminalLine(message, tabID: tabID)
            setTerminalStatus(.disconnected, tabID: tabID)
            updateSelectedHostConnectionAfterTerminalChange(hostID: hostID)
        }
    }

    private func updateSelectedHostConnectionAfterTerminalChange(hostID: UUID?) {
        // Reflect a dropped terminal on THAT host's own session — even if the user
        // is currently viewing a different host — so each session's connection
        // state stays independently accurate.
        guard let hostID, liveTerminalTab(for: hostID) == nil else { return }
        sessions[hostID]?.connectionStatus = .disconnected
    }

    func setActiveTerminalStatus(_ status: TerminalSessionStatus) {
        guard let index = selectedTerminalTabIndex else { return }
        terminalTabs[index].status = status
        terminalTabs[index].updatedAt = Date()
    }

    func setTerminalStatus(_ status: TerminalSessionStatus, tabID: UUID?) {
        guard let tabID,
              let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else {
            setActiveTerminalStatus(status)
            return
        }
        terminalTabs[index].status = status
        terminalTabs[index].updatedAt = Date()
    }

    func setTerminalWorkingDirectory(_ path: String, tabID: UUID?) {
        let normalized = normalizedTerminalWorkingDirectory(path)
        guard let tabID,
              let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else {
            guard let index = selectedTerminalTabIndex else { return }
            terminalTabs[index].workingDirectory = normalized
            terminalTabs[index].updatedAt = Date()
            return
        }
        terminalTabs[index].workingDirectory = normalized
        terminalTabs[index].updatedAt = Date()
    }
}

func parentRemotePath(_ path: String) -> String {
    guard path != "/", path != "." else { return "." }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let parent = (trimmed as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
}

private func joinedRemotePath(parent: String, child: String) -> String {
    if parent == "/" { return "/" + child }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

func sanitizedRemoteName(_ name: String) -> String {
    name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/", with: "")
}

func normalizedRemotePathKey(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "." : trimmed
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func normalizedTerminalWorkingDirectory(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "." : trimmed
}

struct LocalUploadFile {
    let localURL: URL
    let relativePath: String
    let remotePath: String
    let permissions: UInt32?
}

struct LocalUploadPlan {
    let directories: [String]
    let files: [LocalUploadFile]
}

func makeLocalUploadPlan(rootURL: URL, remoteRootPath: String) throws -> LocalUploadPlan {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) else {
        throw LocalFileServiceError.directoryUnavailable(rootURL.path(percentEncoded: false))
    }

    var directories: [String] = []
    var files: [LocalUploadFile] = []
    let rootPath = rootURL.standardizedFileURL.path(percentEncoded: false)

    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: Set(keys))
        let localPath = fileURL.standardizedFileURL.path(percentEncoded: false)
        let relativePath = String(localPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { continue }

        let remotePath = relativePath
            .split(separator: "/")
            .map(String.init)
            .reduce(remoteRootPath) { partial, component in
                joinedRemotePath(parent: partial, child: component)
            }

        if values.isDirectory == true {
            directories.append(remotePath)
        } else if values.isRegularFile == true {
            files.append(
                LocalUploadFile(
                    localURL: fileURL,
                    relativePath: relativePath,
                    remotePath: remotePath,
                    permissions: localExecutablePermissions(for: fileURL)
                )
            )
        }
    }

    directories.sort { lhs, rhs in
        lhs.split(separator: "/").count < rhs.split(separator: "/").count
    }
    return LocalUploadPlan(directories: directories, files: files)
}

func localExecutablePermissions(for url: URL) -> UInt32? {
    let path = url.path(percentEncoded: false)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let mode = attributes[.posixPermissions] as? NSNumber else {
        return nil
    }
    let permissions = UInt32(mode.intValue) & 0o777
    return permissions & 0o111 == 0 ? nil : permissions
}

enum RemoteTextLimits {
    static let editableByteLimit: UInt64 = 512 * 1024
    static let tailPreviewByteLimit: UInt64 = 128 * 1024
}

func fileSize(at url: URL) -> Int64? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
        return nil
    }
    return (values.fileSize ?? values.totalFileAllocatedSize).map(Int64.init)
}

private enum ClipboardUploadError: LocalizedError {
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return String(localized: "无法把剪贴板图片转换为 PNG。")
        }
    }
}

private func fileURLsFromPasteboard(_ pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let objectURLs = pasteboard
        .readObjects(forClasses: [NSURL.self], options: options)?
        .compactMap { item -> URL? in
            if let url = item as? URL { return url }
            if let nsURL = item as? NSURL { return nsURL as URL }
            return nil
        } ?? []

    let itemURLs = pasteboard.pasteboardItems?.compactMap { item -> URL? in
        guard let value = item.string(forType: .fileURL) else { return nil }
        return URL(string: value)
    } ?? []

    var seen: Set<String> = []
    return (objectURLs + itemURLs).filter { url in
        guard url.isFileURL else { return false }
        let key = url.standardizedFileURL.path(percentEncoded: false)
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
    }
}

private func temporaryClipboardImageURL(for image: NSImage) throws -> URL {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw ClipboardUploadError.imageConversionFailed
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpsDeckClipboard", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = "clipboard-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png"
    let url = directory.appendingPathComponent(fileName)
    try data.write(to: url, options: .atomic)
    return url
}

private func redactedCommand(_ command: String) -> String {
    let patterns = [
        #"(?i)(password|passwd|secret|token|api[_-]?key)=\S+"#,
        #"(?i)(--password|--token|--secret)\s+\S+"#
    ]
    var redacted = command
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
        redacted = regex.stringByReplacingMatches(in: redacted, range: range, withTemplate: "$1=<redacted>")
    }
    return redacted
}

extension ByteCountFormatter {
    static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
