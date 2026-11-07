import Foundation

/// Grouping for guide topics in the sidebar. `.tools` is dynamic — populated
/// from the installer catalog so newly added tools automatically get an entry
/// with an on-demand `--help` lookup, satisfying "新增工具顺便更新文档".
enum GuideCategory: String, CaseIterable, Identifiable, Sendable {
    case quickstart
    case shell
    case files
    case textSearch
    case process
    case network
    case permission
    case service
    case nginx
    case docker
    case git
    case database
    case tools

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickstart: return String(localized: "快速入门")
        case .shell: return String(localized: "Shell 基础")
        case .files: return String(localized: "文件与目录")
        case .textSearch: return String(localized: "文本与搜索")
        case .process: return String(localized: "进程与资源")
        case .network: return String(localized: "网络")
        case .permission: return String(localized: "权限与用户")
        case .service: return String(localized: "服务 (systemd)")
        case .nginx: return "Nginx"
        case .docker: return "Docker"
        case .git: return "Git"
        case .database: return String(localized: "数据库")
        case .tools: return String(localized: "已安装工具速查")
        }
    }

    var systemImage: String {
        switch self {
        case .quickstart: return "sparkles"
        case .shell: return "terminal"
        case .files: return "folder"
        case .textSearch: return "text.magnifyingglass"
        case .process: return "gauge.with.dots.needle.67percent"
        case .network: return "network"
        case .permission: return "lock.shield"
        case .service: return "switch.2"
        case .nginx: return "server.rack"
        case .docker: return "shippingbox"
        case .git: return "arrow.triangle.branch"
        case .database: return "cylinder.split.1x2"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

/// A single command with a plain-language explanation for beginners.
struct GuideCommand: Identifiable, Equatable, Sendable {
    var id = UUID()
    var command: String
    var explanation: String
    var example: String?

    init(_ command: String, _ explanation: String, example: String? = nil) {
        self.command = command
        self.explanation = explanation
        self.example = example
    }
}

struct GuideSection: Identifiable, Equatable, Sendable {
    var id = UUID()
    var heading: String
    var commands: [GuideCommand]

    init(_ heading: String, _ commands: [GuideCommand]) {
        self.heading = heading
        self.commands = commands
    }
}

struct GuideTopic: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var category: GuideCategory
    var summary: String
    /// 快速入门：最常用的几条，让新手立刻能上手。
    var quickStart: [GuideCommand]
    /// 更详细：按主题拆分的完整参考。
    var sections: [GuideSection]
    /// 关联的安装器工具 id（存在则可在服务器上抓取 `--help`）。
    var toolID: String?
    /// 该工具的主可执行名（用于 `--help`/`man`，默认取 toolID）。
    var helpBinary: String?
    /// 官方文档链接（仅展示，不自动打开）。
    var externalDoc: String?

    init(
        id: String,
        title: String,
        category: GuideCategory,
        summary: String,
        quickStart: [GuideCommand] = [],
        sections: [GuideSection] = [],
        toolID: String? = nil,
        helpBinary: String? = nil,
        externalDoc: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.summary = summary
        self.quickStart = quickStart
        self.sections = sections
        self.toolID = toolID
        self.helpBinary = helpBinary
        self.externalDoc = externalDoc
    }
}
