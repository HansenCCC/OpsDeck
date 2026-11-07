import Foundation

enum SpikeStatus: String, Sendable {
    case notStarted
    case needsManualServer
    case passed
    case failed
}

struct SSHCommandSpikeReport: Sendable, Equatable {
    var status: SpikeStatus
    var dependency: String
    var testCommand: String
    var notes: String

    static let initial = SSHCommandSpikeReport(
        status: .passed,
        dependency: "Citadel 0.12.1 + SwiftTerm 1.14.0",
        testCommand: "uname -a",
        notes: "Password-based SSH command execution and SFTP list/upload/download/mkdir/rename/tail/remove were verified against a real Linux test server using only /tmp temporary files. The app now targets macOS 15+ so Citadel PTY APIs can power a real SSH shell through SwiftTerm without installing a server-side agent."
    )
}
