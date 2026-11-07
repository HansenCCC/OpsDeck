import Foundation

enum TerminalSessionStatus: String, Sendable, Codable {
    case idle
    case running
    case disconnected

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "运行中")
        case .disconnected:
            return String(localized: "已断开")
        }
    }
}

struct TerminalSessionTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let hostID: UUID
    var title: String
    var output: String
    var outputBytes: [UInt8]
    var status: TerminalSessionStatus
    var workingDirectory: String
    var columns: Int
    var rows: Int
    var createdAt: Date
    var updatedAt: Date
    /// When set, the PTY switches to this shell via `exec` after opening.
    var shellOverride: String? = nil

    init(
        id: UUID = UUID(),
        hostID: UUID,
        title: String,
        output: String,
        outputBytes: [UInt8]? = nil,
        status: TerminalSessionStatus = .idle,
        workingDirectory: String = ".",
        columns: Int = 80,
        rows: Int = 24,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.output = output
        self.outputBytes = outputBytes ?? Array(output.utf8)
        self.status = status
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
