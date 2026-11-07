import AppKit
import Foundation
import UniformTypeIdentifiers

/// Per-host connection session. Each configured server gets one `ServerSession`
/// instance that owns *its own* connection status, server profile, remote-file
/// browser state, workbench-module snapshots and runbook state — so multiple
/// servers can be connected at once and switching the sidebar merely swaps which
/// session the UI observes (like browser tabs), never disconnecting or reloading.
///
/// The single source of truth for shared, stateless collaborators (the SSH /
/// SFTP / module services, storage, static catalogs, the global history feed and
/// the global modal chrome) remains `AppState`; a session reaches them through
/// its `unowned` back-reference. `app` always outlives its sessions (it is held
/// by the app delegate), so `unowned` is correct and cannot dangle.
///
/// This type is being filled in phase-by-phase; see the migration plan. Phase A
/// establishes only identity + the config helper so the SwiftUI injection and
/// session-swap machinery can be wired and verified before any per-host state
/// moves off `AppState`.
@MainActor
final class ServerSession: ObservableObject {
    /// The host this session drives. Kept in sync by `AppState.reload()` when the
    /// user edits the host (name/address/credentials), so display + config stay
    /// current without recreating the session (which would drop live state).
    @Published var host: HostProfile

    /// Back-reference to shared, app-global collaborators. `unowned` because the
    /// owning `AppState` outlives every session it stores.
    unowned let app: AppState

    init(host: HostProfile, app: AppState) {
        self.host = host
        self.app = app
    }

    /// Build a fresh connection config for this host. Reads credentials from the
    /// Keychain on each call (matching the app's ephemeral-per-command model), so
    /// there is nothing to invalidate when the password changes.
    func makeConfig() throws -> SSHConnectionConfig {
        try app.makeConnectionConfig(for: host)
    }

    /// A session always drives exactly one host. Exposed as an optional so the
    /// large body of migrated code that was written against
    /// `AppState.selectedHost` (e.g. `guard let host = selectedHost`) keeps
    /// working unchanged — here it never yields nil.
    var selectedHost: HostProfile? { host }

    /// Open this host's SSH session and load its initial state. Writes only this
    /// session's state, so a connect in flight is unaffected by the user
    /// switching to another host.
    func connect() {
        // Idempotency: ignore repeat taps while a connection is already in flight
        // or established, so we don't spin up two full connect pipelines at once.
        guard connectionStatus != .connecting, connectionStatus != .connected else { return }
        connectGeneration += 1
        let generation = connectGeneration
        connectionStatus = .connecting
        // 连接一开始就置为加载中，避免握手 + 抓取画像的这段空窗里
        // 远端文件面板误显示“此文件夹为空”（真正的目录加载会在稍后覆盖此标志）。
        remoteFiles = []
        clearRemoteFileSelection()
        remoteFileError = nil
        isRemoteFileLoading = true
        connectTask = Task {
            do {
                try await app.authorizeSensitiveAccessIfNeeded()
                let config = try makeConfig()
                let summary = try await app.sessionManager.connect(hostID: host.id, config: config, sshService: app.sshService)
                // A disconnect (or newer connect) landed while we awaited the
                // handshake — it superseded us; don't write this stale state back.
                guard generation == connectGeneration else { return }
                try app.storage.updateHostStatus(host, status: "connected", connectedAt: summary.connectedAt)
                connectionStatus = .connected
                connectionSummary = summary.systemSummary
                // Only touch the host name shown in the global toolbar if this
                // host is still on screen. Terminal PTY creation is deliberately
                // deferred until the user opens the terminal after connecting.
                let isActive = app.selectedSidebarHostID == host.id
                if isActive { app.currentHostName = host.name }
                app.appendTerminalLine(String(localized: "已连接 \(summary.displayName)"))
                await refreshServerProfile(config: config)
                guard generation == connectGeneration else { return }
                await loadRemoteDirectory(path: lastRemoteDirectory(for: host) ?? ".", config: config)
                guard generation == connectGeneration else { return }
                await refreshServerStatus(config: config)
                app.reload()
            } catch {
                guard generation == connectGeneration else { return }
                isRemoteFileLoading = false
                if app.presentHostKeyChallengeIfNeeded(error, retry: .connect(hostID: host.id)) {
                    connectionStatus = .warning(error.localizedDescription)
                    remoteFileError = error.localizedDescription
                } else {
                    connectionStatus = .failed(error.localizedDescription)
                    remoteFileError = error.localizedDescription
                }
                try? app.storage.updateHostStatus(host, status: "failed")
            }
        }
    }

    /// Tear down this host's session + terminal, and clear its live state. Other
    /// hosts' sessions are untouched.
    func disconnect() {
        // Cancel + supersede any in-flight connect so its post-handshake tail
        // can't re-register this host as connected after the user tore it down.
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        Task {
            await app.sessionManager.disconnect(hostID: host.id, sshService: app.sshService)
            app.disconnectTerminalTabs(for: host.id)
            try? app.storage.updateHostStatus(host, status: "disconnected")
            app.reload()
            connectionStatus = .disconnected
            remoteFiles = []
            selectedRemoteFileID = nil
            connectionSummary = nil
            serverStatus = nil
            serverProfile = nil
            serverProfileError = nil
            resetOperationsState()
            app.appendTerminalLine(String(localized: "已断开 \(host.name)"))
        }
    }

    // MARK: - Migrated per-host state (moved from AppState)

    @Published var connectionStatus: AppState.ConnectionStatus = .disconnected {
        didSet {
            // Mirror into AppState so the sidebar can show THIS host's live status
            // even when another host is selected (didSet never fires for the
            // initial value, so `app` is always set by the time this runs).
            app.noteConnectionStatus(for: host.id, connectionStatus)
        }
    }

    /// Serializes connect/disconnect. A re-entrant `connect()` is ignored while a
    /// connection is already in flight or established, and `disconnect()` bumps
    /// this generation so an in-flight connect still awaiting the handshake cannot
    /// resurrect a session the user has already torn down.
    private var connectGeneration = 0
    private var connectTask: Task<Void, Never>?

    /// Monotonic token for remote-directory loads. Only the newest load applies
    /// its result and owns the loading flag, so a slow listing for an old path
    /// can't overwrite a newer navigation (turns last-writer-wins into
    /// last-requested-wins — mirrors the DB browser's `dbLoadGeneration`).
    private var remoteDirectoryLoadGeneration = 0

    @Published var selectedWorkspaceMode: WorkspaceMode = .files {
        didSet {
            if oldValue != selectedWorkspaceMode {
                operationsError = nil
            }
        }
    }

    /// Selected module id within the 工具 workbench (id from WorkbenchRegistry).
    @Published var selectedWorkbenchModuleID: String = "services"

    @Published var remoteDirectoryPath: String = "."

    @Published var remotePathInput: String = "."

    @Published var remoteFiles: [RemoteFileItem] = []

    /// Finder-style remote-file selection. The set drives row highlighting,
    /// while the primary item and range anchor retain click/open and Shift-click
    /// semantics without leaking selection bookkeeping into SwiftUI views.
    @Published private(set) var selectedRemoteFileIDs: Set<String> = []
    private var primaryRemoteFileID: String?
    private var remoteSelectionAnchorID: String?
    private var remoteDragSelectionStartID: String?
    private var remoteDragSelectionBaseIDs: Set<String> = []

    /// Compatibility facade for the existing single-item actions and screenshot
    /// fixtures. Assigning it intentionally replaces the whole selection.
    var selectedRemoteFileID: String? {
        get { primaryRemoteFileID }
        set {
            guard let newValue else {
                clearRemoteFileSelection()
                return
            }
            selectedRemoteFileIDs = [newValue]
            primaryRemoteFileID = newValue
            remoteSelectionAnchorID = newValue
            endRemoteFileDragSelection()
        }
    }

    @Published var isRemoteFileLoading = false

    @Published var remoteFileError: String?

    @Published var activeTransferProgress: RemoteTransferProgress?

    @Published var remoteDeleteCandidate: RemoteFileItem?

    @Published var isShowingNewRemoteDirectorySheet = false

    @Published var newRemoteDirectoryName = ""

    @Published var isShowingNewRemoteFileSheet = false

    @Published var newRemoteFileName = ""

    @Published var remoteRenameCandidate: RemoteFileItem?

    @Published var remoteRenameName = ""

    @Published var remoteInfoCandidate: RemoteFileItem?

    @Published var remoteInfoSummary: RemoteItemInfoSummary?

    @Published var isRemoteInfoLoading = false

    @Published var remoteInfoError: String?

    @Published var remoteTextDocument: RemoteTextDocument?

    @Published var remoteTextError: String?

    @Published var isRemoteTextLoading = false

    @Published var isRemoteTextSaving = false

    @Published var connectionSummary: String?

    @Published var serverStatus: ServerStatusSnapshot?

    @Published var serverProfile: ServerProfileSnapshot?

    @Published var isServerProfileLoading = false

    @Published var serverProfileError: String?

    @Published var pendingRunbookPlan: RunbookPlan?

    @Published var activeRunbookRun: RunbookRun?

    @Published var runbookRuns: [RunbookRun] = []

    @Published var selectedRunbookRun: RunbookRun?

    private var activeRunbookTask: Task<Void, Never>?

    @Published var serviceUnits: [ServiceUnit] = []

    @Published var isServicesLoading = false

    @Published var logSources: [LogSource] = []

    @Published var selectedLogSourceID: UUID?

    @Published var logPreview = ""

    @Published var isLogSourcesLoading = false

    @Published var isLogPreviewLoading = false

    @Published var isLogFollowing = false

    @Published var isLogFollowPaused = false

    @Published var logLineLimit = 500

    private var logFollowTask: Task<Void, Never>?

    @Published var nginxSnapshot: NginxSnapshot?

    @Published var isNginxLoading = false

    @Published var dockerSnapshot: DockerSnapshot?

    @Published var dockerContainers: [DockerContainerSummary] = []

    @Published var isDockerLoading = false

    @Published var firewallSnapshot: FirewallSnapshot?

    @Published var isFirewallLoading = false

    @Published var pm2Snapshot: PM2Snapshot?

    @Published var isPM2Loading = false

    @Published var certbotSnapshot: CertbotSnapshot?

    @Published var isCertbotLoading = false

    @Published var caddySnapshot: CaddySnapshot?

    @Published var isCaddyLoading = false

    @Published var fail2banSnapshot: Fail2banSnapshot?

    @Published var isFail2banLoading = false

    @Published var cronSnapshot: CronSnapshot?

    @Published var isCronLoading = false

    @Published var shellPathSnapshot: ShellPathSnapshot?

    @Published var isShellPathLoading = false

    @Published var mirrorSnapshot: MirrorSnapshot?

    @Published var isMirrorLoading = false

    @Published var databases: [DatabaseTarget] = []

    @Published var isDatabasesLoading = false

    /// Distinguishes a successful empty discovery from a discovery that has not
    /// run (or failed), so the sidebar does not continuously rescan an empty host.
    @Published var hasLoadedDatabases = false

    // MARK: Database browser (Navicat-lite) — per-host browse state
    //
    // Deliberately NOT on this object: the browser's high-frequency state lives
    // on its own `DBBrowserState` so table loads / page turns only re-render the
    // database views, never the whole window (see DBBrowserState.swift). The
    // db* mutation methods below stay here because they need the SSH context.
    let dbState = DBBrowserState()

    @Published var auditFindings: [AuditFinding] = []

    @Published var isAuditLoading = false

    @Published var operationsError: String?

    private var remoteDirectoryCache: [UUID: [String: SFTPListResult]] = [:]

    private var remoteBackStack: [String] = []

    private var remoteForwardStack: [String] = []

    private let transferControl = RemoteTransferControl()
}

private enum DBLoadKind {
    case navigator
    case rows
}

// MARK: - Migrated per-host behavior (moved from AppState)

extension ServerSession {

    /// Navigate to a specific workbench module (switches to 工具 and selects it).
    func openWorkbenchModule(_ id: String) {
        selectedWorkspaceMode = .tools
        selectedWorkbenchModuleID = id
    }

    var selectedRemoteFiles: [RemoteFileItem] {
        remoteFiles.filter { selectedRemoteFileIDs.contains($0.id) }
    }

    var selectedRemoteFile: RemoteFileItem? {
        if let primaryRemoteFileID,
           let item = remoteFiles.first(where: { $0.id == primaryRemoteFileID }) {
            return item
        }
        return selectedRemoteFiles.first
    }

    var hasSingleRemoteFileSelection: Bool {
        selectedRemoteFileIDs.count == 1
    }

    func isRemoteFileSelected(_ item: RemoteFileItem) -> Bool {
        selectedRemoteFileIDs.contains(item.id)
    }

