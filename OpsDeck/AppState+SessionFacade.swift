import Foundation

// Auto-generated during the per-session refactor. These computed properties
// forward per-host state to the active `ServerSession`, so code and views that
// still read `appState.<field>` keep working (and stay reactive via the
// objectWillChange bridge in AppState). Migrated view sites read the session
// directly; the remaining forwarders can be trimmed once all sites are moved.
@MainActor
extension AppState {

    var connectionStatus: ConnectionStatus {
        get { activeSession?.connectionStatus ?? .disconnected }
        set { activeSession?.connectionStatus = newValue }
    }

    var selectedWorkspaceMode: WorkspaceMode {
        get { activeSession?.selectedWorkspaceMode ?? .files }
        set { activeSession?.selectedWorkspaceMode = newValue }
    }

    var selectedWorkbenchModuleID: String {
        get { activeSession?.selectedWorkbenchModuleID ?? "services" }
        set { activeSession?.selectedWorkbenchModuleID = newValue }
    }

    var remoteDirectoryPath: String {
        get { activeSession?.remoteDirectoryPath ?? "." }
        set { activeSession?.remoteDirectoryPath = newValue }
    }

    var remotePathInput: String {
        get { activeSession?.remotePathInput ?? "." }
        set { activeSession?.remotePathInput = newValue }
    }

    var remoteFiles: [RemoteFileItem] {
        get { activeSession?.remoteFiles ?? [] }
        set { activeSession?.remoteFiles = newValue }
    }

    var selectedRemoteFileID: String? {
        get { activeSession?.selectedRemoteFileID ?? nil }
        set { activeSession?.selectedRemoteFileID = newValue }
    }

    var isRemoteFileLoading: Bool {
        get { activeSession?.isRemoteFileLoading ?? false }
        set { activeSession?.isRemoteFileLoading = newValue }
    }

    var remoteFileError: String? {
        get { activeSession?.remoteFileError ?? nil }
        set { activeSession?.remoteFileError = newValue }
    }

    var activeTransferProgress: RemoteTransferProgress? {
        get { activeSession?.activeTransferProgress ?? nil }
        set { activeSession?.activeTransferProgress = newValue }
    }

    var remoteDeleteCandidate: RemoteFileItem? {
        get { activeSession?.remoteDeleteCandidate ?? nil }
        set { activeSession?.remoteDeleteCandidate = newValue }
    }

    var isShowingNewRemoteDirectorySheet: Bool {
        get { activeSession?.isShowingNewRemoteDirectorySheet ?? false }
        set { activeSession?.isShowingNewRemoteDirectorySheet = newValue }
    }

    var newRemoteDirectoryName: String {
        get { activeSession?.newRemoteDirectoryName ?? "" }
        set { activeSession?.newRemoteDirectoryName = newValue }
    }

    var isShowingNewRemoteFileSheet: Bool {
        get { activeSession?.isShowingNewRemoteFileSheet ?? false }
        set { activeSession?.isShowingNewRemoteFileSheet = newValue }
    }

    var newRemoteFileName: String {
        get { activeSession?.newRemoteFileName ?? "" }
        set { activeSession?.newRemoteFileName = newValue }
    }

    var remoteRenameCandidate: RemoteFileItem? {
        get { activeSession?.remoteRenameCandidate ?? nil }
        set { activeSession?.remoteRenameCandidate = newValue }
    }

    var remoteRenameName: String {
        get { activeSession?.remoteRenameName ?? "" }
        set { activeSession?.remoteRenameName = newValue }
    }

    var remoteInfoCandidate: RemoteFileItem? {
        get { activeSession?.remoteInfoCandidate ?? nil }
        set { activeSession?.remoteInfoCandidate = newValue }
    }

    var remoteInfoSummary: RemoteItemInfoSummary? {
        get { activeSession?.remoteInfoSummary ?? nil }
        set { activeSession?.remoteInfoSummary = newValue }
    }

