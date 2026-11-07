import Foundation
import SwiftData

@Model
final class HostGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int
    var colorHex: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        colorHex: String = "#167C8A",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