    /// Implements macOS Finder selection conventions:
    /// plain click replaces, Command-click toggles, Shift-click selects a range,
    /// and Command-Shift-click adds that range to the current selection.
    func selectRemoteFileItem(_ item: RemoteFileItem, modifiers: NSEvent.ModifierFlags = []) {
        endRemoteFileDragSelection()
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            selectRemoteFileRange(through: item, extending: flags.contains(.command))
        } else if flags.contains(.command) {
            toggleRemoteFileSelection(item)
        } else {
            replaceRemoteFileSelection(with: item)
        }
    }

    func selectAllRemoteFiles() {
        endRemoteFileDragSelection()
        guard !remoteFiles.isEmpty else {
            clearRemoteFileSelection()
            return
        }
        selectedRemoteFileIDs = Set(remoteFiles.map(\.id))
        if primaryRemoteFileID.map({ !selectedRemoteFileIDs.contains($0) }) ?? true {
            primaryRemoteFileID = remoteFiles.first?.id
        }
        if remoteSelectionAnchorID.map({ !selectedRemoteFileIDs.contains($0) }) ?? true {
            remoteSelectionAnchorID = primaryRemoteFileID
        }
    }

    func clearRemoteFileSelection() {
        selectedRemoteFileIDs = []
        primaryRemoteFileID = nil
        remoteSelectionAnchorID = nil
        endRemoteFileDragSelection()
    }

    func beginRemoteFileDragSelection(at item: RemoteFileItem, modifiers: NSEvent.ModifierFlags = []) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let usesExistingAnchor = flags.contains(.shift)
        remoteDragSelectionStartID = usesExistingAnchor ? (remoteSelectionAnchorID ?? item.id) : item.id
        remoteDragSelectionBaseIDs = flags.contains(.command) ? selectedRemoteFileIDs : []
        if !usesExistingAnchor {
            remoteSelectionAnchorID = item.id
        }
        updateRemoteFileDragSelection(through: item)
    }

    func updateRemoteFileDragSelection(through item: RemoteFileItem) {
        guard let startID = remoteDragSelectionStartID,
              let startIndex = remoteFiles.firstIndex(where: { $0.id == startID }),
              let targetIndex = remoteFiles.firstIndex(where: { $0.id == item.id }) else { return }
        let range = min(startIndex, targetIndex)...max(startIndex, targetIndex)
        let rangeIDs = Set(range.map { remoteFiles[$0].id })
        selectedRemoteFileIDs = remoteDragSelectionBaseIDs.union(rangeIDs)
        primaryRemoteFileID = item.id
    }

    func endRemoteFileDragSelection() {
        remoteDragSelectionStartID = nil
        remoteDragSelectionBaseIDs = []
    }

    /// A contextual action keeps an existing multi-selection when the clicked
    /// row belongs to it; right-clicking an unselected row makes that row the
    /// sole target, matching Finder's safety behavior.
    func prepareRemoteContextSelection(_ item: RemoteFileItem) {
        guard !selectedRemoteFileIDs.contains(item.id) else { return }
        replaceRemoteFileSelection(with: item)
    }

    private func replaceRemoteFileSelection(with item: RemoteFileItem) {
        endRemoteFileDragSelection()
        selectedRemoteFileIDs = [item.id]
        primaryRemoteFileID = item.id
        remoteSelectionAnchorID = item.id
    }

    private func toggleRemoteFileSelection(_ item: RemoteFileItem) {
        if selectedRemoteFileIDs.contains(item.id) {
            selectedRemoteFileIDs.remove(item.id)
            if primaryRemoteFileID == item.id {
                primaryRemoteFileID = remoteFiles.first(where: { selectedRemoteFileIDs.contains($0.id) })?.id
            }
        } else {
            selectedRemoteFileIDs.insert(item.id)
            primaryRemoteFileID = item.id
        }
        remoteSelectionAnchorID = item.id
    }

    private func selectRemoteFileRange(through item: RemoteFileItem, extending: Bool) {
        guard let targetIndex = remoteFiles.firstIndex(where: { $0.id == item.id }) else { return }
        let anchorID = remoteSelectionAnchorID ?? primaryRemoteFileID ?? item.id
        guard let anchorIndex = remoteFiles.firstIndex(where: { $0.id == anchorID }) else {
            replaceRemoteFileSelection(with: item)
            return
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let rangeIDs = Set(range.map { remoteFiles[$0].id })
        selectedRemoteFileIDs = extending ? selectedRemoteFileIDs.union(rangeIDs) : rangeIDs
        primaryRemoteFileID = item.id
        remoteSelectionAnchorID = anchorID
    }

    private func reconcileRemoteFileSelection() {
        let visibleIDs = Set(remoteFiles.map(\.id))
        selectedRemoteFileIDs.formIntersection(visibleIDs)
        if primaryRemoteFileID.map({ !visibleIDs.contains($0) }) ?? true {
            primaryRemoteFileID = remoteFiles.first(where: { selectedRemoteFileIDs.contains($0.id) })?.id
        }
        if remoteSelectionAnchorID.map({ !visibleIDs.contains($0) }) ?? true {
            remoteSelectionAnchorID = primaryRemoteFileID
        }
    }

    func refreshRemoteDirectory() {
        guard let host = selectedHost else { return }
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config, useCache: false)
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    var canNavigateRemoteBack: Bool {
        !remoteBackStack.isEmpty
    }

    var canNavigateRemoteForward: Bool {
        !remoteForwardStack.isEmpty
    }

    func navigateRemoteBack() {
        guard let path = remoteBackStack.popLast() else { return }
        remoteForwardStack.append(remoteDirectoryPath)
        openRemoteDirectory(path: path, recordsHistory: false)
    }

    func navigateRemoteForward() {
        guard let path = remoteForwardStack.popLast() else { return }
        remoteBackStack.append(remoteDirectoryPath)
        openRemoteDirectory(path: path, recordsHistory: false)
    }

    func navigateToParentRemoteDirectory() {
        let current = remoteDirectoryPath
        guard current != ".", current != "/" else { return }
        let parent = parentRemotePath(current)
        loadRemoteDirectory(path: parent)
    }

    func openRemoteFileItem(_ item: RemoteFileItem) {
        replaceRemoteFileSelection(with: item)
        if item.isDirectory {
            loadRemoteDirectory(path: item.path)
        } else if item.isEditableTextFile {
            openSelectedRemoteTextFile()
        } else if item.isSystemPreviewableFile {
            previewSelectedRemoteFile()
        } else {
            remoteFileError = String(localized: "此文件类型不支持直接打开。可以使用“下载”或“显示简介”。")
        }
    }

    func openRemotePathFromInput() {
        let path = remotePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        loadRemoteDirectory(path: path.isEmpty ? "." : path)
    }

    func loadRemoteDirectory(path: String) {
        openRemoteDirectory(path: path, recordsHistory: true)
    }

    private func openRemoteDirectory(path: String, recordsHistory: Bool) {
        guard let host = selectedHost else { return }
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = normalizedPath.isEmpty ? "." : normalizedPath
        if recordsHistory, targetPath != remoteDirectoryPath {
            remoteBackStack.append(remoteDirectoryPath)
            remoteForwardStack = []
        }
        if let cached = cachedRemoteDirectory(path: targetPath, hostID: host.id) {
            applyRemoteDirectory(cached, shouldSelectNothing: true)
        }
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                await loadRemoteDirectory(path: targetPath, config: config)
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    func uploadSelectedLocalFile() {
        if app.selectedLocalFile == nil {
            chooseFileForUpload()
            return
        }

        if let settings = app.settings {
            switch app.entitlements.canUse(.upload, settings: settings) {
            case .allowed:
                break
            case .needsPro(let message):
                app.proPromptMessage = message
                app.isShowingProUnlock = true
                return
            }
        }

        guard selectedHost != nil,
              let item = app.selectedLocalFile,
              !item.isDirectory else {
            app.localFileError = String(localized: "请选择要上传的本地文件。")
            return
        }

        uploadLocalFile(url: item.url, byteSize: item.byteSize)
    }

    func chooseFileForUpload() {
        guard selectedHost != nil, connectionStatus == .connected else {
            remoteFileError = String(localized: "请先连接服务器再上传。")
            return
        }
        guard let url = app.localFileService.chooseUploadFile() else { return }
        uploadDroppedLocalFile(url)
    }

    func uploadDroppedLocalFile(_ url: URL) {
        uploadLocalFile(url: url, byteSize: fileSize(at: url))
    }

    private func uploadLocalFile(url: URL, byteSize: Int64?) {
        if let settings = app.settings {
            switch app.entitlements.canUse(.upload, settings: settings) {
            case .allowed:
                break
            case .needsPro(let message):
                app.proPromptMessage = message
                app.isShowingProUnlock = true
                return
            }
        }

        guard let host = selectedHost else {
            remoteFileError = String(localized: "请先连接服务器再上传。")
            return
        }
        let remotePath = joinedRemotePath(parent: remoteDirectoryPath, child: url.lastPathComponent)
        if SafetyService.shouldConfirmDangerousActions(settings: app.settings),
           remoteFiles.contains(where: { $0.path == remotePath }) {
            app.dangerousAction = DangerousActionRequest(kind: .uploadOverwrite(localURL: url, byteSize: byteSize, remotePath: remotePath), hostID: host.id)
            return
        }
        performUploadLocalItem(url: url, byteSize: byteSize, remotePath: remotePath, host: host)
    }

    func performUploadLocalItem(url: URL, byteSize: Int64?, remotePath: String, host: HostProfile) {
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let config = try app.makeConnectionConfig(for: host)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
                    throw LocalFileServiceError.directoryUnavailable(url.path(percentEncoded: false))
                }

                let bytes: Int64
                if isDirectory.boolValue {
                    bytes = try await uploadLocalDirectory(url: url, remotePath: remotePath, config: config)
                } else {
                    bytes = try await uploadLocalFileData(url: url, remotePath: remotePath, config: config)
                }
                try app.storage.recordTransfer(
                    hostID: host.id,
                    direction: .upload,
                    localPath: url.path(percentEncoded: false),
                    remotePath: remotePath,
                    status: .succeeded,
                    bytes: bytes
                )
                finishTransferProgress(detail: String(localized: "完成"))
                app.appendTerminalLine(String(localized: "已上传 \(url.lastPathComponent) 到 \(remotePath)"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
                try app.refreshOperationHistory()
            } catch {
                let wasCancelled = error is CancellationError
                finishTransferProgress(detail: wasCancelled ? String(localized: "已取消") : String(localized: "失败"), shouldComplete: false)
                _ = try? app.storage.recordTransfer(
                    hostID: host.id,
                    direction: .upload,
                    localPath: url.path(percentEncoded: false),
                    remotePath: joinedRemotePath(parent: remoteDirectoryPath, child: url.lastPathComponent),
                    status: wasCancelled ? .cancelled : .failed,
                    bytes: byteSize ?? 0,
                    errorMessage: wasCancelled ? nil : error.localizedDescription
                )
                try? app.refreshOperationHistory()
                remoteFileError = wasCancelled ? String(localized: "上传已取消。") : error.localizedDescription
            }
        }
    }

    private func uploadLocalFileData(url: URL, remotePath: String, config: SSHConnectionConfig) async throws -> Int64 {
        startTransferProgress(kind: .upload, title: String(localized: "正在上传 \(url.lastPathComponent)"), detail: remotePath, totalUnitCount: 1)
        let data = try Data(contentsOf: url)
        _ = try await app.sftpService.uploadReplacing(
            data: data,
            to: remotePath,
            permissions: localExecutablePermissions(for: url),
            config: config
        )
        updateTransferProgress(completedUnitCount: 1, detail: remotePath)
        return Int64(data.count)
    }

    private func uploadLocalDirectory(url: URL, remotePath: String, config: SSHConnectionConfig) async throws -> Int64 {
        let plan = try makeLocalUploadPlan(rootURL: url, remoteRootPath: remotePath)
        startTransferProgress(
            kind: .upload,
            title: String(localized: "正在上传 \(url.lastPathComponent)"),
            detail: String(localized: "\(plan.files.count) 个项目"),
            totalUnitCount: max(plan.files.count, 1),
            canPause: true,
            canCancel: true
        )

        try await waitIfTransferPaused()
        try? await app.sftpService.createDirectory(remotePath: remotePath, config: config)
        for directory in plan.directories {
            try await waitIfTransferPaused()
            try? await app.sftpService.createDirectory(remotePath: directory, config: config)
        }

        var uploadedBytes: Int64 = 0
        for (index, file) in plan.files.enumerated() {
            try await waitIfTransferPaused()
            let data = try Data(contentsOf: file.localURL)
            _ = try await app.sftpService.uploadReplacing(
                data: data,
                to: file.remotePath,
                permissions: file.permissions,
                config: config
            )
            uploadedBytes += Int64(data.count)
            updateTransferProgress(completedUnitCount: index + 1, detail: file.relativePath)
        }
        if plan.files.isEmpty {
            updateTransferProgress(completedUnitCount: 1, detail: remotePath)
        }
        return uploadedBytes
    }

    func downloadSelectedRemoteFile() {
        guard let localDirectoryURL = app.localDirectoryURL else {
            remoteFileError = String(localized: "请先选择远端文件和本地文件夹。")
            return
        }
        downloadSelectedRemoteItem(to: localDirectoryURL, shouldReveal: false)
    }

    func downloadSelectedRemoteFileToChosenDirectory() {
        downloadSelectedRemoteItemToChosenDirectory()
    }

    func downloadSelectedRemoteItemToChosenDirectory() {
        guard let destinationDirectory = app.localFileService.chooseDownloadDirectory() else { return }
        downloadSelectedRemoteItem(to: destinationDirectory, shouldReveal: true)
    }

    private func downloadSelectedRemoteItem(to destinationDirectory: URL, shouldReveal: Bool) {
        let items = selectedRemoteFiles
        guard let host = selectedHost, !items.isEmpty else {
            remoteFileError = String(localized: "请先选择远端文件或文件夹。")
            return
        }

        Task {
            var currentItem: RemoteFileItem?
            let didAccess = destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    destinationDirectory.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let containsDirectory = items.contains(where: \.isDirectory)
                let title = items.count == 1
                    ? String(localized: "正在下载 \(items[0].name)")
                    : String(localized: "正在下载 \(items.count) 个项目")
                startTransferProgress(
                    kind: .download,
                    title: title,
                    detail: items[0].path,
                    totalUnitCount: containsDirectory ? nil : items.count,
                    canPause: true,
                    canCancel: true
                )

                var destinations: [URL] = []
                for (index, item) in items.enumerated() {
                    try await waitIfTransferPaused()
                    currentItem = item
                    let destination = destinationDirectory.appendingPathComponent(item.name, isDirectory: item.isDirectory)
                    let bytes: Int64
                    if item.isDirectory {
                        bytes = try await downloadRemoteDirectory(item, to: destination, config: config)
                    } else {
                        let data = try await app.sftpService.download(remotePath: item.path, config: config)
                        try data.write(to: destination, options: .atomic)
                        bytes = Int64(data.count)
                    }
                    if !containsDirectory {
                        updateTransferProgress(completedUnitCount: index + 1, detail: destination.path(percentEncoded: false))
                    }
                    try app.storage.recordTransfer(
                        hostID: host.id,
                        direction: .download,
                        localPath: destination.path(percentEncoded: false),
                        remotePath: item.path,
                        status: .succeeded,
                        bytes: bytes
                    )
                    destinations.append(destination)
                    app.appendTerminalLine(String(localized: "已下载 \(item.path) 到 \(destination.path(percentEncoded: false))"))
                }
                finishTransferProgress(detail: String(localized: "完成"))
                if destinationDirectory == app.localDirectoryURL {
                    app.loadLocalDirectory(destinationDirectory)
                }
                if shouldReveal, !destinations.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(destinations)
                }
                try app.refreshOperationHistory()
            } catch {
                let wasCancelled = error is CancellationError
                finishTransferProgress(detail: wasCancelled ? String(localized: "已取消") : String(localized: "失败"), shouldComplete: false)
                if let currentItem {
                    _ = try? app.storage.recordTransfer(
                        hostID: host.id,
                        direction: .download,
                        localPath: destinationDirectory.appendingPathComponent(currentItem.name).path(percentEncoded: false),
                        remotePath: currentItem.path,
                        status: wasCancelled ? .cancelled : .failed,
                        bytes: Int64(currentItem.byteSize ?? 0),
                        errorMessage: wasCancelled ? nil : error.localizedDescription
                    )
                }
                try? app.refreshOperationHistory()
                remoteFileError = wasCancelled ? String(localized: "下载已取消。") : error.localizedDescription
            }
        }
    }

    func previewSelectedRemoteFile() {
        guard let host = selectedHost,
              let item = selectedRemoteFile,
              !item.isDirectory else {
            remoteFileError = String(localized: "请先选择远端文件。")
            return
        }
        guard item.isSystemPreviewableFile else {
            remoteFileError = String(localized: "此文件类型不支持系统预览。可以下载到本地后使用对应工具打开。")
            return
        }

        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                startTransferProgress(kind: .download, title: String(localized: "正在准备预览"), detail: item.path, totalUnitCount: 1)
                let data = try await app.sftpService.download(remotePath: item.path, config: config)
                let previewDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("OpsDeckPreview", isDirectory: true)
                    .appendingPathComponent(host.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
                let destination = previewDirectory.appendingPathComponent(item.name)
                try data.write(to: destination, options: .atomic)
                updateTransferProgress(completedUnitCount: 1, detail: destination.path(percentEncoded: false))
                finishTransferProgress(detail: String(localized: "已打开预览"))
                NSWorkspace.shared.open(destination)
            } catch {
                finishTransferProgress(detail: String(localized: "失败"), shouldComplete: false)
                remoteFileError = error.localizedDescription
            }
        }
    }

    func requestDeleteSelectedRemoteFile() {
        let items = selectedRemoteFiles
        guard !items.isEmpty else { return }
        if SafetyService.shouldConfirmDangerousActions(settings: app.settings) {
            app.dangerousAction = DangerousActionRequest(kind: .deleteRemote(items), hostID: host.id)
        } else {
            deleteRemoteFiles(items)
        }
    }

    func requestCompressSelectedRemoteItem() {
        let items = selectedRemoteFiles
        guard let firstItem = items.first else {
            remoteFileError = String(localized: "请先选择远端文件或文件夹。")
            return
        }
        let archiveName = items.count == 1 ? "\(firstItem.name).tar.gz" : availableRemoteArchiveName()
        let archivePath = joinedRemotePath(parent: parentRemotePath(firstItem.path), child: archiveName)
        app.dangerousAction = DangerousActionRequest(kind: .compressRemote(items, archivePath: archivePath), hostID: host.id)
    }

    func compressRemoteItems(_ items: [RemoteFileItem], archivePath: String) {
        guard let host = selectedHost, let firstItem = items.first else { return }
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                let title = items.count == 1
                    ? String(localized: "正在压缩 \(firstItem.name)")
                    : String(localized: "正在压缩 \(items.count) 个项目")
                startTransferProgress(kind: .compress, title: title, detail: archivePath, totalUnitCount: nil)
                let parentPath = parentRemotePath(firstItem.path)
                let archiveName = (archivePath as NSString).lastPathComponent
                let sourceNames = items.map { shellQuote($0.name) }.joined(separator: " ")
                let command = "cd \(shellQuote(parentPath)) && tar -czf \(shellQuote(archiveName)) \(sourceNames)"
                let result = try await app.terminalService.run(command, config: config, sshService: app.sshService)
                let output = result.output.trimmingCharacters(in: .newlines)
                app.appendTerminalLine("$ \(command)")
                if !output.isEmpty {
                    app.appendTerminalLine(output)
                }
                finishTransferProgress(detail: String(localized: "完成"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config, useCache: false)
            } catch {
                finishTransferProgress(detail: String(localized: "失败"), shouldComplete: false)
                remoteFileError = error.localizedDescription
                app.appendTerminalLine(error.localizedDescription)
            }
        }
    }

    private func availableRemoteArchiveName() -> String {
        let existingNames = Set(remoteFiles.map(\.name))
        if !existingNames.contains("Archive.tar.gz") {
            return "Archive.tar.gz"
        }
        var suffix = 2
        while existingNames.contains("Archive \(suffix).tar.gz") {
            suffix += 1
        }
        return "Archive \(suffix).tar.gz"
    }

    func openNewRemoteDirectorySheet() {
        newRemoteDirectoryName = ""
        isShowingNewRemoteDirectorySheet = true
    }

    func openNewRemoteFileSheet() {
        newRemoteFileName = ""
        isShowingNewRemoteFileSheet = true
    }

    func createRemoteDirectory() {
        let name = sanitizedRemoteName(newRemoteDirectoryName)
        guard !name.isEmpty else {
            remoteFileError = String(localized: "文件夹名称不能为空。")
            return
        }
        guard let host = selectedHost else { return }
        isShowingNewRemoteDirectorySheet = false
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                let path = joinedRemotePath(parent: remoteDirectoryPath, child: name)
                try await app.sftpService.createDirectory(remotePath: path, config: config)
                app.appendTerminalLine(String(localized: "已创建文件夹 \(path)"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    func createRemoteFile() {
        let name = sanitizedRemoteName(newRemoteFileName)
        guard !name.isEmpty else {
            remoteFileError = String(localized: "文件名不能为空。")
            return
        }
        guard let host = selectedHost else { return }
        isShowingNewRemoteFileSheet = false

        let remotePath = joinedRemotePath(parent: remoteDirectoryPath, child: name)
        if SafetyService.shouldConfirmDangerousActions(settings: app.settings),
           remoteFiles.contains(where: { $0.path == remotePath }) {
            // The name-entry sheet was just dismissed above. Defer the global confirm
            // alert to the next runloop tick so the sheet finishes dismissing first —
            // otherwise the alert and the closing sheet fight for the window's modal slot.
            DispatchQueue.main.async { [self] in
                app.dangerousAction = DangerousActionRequest(kind: .createRemoteFile(remotePath: remotePath), hostID: host.id)
            }
            return
        }
        performCreateRemoteFile(remotePath: remotePath, host: host)
    }

    func performCreateRemoteFile(remotePath: String, host: HostProfile) {
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                _ = try await app.sftpService.upload(data: Data(), to: remotePath, config: config)
                app.appendTerminalLine(String(localized: "已创建文件 \(remotePath)"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
                selectedRemoteFileID = remotePath
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    func requestRenameSelectedRemoteFile() {
        guard let item = selectedRemoteFile else { return }
        remoteRenameCandidate = item
        remoteRenameName = item.name
    }

    func openRemoteInfo(for item: RemoteFileItem) {
        selectedRemoteFileID = item.id
        remoteInfoCandidate = item
        remoteInfoError = nil
        remoteInfoSummary = RemoteItemInfoSummary(
            byteCount: item.byteSize.map(Int64.init),
            fileCount: item.isDirectory ? 0 : 1,
            folderCount: 0,
            directChildCount: item.childCount
        )

        guard item.isDirectory, let host = selectedHost else { return }
        isRemoteInfoLoading = true
        Task {
            defer { isRemoteInfoLoading = false }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let summary = try await remoteFolderInfoSummary(path: item.path, config: config)
                remoteInfoSummary = summary
                if let directChildCount = summary.directChildCount {
                    updateVisibleRemoteItem(item.withChildCount(directChildCount))
                }
            } catch {
                remoteInfoError = error.localizedDescription
            }
        }
    }

    func requestChangePermissions(for item: RemoteFileItem, mode: String) {
        let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil else {
            remoteInfoError = String(localized: "权限必须是 3 或 4 位八进制数，例如 644、755 或 0640。")
            return
        }
        let previous = item.permissionsText
        let path = OpsShell.quote(item.path)
        presentRunbookPlan(RunbookPlan(
            kind: .service,
            title: String(localized: "更改文件权限"),
            summary: String(localized: "把 \(item.name) 的权限从 \(previous) 改为 \(normalized)。"),
            targetDescription: item.path,
            risk: .medium,
            requiresSudo: false,
            backupDescription: String(localized: "当前权限：\(previous)"),
            rollbackDescription: String(localized: "需要回滚时执行 chmod \(previous) \(item.path)"),
            steps: [
                RunbookStep(title: String(localized: "更改权限"), command: "chmod \(normalized) \(path)"),
                RunbookStep(title: String(localized: "验证权限"), command: "stat -c '%a %U %G %n' \(path) 2>/dev/null || stat -f '%Lp %Su %Sg %N' \(path)")
            ]
        ))
    }

    func renameRemoteCandidate() {
        guard let item = remoteRenameCandidate else { return }
        let name = sanitizedRemoteName(remoteRenameName)
        guard !name.isEmpty else {
            remoteFileError = String(localized: "新名称不能为空。")
            return
        }
        guard name != item.name else {
            remoteRenameCandidate = nil
            return
        }
        guard let host = selectedHost else { return }
        remoteRenameCandidate = nil
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                let newPath = joinedRemotePath(parent: parentRemotePath(item.path), child: name)
                try await app.sftpService.rename(remotePath: item.path, to: newPath, config: config)
                app.appendTerminalLine(String(localized: "已重命名 \(item.path) 为 \(newPath)"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    func deleteRemoteFiles(_ items: [RemoteFileItem]) {
        guard let host = selectedHost, let firstItem = items.first else { return }
        Task {
            var configForRefresh: SSHConnectionConfig?
            do {
                let config = try app.makeConnectionConfig(for: host)
                configForRefresh = config
                let preparingTitle = items.count == 1
                    ? String(localized: "正在准备删除 \(firstItem.name)")
                    : String(localized: "正在准备删除 \(items.count) 个项目")
                startTransferProgress(
                    kind: .delete,
                    title: preparingTitle,
                    detail: firstItem.path,
                    totalUnitCount: nil,
                    canCancel: true
                )
                var plan: [RemoteDeleteEntry] = []
                for item in items {
                    plan += try await makeRemoteDeletePlan(for: item, config: config)
                }
                let deletingTitle = items.count == 1
                    ? String(localized: "正在删除 \(firstItem.name)")
                    : String(localized: "正在删除 \(items.count) 个项目")
                updateTransferProgress(
                    title: deletingTitle,
                    totalUnitCount: max(plan.count, 1),
                    detail: firstItem.path
                )
                let deletedCount = try await deleteRemoteEntries(plan, config: config)
                finishTransferProgress(detail: String(localized: "完成"))
                let deletedSummary = items.count == 1 ? firstItem.path : String(localized: "\(items.count) 个选中项目")
                app.appendTerminalLine(String(localized: "已删除 \(deletedSummary)\(deletedCount > items.count ? String(localized: "，递归共 \(deletedCount) 个项目") : "")"))
                await loadRemoteDirectory(path: remoteDirectoryPath, config: config, useCache: false)
            } catch {
                let wasCancelled = error is CancellationError
                finishTransferProgress(detail: wasCancelled ? String(localized: "已取消") : String(localized: "失败"), shouldComplete: false)
                if let configForRefresh {
                    await loadRemoteDirectory(path: remoteDirectoryPath, config: configForRefresh, useCache: false)
                }
                let message = wasCancelled ? String(localized: "删除已取消。") : remoteDeleteErrorMessage(error, item: firstItem)
                remoteFileError = message
                app.appendTerminalLine(message)
            }
        }
    }

    func deleteRemoteFile(_ item: RemoteFileItem) {
        deleteRemoteFiles([item])
    }

    func openSelectedRemoteTextFile() {
        if let settings = app.settings {
            switch app.entitlements.canUse(.remoteEdit, settings: settings) {
            case .allowed:
                break
            case .needsPro(let message):
                app.proPromptMessage = message
                app.isShowingProUnlock = true
                return
            }
        }

        guard let item = selectedRemoteFile, !item.isDirectory else {
            remoteFileError = String(localized: "请先选择一个远端文本文件。")
            return
        }
        guard item.isEditableTextFile else {
            remoteFileError = String(localized: "只支持打开文本文件，例如 .sh、.log、.txt、.json、.conf。")
            return
        }

        if let byteSize = item.byteSize, byteSize > RemoteTextLimits.editableByteLimit {
            openSelectedRemoteTailPreview()
            return
        }

        guard let host = selectedHost else { return }
        isRemoteTextLoading = true
        remoteTextError = nil
        Task {
            defer { isRemoteTextLoading = false }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let data = try await app.sftpService.download(remotePath: item.path, config: config)
                let content = String(decoding: data, as: UTF8.self)
                remoteTextDocument = RemoteTextDocument(
                    path: item.path,
                    title: item.name,
                    content: content,
                    originalContent: content,
                    mode: .editable,
                    byteCount: UInt64(data.count),
                    loadedByteCount: UInt64(data.count),
                    message: nil
                )
            } catch {
                remoteTextError = error.localizedDescription
                remoteFileError = error.localizedDescription
            }
        }
    }

    func openSelectedRemoteTailPreview() {
        guard let item = selectedRemoteFile, !item.isDirectory else {
            remoteFileError = String(localized: "请先选择远端文件。")
            return
        }
        guard item.isEditableTextFile else {
            remoteFileError = String(localized: "只支持对文本文件做尾部预览。")
            return
        }
        guard let host = selectedHost else { return }
        isRemoteTextLoading = true
        remoteTextError = nil
        Task {
            defer { isRemoteTextLoading = false }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let result = try await app.sftpService.downloadTail(
                    remotePath: item.path,
                    maxBytes: RemoteTextLimits.tailPreviewByteLimit,
                    config: config
                )
                let content = String(decoding: result.data, as: UTF8.self)
                let message: String?
                if result.fileByteCount > result.loadedByteCount {
                    message = String(localized: "只读预览：显示 \(ByteCountFormatter.fileSizeFormatter.string(fromByteCount: Int64(result.fileByteCount))) 文件末尾的 \(ByteCountFormatter.fileSizeFormatter.string(fromByteCount: Int64(result.loadedByteCount)))。")
                } else {
                    message = String(localized: "只读预览。")
                }
                remoteTextDocument = RemoteTextDocument(
                    path: item.path,
                    title: item.name,
                    content: content,
                    originalContent: content,
                    mode: .tailPreview,
                    byteCount: result.fileByteCount,
                    loadedByteCount: result.loadedByteCount,
                    message: message
                )
            } catch {
                remoteTextError = error.localizedDescription
                remoteFileError = error.localizedDescription
            }
        }
    }

    func saveRemoteTextDocument() {
        guard let document = remoteTextDocument, !document.isReadOnly else { return }
        guard document.hasUnsavedChanges else { return }
        if SafetyService.shouldConfirmDangerousActions(settings: app.settings) {
            app.dangerousAction = DangerousActionRequest(kind: .saveRemoteText, hostID: host.id)
            return
        }
        performSaveRemoteTextDocument(document)
    }

    func performSaveRemoteTextDocument(_ document: RemoteTextDocument) {
        var document = document
        guard let host = selectedHost else { return }
        isRemoteTextSaving = true
        remoteTextError = nil
        Task {
            defer { isRemoteTextSaving = false }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let data = Data(document.content.utf8)
                let ctx = RemoteConfigSave.sudoContext(profile: serverProfile, password: config.authentication.password)
                let sizeText = ByteCountFormatter.fileSizeFormatter.string(fromByteCount: Int64(data.count))

                if let validator = document.validator {
                    // Config with a validator → privileged write + validate + rollback,
                    // so a broken config never survives on the server.
                    let stage = RemoteConfigSave.stagingPath(id: UUID())
                    _ = try await app.sftpService.upload(data: data, to: stage, config: config)
                    let cmd = RemoteConfigSave.validateWriteCommand(stage: stage, target: document.path, test: validator.testCommand, ctx: ctx)
                    let out = try await app.sshService.executeCommand(cmd, on: config).stdout
                    switch RemoteConfigSave.parse(out) {
                    case .validated:
                        document = saved(document, byteCount: data.count)
                        document.message = String(localized: "已保存并通过 \(validator.toolName) 校验。点击「测试并重载」使其生效。")
                        remoteTextDocument = document
                        app.appendTerminalLine(String(localized: "已保存并通过校验：\(document.path)"))
                        await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
                        // Refresh the nginx pane so a newly created/edited site shows up.
                        if validator == .nginx { refreshNginx() }
                    case .validationFailed(let detail):
                        // Live file was rolled back; keep the buffer dirty so the user can fix.
                        remoteTextError = String(localized: "\(validator.toolName) 校验未通过，已回滚，服务器上的文件未改动：\n\(detail)")
                    case .sudoAuthFailed:
                        remoteTextError = sudoAuthFailureMessage
                    case .saveFailed(let detail):
                        remoteTextError = String(localized: "保存失败（写入被拒绝，可能需要 root 或免密 sudo 权限）：\n\(detail)")
                    case .saved:
                        document = saved(document, byteCount: data.count)
                        remoteTextDocument = document
                    }
                    return
                }

                do {
                    // Fast path: direct SFTP write (atomic temp + replace) so a dropped
                    // connection can't leave the file truncated/half-written.
                    _ = try await app.sftpService.uploadReplacing(data: data, to: document.path, config: config)
                    document = saved(document, byteCount: data.count)
                    document.message = String(localized: "已保存 \(sizeText)。")
                    remoteTextDocument = document
                    app.appendTerminalLine(String(localized: "已保存远端文件 \(document.path)"))
                    await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
                } catch {
                    // Direct write failed — most often a permission issue on a root-owned
                    // path (e.g. /etc/**). Retry via a staged sudo copy.
                    let stage = RemoteConfigSave.stagingPath(id: UUID())
                    _ = try await app.sftpService.upload(data: data, to: stage, config: config)
                    let cmd = RemoteConfigSave.sudoWriteCommand(stage: stage, target: document.path, ctx: ctx)
                    let out = try await app.sshService.executeCommand(cmd, on: config).stdout
                    switch RemoteConfigSave.parse(out) {
                    case .saved:
                        document = saved(document, byteCount: data.count)
                        document.message = String(localized: "已用 sudo 保存 \(sizeText)。")
                        remoteTextDocument = document
                        app.appendTerminalLine(String(localized: "已用 sudo 保存远端文件 \(document.path)"))
                        await loadRemoteDirectory(path: remoteDirectoryPath, config: config)
                    case .sudoAuthFailed:
                        remoteTextError = sudoAuthFailureMessage
                    case .saveFailed(let detail):
                        remoteTextError = String(localized: "保存失败（直接写入与 sudo 均未成功，可能需要 root 或免密 sudo 权限）：\n\(detail)")
                    case .validated, .validationFailed:
                        remoteTextError = String(localized: "保存失败（直接写入与 sudo 均未成功）。")
                    }
                }
            } catch {
                remoteTextError = error.localizedDescription
            }
        }
    }

    private var sudoAuthFailureMessage: String {
        String(localized: "sudo 授权失败：这台服务器的 sudo 需要密码。OpsDeck 已尝试用你的 SSH 登录密码，但未通过——通常是登录密码与 sudo 密码不同，或该账号没有 sudo 权限。")
    }

    /// Returns a copy of `document` marked as saved (buffer == original, sizes updated).
    private func saved(_ document: RemoteTextDocument, byteCount: Int) -> RemoteTextDocument {
        var d = document
        d.originalContent = d.content
        d.byteCount = UInt64(byteCount)
        d.loadedByteCount = UInt64(byteCount)
        return d
    }

    func closeRemoteTextDocument() {
        remoteTextDocument = nil
        remoteTextError = nil
    }

    func refreshServerStatus() {
        guard let host = selectedHost else { return }
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                await refreshServerStatus(config: config)
            } catch {
                remoteFileError = error.localizedDescription
            }
        }
    }

    func refreshServerProfile() {
        guard let host = selectedHost else { return }
        Task {
            do {
                let config = try app.makeConnectionConfig(for: host)
                await refreshServerProfile(config: config)
            } catch {
                serverProfileError = error.localizedDescription
            }
        }
    }

    func refreshServerOverview() {
        refreshServerProfile()
        refreshServerStatus()
    }

    func refreshCurrentWorkspace() {
        guard selectedHost != nil else { return }
        guard connectionStatus == .connected else {
            if selectedWorkspaceMode == .tools {
                app.refreshToolCatalog()
                refreshDeploymentTemplates()
            } else {
                remoteFileError = String(localized: "请先连接服务器再刷新。")
                operationsError = String(localized: "请先连接服务器再刷新。")
            }
            return
        }

        switch selectedWorkspaceMode {
        case .files:
            refreshRemoteDirectory()
            refreshServerOverview()
        case .logs:
            refreshSelectedLogSource()
        case .tools:
            app.refreshToolCatalog()
            refreshDeploymentTemplates()
            refreshServices()
            refreshServerOverview()
            // Let the active module refresh its own data.
            WorkbenchRegistry.module(id: selectedWorkbenchModuleID).refresh(self)
        case .audit:
            refreshAuditFindings()
            refreshServerOverview()
        case .history:
            try? app.refreshOperationHistory()
        }
    }

    func presentRunbookPlan(_ plan: RunbookPlan) {
        // Every runbook executes commands on the server, so a live connection is
        // required. Guard centrally here so all action buttons are safe even if a
        // pane forgets to disable itself when offline.
        guard connectionStatus == .connected else {
            operationsError = String(localized: "请先连接服务器，再执行此操作。")
            return
        }
        // Only one mutating runbook may be in flight. Action buttons don't all
        // disable themselves while a run executes, so guard centrally to prevent
        // a second concurrent SSH operation from clobbering the first.
        guard activeRunbookRun == nil else {
            operationsError = String(localized: "已有一个操作正在执行，请等待它完成后再试。")
            return
        }
        // Stamp the module this operation belongs to (unless the caller already set
        // it, e.g. install/uninstall which target a tool's module from anywhere) so
        // the originating pane can show an in-progress / failed state for it.
        var plan = plan
        if plan.moduleID == nil, selectedWorkspaceMode == .tools {
            plan.moduleID = selectedWorkbenchModuleID
        }
        pendingRunbookPlan = plan
    }

    func cancelPendingRunbookPlan() {
        pendingRunbookPlan = nil
    }

    func presentServerProfileDryRun() {
        guard let host = selectedHost else {
            operationsError = String(localized: "请先选择服务器。")
            return
        }
        presentRunbookPlan(.dryRun(
            title: String(localized: "重新识别服务器画像"),
            command: "cat /etc/os-release 2>/dev/null; uname -m; whoami; command -v apt dnf yum pacman zypper apk 2>/dev/null || true",
            target: host.name
        ))
    }

    func executePendingRunbookPlan() {
        guard let plan = pendingRunbookPlan else { return }
        pendingRunbookPlan = nil
        executeRunbookPlan(plan)
    }

    func executeRunbookPlan(_ plan: RunbookPlan) {
        guard let host = selectedHost else {
            operationsError = String(localized: "请先选择服务器。")
            return
        }

        guard activeRunbookTask == nil else {
            operationsError = String(localized: "已有执行计划正在运行，请等待完成或先取消。")
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { activeRunbookTask = nil }
            var startingRun = RunbookRun(plan: plan, hostID: host.id)
            startingRun.status = .running
            activeRunbookRun = startingRun
            operationsError = nil
            do {
                let config = try app.makeConnectionConfig(for: host)
                let run = await app.runbookService.execute(
                    plan: plan,
                    hostID: host.id,
                    config: config,
                    sshService: app.sshService,
                    initialRun: startingRun,
                    onUpdate: { [weak self] updatedRun in
                        self?.activeRunbookRun = updatedRun
                        if self?.selectedRunbookRun?.id == updatedRun.id {
                            self?.selectedRunbookRun = updatedRun
                        }
                    }
                )
                activeRunbookRun = nil
                runbookRuns.insert(run, at: 0)
                await refreshServerStatus(config: config)
                await refreshServerProfile(config: config)
                await refreshOperationsAfterRunbook(kind: plan.kind, config: config)
                // Deterministically refresh the workbench module the user is on so
                // install/uninstall/换源/chsh etc. reflect immediately. Awaited and
                // only overwrites on success (a transient error keeps the last view).
                if selectedWorkspaceMode == .tools {
                    await refreshCurrentWorkbenchModuleData(config: config)
                }
                operationsError = run.status == .failed ? run.failureSummary : nil
            } catch {
                activeRunbookRun = nil
                startingRun.status = .failed
                startingRun.finishedAt = Date()
                startingRun.errorMessage = error.localizedDescription
                runbookRuns.insert(startingRun, at: 0)
                operationsError = error.localizedDescription
            }
        }
        activeRunbookTask = task
    }

    func cancelActiveRunbook() {
        guard activeRunbookTask != nil, activeRunbookRun?.status == .running else { return }
        activeRunbookTask?.cancel()
        operationsError = nil
    }

    /// Fetch a tool's own `--help`/`man` text from the server (read-only).
    func requestToolHelp(binary: String, title: String) {
        presentRunbookPlan(app.guideCatalogService.helpPlan(binary: binary, title: title))
    }

    func clearOperationsError() {
        operationsError = nil
    }

    func refreshServices() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isServicesLoading = true
        operationsError = nil
        Task {
            defer { isServicesLoading = false }
            do {
                serviceUnits = try await app.serviceManagerService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestServiceAction(_ action: ServiceAction, service: ServiceUnit) {
        presentRunbookPlan(app.serviceManagerService.plan(action: action, service: service, profile: serverProfile))
    }

    func openServiceLogs(_ service: ServiceUnit) {
        let source = LogSource(
            title: String(localized: "\(service.name) 日志"),
            detail: "journalctl -u \(service.name)",
            command: "journalctl -u \(OpsShell.quote(service.name)) -n 200 --no-pager",
            kind: .journal,
            byteCount: nil
        )
        selectedWorkspaceMode = .logs
        upsertAndSelectLogSource(source)
    }

    func refreshLogSources() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isLogSourcesLoading = true
        operationsError = nil
        Task {
            defer { isLogSourcesLoading = false }
            do {
                let sources = try await app.logDiscoveryService.discover(config: config, sshService: app.sshService)
                logSources = sources
                isLogSourcesLoading = false
                if let selectedLogSourceID,
                   sources.contains(where: { $0.id == selectedLogSourceID }) {
                    if let source = sources.first(where: { $0.id == selectedLogSourceID }) {
                        isLogPreviewLoading = true
                        defer { isLogPreviewLoading = false }
                        await loadLogPreview(source: source, config: config)
                    }
                } else if let first = sources.first {
                    selectedLogSourceID = first.id
                    isLogPreviewLoading = true
                    defer { isLogPreviewLoading = false }
                    await loadLogPreview(source: first, config: config)
                } else {
                    selectedLogSourceID = nil
                    logPreview = ""
                }
            } catch {
                // Keep the last good sources/preview on a transient error; just
                // surface it instead of blanking the whole log panel.
                operationsError = error.localizedDescription
            }
        }
    }

    func selectLogSource(_ source: LogSource) {
        guard let (_, config) = selectedOperationTarget() else { return }
        stopLogFollow()
        selectedLogSourceID = source.id
        isLogPreviewLoading = true
        operationsError = nil
        Task {
            defer { isLogPreviewLoading = false }
            await loadLogPreview(source: source, config: config)
        }
    }

    func refreshSelectedLogSource() {
        guard let source = logSources.first(where: { $0.id == selectedLogSourceID }) else {
            refreshLogSources()
            return
        }
        selectLogSource(source)
    }

    func startLogFollow() {
        guard !isLogFollowing,
              let source = logSources.first(where: { $0.id == selectedLogSourceID }),
              let (_, config) = selectedOperationTarget() else { return }
        let command = logFollowCommand(for: source, lineLimit: logLineLimit)
        let sshService = app.sshService
        let session = self
        isLogFollowing = true
        isLogFollowPaused = false
        operationsError = nil
        logFollowTask = Task.detached(priority: .userInitiated) {
            do {
                let stream = await sshService.executeCommandStream(command, on: config, maxResponseSize: 8 * 1024 * 1024)
                var pending = ""
                var lastPublish = Date()
                for try await chunk in stream {
                    try Task.checkCancellation()
                    pending += String(decoding: chunk.bytes, as: UTF8.self)
                    if pending.utf8.count >= 32 * 1024 || Date().timeIntervalSince(lastPublish) >= 0.12 {
                        let value = pending
                        pending = ""
                        lastPublish = Date()
                        await session.appendFollowedLog(value)
                    }
                }
                if !pending.isEmpty {
                    let finalValue = pending
                    await session.appendFollowedLog(finalValue)
                }
            } catch is CancellationError {
                // User stop, source switch, disconnect and page exit are normal.
            } catch {
                await session.setLogFollowError(error.localizedDescription)
            }
            await session.finishLogFollow()
        }
    }

    func stopLogFollow() {
        logFollowTask?.cancel()
        logFollowTask = nil
        isLogFollowing = false
        isLogFollowPaused = false
    }

    func toggleLogFollowPause() {
        guard isLogFollowing else { return }
        isLogFollowPaused.toggle()
    }

    private func appendFollowedLog(_ text: String) {
        guard !isLogFollowPaused, !text.isEmpty else { return }
        logPreview += text
        let lines = logPreview.split(separator: "\n", omittingEmptySubsequences: false)
        let maximum = max(logLineLimit * 3, 1_000)
        if lines.count > maximum {
            logPreview = lines.suffix(maximum).joined(separator: "\n")
        }
    }

    private func setLogFollowError(_ message: String) {
        operationsError = message
    }

    private func finishLogFollow() {
        isLogFollowing = false
        isLogFollowPaused = false
        logFollowTask = nil
    }

    private func logFollowCommand(for source: LogSource, lineLimit: Int) -> String {
        switch source.kind {
        case .file:
            return "tail -n \(lineLimit) -F \(OpsShell.quote(source.detail))"
        case .journal:
            return source.command
                .replacingOccurrences(of: "-n 200", with: "-n \(lineLimit)")
                .replacingOccurrences(of: "--no-pager", with: "--no-pager -f")
        case .docker:
            return source.command
                .replacingOccurrences(of: "logs --tail 200", with: "logs --tail \(lineLimit) --follow")
        }
    }

    func copyLogPreview() {
        guard !logPreview.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logPreview, forType: .string)
        app.appendTerminalLine(String(localized: "日志片段已复制到剪贴板。"))
    }

    func exportLogPreview() {
        guard !logPreview.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "OpsDeck-Log-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logPreview.write(to: url, atomically: true, encoding: .utf8)
            app.appendTerminalLine(String(localized: "日志已导出到 \(url.path(percentEncoded: false))"))
            app.localFileService.revealInFinder(url)
        } catch {
            operationsError = error.localizedDescription
        }
    }

    func refreshNginx() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isNginxLoading = true
        operationsError = nil
        Task {
            defer { isNginxLoading = false }
            do {
                nginxSnapshot = try await app.nginxManagerService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestNginxTestAndReload() {
        presentRunbookPlan(app.nginxManagerService.testAndReloadPlan(profile: serverProfile))
    }

    func requestNginxValidate() {
        presentRunbookPlan(app.nginxManagerService.validatePlan(profile: serverProfile))
    }

    func requestNginxSiteEnabled(site: NginxSiteConfig, enable: Bool) {
        presentRunbookPlan(app.nginxManagerService.setSiteEnabledPlan(sitePath: site.path, enable: enable, profile: serverProfile))
    }

    func requestCreateNginxSite(domains: [String], type: NginxSiteType, upstreamPort: Int, staticRoot: String, createRoot: Bool, enable: Bool, requestSSL: Bool, staging: Bool) {
        presentRunbookPlan(app.nginxManagerService.createSitePlan(
            domains: domains,
            type: type,
            upstreamPort: upstreamPort,
            staticRoot: staticRoot,
            createRoot: createRoot,
            enable: enable,
            requestSSL: requestSSL,
            email: app.settings?.acmeEmail,
            staging: staging,
            profile: serverProfile
        ))
    }

    /// One-click SSL for an existing site. `domain` is guessed from the site file
    /// name (we name site files `<domain>.conf`); the user can adjust it in the form.
    func requestSiteSSL(domains: [String], staging: Bool) {
        presentRunbookPlan(app.certbotService.obtainPlan(
            domains: domains,
            method: .nginx,
            email: app.settings?.acmeEmail,
            staging: staging,
            cloudflareToken: nil,
            profile: serverProfile
        ))
    }

    func composeNginxSiteTemplate() {
        guard connectionStatus == .connected else {
            remoteTextError = String(localized: "请先连接服务器。")
            return
        }
        let template = NginxManagerService.newSiteTemplate()
        remoteTextDocument = RemoteTextDocument(
            path: "/etc/nginx/sites-available/new-site.conf",
            title: String(localized: "new-site.conf（新建）"),
            content: template,
            originalContent: "",
            mode: .editable,
            byteCount: UInt64(template.utf8.count),
            loadedByteCount: UInt64(template.utf8.count),
            message: String(localized: "新建站点模板：保存将写入 sites-available（需要时自动用 sudo）；启用需软链到 sites-enabled 后 reload。保存时会跑 nginx -t 校验，不通过会自动回滚。"),
            validator: .nginx
        )
    }

    func openRemoteTextPath(_ path: String, title: String? = nil, byteCount: UInt64? = nil, validator: ConfigValidator? = nil) {
        guard let host = selectedHost else {
            remoteFileError = String(localized: "请先选择服务器。")
            return
        }
        guard connectionStatus == .connected else {
            remoteFileError = String(localized: "请先连接服务器。")
            return
        }
        isRemoteTextLoading = true
        remoteTextError = nil
        Task {
            defer { isRemoteTextLoading = false }
            do {
                let config = try app.makeConnectionConfig(for: host)
                let data = try await app.sftpService.download(remotePath: path, config: config)
                let content = String(decoding: data, as: UTF8.self)
                remoteTextDocument = RemoteTextDocument(
                    path: path,
                    title: title ?? (path as NSString).lastPathComponent,
                    content: content,
                    originalContent: content,
                    mode: .editable,
                    byteCount: byteCount ?? UInt64(data.count),
                    loadedByteCount: UInt64(data.count),
                    message: nil,
                    validator: validator
                )
            } catch {
                remoteTextError = error.localizedDescription
                remoteFileError = error.localizedDescription
            }
        }
    }

    func requestInstallTool(_ tool: ToolDefinition) {
        var plan = app.installerCatalogService.installPlan(tool: tool, profile: serverProfile, policy: effectiveDownloadMirrorPolicy)
        plan.toolID = tool.id
        plan.moduleID = tool.workbenchModuleID
        presentRunbookPlan(plan)
    }

    /// One-click deploy: install the given catalog tools (+ their dependencies) in
    /// dependency order, skipping already-installed ones, in a single runbook.
    func requestDeployTools(_ toolIDs: [String]) {
        var plan = app.installerCatalogService.deployPlan(toolIDs: toolIDs, profile: serverProfile, policy: effectiveDownloadMirrorPolicy)
        plan.moduleID = "deployment"
        presentRunbookPlan(plan)
    }

    /// Install-time environment prerequisites for a tool against the current profile.
    func preflightIssues(for tool: ToolDefinition) -> [PreflightIssue] {
        app.installerCatalogService.preflight(for: tool, profile: serverProfile)
    }

    /// Names of a tool's declared dependencies that aren't installed yet (will be
    /// auto-installed first). Empty when all deps present or profile unknown.
    func missingDependencies(for tool: ToolDefinition) -> [String] {
        guard serverProfile != nil else { return [] }
        return tool.dependencies.compactMap { id in
            guard let dep = app.toolCatalog.first(where: { $0.id == id }) ?? app.installerCatalogService.catalog().first(where: { $0.id == id }) else { return nil }
            return dep.isInstalled(on: serverProfile) ? nil : dep.name
        }
    }

    func requestUninstallTool(_ tool: ToolDefinition) {
        guard tool.uninstallPolicy.isAllowed else { return }
        var plan = app.installerCatalogService.uninstallPlan(tool: tool, profile: serverProfile)
        plan.toolID = tool.id
        plan.moduleID = tool.workbenchModuleID
        presentRunbookPlan(plan)
    }

    /// Offers a repair only for package-manager failures whose remediation is
    /// deterministic. Unknown / unsafe errors remain diagnostic-only.
    func requestPackageRecovery(for run: RunbookRun) {
        let message = run.steps.map(\.output).joined(separator: "\n") + "\n" + (run.failureSummary ?? "")
        guard var plan = PackageRecoveryPlanFactory().plan(for: message, profile: serverProfile) else { return }
        plan.moduleID = run.moduleID
        plan.toolID = run.toolID
        presentRunbookPlan(plan)
    }

    func hasPackageRecovery(for run: RunbookRun) -> Bool {
        let message = run.steps.map(\.output).joined(separator: "\n") + "\n" + (run.failureSummary ?? "")
        return PackageRecoveryPlanFactory().diagnosis(for: message) != nil
    }

    /// Current runbook activity attributable to a workbench module, so its pane can
    /// show an installing / failed card instead of the idle empty state. `.running`
    /// wins; otherwise if the module's most recent finished run failed we surface it
    /// (newest-first history means a later success clears the failed state).
    func moduleActivity(_ id: String) -> ModuleActivity {
        if let run = activeRunbookRun, run.moduleID == id {
            return .running(run)
        }
        if let last = runbookRuns.first(where: { $0.moduleID == id }), last.status == .failed {
            return .failed(last)
        }
        return .idle
    }

    /// Same as `moduleActivity` but keyed on a specific installer tool id, so the
    /// installer list can show per-row install state (many tools share the
    /// "installer" module).
    func toolActivity(_ toolID: String) -> ModuleActivity {
        if let run = activeRunbookRun, run.toolID == toolID {
            return .running(run)
        }
        if let last = runbookRuns.first(where: { $0.toolID == toolID }), last.status == .failed {
            return .failed(last)
        }
        return .idle
    }

    /// Whether a runbook is currently executing against this module (used to disable
    /// a pane's action controls for the duration).
    func isModuleBusy(_ id: String) -> Bool {
        activeRunbookRun?.moduleID == id
    }

    /// Re-run a failed operation. Re-presents the confirmation sheet so high-risk
    /// operations are still confirmed before re-executing.
    func retryRun(_ run: RunbookRun) {
        presentRunbookPlan(run.plan)
    }

    /// Open the live-log / diagnostic detail for a run (reuses the run detail sheet).
    func showRunDetail(_ run: RunbookRun) {
        selectedRunbookRun = run
    }

    func refreshDockerContainers() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isDockerLoading = true
        operationsError = nil
        Task {
            defer { isDockerLoading = false }
            do {
                applyDockerSnapshot(try await app.dockerManagerService.collect(config: config, sshService: app.sshService))
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestDockerAction(_ action: ServiceAction, container: DockerContainerSummary) {
        presentRunbookPlan(app.dockerManagerService.plan(action: action, container: container))
    }

    func requestStartDockerService() {
        presentRunbookPlan(app.dockerManagerService.startDaemonPlan(profile: serverProfile))
    }

    func requestRemoveDockerContainer(_ container: DockerContainerSummary) {
        presentRunbookPlan(app.dockerManagerService.removeContainerPlan(container: container))
    }

    func requestInspectDockerContainer(_ container: DockerContainerSummary) {
        presentRunbookPlan(app.dockerManagerService.inspectContainerPlan(container: container))
    }

    func requestDockerDiskUsage() {
        presentRunbookPlan(app.dockerManagerService.diskUsagePlan())
    }

    func requestDockerPrune() {
        presentRunbookPlan(app.dockerManagerService.prunePlan())
    }

    func requestDockerPull(reference: String) {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            operationsError = String(localized: "请填写镜像名称，例如 nginx:alpine。")
            return
        }
        presentRunbookPlan(app.dockerManagerService.pullImagePlan(reference: reference))
    }

    func requestDockerRun(name: String, image: String, portMapping: String, restartPolicy: String) {
        let validName = name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
        let validPort = portMapping.isEmpty
            || portMapping.range(of: "^[0-9]{1,5}:[0-9]{1,5}(/(tcp|udp))?$", options: [.regularExpression, .caseInsensitive]) != nil
        guard validName, !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validPort else {
            operationsError = String(localized: "请检查容器名称、镜像和端口映射（例如 8080:80）。")
            return
        }
        presentRunbookPlan(app.dockerManagerService.runContainerPlan(
            name: name, image: image, portMapping: portMapping, restartPolicy: restartPolicy
        ))
    }

    func requestDockerExec(container: DockerContainerSummary, command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        presentRunbookPlan(app.dockerManagerService.execPlan(container: container, command: command))
    }

    func requestRemoveDockerImage(_ image: DockerImageSummary) {
        presentRunbookPlan(app.dockerManagerService.removeImagePlan(image: image))
    }

    func openDockerLogs(_ container: DockerContainerSummary) {
        let source = LogSource(
            title: "Docker \(container.name)",
            detail: container.name,
            command: "docker logs --tail 200 \(OpsShell.quote(container.name))",
            kind: .docker,
            byteCount: nil
        )
        selectedWorkspaceMode = .logs
        upsertAndSelectLogSource(source)
    }

    func refreshDatabases() {
        guard !isDatabasesLoading else { return }
        guard let (_, config) = selectedOperationTarget() else { return }
        isDatabasesLoading = true
        operationsError = nil
        Task {
            defer { isDatabasesLoading = false }
            do {
                databases = try await app.databaseManagerService.collect(profile: serverProfile, config: config, sshService: app.sshService)
                hasLoadedDatabases = true
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestDatabaseBackup(_ database: DatabaseTarget) {
        presentRunbookPlan(app.databaseManagerService.backupPlan(database: database, profile: serverProfile))
    }

    func requestDatabaseInspect(_ database: DatabaseTarget) {
        presentRunbookPlan(app.databaseManagerService.inspectPlan(database: database, profile: serverProfile))
    }

    // MARK: - Redis manager

    private var redisCredentialID: String { "redis-credential-\(host.id.uuidString)" }

    func redisStoredCredential() -> RedisCredential? {
        guard let record = try? app.credentialStore.read(id: redisCredentialID, kind: .password),
              let data = record.value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RedisCredential.self, from: data)
    }

    func redisSaveCredential(_ credential: RedisCredential?) throws {
        guard let credential else {
            try app.credentialStore.delete(id: redisCredentialID)
            return
        }
        guard !credential.password.isEmpty else {
            throw RedisManagerError.invalidInput(String(localized: "Redis 密码不能为空；无需认证时请清除凭据。"))
        }
        let data = try JSONEncoder().encode(credential)
        guard let value = String(data: data, encoding: .utf8) else {
            throw RedisManagerError.invalidInput(String(localized: "无法保存 Redis 凭据。"))
        }
        _ = try app.credentialStore.save(value, kind: .password, id: redisCredentialID)
    }

    func redisLoadSnapshot(credential: RedisCredential?) async throws -> RedisServerSnapshot {
        guard connectionStatus == .connected else {
            throw RedisManagerError.unavailable(String(localized: "请先连接服务器。"))
        }
        return try await app.redisManagerService.loadSnapshot(
            credential: credential,
            config: makeConfig(),
            sshService: app.databaseSSHService
        )
    }

    func redisScanKeys(
        database: Int,
        cursor: String,
        pattern: String,
        credential: RedisCredential?
    ) async throws -> RedisKeyPage {
        try await app.redisManagerService.scanKeys(
            database: database,
            cursor: cursor,
            pattern: pattern,
            credential: credential,
            config: makeConfig(),
            sshService: app.databaseSSHService
        )
    }

    func redisLoadKeyDetail(
        database: Int,
        key: String,
        credential: RedisCredential?
    ) async throws -> RedisKeyDetail {
        try await app.redisManagerService.loadKeyDetail(
            database: database,
            key: key,
            credential: credential,
            config: makeConfig(),
            sshService: app.databaseSSHService
        )
    }

    func redisSetString(
        database: Int,
        key: String,
        value: String,
        preserveTTL: Bool,
        credential: RedisCredential?
    ) async throws {
        do {
            try await app.redisManagerService.setString(
                database: database,
                key: key,
                value: value,
                preserveTTL: preserveTTL,
                credential: credential,
                config: makeConfig(),
                sshService: app.databaseSSHService
            )
            app.recordOperationNotice(
                title: String(localized: "Redis 键已保存"),
                detail: String(localized: "DB \(database) · \(key)"),
                systemImage: "checkmark.circle",
                level: .success
            )
        } catch {
            app.recordOperationNotice(
                title: String(localized: "Redis 键保存失败"),
                detail: error.localizedDescription,
                systemImage: "exclamationmark.triangle",
                level: .warning
            )
            throw error
        }
    }

    func redisDeleteKey(database: Int, key: String, credential: RedisCredential?) async throws {
        do {
            try await app.redisManagerService.deleteKey(
                database: database,
                key: key,
                credential: credential,
                config: makeConfig(),
                sshService: app.databaseSSHService
            )
            app.recordOperationNotice(
                title: String(localized: "Redis 键已删除"),
                detail: String(localized: "DB \(database) · \(key)"),
                systemImage: "trash",
                level: .success
            )
        } catch {
            app.recordOperationNotice(
                title: String(localized: "Redis 键删除失败"),
                detail: error.localizedDescription,
                systemImage: "exclamationmark.triangle",
                level: .warning
            )
            throw error
        }
    }

    func redisSetTTL(database: Int, key: String, seconds: Int?, credential: RedisCredential?) async throws {
        try await app.redisManagerService.setTTL(
            database: database,
            key: key,
            seconds: seconds,
            credential: credential,
            config: makeConfig(),
            sshService: app.databaseSSHService
        )
        app.recordOperationNotice(
            title: String(localized: "Redis TTL 已更新"),
            detail: String(localized: "DB \(database) · \(key)"),
            systemImage: "timer",
            level: .success
        )
    }

    func openRedisLogs() {
        let source = LogSource(
            title: String(localized: "Redis 日志"),
            detail: "redis-server",
            command: "journalctl -u redis-server -n 300 --no-pager 2>/dev/null || tail -n 300 /var/log/redis/redis-server.log 2>/dev/null || true",
            kind: .journal,
            byteCount: nil
        )
        selectedWorkspaceMode = .logs
        upsertAndSelectLogSource(source)
    }

    // MARK: - Database browser (Navicat-lite)

    /// The engine + connection context for the currently open browser target.
    private var dbContext: (dialect: DBDialect, config: SSHConnectionConfig, adminSudo: String)? {
        guard dbState.dbBrowserTarget != nil,
              let dialect = dbState.dbSelectedConnection?.dialect,
              let config = try? makeConfig() else { return nil }
        return (dialect, config, OpsShell.sudoPrefix(for: serverProfile))
    }

    /// Open the browser for a database target and load its database list. Redis
    /// (no SQL grid) is rejected up front.
    func openDatabaseBrowser(_ target: DatabaseTarget) {
        guard DBDialect.from(target.kind) != nil else {
            dbState.dbError = String(localized: "Redis 暂不支持表格浏览。")
            return
        }
        guard dbState.dbBrowserTarget == nil || dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        dbPersistQueryWorkspace()
        cancelDBLoad()
        dbStopSQL()
        dbState.dbBrowserTarget = target
        dbLoadConnections(opening: target)
        dbState.dbDatabases = []; dbState.dbSelectedDatabase = nil
        dbState.dbTables = []; dbState.dbSelectedTable = nil
        dbState.dbColumns = []; dbState.dbRows = DBResultSet()
        dbState.dbError = nil; dbState.dbTab = .data
        dbState.dbSQLText = ""; dbState.dbSQLResult = nil; dbState.dbSQLError = nil
        dbState.dbFilterColumn = nil; dbState.dbAppliedFilter = nil
        dbState.dbPageCursors = []; dbState.dbTableCache = [:]; dbState.dbColumnCache = [:]
        dbState.dbNavigatorSnapshots = [:]
        dbState.dbRowsVersion += 1; dbState.dbSQLResultVersion += 1
        dbState.dbSelectedRows = []; dbState.dbStagedChanges = []; dbState.dbPendingWrite = nil; dbState.dbWriteError = nil
        dbLoadStoredCredential()
        dbLoadQueryWorkspace()
        dbLoadDatabases()
    }

    func openDatabaseConnectionsWorkspace() {
        if let target = databases.first(where: {
            $0.activeState == "active" && DBDialect.from($0.kind) != nil
        }) {
            openDatabaseBrowser(target)
            return
        }
        // Window-only placeholder. It is not shown as a detected service; it
        // simply gives servers without a local SQL daemon access to saved/manual
        // connections reachable through that SSH host.
        openDatabaseBrowser(DatabaseTarget(
            kind: .mysql,
            serviceName: "manual-connections",
            installed: false,
            serviceInstalled: false,
            activeState: nil,
            version: nil
        ))
    }

    func closeDatabaseBrowser() {
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        dbPersistQueryWorkspace()
        cancelDBLoad()
        dbStopSQL()
        if let config = dbContext?.config {
            Task { await app.databaseSSHService.disconnect(config: config) }
        }
        dbState.dbBrowserTarget = nil
        dbState.dbError = nil
    }

    /// Re-run the browser login with a (possibly new) credential, persisting it
    /// to the Keychain (or clearing it when switching back to admin/socket auth).
    func dbApplyCredential(_ credential: DBCredential?) {
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        dbStopSQL()
        dbStoreCurrentNavigatorSnapshot()
        dbState.dbCredential = (credential?.isEmpty ?? true) ? nil : credential
        if let credential,
           let index = dbState.dbConnections.firstIndex(where: { $0.id == dbState.dbSelectedConnectionID }),
           dbState.dbConnections[index].source == .manual {
            dbState.dbConnections[index].host = credential.host
            dbState.dbConnections[index].port = credential.port ?? dbState.dbConnections[index].dialect.defaultPort
            dbState.dbConnections[index].username = credential.username
            dbPersistConnectionProfiles()
        }
        dbPersistCredential(dbState.dbCredential)
        dbState.dbShowCredentialSheet = false
        dbState.dbTableCache = [:]
        dbState.dbColumnCache = [:]
        dbLoadDatabases()
    }

    // MARK: DB connection + credential persistence

    private var dbConnectionsDefaultsKey: String {
        "database-connections-\(host.id.uuidString)"
    }

    private func dbLoadConnections(opening target: DatabaseTarget) {
        var seenKinds: Set<DatabaseKind> = []
        var detected: [DBConnectionProfile] = []
        let detectedCandidates = target.installed ? databases + [target] : databases
        for candidate in detectedCandidates where seenKinds.insert(candidate.kind).inserted {
            if let profile = DBConnectionProfile.detected(candidate) {
                detected.append(profile)
            }
        }
        let manual: [DBConnectionProfile]
        if let data = UserDefaults.standard.data(forKey: dbConnectionsDefaultsKey),
           let saved = try? JSONDecoder().decode([DBConnectionProfile].self, from: data) {
            manual = saved.filter { $0.source == .manual }
        } else {
            manual = []
        }
        dbState.dbConnections = detected + manual
        let preferredDetectedID = target.installed ? DBConnectionProfile.detected(target)?.id : nil
        dbState.dbSelectedConnectionID = preferredDetectedID ?? manual.first?.id ?? detected.first?.id
    }

    private func dbPersistConnectionProfiles() {
        let manual = dbState.dbConnections.filter { $0.source == .manual }
        guard let data = try? JSONEncoder().encode(manual) else { return }
        UserDefaults.standard.set(data, forKey: dbConnectionsDefaultsKey)
    }

    func dbSelectConnection(
        _ id: String,
        preferredDatabase: String? = nil,
        preferredTable: String? = nil
    ) {
        if id == dbState.dbSelectedConnectionID {
            if let preferredDatabase,
               preferredDatabase != dbState.dbSelectedDatabase,
               dbState.dbDatabases.contains(preferredDatabase) {
                dbSelectDatabase(preferredDatabase, preferredTable: preferredTable)
            } else if let preferredTable,
                      dbState.dbTables.contains(where: { $0.name == preferredTable }) {
                dbSelectTable(preferredTable)
            }
            return
        }
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        guard dbState.dbConnections.contains(where: { $0.id == id }) else { return }
        dbStoreCurrentNavigatorSnapshot()
        dbPersistQueryWorkspace()
        cancelDBLoad()
        dbStopSQL()
        dbState.dbSelectedConnectionID = id
        dbResetConnectionWorkspace()
        dbState.dbTableCache = [:]
        dbState.dbColumnCache = [:]
        dbLoadStoredCredential()
        dbLoadQueryWorkspace()
        dbLoadDatabases(preferredDatabase: preferredDatabase, preferredTable: preferredTable)
    }

    func dbSaveConnection(
        _ profile: DBConnectionProfile,
        credential: DBCredential,
        preferredDatabase: String? = nil
    ) {
        dbStopSQL()
        dbPersistQueryWorkspace()
        dbStoreCurrentNavigatorSnapshot()
        var saved = profile
        saved.source = .manual
        saved.host = credential.host
        saved.port = credential.port ?? saved.dialect.defaultPort
        saved.username = credential.username
        if let index = dbState.dbConnections.firstIndex(where: { $0.id == saved.id }) {
            dbState.dbConnections[index] = saved
        } else {
            dbState.dbConnections.append(saved)
        }
        dbPersistConnectionProfiles()
        dbState.dbSelectedConnectionID = saved.id
        dbState.dbCredential = credential
        dbPersistCredential(credential)
        dbResetConnectionWorkspace()
        dbLoadQueryWorkspace()
        dbState.dbTableCache = [:]
        dbState.dbColumnCache = [:]
        dbLoadDatabases(preferredDatabase: preferredDatabase)
    }

    func dbDeleteConnection(_ profile: DBConnectionProfile) {
        guard profile.source == .manual else { return }
        let wasSelected = dbState.dbSelectedConnectionID == profile.id
        if wasSelected { dbStopSQL() }
        dbState.dbConnections.removeAll { $0.id == profile.id }
        dbState.dbNavigatorSnapshots.removeValue(forKey: profile.id)
        dbPersistConnectionProfiles()
        try? app.credentialStore.delete(id: dbCredentialKey(connectionID: profile.id))
        DatabaseQueryStore().clear(hostID: host.id, connectionID: profile.id)
        guard wasSelected else { return }
        dbState.dbSelectedConnectionID = dbState.dbConnections.first?.id
        dbResetConnectionWorkspace()
        dbLoadStoredCredential()
        dbLoadQueryWorkspace()
        dbState.dbTableCache = [:]
        dbState.dbColumnCache = [:]
        dbLoadDatabases()
    }

    func dbStoredCredential(for profile: DBConnectionProfile) -> DBCredential? {
        if profile.id == dbState.dbSelectedConnectionID, let credential = dbState.dbCredential {
            return credential
        }
        return dbReadCredential(connectionID: profile.id)
    }

    func dbTestConnection(_ profile: DBConnectionProfile, credential: DBCredential) async throws -> Int {
        guard let config = try? makeConfig() else {
            throw DBEngineError.notSupported(String(localized: "当前 SSH 服务器尚未连接。"))
        }
        let names = try await app.databaseBrowser.listDatabases(
            dialect: profile.dialect,
            config: config,
            credential: credential,
            adminSudo: OpsShell.sudoPrefix(for: serverProfile),
            sshService: app.databaseSSHService
        )
        return names.count
    }

    private func dbCredentialKey() -> String? {
        guard let connectionID = dbState.dbSelectedConnectionID else { return nil }
        return dbCredentialKey(connectionID: connectionID)
    }

    private func dbResetConnectionWorkspace() {
        dbState.dbDatabases = []
        dbState.dbSelectedDatabase = nil
        dbState.dbTables = []
        dbState.dbSelectedTable = nil
        dbState.dbColumns = []
        dbState.dbRows = DBResultSet()
        dbResetGridControls()
        dbState.dbSelectedRows = []
        dbState.dbStagedChanges = []
        dbState.dbPendingWrite = nil
        dbState.dbShowInsertSheet = false
        dbState.dbWriteError = nil
        dbState.dbSQLText = ""
        dbState.dbSQLResult = nil
        dbState.dbSQLError = nil
        dbState.dbRowsVersion += 1
        dbState.dbSQLResultVersion += 1
    }

    // MARK: Local query tabs / history / favorites

    private func dbLoadQueryWorkspace() {
        guard let connectionID = dbState.dbSelectedConnectionID else {
            let tab = DBQueryTab()
            dbState.dbQueryTabs = [tab]
            dbState.dbSelectedQueryTabID = tab.id
            dbState.dbQueryHistory = []
            dbState.dbQueryFavorites = []
            dbState.dbSQLText = ""
            return
        }
        let snapshot = DatabaseQueryStore().load(hostID: host.id, connectionID: connectionID)
        dbState.dbQueryTabs = snapshot.tabs
        dbState.dbSelectedQueryTabID = snapshot.selectedTabID ?? snapshot.tabs.first?.id
        dbState.dbQueryHistory = snapshot.history
        dbState.dbQueryFavorites = snapshot.favorites
        dbState.dbSQLText = snapshot.tabs.first(where: { $0.id == dbState.dbSelectedQueryTabID })?.sql ?? ""
    }

    private func dbPersistQueryWorkspace() {
        guard let connectionID = dbState.dbSelectedConnectionID else { return }
        DatabaseQueryStore().save(
            DBQueryWorkspaceSnapshot(
                tabs: dbState.dbQueryTabs,
                selectedTabID: dbState.dbSelectedQueryTabID,
                history: dbState.dbQueryHistory,
                favorites: dbState.dbQueryFavorites
            ),
            hostID: host.id,
            connectionID: connectionID
        )
    }

    func dbUpdateCurrentQueryDraft(_ sql: String) {
        dbState.dbSQLText = sql
        guard let id = dbState.dbSelectedQueryTabID,
              let index = dbState.dbQueryTabs.firstIndex(where: { $0.id == id }) else { return }
        dbState.dbQueryTabs[index].sql = sql
        dbPersistQueryWorkspace()
    }

    func dbNewQueryTab(currentSQL: String) {
        dbUpdateCurrentQueryDraft(currentSQL)
        guard dbState.dbQueryTabs.count < 12 else {
            dbState.dbSQLError = String(localized: "最多同时打开 12 个查询标签。")
            return
        }
        let tab = DBQueryTab()
        dbState.dbQueryTabs.append(tab)
        dbState.dbSelectedQueryTabID = tab.id
        dbState.dbSQLText = ""
        dbState.dbSQLResult = nil
        dbState.dbSQLError = nil
        dbPersistQueryWorkspace()
    }

    func dbSelectQueryTab(_ id: UUID, currentSQL: String) {
        guard dbState.dbQueryTabs.contains(where: { $0.id == id }) else { return }
        dbUpdateCurrentQueryDraft(currentSQL)
        dbState.dbSelectedQueryTabID = id
        dbState.dbSQLText = dbState.dbQueryTabs.first(where: { $0.id == id })?.sql ?? ""
        dbState.dbSQLResult = nil
        dbState.dbSQLError = nil
        dbPersistQueryWorkspace()
    }

    func dbCloseQueryTab(_ id: UUID, currentSQL: String) {
        dbUpdateCurrentQueryDraft(currentSQL)
        guard dbState.dbQueryTabs.count > 1,
              let index = dbState.dbQueryTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = dbState.dbSelectedQueryTabID == id
        dbState.dbQueryTabs.remove(at: index)
        if wasSelected {
            let nextIndex = min(index, dbState.dbQueryTabs.count - 1)
            let next = dbState.dbQueryTabs[nextIndex]
            dbState.dbSelectedQueryTabID = next.id
            dbState.dbSQLText = next.sql
            dbState.dbSQLResult = nil
            dbState.dbSQLError = nil
        }
        dbPersistQueryWorkspace()
    }

    func dbUseSavedQuery(_ query: DBSavedQuery) {
        dbUpdateCurrentQueryDraft(query.sql)
    }

    func dbToggleFavorite(sql: String) {
        let value = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let index = dbState.dbQueryFavorites.firstIndex(where: { $0.sql == value }) {
            dbState.dbQueryFavorites.remove(at: index)
        } else {
            dbState.dbQueryFavorites.insert(DBSavedQuery(sql: value), at: 0)
            dbState.dbQueryFavorites = Array(dbState.dbQueryFavorites.prefix(100))
        }
        dbPersistQueryWorkspace()
    }

    func dbClearQueryHistory() {
        dbState.dbQueryHistory = []
        dbPersistQueryWorkspace()
    }

    func dbClearQueryFavorites() {
        dbState.dbQueryFavorites = []
        dbPersistQueryWorkspace()
    }

    private func dbRecordQuery(_ sql: String) {
        let value = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        dbState.dbQueryHistory.removeAll { $0.sql == value }
        dbState.dbQueryHistory.insert(DBSavedQuery(sql: value), at: 0)
        dbState.dbQueryHistory = Array(dbState.dbQueryHistory.prefix(100))
        dbPersistQueryWorkspace()
    }

    private func dbCredentialKey(connectionID: String) -> String {
        "dbcred-\(host.id.uuidString)-\(connectionID)"
    }

    private func dbReadCredential(connectionID: String) -> DBCredential? {
        let key = dbCredentialKey(connectionID: connectionID)
        guard let rec = try? app.credentialStore.read(id: key, kind: .password),
              let data = rec.value.data(using: .utf8),
              let credential = try? JSONDecoder().decode(DBCredential.self, from: data),
              !credential.isEmpty else { return nil }
        return credential
    }

    private func dbLoadStoredCredential() {
        guard let profile = dbState.dbSelectedConnection else {
            dbState.dbCredential = nil
            return
        }
        if let credential = dbReadCredential(connectionID: profile.id) {
            dbState.dbCredential = credential
        } else if profile.source == .manual, !profile.username.isEmpty {
            dbState.dbCredential = DBCredential(
                username: profile.username,
                password: "",
                host: profile.host,
                port: profile.port
            )
        } else {
            // Migrate the former host+kind credential key for detected services.
            let detectedPrefix = "detected-"
            let legacyKind = profile.id.hasPrefix(detectedPrefix)
                ? String(profile.id.dropFirst(detectedPrefix.count))
                : (profile.dialect == .mysql ? DatabaseKind.mysql.rawValue : DatabaseKind.postgresql.rawValue)
            let legacyKey = "dbcred-\(host.id.uuidString)-\(legacyKind)"
            if let rec = try? app.credentialStore.read(id: legacyKey, kind: .password),
               let data = rec.value.data(using: .utf8),
               let credential = try? JSONDecoder().decode(DBCredential.self, from: data), !credential.isEmpty {
                dbState.dbCredential = credential
                dbPersistCredential(credential)
            } else {
                dbState.dbCredential = nil
            }
        }
    }

    private func dbPersistCredential(_ cred: DBCredential?) {
        guard let key = dbCredentialKey() else { return }
        if let cred, !cred.isEmpty,
           let data = try? JSONEncoder().encode(cred), let json = String(data: data, encoding: .utf8) {
            _ = try? app.credentialStore.save(json, kind: .password, id: key)
        } else {
            try? app.credentialStore.delete(id: key)
        }
    }

    /// Preserve only the outline's cheap metadata when leaving a connection.
    /// Row data, SQL results and credentials remain isolated to the active
    /// workspace and are never duplicated here.
    private func dbStoreCurrentNavigatorSnapshot() {
        guard let connectionID = dbState.dbSelectedConnectionID else { return }
        var snapshot = dbState.dbNavigatorSnapshots[connectionID] ?? DBNavigatorSnapshot()
        if !dbState.dbDatabases.isEmpty || !dbState.dbNavigatorIsLoading {
            snapshot.databases = dbState.dbDatabases
        }
        snapshot.selectedDatabase = dbState.dbSelectedDatabase ?? snapshot.selectedDatabase
        if let database = dbState.dbSelectedDatabase,
           !dbState.dbTables.isEmpty || !dbState.dbNavigatorIsLoading {
            snapshot.tablesByDatabase[database] = dbState.dbTables
        }
        dbState.dbNavigatorSnapshots[connectionID] = snapshot
    }

    private func dbStoreNavigatorDatabases(
        _ databases: [String],
        selectedDatabase: String?,
        connectionID: String
    ) {
        var snapshot = dbState.dbNavigatorSnapshots[connectionID] ?? DBNavigatorSnapshot()
        snapshot.databases = databases
        snapshot.selectedDatabase = selectedDatabase
        dbState.dbNavigatorSnapshots[connectionID] = snapshot
    }

    private func dbStoreNavigatorTables(
        _ tables: [DBTableInfo],
        database: String,
        connectionID: String
    ) {
        var snapshot = dbState.dbNavigatorSnapshots[connectionID] ?? DBNavigatorSnapshot()
        snapshot.selectedDatabase = database
        snapshot.tablesByDatabase[database] = tables
        dbState.dbNavigatorSnapshots[connectionID] = snapshot
    }

    func dbLoadDatabases(preferredDatabase: String? = nil, preferredTable: String? = nil) {
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        guard let ctx = dbContext,
              let connectionID = dbState.dbSelectedConnectionID else { return }
        dbState.dbDatabases = []; dbState.dbSelectedDatabase = nil
        dbState.dbTables = []; dbState.dbSelectedTable = nil
        dbState.dbColumns = []; dbState.dbRows = DBResultSet()
        dbState.dbRowsVersion += 1
        dbState.dbSelectedRows = []
        let credential = dbState.dbCredential
        let generation = beginDBLoad(.navigator)
        dbState.dbLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDBLoad(generation) }
            do {
                let names = try await self.app.databaseBrowser.listDatabases(
                    dialect: ctx.dialect, config: ctx.config, credential: credential,
                    adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                guard self.isCurrentDBLoad(generation) else { return }
                self.dbState.dbDatabases = names
                // Auto-open the first user database for a one-click feel.
                guard let first = preferredDatabase.flatMap({ names.contains($0) ? $0 : nil })
                    ?? self.preferredDatabase(in: names, dialect: ctx.dialect) else {
                    self.dbStoreNavigatorDatabases(names, selectedDatabase: nil, connectionID: connectionID)
                    return
                }
                self.dbState.dbSelectedDatabase = first
                self.dbStoreNavigatorDatabases(names, selectedDatabase: first, connectionID: connectionID)
                if let cached = self.dbState.dbTableCache[first] {
                    self.dbState.dbTables = cached
                }
                let tables = try await self.app.databaseBrowser.listTables(
                    dialect: ctx.dialect, database: first, config: ctx.config, credential: credential,
                    adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                guard self.isCurrentDBLoad(generation), self.dbState.dbSelectedDatabase == first else { return }
                self.dbState.dbTables = tables
                self.dbState.dbTableCache[first] = tables
                self.dbStoreNavigatorTables(tables, database: first, connectionID: connectionID)
                if let preferredTable, tables.contains(where: { $0.name == preferredTable }) {
                    self.dbScheduleTableSelection(
                        preferredTable,
                        connectionID: connectionID,
                        database: first
                    )
                }
            } catch {
                guard self.isCurrentDBLoad(generation) else { return }
                self.handleDBError(error)
            }
        }
    }

    /// Skip engine bookkeeping schemas when auto-selecting a database.
    private func preferredDatabase(in names: [String], dialect: DBDialect) -> String? {
        names.first { !dialect.systemDatabases.contains($0) } ?? names.first
    }

    func dbDatabaseCreationPlan(_ request: DBCreateDatabaseRequest) throws -> DBCreateDatabasePlan {
        guard let dialect = dbState.dbSelectedConnection?.dialect else {
            throw DBEngineError.notSupported(String(localized: "请先选择数据库连接。"))
        }
        return try app.databaseBrowser.databaseCreationPlan(dialect: dialect, request: request)
    }

    func dbCreateDatabase(_ request: DBCreateDatabaseRequest) async throws {
        guard !dbState.dbCreateRunning else {
            throw DBEngineError.notSupported(String(localized: "已有数据库创建任务正在执行。"))
        }
        guard let ctx = dbContext, let connection = dbState.dbSelectedConnection else {
            throw DBEngineError.notSupported(String(localized: "请先选择数据库连接。"))
        }
        let databaseName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        dbState.dbCreateRunning = true
        defer { dbState.dbCreateRunning = false }
        try await app.databaseBrowser.createDatabase(
            dialect: ctx.dialect,
            request: request,
            config: ctx.config,
            credential: dbState.dbCredential,
            adminSudo: ctx.adminSudo,
            sshService: app.databaseSSHService
        )
        dbState.dbShowCreateDatabaseSheet = false
        if let rawUsername = request.username,
           let password = request.password,
           !rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = DBConnectionProfile(
                id: UUID().uuidString,
                name: "\(databaseName) · \(username)",
                dialect: connection.dialect,
                host: connection.host,
                port: connection.port,
                username: username,
                source: .manual
            )
            dbSaveConnection(
                profile,
                credential: DBCredential(
                    username: username,
                    password: password,
                    host: connection.host,
                    port: connection.port
                ),
                preferredDatabase: databaseName
            )
        } else {
            dbLoadDatabases(preferredDatabase: databaseName)
        }
    }

    func dbSelectDatabase(_ name: String, preferredTable: String? = nil) {
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        guard let connectionID = dbState.dbSelectedConnectionID else { return }
        dbStoreCurrentNavigatorSnapshot()
        dbState.dbSelectedDatabase = name
        dbState.dbTables = dbState.dbTableCache[name] ?? []; dbState.dbSelectedTable = nil
        dbStoreNavigatorDatabases(dbState.dbDatabases, selectedDatabase: name, connectionID: connectionID)
        if let cached = dbState.dbTableCache[name] {
            dbStoreNavigatorTables(cached, database: name, connectionID: connectionID)
        }
        dbState.dbColumns = []; dbState.dbRows = DBResultSet()
        dbState.dbRowsVersion += 1
        dbResetGridControls()
        dbState.dbSelectedRows = []
        guard let ctx = dbContext else { return }
        let credential = dbState.dbCredential
        let generation = beginDBLoad(.navigator)
        dbState.dbLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDBLoad(generation) }
            do {
                let tables = try await self.app.databaseBrowser.listTables(
                    dialect: ctx.dialect, database: name, config: ctx.config, credential: credential,
                    adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                guard self.isCurrentDBLoad(generation), self.dbState.dbSelectedDatabase == name else { return }
                self.dbState.dbTables = tables
                self.dbState.dbTableCache[name] = tables
                self.dbStoreNavigatorTables(tables, database: name, connectionID: connectionID)
                if let preferredTable, tables.contains(where: { $0.name == preferredTable }) {
                    self.dbScheduleTableSelection(
                        preferredTable,
                        connectionID: connectionID,
                        database: name
                    )
                }
            } catch {
                guard self.isCurrentDBLoad(generation) else { return }
                self.handleDBError(error)
            }
        }
    }

    private func dbScheduleTableSelection(
        _ table: String,
        connectionID: String,
        database: String
    ) {
        // Run after the navigator task's defer has cleared its loading state;
        // selecting the table starts the independent row/column load.
        Task { @MainActor [weak self] in
            guard let self,
                  self.dbState.dbSelectedConnectionID == connectionID,
                  self.dbState.dbSelectedDatabase == database,
                  self.dbState.dbTables.contains(where: { $0.name == table }) else { return }
            self.dbSelectTable(table)
        }
    }

    func dbSelectTable(_ name: String) {
        guard dbState.dbStagedChanges.isEmpty else {
            dbState.dbError = String(localized: "请先应用或撤销暂存修改。")
            return
        }
        dbState.dbSelectedTable = name
        dbResetGridControls()
        dbState.dbRows = DBResultSet()
        dbState.dbRowsVersion += 1
        if let db = dbState.dbSelectedDatabase, let cached = dbState.dbColumnCache[dbCacheKey(database: db, table: name)] {
            dbState.dbColumns = cached.value
            dbState.dbFilterColumn = cached.value.first?.name
        } else {
            dbState.dbColumns = []
        }
        dbState.dbSelectedRows = []
        dbState.dbTab = .data
        dbLoadTable()
    }

    /// Load the current table's structure + current data page together.
    func dbLoadTable() {
        guard let ctx = dbContext, let db = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        let credential = dbState.dbCredential
        let orderBy = dbState.dbOrderBy
        let ascending = dbState.dbAscending
        let limit = dbState.dbPageSize
        let cursor = dbCursorForCurrentPage(orderBy: orderBy)
        let offset = cursor == nil ? dbState.dbPage * dbState.dbPageSize : 0
        let filter = dbState.dbAppliedFilter
        let cacheKey = dbCacheKey(database: db, table: table)
        let cachedColumns = dbState.dbColumnCache[cacheKey]
        let shouldRefreshColumns = cachedColumns == nil || Date().timeIntervalSince(cachedColumns!.loadedAt) > 300
        let generation = beginDBLoad(.rows)
        dbState.dbLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDBLoad(generation) }
            do {
                let fetchedColumns: [DBColumnInfo]?
                let rows: DBResultSet
                if shouldRefreshColumns {
                    async let columnsRequest = self.app.databaseBrowser.columns(
                        dialect: ctx.dialect, database: db, table: table, config: ctx.config,
                        credential: credential, adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                    async let rowsRequest = self.app.databaseBrowser.selectRows(
                        dialect: ctx.dialect, database: db, table: table, orderBy: orderBy, ascending: ascending,
                        limit: limit, offset: offset, filter: filter, cursor: cursor, config: ctx.config,
                        credential: credential, adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                    (fetchedColumns, rows) = try await (columnsRequest, rowsRequest)
                } else {
                    fetchedColumns = nil
                    rows = try await self.app.databaseBrowser.selectRows(
                        dialect: ctx.dialect, database: db, table: table, orderBy: orderBy, ascending: ascending,
                        limit: limit, offset: offset, filter: filter, cursor: cursor, config: ctx.config,
                        credential: credential, adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                }
                guard self.isCurrentDBLoad(generation), self.dbState.dbSelectedDatabase == db,
                      self.dbState.dbSelectedTable == table else { return }
                if let fetchedColumns {
                    self.dbState.dbColumns = fetchedColumns
                    self.dbState.dbColumnCache[cacheKey] = (Date(), fetchedColumns)
                }
                self.dbState.dbFilterColumn = self.dbState.dbFilterColumn ?? self.dbState.dbRows.columns.first ?? rows.columns.first
                self.dbState.dbRows = rows
                self.dbState.dbRowsVersion += 1
                self.recordDBPerformance(rows, phase: "table-load")
            } catch {
                guard self.isCurrentDBLoad(generation) else { return }
                self.handleDBError(error)
            }
        }
    }

    func dbReloadRows() {
        guard let ctx = dbContext, let db = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        let credential = dbState.dbCredential
        let orderBy = dbState.dbOrderBy
        let ascending = dbState.dbAscending
        let limit = dbState.dbPageSize
        let cursor = dbCursorForCurrentPage(orderBy: orderBy)
        let offset = cursor == nil ? dbState.dbPage * dbState.dbPageSize : 0
        let filter = dbState.dbAppliedFilter
        let generation = beginDBLoad(.rows)
        dbState.dbLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDBLoad(generation) }
            do {
                let rows = try await self.app.databaseBrowser.selectRows(
                    dialect: ctx.dialect, database: db, table: table, orderBy: orderBy, ascending: ascending,
                    limit: limit, offset: offset, filter: filter, cursor: cursor, config: ctx.config,
                    credential: credential, adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                guard self.isCurrentDBLoad(generation), self.dbState.dbSelectedDatabase == db,
                      self.dbState.dbSelectedTable == table else { return }
                self.dbState.dbRows = rows
                self.dbState.dbRowsVersion += 1
                self.dbState.dbSelectedRows = []
                self.recordDBPerformance(rows, phase: "page-load")
            } catch {
                guard self.isCurrentDBLoad(generation) else { return }
                self.handleDBError(error)
            }
        }
    }

    /// Toggle sort on a column (same column flips direction) and reload page 0.
    func dbSort(by column: String) {
        guard dbState.dbStagedChanges.isEmpty else { return }
        if dbState.dbOrderBy == column { dbState.dbAscending.toggle() } else { dbState.dbOrderBy = column; dbState.dbAscending = true }
        dbResetPagination()
        dbReloadRows()
    }

    func dbNextPage() {
        guard dbState.dbRows.truncated, dbState.dbStagedChanges.isEmpty else { return }
        if let cursor = dbCursorAfterCurrentPage() {
            if dbState.dbPageCursors.indices.contains(dbState.dbPage) {
                dbState.dbPageCursors[dbState.dbPage] = cursor
                if dbState.dbPageCursors.count > dbState.dbPage + 1 {
                    dbState.dbPageCursors.removeSubrange((dbState.dbPage + 1)...)
                }
            } else {
                dbState.dbPageCursors.append(cursor)
            }
        } else {
            dbState.dbPageCursors = []
        }
        dbState.dbPage += 1
        dbReloadRows()
    }

    func dbPrevPage() {
        guard dbState.dbPage > 0, dbState.dbStagedChanges.isEmpty else { return }
        dbState.dbPage -= 1
        dbReloadRows()
    }

    func dbSetPageSize(_ size: Int) {
        guard dbState.dbStagedChanges.isEmpty else { return }
        let normalized = [50, 100, 200].contains(size) ? size : 50
        guard dbState.dbPageSize != normalized else { return }
        dbState.dbPageSize = normalized
        dbResetPagination()
        dbReloadRows()
    }

    func dbApplyFilter(value: String) {
        guard dbState.dbStagedChanges.isEmpty else { return }
        guard let column = dbState.dbFilterColumn ?? dbState.dbRows.columns.first else { return }
        if dbState.dbFilterOperation.needsValue && value.isEmpty { return }
        dbState.dbAppliedFilter = DBFilter(column: column, operation: dbState.dbFilterOperation, value: value)
        dbResetPagination()
        dbReloadRows()
    }

    func dbClearFilter() {
        guard dbState.dbStagedChanges.isEmpty else { return }
        guard dbState.dbAppliedFilter != nil else { return }
        dbState.dbAppliedFilter = nil
        dbResetPagination()
        dbReloadRows()
    }

    func dbStopRowsLoad() {
        guard dbState.dbRowsIsLoading, let config = dbContext?.config else { return }
        cancelDBLoad()
        Task { await app.databaseSSHService.disconnect(config: config) }
    }

    func dbRunSQL(_ text: String? = nil) {
        if let text { dbUpdateCurrentQueryDraft(text) }
        let sql = dbState.dbSQLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        let kind = DBSQLStatementKind.classify(sql)
        if kind.requiresConfirmation {
            dbState.dbPendingWrite = DBWriteRequest(
                title: kind == .dataMutation
                    ? String(localized: "确认执行数据修改语句")
                    : String(localized: "确认执行结构或权限语句"),
                sql: sql,
                isDestructive: kind.isDestructive,
                showsSQLResult: true
            )
            return
        }
        dbRecordQuery(sql)
        dbExecuteSQL(sql)
    }

    private func dbExecuteSQL(_ sql: String) {
        guard let ctx = dbContext else { return }
        dbState.dbSQLTask?.cancel()
        dbState.dbSQLGeneration += 1
        let generation = dbState.dbSQLGeneration
        dbState.dbSQLRunning = true; dbState.dbSQLError = nil
        dbState.dbSQLTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.dbState.dbSQLGeneration == generation {
                    self.dbState.dbSQLRunning = false
                    self.dbState.dbSQLTask = nil
                }
            }
            do {
                let result = try await self.app.databaseBrowser.runSQL(
                    dialect: ctx.dialect, database: self.dbState.dbSelectedDatabase, sql: sql, config: ctx.config,
                    credential: self.dbState.dbCredential, adminSudo: ctx.adminSudo, sshService: self.app.databaseSSHService)
                guard !Task.isCancelled, self.dbState.dbSQLGeneration == generation else { return }
                self.dbState.dbSQLResult = result
                self.dbState.dbSQLResultVersion += 1
                self.recordDBPerformance(result, phase: "sql")
            } catch {
                guard !Task.isCancelled, self.dbState.dbSQLGeneration == generation else { return }
                self.dbState.dbSQLError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func dbStopSQL() {
        guard dbState.dbSQLTask != nil else { return }
        dbState.dbSQLGeneration += 1
        dbState.dbSQLTask?.cancel()
        dbState.dbSQLTask = nil
        dbState.dbSQLRunning = false
        if let config = dbContext?.config {
            Task { await app.databaseSSHService.disconnect(config: config) }
        }
    }

    /// Route engine errors: auth-ish failures pop the credential sheet, others show inline.
    private func handleDBError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        dbState.dbError = message
        let lower = message.lowercased()
        let looksLikeAuth = lower.contains("access denied") || lower.contains("authentication")
            || lower.contains("password") || lower.contains("role") || lower.contains("permission denied")
            || lower.contains("ident") || lower.contains("peer")
        if looksLikeAuth && dbState.dbCredential == nil {
            dbState.dbShowCredentialSheet = true
        }
    }

    private func beginDBLoad(_ kind: DBLoadKind) -> Int {
        dbState.dbLoadTask?.cancel()
        dbState.dbNavigatorIsLoading = false
        dbState.dbRowsIsLoading = false
        dbState.dbLoadGeneration += 1
        switch kind {
        case .navigator: dbState.dbNavigatorIsLoading = true
        case .rows: dbState.dbRowsIsLoading = true
        }
        dbState.dbError = nil
        return dbState.dbLoadGeneration
    }

    private func finishDBLoad(_ generation: Int) {
        guard generation == dbState.dbLoadGeneration else { return }
        dbState.dbNavigatorIsLoading = false
        dbState.dbRowsIsLoading = false
        dbState.dbLoadTask = nil
    }

    private func isCurrentDBLoad(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == dbState.dbLoadGeneration
    }

    private func cancelDBLoad() {
        dbState.dbLoadTask?.cancel()
        dbState.dbLoadTask = nil
        dbState.dbLoadGeneration += 1
        dbState.dbNavigatorIsLoading = false
        dbState.dbRowsIsLoading = false
    }

    private func dbResetGridControls() {
        dbState.dbPage = 0
        dbState.dbOrderBy = nil
        dbState.dbAscending = true
        dbState.dbFilterColumn = nil
        dbState.dbFilterOperation = .equals
        dbState.dbAppliedFilter = nil
        dbState.dbPageCursors = []
    }

    private func dbResetPagination() {
        dbState.dbPage = 0
        dbState.dbPageCursors = []
        dbState.dbSelectedRows = []
    }

    private func dbCacheKey(database: String, table: String) -> String {
        database + "\u{1F}" + table
    }

    private func recordDBPerformance(_ result: DBResultSet, phase: String) {
        dbState.dbPerformanceEvents.append(DBPerformanceEvent(
            capturedAt: Date(),
            phase: phase,
            totalMilliseconds: Int(result.elapsed * 1_000),
            transportMilliseconds: Int(result.transportElapsed * 1_000),
            parseMilliseconds: Int(result.parseElapsed * 1_000),
            responseBytes: result.responseBytes,
            rows: result.rows.count,
            columns: result.columns.count
        ))
        if dbState.dbPerformanceEvents.count > 30 {
            dbState.dbPerformanceEvents.removeFirst(dbState.dbPerformanceEvents.count - 30)
        }
    }

    private func dbCursorForCurrentPage(orderBy: String?) -> DBPageCursor? {
        guard dbState.dbPage > 0, dbState.dbPrimaryKeyColumns.count == 1,
              orderBy == dbState.dbPrimaryKeyColumns[0], dbState.dbPageCursors.indices.contains(dbState.dbPage - 1) else { return nil }
        return dbState.dbPageCursors[dbState.dbPage - 1]
    }

    private func dbCursorAfterCurrentPage() -> DBPageCursor? {
        guard dbState.dbPrimaryKeyColumns.count == 1, dbState.dbOrderBy == dbState.dbPrimaryKeyColumns[0],
              let row = dbState.dbRows.rows.last,
              let columnIndex = dbState.dbRows.columns.firstIndex(of: dbState.dbPrimaryKeyColumns[0]),
              row.indices.contains(columnIndex), let value = row[columnIndex] else { return nil }
        return DBPageCursor(column: dbState.dbPrimaryKeyColumns[0], value: value)
    }

    // MARK: - Database writes — all previewed as SQL, then confirmed

    // dbState.dbPrimaryKeyColumns / dbState.dbCanEditRows live on DBBrowserState.

    /// The primary-key column/value pairs for a data row (nil if no PK or the row
    /// is out of range).
    private func dbPKPairs(forRow rowIndex: Int) -> [(column: String, value: String?)]? {
        guard dbState.dbCanEditRows, dbState.dbRows.rows.indices.contains(rowIndex) else { return nil }
        let row = dbState.dbRows.rows[rowIndex]
        var pairs: [(String, String?)] = []
        for pk in dbState.dbPrimaryKeyColumns {
            guard let ci = dbState.dbRows.columns.firstIndex(of: pk), row.indices.contains(ci) else { return nil }
            pairs.append((pk, row[ci]))
        }
        return pairs
    }

    /// Fresh insert form seeded from the table's columns (PK / defaulted columns
    /// pre-marked "use default" so auto-increment/defaults apply).
    func dbInsertFields() -> [DBInsertField] {
        dbState.dbColumns.map { c in
            DBInsertField(column: c.name, dataType: c.dataType, isPrimaryKey: c.isPrimaryKey,
                          nullable: c.nullable, useDefault: c.isPrimaryKey || c.defaultValue != nil)
        }
    }

    /// Stage a cell locally. Multiple edits are sent as one transaction when the
    /// user presses Apply, avoiding one SSH/CLI round trip per cell.
    func dbRequestUpdateCell(rowIndex: Int, column: String, newValue: String?, isNull: Bool) {
        guard !dbState.dbRowsIsLoading, let ctx = dbContext, let db = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable,
              let pk = dbPKPairs(forRow: rowIndex), dbState.dbRows.rows.indices.contains(rowIndex),
              let columnIndex = dbState.dbRows.columns.firstIndex(of: column),
              dbState.dbRows.rows[rowIndex].indices.contains(columnIndex) else { return }
        guard !dbState.dbPrimaryKeyColumns.contains(column) else {
            dbState.dbError = String(localized: "主键列暂不支持表格内编辑，请使用 SQL 标签。")
            return
        }
        let stagedValue = isNull ? nil : newValue
        let existingIndex = dbState.dbStagedChanges.firstIndex { $0.rowIndex == rowIndex && $0.column == column }
        let originalValue = existingIndex.map { dbState.dbStagedChanges[$0].originalValue } ?? dbState.dbRows.rows[rowIndex][columnIndex]
        if stagedValue == originalValue {
            if let existingIndex { dbState.dbStagedChanges.remove(at: existingIndex) }
            dbState.dbRows.rows[rowIndex][columnIndex] = originalValue
            dbState.dbRowsVersion += 1
            return
        }
        let sql = CLIDatabaseEngine().buildUpdate(dialect: ctx.dialect, database: db, table: table,
                                                  pk: pk, setColumn: column, value: newValue, isNull: isNull)
        let change = DBStagedCellChange(
            rowIndex: rowIndex, column: column, originalValue: originalValue,
            newValue: stagedValue, sql: sql
        )
        if let existingIndex {
            dbState.dbStagedChanges[existingIndex] = change
        } else {
            dbState.dbStagedChanges.append(change)
        }
        dbState.dbRows.rows[rowIndex][columnIndex] = stagedValue
        dbState.dbRowsVersion += 1
        dbState.dbError = nil
    }

    func dbDiscardStagedChanges() {
        for change in dbState.dbStagedChanges {
            guard dbState.dbRows.rows.indices.contains(change.rowIndex),
                  let columnIndex = dbState.dbRows.columns.firstIndex(of: change.column),
                  dbState.dbRows.rows[change.rowIndex].indices.contains(columnIndex) else { continue }
            dbState.dbRows.rows[change.rowIndex][columnIndex] = change.originalValue
        }
        dbState.dbStagedChanges = []
        dbState.dbRowsVersion += 1
    }

    func dbRequestApplyStagedChanges() {
        guard !dbState.dbStagedChanges.isEmpty else { return }
        let statements = dbState.dbStagedChanges.map(\.sql).joined(separator: ";\n")
        let sql = "START TRANSACTION;\n\(statements);\nCOMMIT;"
        dbState.dbPendingWrite = DBWriteRequest(
            title: String(localized: "应用 \(dbState.dbStagedChanges.count) 处修改"),
            sql: sql,
            isDestructive: false,
            clearsStagedChanges: true
        )
    }

    /// Stage a DELETE of the currently selected rows for confirmation.
    func dbRequestDeleteSelected() {
        guard dbState.dbStagedChanges.isEmpty, let ctx = dbContext, let db = dbState.dbSelectedDatabase,
              let table = dbState.dbSelectedTable, dbState.dbCanEditRows else { return }
        let rowsPK = dbState.dbSelectedRows.sorted().compactMap { dbPKPairs(forRow: $0) }
        guard !rowsPK.isEmpty else { return }
        let sql = CLIDatabaseEngine().buildDelete(dialect: ctx.dialect, database: db, table: table, rows: rowsPK)
        dbState.dbPendingWrite = DBWriteRequest(title: String(localized: "删除 \(rowsPK.count) 行"), sql: sql, isDestructive: true)
    }

    /// Stage an INSERT built from the insert form for confirmation.
    func dbRequestInsert(_ fields: [DBInsertField]) {
        guard dbState.dbStagedChanges.isEmpty, let ctx = dbContext, let db = dbState.dbSelectedDatabase,
              let table = dbState.dbSelectedTable else { return }
        let sql = CLIDatabaseEngine().buildInsert(dialect: ctx.dialect, database: db, table: table, fields: fields)
        dbState.dbShowInsertSheet = false
        dbState.dbPendingWrite = DBWriteRequest(title: String(localized: "新增 1 行"), sql: sql, isDestructive: false)
    }

    func dbRequestImportCSV(_ document: DBCSVDocument) {
        guard dbState.dbStagedChanges.isEmpty, let ctx = dbContext, let db = dbState.dbSelectedDatabase,
              let table = dbState.dbSelectedTable else { return }
        guard !document.rows.isEmpty else {
            dbState.dbError = String(localized: "CSV 没有可导入的数据行。")
            return
        }
        guard document.rows.count <= 500 else {
            dbState.dbError = String(localized: "单次最多导入 500 行，请拆分 CSV 后重试。")
            return
        }
        let knownColumns = Set(dbState.dbColumns.map(\.name))
        let unknown = document.columns.filter { !knownColumns.contains($0) }
        guard unknown.isEmpty else {
            dbState.dbError = String(localized: "CSV 包含当前表不存在的列：\(unknown.joined(separator: ", "))")
            return
        }
        let inputIndexes = Dictionary(uniqueKeysWithValues: document.columns.enumerated().map { ($0.element, $0.offset) })
        let engine = CLIDatabaseEngine()
        let statements = document.rows.map { row in
            let fields = dbState.dbColumns.map { column -> DBInsertField in
                guard let index = inputIndexes[column.name] else {
                    return DBInsertField(
                        column: column.name, dataType: column.dataType, isPrimaryKey: column.isPrimaryKey,
                        nullable: column.nullable, useDefault: true
                    )
                }
                return DBInsertField(
                    column: column.name, dataType: column.dataType, isPrimaryKey: column.isPrimaryKey,
                    nullable: column.nullable, text: row[index], useDefault: false
                )
            }
            return engine.buildInsert(dialect: ctx.dialect, database: db, table: table, fields: fields)
        }
        let sql = "START TRANSACTION;\n\(statements.joined(separator: ";\n"));\nCOMMIT;"
        guard sql.utf8.count <= 1_000_000 else {
            dbState.dbError = String(localized: "CSV 生成的导入语句超过 1 MB，请拆分后重试。")
            return
        }
        dbState.dbError = nil
        dbState.dbPendingWrite = DBWriteRequest(
            title: String(localized: "导入 \(document.rows.count) 行"), sql: sql, isDestructive: false
        )
    }

    // MARK: Basic schema and user management

    private func dbStageSchemaWrite(
        title: String,
        sql: String,
        previewSQL: String? = nil,
        destructive: Bool,
        connectionLevel: Bool = false,
        reloadsNavigator: Bool = true,
        preferredDatabaseAfter: String? = nil
    ) {
        dbState.dbWriteError = nil
        dbState.dbPendingWrite = DBWriteRequest(
            title: title,
            sql: sql,
            isDestructive: destructive,
            previewSQL: previewSQL,
            runsAtConnectionLevel: connectionLevel,
            reloadsNavigator: reloadsNavigator,
            preferredDatabaseAfter: preferredDatabaseAfter
        )
    }

    func dbRequestCreateTable(name: String, firstColumn: String, dataType: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect, let database = dbState.dbSelectedDatabase else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().createTable(
                dialect: dialect, database: database, table: name, firstColumn: firstColumn, dataType: dataType
            )
            dbStageSchemaWrite(title: String(localized: "创建表 \(name)"), sql: sql, destructive: false, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestDropDatabase(_ database: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().dropDatabase(dialect: dialect, database: database)
            dbStageSchemaWrite(
                title: String(localized: "删除数据库 \(database)"), sql: sql, destructive: true,
                connectionLevel: true, preferredDatabaseAfter: nil
            )
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestRenameTable(_ table: String, to newName: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect, let database = dbState.dbSelectedDatabase else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().renameTable(dialect: dialect, database: database, table: table, newName: newName)
            dbStageSchemaWrite(title: String(localized: "重命名表 \(table)"), sql: sql, destructive: false, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestDropTable(_ table: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect, let database = dbState.dbSelectedDatabase else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().dropTable(dialect: dialect, database: database, table: table)
            dbStageSchemaWrite(title: String(localized: "删除表 \(table)"), sql: sql, destructive: true, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestAddColumn(name: String, dataType: String, nullable: Bool) {
        guard let dialect = dbState.dbSelectedConnection?.dialect,
              let database = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().addColumn(
                dialect: dialect, database: database, table: table, column: name, dataType: dataType, nullable: nullable
            )
            dbStageSchemaWrite(title: String(localized: "新增列 \(name)"), sql: sql, destructive: false, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestModifyColumn(name: String, dataType: String, nullable: Bool) {
        guard let dialect = dbState.dbSelectedConnection?.dialect,
              let database = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().modifyColumn(
                dialect: dialect, database: database, table: table, column: name, dataType: dataType, nullable: nullable
            )
            dbStageSchemaWrite(title: String(localized: "修改列 \(name)"), sql: sql, destructive: true, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestDropColumn(_ name: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect,
              let database = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().dropColumn(dialect: dialect, database: database, table: table, column: name)
            dbStageSchemaWrite(title: String(localized: "删除列 \(name)"), sql: sql, destructive: true, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestAddIndex(name: String, columns: [String], unique: Bool) {
        guard let dialect = dbState.dbSelectedConnection?.dialect,
              let database = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().addIndex(
                dialect: dialect, database: database, table: table, index: name, columns: columns, unique: unique
            )
            dbStageSchemaWrite(title: String(localized: "新增索引 \(name)"), sql: sql, destructive: false, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestDropIndex(_ name: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect,
              let database = dbState.dbSelectedDatabase, let table = dbState.dbSelectedTable else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().dropIndex(dialect: dialect, database: database, table: table, index: name)
            dbStageSchemaWrite(title: String(localized: "删除索引 \(name)"), sql: sql, destructive: true, preferredDatabaseAfter: database)
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestCreateUser(username: String, host: String, password: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect else { return }
        do {
            let generated = try DatabaseSchemaSQLBuilder().createUser(
                dialect: dialect, username: username, host: host, password: password
            )
            dbStageSchemaWrite(
                title: String(localized: "创建数据库用户 \(username)"), sql: generated.sql,
                previewSQL: generated.preview, destructive: true, connectionLevel: true, reloadsNavigator: false
            )
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestChangeUserPassword(username: String, host: String, password: String) {
        guard let dialect = dbState.dbSelectedConnection?.dialect else { return }
        do {
            let generated = try DatabaseSchemaSQLBuilder().changePassword(
                dialect: dialect, username: username, host: host, password: password
            )
            dbStageSchemaWrite(
                title: String(localized: "修改数据库用户密码"), sql: generated.sql,
                previewSQL: generated.preview, destructive: true, connectionLevel: true, reloadsNavigator: false
            )
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbRequestGrantUser(username: String, host: String, preset: DBPrivilegePreset) {
        guard let dialect = dbState.dbSelectedConnection?.dialect, let database = dbState.dbSelectedDatabase else { return }
        do {
            let sql = try DatabaseSchemaSQLBuilder().grant(
                dialect: dialect, database: database, username: username, host: host, preset: preset
            )
            dbStageSchemaWrite(
                title: String(localized: "授予 \(preset.title)"), sql: sql,
                destructive: true, reloadsNavigator: false, preferredDatabaseAfter: database
            )
        } catch { dbState.dbError = error.localizedDescription }
    }

    func dbCancelPendingWrite() { dbState.dbPendingWrite = nil; dbState.dbWriteError = nil }

    /// Execute the staged write, then reload the current page on success.
    func dbConfirmPendingWrite() {
        guard !dbState.dbWriteRunning, let ctx = dbContext, let req = dbState.dbPendingWrite else { return }
        dbState.dbWriteRunning = true; dbState.dbWriteError = nil
        Task {
            defer { dbState.dbWriteRunning = false }
            do {
                if req.showsSQLResult { dbRecordQuery(req.sql) }
                let result = try await app.databaseBrowser.runSQL(
                    dialect: ctx.dialect, database: req.runsAtConnectionLevel ? nil : dbState.dbSelectedDatabase, sql: req.sql, config: ctx.config,
                    credential: dbState.dbCredential, adminSudo: ctx.adminSudo, sshService: app.databaseSSHService)
                dbState.dbPendingWrite = nil
                if req.showsSQLResult {
                    dbState.dbSQLResult = result
                    dbState.dbSQLResultVersion += 1
                    recordDBPerformance(result, phase: "sql-write")
                }
                if req.clearsStagedChanges {
                    dbState.dbStagedChanges = []
                    dbState.dbRowsVersion += 1
                }
                dbState.dbSelectedRows = []
                if req.reloadsNavigator {
                    dbState.dbTableCache = [:]
                    dbState.dbColumnCache = [:]
                    dbState.dbSelectedTable = nil
                    dbState.dbColumns = []
                    dbState.dbRows = DBResultSet()
                    dbLoadDatabases(preferredDatabase: req.preferredDatabaseAfter)
                } else if req.showsSQLResult {
                    // A user-authored statement may change schema or rows. Refresh
                    // the navigator/table on demand rather than guessing which
                    // objects it touched, while still showing its direct result.
                    if dbState.dbSelectedTable != nil { dbReloadRows() }
                } else {
                    dbReloadRows()
                }
            } catch {
                dbState.dbWriteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func refreshFirewall() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isFirewallLoading = true
        operationsError = nil
        Task {
            defer { isFirewallLoading = false }
            do {
                firewallSnapshot = try await app.firewallService.collect(profile: serverProfile, config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestFirewallToggle(enable: Bool) {
        let kind = firewallSnapshot?.kind ?? .none
        // Use the port our live session connected on so enabling can't lock us out.
        let sshPort = selectedHost?.port ?? 22
        presentRunbookPlan(app.firewallService.togglePlan(enable: enable, sshPort: sshPort, kind: kind, profile: serverProfile))
    }

    func requestFirewallAddRule(action: FirewallAction, direction: FirewallDirection, proto: String, ports: String, source: String, comment: String) {
        let cleanPorts = ports.trimmingCharacters(in: .whitespaces)
        guard !cleanPorts.isEmpty else { operationsError = String(localized: "请先填写端口。"); return }
        let kind = firewallSnapshot?.kind ?? .none
        presentRunbookPlan(app.firewallService.addRulePlan(action: action, direction: direction, proto: proto, ports: cleanPorts, source: source, comment: comment, kind: kind, profile: serverProfile))
    }

    func requestFirewallDeleteRuleSpec(_ spec: String) {
        let kind = firewallSnapshot?.kind ?? .none
        presentRunbookPlan(app.firewallService.deleteRuleSpecPlan(spec: spec, kind: kind, profile: serverProfile))
    }

    func requestFirewallEditRule(old: FirewallRule, action: FirewallAction, direction: FirewallDirection, proto: String, ports: String, source: String, comment: String) {
        let cleanPorts = ports.trimmingCharacters(in: .whitespaces)
        guard !cleanPorts.isEmpty else { operationsError = String(localized: "请先填写端口。"); return }
        let kind = firewallSnapshot?.kind ?? .none
        presentRunbookPlan(app.firewallService.editRulePlan(old: old, action: action, direction: direction, proto: proto, ports: cleanPorts, source: source, comment: comment, kind: kind, profile: serverProfile))
    }

    func requestFirewallSetPingBlocked(_ block: Bool) {
        presentRunbookPlan(app.firewallService.setPingBlockedPlan(block: block, profile: serverProfile))
    }

    func refreshPM2() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isPM2Loading = true
        operationsError = nil
        Task {
            defer { isPM2Loading = false }
            do {
                pm2Snapshot = try await app.pm2Service.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestPM2Action(_ action: ServiceAction, process: PM2Process) {
        presentRunbookPlan(app.pm2Service.actionPlan(action, process: process))
    }

    func requestPM2Delete(_ process: PM2Process) {
        presentRunbookPlan(app.pm2Service.deletePlan(process: process))
    }

    func requestPM2Start(name: String, scriptPath: String, workingDirectory: String) {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
              scriptPath.hasPrefix("/") else {
            operationsError = String(localized: "请填写有效应用名称和绝对脚本路径。")
            return
        }
        presentRunbookPlan(app.pm2Service.startApplicationPlan(
            name: name, scriptPath: scriptPath, workingDirectory: workingDirectory
        ))
    }

    func requestAddCronJob(schedule: String, command: String, label: String) {
        let fields = schedule.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.contains("\n") else {
            operationsError = String(localized: "Cron 表达式需要 5 段，命令必须是单行。")
            return
        }
        presentRunbookPlan(app.cronService.addUserJobPlan(
            schedule: schedule,
            command: command,
            label: label.isEmpty ? "Scheduled job" : label
        ))
    }

    func requestEditCronJob(_ job: CronJob, schedule: String, command: String) {
        guard job.source == String(localized: "用户") || job.source == "用户" else { return }
        let fields = schedule.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5, !command.isEmpty, !command.contains("\n") else {
            operationsError = String(localized: "Cron 表达式需要 5 段，命令必须是单行。")
            return
        }
        presentRunbookPlan(app.cronService.editUserJobPlan(job: job, schedule: schedule, command: command))
    }

    func requestSetCronJobEnabled(_ job: CronJob, enabled: Bool) {
        guard job.source == String(localized: "用户") || job.source == "用户" else { return }
        presentRunbookPlan(app.cronService.setUserJobEnabledPlan(job: job, enabled: enabled))
    }

    func requestDeleteCronJob(_ job: CronJob) {
        guard job.source == String(localized: "用户") || job.source == "用户" else { return }
        presentRunbookPlan(app.cronService.deleteUserJobPlan(job: job))
    }

    func openPM2Logs(_ process: PM2Process) {
        let source = LogSource(
            title: "PM2 \(process.name)",
            detail: process.name,
            command: "pm2 logs \(OpsShell.quote(process.name)) --lines 200 --nostream",
            kind: .file,
            byteCount: nil
        )
        selectedWorkspaceMode = .logs
        upsertAndSelectLogSource(source)
    }

    func refreshCertificates() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isCertbotLoading = true
        operationsError = nil
        Task {
            defer { isCertbotLoading = false }
            do {
                certbotSnapshot = try await app.certbotService.collect(profile: serverProfile, config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestCertRenew(certName: String?, dryRun: Bool) {
        presentRunbookPlan(app.certbotService.renewPlan(certName: certName, dryRun: dryRun, profile: serverProfile))
    }

    func requestObtainCert(domains: [String], method: CertbotMethod, email: String?, staging: Bool, cloudflareToken: String?) {
        let cleaned = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            operationsError = String(localized: "请先填写域名。")
            return
        }
        if method == .dnsCloudflare, (cloudflareToken?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            operationsError = String(localized: "DNS 验证需要填写 Cloudflare API Token。")
            return
        }
        presentRunbookPlan(app.certbotService.obtainPlan(domains: cleaned, method: method, email: email, staging: staging, cloudflareToken: cloudflareToken, profile: serverProfile))
    }

    func refreshCaddy() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isCaddyLoading = true
        operationsError = nil
        Task {
            defer { isCaddyLoading = false }
            do {
                caddySnapshot = try await app.caddyService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestCaddyValidate() {
        presentRunbookPlan(app.caddyService.validatePlan(configPath: caddySnapshot?.configPath))
    }

    func requestCaddyReload() {
        presentRunbookPlan(app.caddyService.reloadPlan(configPath: caddySnapshot?.configPath, profile: serverProfile))
    }

    func openCaddyConfig() {
        guard let path = caddySnapshot?.configPath else { return }
        openRemoteTextPath(path, title: "Caddyfile")
    }

    func refreshFail2ban() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isFail2banLoading = true
        operationsError = nil
        Task {
            defer { isFail2banLoading = false }
            do {
                fail2banSnapshot = try await app.fail2banService.collect(profile: serverProfile, config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestFail2banUnban(jail: String, ip: String) {
        presentRunbookPlan(app.fail2banService.unbanPlan(jail: jail, ip: ip, profile: serverProfile))
    }

    func refreshCron() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isCronLoading = true
        operationsError = nil
        Task {
            defer { isCronLoading = false }
            do {
                cronSnapshot = try await app.cronService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func refreshMirror() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isMirrorLoading = true
        operationsError = nil
        Task {
            defer { isMirrorLoading = false }
            do {
                mirrorSnapshot = try await app.mirrorService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestAptMirror(_ provider: MirrorProvider) {
        presentRunbookPlan(app.mirrorService.aptPlan(provider: provider, profile: serverProfile))
    }

    func requestPipMirror(_ provider: MirrorProvider) {
        presentRunbookPlan(app.mirrorService.pipPlan(provider: provider))
    }

    func requestNpmMirror(_ provider: MirrorProvider) {
        presentRunbookPlan(app.mirrorService.npmPlan(provider: provider))
    }

    func requestDockerMirror(_ provider: MirrorProvider) {
        presentRunbookPlan(app.mirrorService.dockerPlan(provider: provider, profile: serverProfile))
    }

    func refreshShellPath() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isShellPathLoading = true
        operationsError = nil
        Task {
            defer { isShellPathLoading = false }
            do {
                shellPathSnapshot = try await app.shellPathService.collect(config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestSetDefaultShell(_ shell: ShellInfo) {
        presentRunbookPlan(app.shellPathService.setDefaultShellPlan(shell: shell, profile: serverProfile))
    }

    func requestAddPath(dir: String, shellPath: String) {
        presentRunbookPlan(app.shellPathService.addPathPlan(dir: dir, shellPath: shellPath))
    }

    func requestInstallOhMyZsh() {
        presentRunbookPlan(app.shellPathService.installOhMyZshPlan(policy: effectiveDownloadMirrorPolicy))
    }

    func requestInstallZshPlugins(_ pluginIDs: [String]) {
        guard !pluginIDs.isEmpty else { return }
        presentRunbookPlan(app.shellPathService.installZshPluginsPlan(pluginIDs: pluginIDs, profile: serverProfile, policy: effectiveDownloadMirrorPolicy))
    }

    /// The host's own policy if set, otherwise the global default.
    var effectiveDownloadMirrorPolicy: DownloadMirrorPolicy {
        host.downloadMirrorPolicy ?? app.settings?.downloadMirrorPolicy ?? .default
    }

    func refreshDeploymentTemplates() {
        app.deploymentTemplates = app.deploymentTemplateService.templates()
    }

    func requestDeploymentTemplate(_ template: DeploymentTemplate) {
        presentRunbookPlan(app.deploymentTemplateService.plan(template: template))
    }

    func refreshAuditFindings() {
        guard let (_, config) = selectedOperationTarget() else { return }
        isAuditLoading = true
        operationsError = nil
        Task {
            defer { isAuditLoading = false }
            do {
                auditFindings = try await app.securityAuditService.collect(profile: serverProfile, config: config, sshService: app.sshService)
            } catch {
                operationsError = error.localizedDescription
            }
        }
    }

    func requestAuditFix(_ finding: AuditFinding) {
        guard let plan = finding.fixPlan else { return }
        presentRunbookPlan(plan)
    }

    private func selectedOperationTarget() -> (HostProfile, SSHConnectionConfig)? {
        guard let host = selectedHost else {
            operationsError = String(localized: "请先选择服务器。")
            return nil
        }
        guard connectionStatus == .connected else {
            operationsError = String(localized: "请先连接服务器。")
            return nil
        }
        do {
            return (host, try app.makeConnectionConfig(for: host))
        } catch {
            operationsError = error.localizedDescription
            return nil
        }
    }

    private func resetOperationsState() {
        stopLogFollow()
        serviceUnits = []
        isServicesLoading = false
        logSources = []
        selectedLogSourceID = nil
        logPreview = ""
        isLogSourcesLoading = false
        isLogPreviewLoading = false
        nginxSnapshot = nil
        isNginxLoading = false
        dockerContainers = []
        dockerSnapshot = nil
        isDockerLoading = false
        databases = []
        isDatabasesLoading = false
        hasLoadedDatabases = false
        auditFindings = []
        isAuditLoading = false
        // Newer workbench-module snapshots must reset too, otherwise reconnecting
        // to a different host would briefly show the previous host's data.
        firewallSnapshot = nil
        isFirewallLoading = false
        pm2Snapshot = nil
        isPM2Loading = false
        certbotSnapshot = nil
        isCertbotLoading = false
        caddySnapshot = nil
        isCaddyLoading = false
        fail2banSnapshot = nil
        isFail2banLoading = false
        cronSnapshot = nil
        isCronLoading = false
        shellPathSnapshot = nil
        isShellPathLoading = false
        mirrorSnapshot = nil
        isMirrorLoading = false
        operationsError = nil
        pendingRunbookPlan = nil
        activeRunbookTask?.cancel()
        activeRunbookTask = nil
        activeRunbookRun = nil
        selectedRunbookRun = nil
    }

    private func upsertAndSelectLogSource(_ source: LogSource) {
        if !logSources.contains(where: { $0.title == source.title && $0.command == source.command }) {
            logSources.insert(source, at: 0)
        }
        selectLogSource(source)
    }

    private func loadLogPreview(source: LogSource, config: SSHConnectionConfig) async {
        do {
            logPreview = try await app.logDiscoveryService.tail(source: source, config: config, sshService: app.sshService)
            operationsError = nil
        } catch {
            logPreview = ""
            operationsError = error.localizedDescription
        }
    }

    /// Re-collect the currently-selected 工具 module's data after a runbook, so
    /// its panel updates without a manual refresh. Uses `if let` so a transient
    /// collection error never blanks a previously-loaded panel.
    func refreshCurrentWorkbenchModuleData(config: SSHConnectionConfig) async {
        // Signal loading for the duration of the re-collect so panes show a
        // skeleton (not the stale "未检测到/未安装" empty state) during the 1–2s
        // window after an install/uninstall while the fresh snapshot is fetched.
        let moduleID = selectedWorkbenchModuleID
        setWorkbenchModuleLoading(moduleID, true)
        defer { setWorkbenchModuleLoading(moduleID, false) }
        switch selectedWorkbenchModuleID {
        case "services":
            if let v = try? await app.serviceManagerService.collect(config: config, sshService: app.sshService) { serviceUnits = v }
        case "nginx":
            if let v = try? await app.nginxManagerService.collect(config: config, sshService: app.sshService) { nginxSnapshot = v }
        case "caddy":
            if let v = try? await app.caddyService.collect(config: config, sshService: app.sshService) { caddySnapshot = v }
        case "certbot":
            if let v = try? await app.certbotService.collect(profile: serverProfile, config: config, sshService: app.sshService) { certbotSnapshot = v }
        case "docker":
            if let v = try? await app.dockerManagerService.collect(config: config, sshService: app.sshService) { applyDockerSnapshot(v) }
        case "database":
            if let v = try? await app.databaseManagerService.collect(profile: serverProfile, config: config, sshService: app.sshService) {
                databases = v
                hasLoadedDatabases = true
            }
        case "firewall":
            if let v = try? await app.firewallService.collect(profile: serverProfile, config: config, sshService: app.sshService) { firewallSnapshot = v }
        case "fail2ban":
            if let v = try? await app.fail2banService.collect(profile: serverProfile, config: config, sshService: app.sshService) { fail2banSnapshot = v }
        case "pm2":
            if let v = try? await app.pm2Service.collect(config: config, sshService: app.sshService) { pm2Snapshot = v }
        case "cron":
            if let v = try? await app.cronService.collect(config: config, sshService: app.sshService) { cronSnapshot = v }
        case "shellpath":
            if let v = try? await app.shellPathService.collect(config: config, sshService: app.sshService) { shellPathSnapshot = v }
        case "mirror":
            if let v = try? await app.mirrorService.collect(config: config, sshService: app.sshService) { mirrorSnapshot = v }
        default:
            break // installer/deployment rely on serverProfile / static data
        }
    }

    private func setWorkbenchModuleLoading(_ id: String, _ value: Bool) {
        switch id {
        case "services": isServicesLoading = value
        case "nginx": isNginxLoading = value
        case "caddy": isCaddyLoading = value
        case "certbot": isCertbotLoading = value
        case "docker": isDockerLoading = value
        case "database": isDatabasesLoading = value
        case "firewall": isFirewallLoading = value
        case "fail2ban": isFail2banLoading = value
        case "pm2": isPM2Loading = value
        case "cron": isCronLoading = value
        case "shellpath": isShellPathLoading = value
        case "mirror": isMirrorLoading = value
        case "installer": isServerProfileLoading = value
        default: break
        }
    }

    private func refreshOperationsAfterRunbook(kind: RunbookKind, config: SSHConnectionConfig) async {
        switch kind {
        case .service:
            serviceUnits = (try? await app.serviceManagerService.collect(config: config, sshService: app.sshService)) ?? serviceUnits
        case .log:
            if let source = logSources.first(where: { $0.id == selectedLogSourceID }) {
                await loadLogPreview(source: source, config: config)
            }
        case .nginx:
            serviceUnits = (try? await app.serviceManagerService.collect(config: config, sshService: app.sshService)) ?? serviceUnits
            if let v = try? await app.nginxManagerService.collect(config: config, sshService: app.sshService) { nginxSnapshot = v }
        case .install:
            if let v = try? await app.serverProfileService.collect(config: config, sshService: app.sshService) { serverProfile = v }
            serviceUnits = (try? await app.serviceManagerService.collect(config: config, sshService: app.sshService)) ?? serviceUnits
            if let v = try? await app.nginxManagerService.collect(config: config, sshService: app.sshService) { nginxSnapshot = v }
            if let snapshot = try? await app.dockerManagerService.collect(config: config, sshService: app.sshService) {
                applyDockerSnapshot(snapshot)
            }
            if let value = try? await app.databaseManagerService.collect(profile: serverProfile, config: config, sshService: app.sshService) {
                databases = value
                hasLoadedDatabases = true
            }
        case .docker:
            if let snapshot = try? await app.dockerManagerService.collect(config: config, sshService: app.sshService) {
                applyDockerSnapshot(snapshot)
            }
        case .database:
            if let value = try? await app.databaseManagerService.collect(profile: serverProfile, config: config, sshService: app.sshService) {
                databases = value
                hasLoadedDatabases = true
            }
        case .deployment:
            serviceUnits = (try? await app.serviceManagerService.collect(config: config, sshService: app.sshService)) ?? serviceUnits
            if let v = try? await app.nginxManagerService.collect(config: config, sshService: app.sshService) { nginxSnapshot = v }
            if let snapshot = try? await app.dockerManagerService.collect(config: config, sshService: app.sshService) {
                applyDockerSnapshot(snapshot)
            }
        case .audit, .dryRun:
            auditFindings = (try? await app.securityAuditService.collect(profile: serverProfile, config: config, sshService: app.sshService)) ?? auditFindings
        }
    }

    private func applyDockerSnapshot(_ snapshot: DockerSnapshot) {
        dockerSnapshot = snapshot
        dockerContainers = snapshot.containers
    }

    private func loadRemoteDirectory(path: String, config: SSHConnectionConfig, useCache: Bool = true) async {
        remoteDirectoryLoadGeneration += 1
        let generation = remoteDirectoryLoadGeneration
        let shouldClearSelection = normalizedRemotePathKey(path) != normalizedRemotePathKey(remoteDirectoryPath)
        if useCache,
           let host = selectedHost,
           let cached = cachedRemoteDirectory(path: path, hostID: host.id) {
            applyRemoteDirectory(cached, shouldSelectNothing: shouldClearSelection)
        }
        isRemoteFileLoading = true
        // Only the newest load owns the loading flag; a superseded older load
        // returning late must not flip it off while a newer load is still running.
        defer { if generation == remoteDirectoryLoadGeneration { isRemoteFileLoading = false } }
        do {
            let result = try await app.sftpService.listDirectory(path: path, config: config)
            // A newer navigation/refresh started while we listed; discard this
            // stale result so it can't overwrite the newer path's contents.
            guard generation == remoteDirectoryLoadGeneration else { return }
            applyRemoteDirectory(result, shouldSelectNothing: shouldClearSelection)
            if let host = selectedHost {
                cacheRemoteDirectory(result, hostID: host.id)
                saveLastRemoteDirectory(result.path, for: host)
                Task {
                    await refreshVisibleRemoteDirectoryCounts(for: result.path, hostID: host.id, config: config)
                }
            }
            remoteFileError = nil
        } catch {
            // Superseded by a newer load — let that one own the outcome.
            guard generation == remoteDirectoryLoadGeneration else { return }
            // Keep the previous listing on a failed navigation/refresh (e.g. opening
            // a directory without permission) and show the error, rather than
            // blanking to an empty folder that doesn't match the path field.
            remoteFileError = error.localizedDescription
        }
    }

    private func refreshServerStatus(config: SSHConnectionConfig) async {
        do {
            serverStatus = try await app.serverStatusService.collect(config: config, sshService: app.sshService)
        } catch {
            serverStatus = nil
        }
    }

    private func refreshServerProfile(config: SSHConnectionConfig) async {
        isServerProfileLoading = true
        defer { isServerProfileLoading = false }
        do {
            serverProfile = try await app.serverProfileService.collect(config: config, sshService: app.sshService)
            serverProfileError = nil
        } catch {
            // Keep the last good profile on a transient error. serverProfile feeds
            // sudo-prefix and package-manager selection for every generated runbook,
            // so silently nilling it would degrade later command generation.
            serverProfileError = error.localizedDescription
        }
    }

    private func startTransferProgress(
        kind: RemoteTransferProgress.Kind,
        title: String,
        detail: String,
        totalUnitCount: Int?,
        canPause: Bool = false,
        canCancel: Bool = false
    ) {
        transferControl.reset()
        activeTransferProgress = RemoteTransferProgress(
            kind: kind,
            title: title,
            detail: detail,
            completedUnitCount: 0,
            totalUnitCount: totalUnitCount,
            canPause: canPause,
            canCancel: canCancel
        )
    }

    private func updateTransferProgress(completedUnitCount: Int, detail: String) {
        guard var progress = activeTransferProgress else { return }
        progress.completedUnitCount = completedUnitCount
        progress.detail = detail
        activeTransferProgress = progress
    }

    private func updateTransferProgress(title: String, totalUnitCount: Int, detail: String) {
        guard var progress = activeTransferProgress else { return }
        progress.title = title
        progress.totalUnitCount = totalUnitCount
        progress.detail = detail
        activeTransferProgress = progress
    }

    private func finishTransferProgress(detail: String, shouldComplete: Bool = true) {
        guard var progress = activeTransferProgress else { return }
        progress.detail = detail
        if shouldComplete, let total = progress.totalUnitCount {
            progress.completedUnitCount = total
        }
        progress.isFinished = true
        activeTransferProgress = progress
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if activeTransferProgress?.id == progress.id {
                activeTransferProgress = nil
            }
        }
    }

    func pauseActiveTransfer() {
        guard var progress = activeTransferProgress, progress.canPause, !progress.isFinished else { return }
        transferControl.isPaused = true
        progress.isPaused = true
        activeTransferProgress = progress
    }

    func resumeActiveTransfer() {
        guard var progress = activeTransferProgress, progress.canPause, !progress.isFinished else { return }
        transferControl.isPaused = false
        progress.isPaused = false
        activeTransferProgress = progress
    }

    func cancelActiveTransfer() {
        guard var progress = activeTransferProgress, progress.canCancel, !progress.isFinished else { return }
        transferControl.isCancelled = true
        transferControl.isPaused = false
        progress.isPaused = false
        progress.detail = String(localized: "正在取消")
        activeTransferProgress = progress
    }

    private func waitIfTransferPaused() async throws {
        if transferControl.isCancelled {
            throw CancellationError()
        }
        while transferControl.isPaused {
            try await Task.sleep(for: .milliseconds(180))
            if transferControl.isCancelled {
                throw CancellationError()
            }
        }
    }

    private func makeRemoteDeletePlan(for item: RemoteFileItem, config: SSHConnectionConfig) async throws -> [RemoteDeleteEntry] {
        if transferControl.isCancelled {
            throw CancellationError()
        }

        if item.isDirectory {
            let result = try await app.sftpService.listDirectory(path: item.path, config: config)
            var plan: [RemoteDeleteEntry] = []
            for child in result.items {
                plan += try await makeRemoteDeletePlan(for: child, config: config)
            }
            plan.append(RemoteDeleteEntry(path: item.path, isDirectory: true))
            return plan
        }

        return [RemoteDeleteEntry(path: item.path, isDirectory: false)]
    }

    private func deleteRemoteEntries(_ entries: [RemoteDeleteEntry], config: SSHConnectionConfig) async throws -> Int {
        for (index, entry) in entries.enumerated() {
            if transferControl.isCancelled {
                throw CancellationError()
            }
            if entry.isDirectory {
                try await app.sftpService.removeDirectory(remotePath: entry.path, config: config)
            } else {
                try await app.sftpService.remove(remotePath: entry.path, config: config)
            }
            updateTransferProgress(completedUnitCount: index + 1, detail: entry.path)
        }
        return entries.count
    }

    private func remoteFolderInfoSummary(path: String, config: SSHConnectionConfig) async throws -> RemoteItemInfoSummary {
        var totalBytes: Int64 = 0
        var fileCount = 0
        var folderCount = 0
        var directChildCount: Int?

        func walk(_ path: String, isRoot: Bool) async throws {
            let result = try await app.sftpService.listDirectory(path: path, config: config)
            if isRoot {
                directChildCount = result.items.count
            }
            for child in result.items {
                if child.isDirectory {
                    folderCount += 1
                    try await walk(child.path, isRoot: false)
                } else {
                    fileCount += 1
                    totalBytes += Int64(child.byteSize ?? 0)
                }
            }
        }

        try await walk(path, isRoot: true)
        return RemoteItemInfoSummary(
            byteCount: totalBytes,
            fileCount: fileCount,
            folderCount: folderCount,
            directChildCount: directChildCount
        )
    }

    private func remoteDeleteErrorMessage(_ error: Error, item: RemoteFileItem) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("permission") || lower.contains("denied") {
            return String(localized: "删除失败：没有权限删除 \(item.path)。请检查当前 SSH 用户权限。原始错误：\(raw)")
        }
        if raw.contains("SSH_FX_FAILURE") || raw.contains("#Failure") {
            if item.isDirectory {
                return String(localized: "删除失败：服务器拒绝删除 \(item.path)。常见原因是目录内有受保护文件、权限不足，或目标正在被占用。原始错误：\(raw)")
            }
            return String(localized: "删除失败：服务器拒绝删除 \(item.path)。请检查文件权限或占用状态。原始错误：\(raw)")
        }
        return String(localized: "删除失败：\(raw)")
    }

    private func downloadRemoteDirectory(_ item: RemoteFileItem, to destination: URL, config: SSHConnectionConfig) async throws -> Int64 {
        try await waitIfTransferPaused()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var downloadedBytes: Int64 = 0
        var completedItems = 0

        func downloadDirectory(remotePath: String, localURL: URL) async throws {
            try await waitIfTransferPaused()
            let result = try await app.sftpService.listDirectory(path: remotePath, config: config)
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for child in result.items {
                try await waitIfTransferPaused()
                let childDestination = localURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                if child.isDirectory {
                    try await downloadDirectory(remotePath: child.path, localURL: childDestination)
                } else {
                    let data = try await app.sftpService.download(remotePath: child.path, config: config)
                    try data.write(to: childDestination, options: .atomic)
                    downloadedBytes += Int64(data.count)
                    completedItems += 1
                    updateTransferProgress(completedUnitCount: completedItems, detail: child.path)
                }
            }
        }

        try await downloadDirectory(remotePath: item.path, localURL: destination)
        return downloadedBytes
    }

    private func applyRemoteDirectory(_ result: SFTPListResult, shouldSelectNothing: Bool) {
        remoteDirectoryPath = result.path
        remotePathInput = result.path
        remoteFiles = result.items
        if shouldSelectNothing {
            clearRemoteFileSelection()
        } else {
            reconcileRemoteFileSelection()
        }
    }

    private func refreshVisibleRemoteDirectoryCounts(for directoryPath: String, hostID: UUID, config: SSHConnectionConfig) async {
        let directories = remoteFiles.filter(\.isDirectory)
        guard !directories.isEmpty else { return }

        for directory in directories {
            guard remoteDirectoryPath == directoryPath else { return }
            do {
                let result = try await app.sftpService.listDirectory(path: directory.path, config: config)
                guard remoteDirectoryPath == directoryPath else { return }
                if let index = remoteFiles.firstIndex(where: { $0.id == directory.id }) {
                    remoteFiles[index] = remoteFiles[index].withChildCount(result.items.count)
                }
            } catch {
                continue
            }
        }

        if remoteDirectoryPath == directoryPath {
            cacheRemoteDirectory(SFTPListResult(path: directoryPath, items: remoteFiles), hostID: hostID)
        }
    }

    private func updateVisibleRemoteItem(_ item: RemoteFileItem) {
        if let index = remoteFiles.firstIndex(where: { $0.id == item.id }) {
            remoteFiles[index] = item
        }
        if remoteInfoCandidate?.id == item.id {
            remoteInfoCandidate = item
        }
        if let host = selectedHost {
            cacheRemoteDirectory(SFTPListResult(path: remoteDirectoryPath, items: remoteFiles), hostID: host.id)
        }
    }

    private func cachedRemoteDirectory(path: String, hostID: UUID) -> SFTPListResult? {
        let key = normalizedRemotePathKey(path)
        return remoteDirectoryCache[hostID]?[key]
    }

    private func cacheRemoteDirectory(_ result: SFTPListResult, hostID: UUID) {
        let key = normalizedRemotePathKey(result.path)
        var hostCache = remoteDirectoryCache[hostID] ?? [:]
        hostCache[key] = result
        remoteDirectoryCache[hostID] = hostCache
    }

    private func saveLastRemoteDirectory(_ path: String, for host: HostProfile) {
        UserDefaults.standard.set(path, forKey: lastRemoteDirectoryKey(for: host.id))
    }

    func lastRemoteDirectory(for host: HostProfile) -> String? {
        UserDefaults.standard.string(forKey: lastRemoteDirectoryKey(for: host.id))
    }

    private func lastRemoteDirectoryKey(for hostID: UUID) -> String {
        "OpsDeck.lastRemoteDirectory.\(hostID.uuidString)"
    }
}


// Small pure path helpers used by the migrated remote-file methods. Kept
// fileprivate here (mirroring the same helpers in SFTPService/TerminalService)
// rather than sharing AppState's file-private copies across files.
fileprivate func joinedRemotePath(parent: String, child: String) -> String {
    if parent == "/" { return "/" + child }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

fileprivate func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