    var isRemoteInfoLoading: Bool {
        get { activeSession?.isRemoteInfoLoading ?? false }
        set { activeSession?.isRemoteInfoLoading = newValue }
    }

    var remoteInfoError: String? {
        get { activeSession?.remoteInfoError ?? nil }
        set { activeSession?.remoteInfoError = newValue }
    }

    var remoteTextDocument: RemoteTextDocument? {
        get { activeSession?.remoteTextDocument ?? nil }
        set { activeSession?.remoteTextDocument = newValue }
    }

    var remoteTextError: String? {
        get { activeSession?.remoteTextError ?? nil }
        set { activeSession?.remoteTextError = newValue }
    }

    var isRemoteTextLoading: Bool {
        get { activeSession?.isRemoteTextLoading ?? false }
        set { activeSession?.isRemoteTextLoading = newValue }
    }

    var isRemoteTextSaving: Bool {
        get { activeSession?.isRemoteTextSaving ?? false }
        set { activeSession?.isRemoteTextSaving = newValue }
    }

    var connectionSummary: String? {
        get { activeSession?.connectionSummary ?? nil }
        set { activeSession?.connectionSummary = newValue }
    }

    var serverStatus: ServerStatusSnapshot? {
        get { activeSession?.serverStatus ?? nil }
        set { activeSession?.serverStatus = newValue }
    }

    var serverProfile: ServerProfileSnapshot? {
        get { activeSession?.serverProfile ?? nil }
        set { activeSession?.serverProfile = newValue }
    }

    var isServerProfileLoading: Bool {
        get { activeSession?.isServerProfileLoading ?? false }
        set { activeSession?.isServerProfileLoading = newValue }
    }

    var serverProfileError: String? {
        get { activeSession?.serverProfileError ?? nil }
        set { activeSession?.serverProfileError = newValue }
    }

    var pendingRunbookPlan: RunbookPlan? {
        get { activeSession?.pendingRunbookPlan ?? nil }
        set { activeSession?.pendingRunbookPlan = newValue }
    }

    var activeRunbookRun: RunbookRun? {
        get { activeSession?.activeRunbookRun ?? nil }
        set { activeSession?.activeRunbookRun = newValue }
    }

    var runbookRuns: [RunbookRun] {
        get { activeSession?.runbookRuns ?? [] }
        set { activeSession?.runbookRuns = newValue }
    }

    var selectedRunbookRun: RunbookRun? {
        get { activeSession?.selectedRunbookRun ?? nil }
        set { activeSession?.selectedRunbookRun = newValue }
    }

    var serviceUnits: [ServiceUnit] {
        get { activeSession?.serviceUnits ?? [] }
        set { activeSession?.serviceUnits = newValue }
    }

    var isServicesLoading: Bool {
        get { activeSession?.isServicesLoading ?? false }
        set { activeSession?.isServicesLoading = newValue }
    }

    var logSources: [LogSource] {
        get { activeSession?.logSources ?? [] }
        set { activeSession?.logSources = newValue }
    }

    var selectedLogSourceID: UUID? {
        get { activeSession?.selectedLogSourceID ?? nil }
        set { activeSession?.selectedLogSourceID = newValue }
    }

    var logPreview: String {
        get { activeSession?.logPreview ?? "" }
        set { activeSession?.logPreview = newValue }
    }

    var isLogSourcesLoading: Bool {
        get { activeSession?.isLogSourcesLoading ?? false }
        set { activeSession?.isLogSourcesLoading = newValue }
    }

    var isLogPreviewLoading: Bool {
        get { activeSession?.isLogPreviewLoading ?? false }
        set { activeSession?.isLogPreviewLoading = newValue }
    }

    var nginxSnapshot: NginxSnapshot? {
        get { activeSession?.nginxSnapshot ?? nil }
        set { activeSession?.nginxSnapshot = newValue }
    }

    var isNginxLoading: Bool {
        get { activeSession?.isNginxLoading ?? false }
        set { activeSession?.isNginxLoading = newValue }
    }

