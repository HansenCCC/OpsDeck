import Foundation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case files
    case tools
    case logs
    case audit
    case history

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .files:
            return String(localized: "文件")
        case .tools:
            return String(localized: "运维")
        case .logs:
            return String(localized: "日志")
        case .audit:
            return String(localized: "巡检")
        case .history:
            return String(localized: "操作日志")
        }
    }

    var systemImage: String {
        switch self {
        case .files:
            return "folder"
        case .tools:
            return "shippingbox"
        case .logs:
            return "doc.text.magnifyingglass"
        case .audit:
            return "checkmark.shield"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}
