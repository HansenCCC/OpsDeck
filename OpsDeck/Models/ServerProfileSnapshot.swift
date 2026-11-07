import Foundation

enum ServerPackageManager: String, Sendable, Equatable {
    case apt
    case dnf
    case yum
    case pacman
    case zypper
    case apk
    case unknown

    var displayName: String {
        switch self {
        case .apt:
            return "apt"
        case .dnf:
            return "dnf"
        case .yum:
            return "yum"
        case .pacman:
            return "pacman"
        case .zypper:
            return "zypper"
        case .apk:
            return "apk"
        case .unknown:
            return String(localized: "未识别")
        }
    }
}

enum ServerInitSystem: String, Sendable, Equatable {
    case systemd
    case openrc
    case service
    case unknown

    var displayName: String {
        switch self {
        case .systemd:
            return "systemd"
        case .openrc:
            return "OpenRC"
        case .service:
            return "service"
        case .unknown:
            return String(localized: "未识别")
        }
    }
}

enum ServerSudoStatus: String, Sendable, Equatable {
    case root
    case passwordless
    case requiresPassword
    case unavailable
    case unknown

    var displayName: String {
        switch self {
        case .root:
            return String(localized: "root 用户")
        case .passwordless:
            return String(localized: "可免密 sudo")
        case .requiresPassword:
            return String(localized: "需要 sudo 密码")
        case .unavailable:
            return String(localized: "未安装 sudo")
        case .unknown:
            return String(localized: "未识别")
        }
    }
}

struct ServerToolPresence: Identifiable, Equatable, Sendable {
    var name: String
    var path: String?
    var version: String?
    /// All PATH locations for this binary (from `which -a`), primary first.
    /// More than one entry usually means multiple installed versions.
    var allPaths: [String] = []

    var id: String { name }
    var isInstalled: Bool { path?.isEmpty == false }

    /// Extra install locations beyond the primary one (used to surface
    /// "multiple versions" without cluttering the common single-version case).
    var alternatePaths: [String] {
        guard let path, !path.isEmpty else { return [] }
        return allPaths.filter { $0 != path }
    }

    var hasMultipleVersions: Bool { !alternatePaths.isEmpty }
}

struct ServerServicePresence: Identifiable, Equatable, Sendable {
    var name: String
    var activeState: String?
    var enabledState: String?

    var id: String { name }

    var isInstalled: Bool {
        activeState?.isEmpty == false || enabledState?.isEmpty == false
    }

    var displayState: String {
        let active = activeState?.isEmpty == false ? activeState! : "unknown"
        let enabled = enabledState?.isEmpty == false ? enabledState! : "unknown"
        return "\(active) · \(enabled)"
    }
}

struct ServerProfileSnapshot: Equatable, Sendable {
    var osName: String?
    var osID: String?
    var osVersionID: String?
    var architecture: String?
    var username: String?
    var userID: String?
    var sudoStatus: ServerSudoStatus
    var packageManager: ServerPackageManager
    var initSystem: ServerInitSystem
    var tools: [ServerToolPresence]
    var services: [ServerServicePresence]
    var capturedAt: Date

    var installedTools: [ServerToolPresence] {
        tools.filter(\.isInstalled)
    }

    var installedServices: [ServerServicePresence] {
        services.filter(\.isInstalled)
    }

    func tool(named name: String) -> ServerToolPresence? {
        tools.first { $0.name == name }
    }

    func service(named name: String) -> ServerServicePresence? {
        services.first { $0.name == name }
    }
}