    var dockerSnapshot: DockerSnapshot? {
        get { activeSession?.dockerSnapshot ?? nil }
        set { activeSession?.dockerSnapshot = newValue }
    }

    var dockerContainers: [DockerContainerSummary] {
        get { activeSession?.dockerContainers ?? [] }
        set { activeSession?.dockerContainers = newValue }
    }

    var isDockerLoading: Bool {
        get { activeSession?.isDockerLoading ?? false }
        set { activeSession?.isDockerLoading = newValue }
    }

    var firewallSnapshot: FirewallSnapshot? {
        get { activeSession?.firewallSnapshot ?? nil }
        set { activeSession?.firewallSnapshot = newValue }
    }

    var isFirewallLoading: Bool {
        get { activeSession?.isFirewallLoading ?? false }
        set { activeSession?.isFirewallLoading = newValue }
    }

    var pm2Snapshot: PM2Snapshot? {
        get { activeSession?.pm2Snapshot ?? nil }
        set { activeSession?.pm2Snapshot = newValue }
    }

    var isPM2Loading: Bool {
        get { activeSession?.isPM2Loading ?? false }
        set { activeSession?.isPM2Loading = newValue }
    }

    var certbotSnapshot: CertbotSnapshot? {
        get { activeSession?.certbotSnapshot ?? nil }
        set { activeSession?.certbotSnapshot = newValue }
    }

    var isCertbotLoading: Bool {
        get { activeSession?.isCertbotLoading ?? false }
        set { activeSession?.isCertbotLoading = newValue }
    }

    var caddySnapshot: CaddySnapshot? {
        get { activeSession?.caddySnapshot ?? nil }
        set { activeSession?.caddySnapshot = newValue }
    }

    var isCaddyLoading: Bool {
        get { activeSession?.isCaddyLoading ?? false }
        set { activeSession?.isCaddyLoading = newValue }
    }

    var fail2banSnapshot: Fail2banSnapshot? {
        get { activeSession?.fail2banSnapshot ?? nil }
        set { activeSession?.fail2banSnapshot = newValue }
    }

    var isFail2banLoading: Bool {
        get { activeSession?.isFail2banLoading ?? false }
        set { activeSession?.isFail2banLoading = newValue }
    }

    var cronSnapshot: CronSnapshot? {
        get { activeSession?.cronSnapshot ?? nil }
        set { activeSession?.cronSnapshot = newValue }
    }

    var isCronLoading: Bool {
        get { activeSession?.isCronLoading ?? false }
        set { activeSession?.isCronLoading = newValue }
    }

    var shellPathSnapshot: ShellPathSnapshot? {
        get { activeSession?.shellPathSnapshot ?? nil }
        set { activeSession?.shellPathSnapshot = newValue }
    }

    var isShellPathLoading: Bool {
        get { activeSession?.isShellPathLoading ?? false }
        set { activeSession?.isShellPathLoading = newValue }
    }

    var mirrorSnapshot: MirrorSnapshot? {
        get { activeSession?.mirrorSnapshot ?? nil }
        set { activeSession?.mirrorSnapshot = newValue }
    }

    var isMirrorLoading: Bool {
        get { activeSession?.isMirrorLoading ?? false }
        set { activeSession?.isMirrorLoading = newValue }
    }

    var databases: [DatabaseTarget] {
        get { activeSession?.databases ?? [] }
        set { activeSession?.databases = newValue }
    }

    var isDatabasesLoading: Bool {
        get { activeSession?.isDatabasesLoading ?? false }
        set { activeSession?.isDatabasesLoading = newValue }
    }

    var auditFindings: [AuditFinding] {
        get { activeSession?.auditFindings ?? [] }
        set { activeSession?.auditFindings = newValue }
    }

    var isAuditLoading: Bool {
        get { activeSession?.isAuditLoading ?? false }
        set { activeSession?.isAuditLoading = newValue }
    }

    var operationsError: String? {
        get { activeSession?.operationsError ?? nil }
        set { activeSession?.operationsError = newValue }
    }
}
