import Foundation
import SwiftUI

enum EntitlementFeature: String, CaseIterable, Sendable {
    case unlimitedHosts
    case upload
    case remoteEdit
    case commandSnippets
    case transferHistory
    case themes
}

struct EntitlementLimits: Sendable {
    static let freeHostLimit = 2
}

enum EntitlementDecision: Equatable, Sendable {
    case allowed
    case needsPro(String)
}

@MainActor
final class EntitlementService: ObservableObject {
    @Published var debugIsProUnlocked = false

    func isProUnlocked(settings _: AppSettings) -> Bool {
        true
    }

    func canAddHost(currentHostCount _: Int, settings _: AppSettings) -> EntitlementDecision {
        .allowed
    }

    func canUse(_: EntitlementFeature, settings _: AppSettings) -> EntitlementDecision {
        .allowed
    }
}
