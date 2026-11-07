import Foundation
import SwiftData

@Model
final class CommandSnippet {
    @Attribute(.unique) var id: UUID
    var title: String
    var command: String
    var group: String
    var requiresConfirmation: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        group: String = "General",
        requiresConfirmation: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.group = group
        self.requiresConfirmation = requiresConfirmation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

