import Foundation
import SwiftData

/// How a runbook that must fetch a resource from an overseas host (GitHub,
/// astral.sh, …) chooses between the official upstream and a China mirror.
/// Expresses the user's *intent*; each tool's plan honors it as best it can
/// (some tools have a clean mirror, e.g. oh-my-zsh → Gitee; others only a
/// best-effort one). A per-host override may pin a different policy than the
/// global default.
enum DownloadMirrorPolicy: String, CaseIterable, Hashable, Identifiable, Sendable {
    /// Official upstream first, fall back to the mirror. Best for overseas servers.
    case officialFirst
    /// Mirror first, fall back to the official upstream. Best for most CN servers.
    case mirrorFirst
    /// Mirror only — never touch the official upstream. For known-blocked
    /// networks: fastest, no wasted connection timeouts.
    case mirrorOnly

    var id: String { rawValue }

    static var `default`: DownloadMirrorPolicy { .officialFirst }

    var displayName: String {
        switch self {
        case .officialFirst: return String(localized: "自动 · 官方优先")
        case .mirrorFirst: return String(localized: "国内镜像优先")
        case .mirrorOnly: return String(localized: "仅国内镜像")
        }
    }

    /// Whether the official upstream is attempted at all under this policy.
    var usesOfficial: Bool { self != .mirrorOnly }

    /// Order an (official, mirror) source pair into the attempt sequence.
    /// `.mirrorOnly` drops the official source entirely.
    func order<T>(official: T, mirror: T) -> [T] {
        switch self {
        case .officialFirst: return [official, mirror]
        case .mirrorFirst: return [mirror, official]
        case .mirrorOnly: return [mirror]
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "跟随系统")
        case .light:
            return String(localized: "浅色")
        case .dark:
            return String(localized: "深色")
        }
    }
}

@Model
final class AppSettings {
    @Attribute(.unique) var id: String
    var theme: String
    var defaultLocalDirectoryBookmark: Data?
    var confirmDangerousActions: Bool
    var protectWithTouchID: Bool
    var isProUnlocked: Bool
    /// Global default download-source policy for overseas fetches (oh-my-zsh, uv…).
    /// A host may override this; see `HostProfile.downloadMirrorPolicy`.
    var downloadMirrorPolicyRaw: String = DownloadMirrorPolicy.default.rawValue
    /// Remembered Let's Encrypt account email, prefilled when requesting SSL certs.
    var acmeEmail: String = ""
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "default",
        theme: String = "system",
        defaultLocalDirectoryBookmark: Data? = nil,
        confirmDangerousActions: Bool = true,
        protectWithTouchID: Bool = false,
        isProUnlocked: Bool = false,
        downloadMirrorPolicyRaw: String = DownloadMirrorPolicy.default.rawValue,
        acmeEmail: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.theme = theme
        self.defaultLocalDirectoryBookmark = defaultLocalDirectoryBookmark
        self.confirmDangerousActions = confirmDangerousActions
        self.protectWithTouchID = protectWithTouchID
        self.isProUnlocked = isProUnlocked
        self.downloadMirrorPolicyRaw = downloadMirrorPolicyRaw
        self.acmeEmail = acmeEmail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension AppSettings {
    var appearanceMode: AppAppearanceMode {
        get { AppAppearanceMode(rawValue: theme) ?? .system }
        set { theme = newValue.rawValue }
    }

    var downloadMirrorPolicy: DownloadMirrorPolicy {
        get { DownloadMirrorPolicy(rawValue: downloadMirrorPolicyRaw) ?? .default }
        set { downloadMirrorPolicyRaw = newValue.rawValue }
    }
}
