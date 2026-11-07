import Foundation
import SwiftData

@Model
final class CommandRun {
    @Attribute(.unique) var id: UUID
    var hostID: UUID
    var snippetID: UUID?
    var command: String
    var stdoutPreview: String
    var stderrPreview: String
    var exitCode: Int
    var startedAt: Date
    var duration: TimeInterval

    init(
        id: UUID = UUID(),
        hostID: UUID,
        snippetID: UUID? = nil,
        command: String,
        stdoutPreview: String = "",
        stderrPreview: String = "",
        exitCode: Int = 0,
        startedAt: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.hostID = hostID
        self.snippetID = snippetID
        self.command = command
        self.stdoutPreview = stdoutPreview
        self.stderrPreview = stderrPreview
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.duration = duration
    }
}

