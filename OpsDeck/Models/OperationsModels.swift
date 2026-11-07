import Foundation

enum OpsShell {
    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func sudoPrefix(for profile: ServerProfileSnapshot?) -> String {
        guard let profile else { return "sudo -n " }
        switch profile.sudoStatus {
        case .root:
            return ""
        case .passwordless:
            return "sudo -n "
        case .requiresPassword, .unavailable, .unknown:
            return "sudo "
        }
    }

    /// apt must never try to open an interactive debconf frontend in an SSH
    /// runbook. The lock timeout also turns short-lived unattended-upgrade races
    /// into a wait instead of an immediate failure.
    static func unattendedAptGet(sudo: String) -> String {
        "\(sudo)env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180"
    }

    /// Install apt packages and restore only conffiles that dpkg reports as
    /// missing. A normal reinstall deliberately preserves a deleted conffile;
    /// `--force-confmiss` is the narrow repair that restores it without
    /// overwriting an existing administrator-edited configuration.
    static func unattendedAptInstall(packages: [String], sudo: String) -> String {
        let packageText = packages.map(quote).joined(separator: " ")
        let apt = unattendedAptGet(sudo: sudo)
        let recoveryNotice = quote(String(localized: "检测到缺失的软件包配置，正在恢复："))
        return """
        \(apt) install -y \(packageText) && {
          opsdeck_missing_packages=""
          for opsdeck_package in \(packageText); do
            if \(sudo)dpkg --verify "$opsdeck_package" 2>/dev/null | grep -Eq '^missing[[:space:]]+c[[:space:]]'; then
              opsdeck_missing_packages="$opsdeck_missing_packages $opsdeck_package"
            fi
          done
          if [ -n "$opsdeck_missing_packages" ]; then
            printf '%s%s\n' \(recoveryNotice) "$opsdeck_missing_packages"
            \(apt) -o Dpkg::Options::=--force-confmiss install --reinstall -y $opsdeck_missing_packages
          fi
        }
        """
    }

    /// `systemctl enable --now` can return success when enabling succeeded even
    /// though the `--now` start job failed. Split those operations and require
    /// the unit to become active before reporting success. On failure include
    /// bounded status/journal output so the Runbook summary can surface the
    /// actual service error instead of a bare exit code.
    static func systemdEnableAndStart(serviceName: String, sudo: String) -> String {
        let service = quote(serviceName)
        let stateLabel = quote(String(localized: "服务状态："))
        return """
        \(sudo)systemctl enable \(service)
        opsdeck_enable_rc=$?
        if [ "$opsdeck_enable_rc" -ne 0 ]; then exit "$opsdeck_enable_rc"; fi
        \(sudo)systemctl reset-failed \(service) 2>/dev/null || true
        \(sudo)systemctl start \(service)
        opsdeck_start_rc=$?
        opsdeck_service_state="$(systemctl is-active \(service) 2>/dev/null || true)"
        opsdeck_wait=0
        while [ "$opsdeck_start_rc" -eq 0 ] && [ "$opsdeck_service_state" = activating ] && [ "$opsdeck_wait" -lt 10 ]; do
          sleep 0.2
          opsdeck_wait=$((opsdeck_wait + 1))
          opsdeck_service_state="$(systemctl is-active \(service) 2>/dev/null || true)"
        done
        printf '%s%s\n' \(stateLabel) "$opsdeck_service_state"
        if [ "$opsdeck_start_rc" -eq 0 ] && [ "$opsdeck_service_state" = active ]; then exit 0; fi
        \(sudo)systemctl status \(service) --no-pager -l 2>&1 || true
        \(sudo)journalctl -u \(service) -n 40 --no-pager 2>&1 || true
        if [ "$opsdeck_start_rc" -ne 0 ]; then exit "$opsdeck_start_rc"; fi
        exit 1
        """
    }

    static func systemdActiveVerification(serviceName: String, sudo: String) -> String {
        let service = quote(serviceName)
        let stateLabel = quote(String(localized: "服务状态："))
        return """
        opsdeck_service_state="$(systemctl is-active \(service) 2>/dev/null || true)"
        printf '%s%s\n' \(stateLabel) "$opsdeck_service_state"
        if [ "$opsdeck_service_state" = active ]; then exit 0; fi
        \(sudo)systemctl status \(service) --no-pager -l 2>&1 || true
        \(sudo)journalctl -u \(service) -n 40 --no-pager 2>&1 || true
        exit 1
        """
    }

    static func systemdDisableAndStop(serviceName: String, sudo: String) -> String {
        let service = quote(serviceName)
        let stateLabel = quote(String(localized: "服务状态："))
        return """
        \(sudo)systemctl disable \(service)
        opsdeck_disable_rc=$?
        \(sudo)systemctl stop \(service)
        opsdeck_stop_rc=$?
        opsdeck_service_state="$(systemctl is-active \(service) 2>/dev/null || true)"
        printf '%s%s\n' \(stateLabel) "$opsdeck_service_state"
        if [ "$opsdeck_disable_rc" -eq 0 ] && [ "$opsdeck_stop_rc" -eq 0 ] && [ "$opsdeck_service_state" != active ] && [ "$opsdeck_service_state" != activating ]; then exit 0; fi
        \(sudo)systemctl status \(service) --no-pager -l 2>&1 || true
        \(sudo)journalctl -u \(service) -n 40 --no-pager 2>&1 || true
        if [ "$opsdeck_disable_rc" -ne 0 ]; then exit "$opsdeck_disable_rc"; fi
        if [ "$opsdeck_stop_rc" -ne 0 ]; then exit "$opsdeck_stop_rc"; fi
        exit 1
        """
    }
}

enum ServiceAction: String, CaseIterable, Identifiable, Sendable {
    case start
    case stop
    case restart
    case reload
    case enable
    case disable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .start:
            return String(localized: "启动")
        case .stop:
            return String(localized: "停止")
        case .restart:
            return String(localized: "重启")
        case .reload:
            return String(localized: "重载")
        case .enable:
            return String(localized: "开机启动")
        case .disable:
            return String(localized: "取消自启")
        }
    }
}

struct ServiceUnit: Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    var loadState: String
    var activeState: String
    var subState: String
    var unitFileState: String

    var id: String { name }
}

enum LogSourceKind: String, Sendable, Equatable {
    case file
    case journal
    case docker
}

struct LogSource: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var detail: String
    var command: String
    var kind: LogSourceKind
    var byteCount: Int64?
}

enum NginxSiteType: String, CaseIterable, Identifiable, Sendable {
    case reverseProxy
    case staticSite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reverseProxy: return String(localized: "反向代理")
        case .staticSite: return String(localized: "静态站点")
        }
    }
}

struct NginxSiteConfig: Identifiable, Equatable, Sendable {
    var path: String
    var enabled: Bool
    var byteCount: Int64?
    var modifiedAt: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct NginxSnapshot: Equatable, Sendable {
    var isInstalled: Bool
    var version: String?
    var configPath: String?
    var sites: [NginxSiteConfig]
    var accessLogPath: String?
    var errorLogPath: String?
    var certificateHints: [String]
    var capturedAt = Date()
}

enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    case base
    case web
    case runtime
    case container
    case database
    case security

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base:
            return String(localized: "基础")
        case .web:
            return "Web"
        case .runtime:
            return String(localized: "运行时")
        case .container:
            return String(localized: "容器")
        case .database:
            return String(localized: "数据库")
        case .security:
            return String(localized: "安全")
        }
    }
}

/// An install-time environment condition a tool needs (not auto-fixable like a
/// dependency — surfaced as guidance so the user knows what to resolve).
enum ToolRequirement: String, Sendable, Equatable {
    case systemd   // 需要 systemd 才能启用/开机自启
    case arch64    // 需要 64 位 CPU
    case internet  // 安装过程从外网拉取（脚本 / registry）
}

/// One preflight finding for a tool against a server profile.
struct PreflightIssue: Identifiable, Equatable, Sendable {
    enum Severity: Sendable, Equatable { case blocker, warning, info }
    var id = UUID()
    var severity: Severity
    var title: String
    var detail: String
}

struct ToolDefinition: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var category: ToolCategory
    var description: String
    var binaryNames: [String]
    var packagesByManager: [ServerPackageManager: [String]]
    /// Other catalog tool IDs this one needs at install time (e.g. pm2 needs node).
    /// Missing dependencies are installed first, in order.
    var dependencies: [String] = []
    /// Installs into the user's home (no root needed) — e.g. uv/pnpm/yarn.
    var userLevelInstall: Bool = false
    /// Environment conditions this tool needs (checked at preflight, surfaced as guidance).
    var requirements: [ToolRequirement] = []

    func isInstalled(on profile: ServerProfileSnapshot?) -> Bool {
        installedTool(on: profile) != nil
    }

    func installedTool(on profile: ServerProfileSnapshot?) -> ServerToolPresence? {
        guard let profile else { return nil }
        return binaryNames
            .compactMap { profile.tool(named: $0) }
            .first(where: \.isInstalled)
    }

    /// The workbench module whose pane represents this tool, so an install/uninstall
    /// run can be attributed to the right pane (e.g. the PM2 pane shows "installing"
    /// while pm2 installs). Tools without a dedicated pane belong to the installer.
    var workbenchModuleID: String {
        switch id {
        case "nginx": return "nginx"
        case "caddy": return "caddy"
        case "docker": return "docker"
        case "certbot": return "certbot"
        case "pm2": return "pm2"
        case "fail2ban": return "fail2ban"
        case "ufw", "firewalld": return "firewall"
        case "postgresql", "mysql", "mariadb", "redis": return "database"
        default: return "installer"
        }
    }

    var managedServiceName: String? {
        switch id {
        case "nginx":
            return "nginx"
        case "caddy":
            return "caddy"
        case "docker":
            return "docker"
        case "postgresql":
            return "postgresql"
        case "mysql":
            return "mysql"
        case "redis":
            return "redis-server"
        default:
            return nil
        }
    }

    /// Whether OpsDeck exposes one-click uninstall for this tool. Tools that
    /// carry running services or business data (web servers, container engine,
    /// databases) are deliberately blocked to avoid accidental data loss — the
    /// user is directed to remove those by hand.
    var uninstallPolicy: UninstallPolicy {
        switch id {
        case "nginx", "caddy", "docker", "postgresql", "mysql", "mariadb", "redis":
            return .blocked(reason: String(localized: "涉及运行中的服务与业务数据，为避免误删已禁用一键卸载，请按需手动处理。"))
        default:
            return .allowed
        }
    }
}

enum UninstallPolicy: Equatable, Sendable {
    case allowed
    case blocked(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var blockedReason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

struct DockerContainerSummary: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var image: String
    var status: String
    var ports: String
}

struct DockerImageSummary: Identifiable, Equatable, Sendable {
    var id: String
    var repository: String
    var tag: String
    var size: String

    var displayName: String {
        repository == "<none>" ? String(id.prefix(12)) : "\(repository):\(tag)"
    }
}

struct DockerSnapshot: Equatable, Sendable {
    var isInstalled: Bool
    var daemonReachable: Bool
    var clientVersion: String?
    var daemonError: String?
    var containers: [DockerContainerSummary]
    var images: [DockerImageSummary] = []
    var diskUsage: String?
}

enum DatabaseKind: String, CaseIterable, Identifiable, Sendable {
    case postgresql
    case mysql
    case mariadb
    case redis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .postgresql:
            return "PostgreSQL"
        case .mysql:
            return "MySQL"
        case .mariadb:
            return "MariaDB"
        case .redis:
            return "Redis"
        }
    }
}

struct DatabaseTarget: Identifiable, Equatable, Sendable {
    var kind: DatabaseKind
    var serviceName: String
    var installed: Bool
    var serviceInstalled: Bool
    var activeState: String?
    var version: String?

    var id: String { kind.rawValue }
}

// MARK: - Redis manager

/// Optional Redis ACL login. The encoded value is stored only in Keychain by
/// `ServerSession`; it is never written to UserDefaults or operation output.
struct RedisCredential: Codable, Equatable, Sendable {
    var username: String
    var password: String

    var normalizedUsername: String? {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct RedisDatabaseSummary: Identifiable, Equatable, Sendable {
    var index: Int
    var keyCount: Int
    var expiringKeyCount: Int
    var averageTTL: Int

    var id: Int { index }
}

struct RedisServerSnapshot: Equatable, Sendable {
    var version: String?
    var mode: String?
    var uptimeDays: Int
    var connectedClients: Int
    var blockedClients: Int
    var usedMemory: String?
    var peakMemory: String?
    var maxMemory: String?
    var maxMemoryPolicy: String?
    var totalConnections: Int
    var totalCommands: Int
    var keyspaceHits: Int
    var keyspaceMisses: Int
    var rdbLastSaveTime: Date?
    var rdbLastSaveStatus: String?
    var aofEnabled: Bool
    var persistenceBusy: Bool
    var configuredDatabaseCount: Int
    var databases: [RedisDatabaseSummary]

    var totalKeyCount: Int { databases.reduce(0) { $0 + $1.keyCount } }

    var hitRate: Double? {
        let total = keyspaceHits + keyspaceMisses
        guard total > 0 else { return nil }
        return Double(keyspaceHits) / Double(total)
    }
}

struct RedisKeySummary: Identifiable, Equatable, Sendable {
    var name: String
    var type: String
    /// Redis TTL semantics: -1 = persistent, -2 = missing.
    var ttlSeconds: Int
    var memoryBytes: Int?

    var id: String { name }
}

struct RedisKeyPage: Equatable, Sendable {
    var keys: [RedisKeySummary]
    var nextCursor: String

    var hasMore: Bool { nextCursor != "0" }
}

struct RedisKeyDetailEntry: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var value: String
}

struct RedisKeyDetail: Equatable, Sendable {
    var key: String
    var type: String
    var ttlSeconds: Int
    var logicalSize: Int
    var entries: [RedisKeyDetailEntry]

    var isTruncated: Bool {
        switch type {
        case "hash", "zset": return logicalSize > entries.count
        case "list", "set": return logicalSize > entries.count
        case "stream": return logicalSize > 30
        default: return false
        }
    }
}

// MARK: - Firewall

enum FirewallKind: String, Sendable, Equatable {
    case ufw
    case firewalld
    case none

    var displayName: String {
        switch self {
        case .ufw: return "UFW"
        case .firewalld: return "firewalld"
        case .none: return String(localized: "未安装")
        }
    }
}

enum FirewallAction: String, Sendable, Equatable, CaseIterable, Identifiable {
    case allow, deny
    var id: String { rawValue }
    var displayName: String { self == .allow ? String(localized: "放行") : String(localized: "拒绝") }
}

enum FirewallDirection: String, Sendable, Equatable, CaseIterable, Identifiable {
    case inbound = "in"
    case outbound = "out"
    var id: String { rawValue }
    var displayName: String { self == .inbound ? String(localized: "入站") : String(localized: "出站") }
}

/// A single parsed firewall rule (from `ufw status numbered`).
struct FirewallRule: Identifiable, Equatable, Sendable {
    var id = UUID()
    var number: Int
    var action: FirewallAction
    var direction: FirewallDirection
    var proto: String          // tcp / udp / any
    var port: String           // "8080", "6000:6100", or "" (whole host)
    var source: String         // "Anywhere" / IP / CIDR
    var comment: String
    var isV6: Bool
    var raw: String
}

struct FirewallSnapshot: Equatable, Sendable {
    var kind: FirewallKind
    var active: Bool
    var pingBlocked: Bool = false          // ICMP echo dropped (禁ping)
    /// Logical user rules from `ufw show added` (one entry per rule, no v4/v6 dupes),
    /// works whether the firewall is active or not. Each carries its ufw spec in
    /// `raw` for deletion (`ufw delete <spec>` removes both v4 and v6). When the
    /// firewall is inactive these are "queued" — applied once it's enabled.
    var rules: [FirewallRule] = []
    /// Raw status/rules text from `ufw status` / `firewall-cmd --list-all` (fallback view).
    var detail: String
    var capturedAt = Date()
}

// MARK: - PM2

struct PM2Process: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var status: String
    var cpu: String
    var memory: String
    var restarts: String

    var isOnline: Bool { status.lowercased() == "online" }
}

struct PM2Snapshot: Equatable, Sendable {
    var installed: Bool
    var processes: [PM2Process]
    var capturedAt = Date()
}

// MARK: - Certbot / SSL

enum CertbotMethod: String, CaseIterable, Identifiable, Sendable {
    case nginx
    case standalone
    case dnsCloudflare

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .nginx: return String(localized: "Nginx 插件")
        case .standalone: return String(localized: "Standalone 独立")
        case .dnsCloudflare: return String(localized: "DNS 验证 (Cloudflare)")
        }
    }
    var detail: String {
        switch self {
        case .nginx: return String(localized: "自动改 Nginx 配置并加 HTTPS 跳转（需已装并运行 Nginx，走 80 端口验证）")
        case .standalone: return String(localized: "Certbot 临时占用 80 端口验证（需 80 空闲、无其它 Web 服务）")
        case .dnsCloudflare: return String(localized: "用 Cloudflare API 建 TXT 记录验证，不走 80 端口，绕过大陆未备案拦截（需 API Token）")
        }
    }
    /// HTTP-based methods (nginx/standalone) get blocked by China's ICP filing
    /// interception; DNS-01 does not.
    var usesHTTP: Bool { self != .dnsCloudflare }
}

struct CertInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var domains: String
    var expiry: String
    var validDays: String?
}

struct CertbotSnapshot: Equatable, Sendable {
    var installed: Bool
    var certificates: [CertInfo]
    var capturedAt = Date()
}

// MARK: - Caddy

struct CaddySnapshot: Equatable, Sendable {
    var installed: Bool
    var version: String?
    var configPath: String?
    var active: Bool
    var capturedAt = Date()
}

// MARK: - Fail2ban

struct Fail2banJail: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var currentlyBanned: Int
    var totalBanned: Int
    var bannedIPs: [String]
}

struct Fail2banSnapshot: Equatable, Sendable {
    var installed: Bool
    var active: Bool
    var jails: [Fail2banJail]
    var capturedAt = Date()
}

// MARK: - Mirror sources 镜像源

enum MirrorProvider: String, CaseIterable, Identifiable, Sendable {
    case aliyun
    case tuna
    case ustc
    case official

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .aliyun: return String(localized: "阿里云")
        case .tuna: return String(localized: "清华 TUNA")
        case .ustc: return String(localized: "中科大 USTC")
        case .official: return String(localized: "官方源")
        }
    }

    /// The official upstream reset (best for overseas servers) vs a China-domestic
    /// accelerator (best for servers inside China).
    var isOfficial: Bool { self == .official }

    /// Short label telling the user which deployment this source fits.
    var applicabilityLabel: String {
        isOfficial ? String(localized: "海外服务器") : String(localized: "国内服务器")
    }
}

struct MirrorSnapshot: Equatable, Sendable {
    var aptSource: String
    var pipIndex: String
    var npmRegistry: String
    var dockerMirrors: String
    var capturedAt = Date()
}

// MARK: - Shell & PATH

struct ShellInfo: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isLogin: Bool
}

struct PathCandidate: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var exists: Bool
    var inPath: Bool

    /// Needs attention: the directory exists but isn't on PATH.
    var needsFix: Bool { exists && !inPath }
}

struct ShellPathSnapshot: Equatable, Sendable {
    var loginShell: String
    var currentPath: String
    var shells: [ShellInfo]
    var candidates: [PathCandidate]
    var rcFileForLoginShell: String
    /// Whether `~/.oh-my-zsh` exists — drives the install button's installed state.
    var ohMyZshInstalled: Bool = false
    /// oh-my-zsh custom plugins present on the server (git-clone plugins by their
    /// custom-plugin dir; package plugins like autojump by their binary on PATH).
    var zshPluginsInstalled: Set<String> = []
    /// Plugin ids currently listed in the `~/.zshrc` `plugins=(...)` line.
    var zshPluginsEnabled: Set<String> = []
    var capturedAt = Date()
}

/// A curated zsh enhancement (oh-my-zsh custom plugin or distro package) that
/// OpsDeck can install + enable in `~/.zshrc` in one runbook. `id` is the exact
/// token written into the `plugins=(...)` line.
struct ZshPluginDef: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// oh-my-zsh custom plugin — `git clone`d into `$ZSH_CUSTOM/plugins/<id>`.
        /// `github` is the official remote; `gitee` the mainland mirror.
        case gitClone(github: String, gitee: String)
        /// Distro package (needs sudo); the omz plugin just sources it.
        case package(String)
    }
    let id: String
    let name: String
    let detail: String
    let source: Source
    let recommended: Bool
    /// Package-backed plugins need root to install; git-clone plugins are user-level.
    var needsSudo: Bool { if case .package = source { return true } else { return false } }
}

// MARK: - Cron / 定时任务

struct CronJob: Identifiable, Equatable, Sendable {
    var id = UUID()
    var source: String
    var line: String
    var enabled: Bool = true
}

struct CronSnapshot: Equatable, Sendable {
    var jobs: [CronJob]
    var capturedAt = Date()
}

struct DeploymentTemplate: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String
    var kind: RunbookKind
    var steps: [RunbookStep]
}

/// A curated "deployment recipe": a named bundle of installer-catalog tools the
/// user can review and check/uncheck, then install in one runbook. Items are
/// references to `ToolDefinition` ids so the whole installer pipeline (deps,
/// preflight, already-installed detection, source-mirror fallback) is reused.
struct DeploymentRecipe: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String
    var systemImage: String
    var items: [RecipeItem]
}

struct RecipeItem: Identifiable, Equatable, Sendable {
    /// A `ToolDefinition.id` from the installer catalog.
    var toolID: String
    /// Recommended items are pre-checked; optional ones start unchecked.
    var recommended: Bool
    var id: String { toolID }
}

enum AuditSeverity: String, CaseIterable, Sendable {
    case safe
    case warning
    case danger

    var displayName: String {
        switch self {
        case .safe:
            return String(localized: "安全")
        case .warning:
            return String(localized: "警告")
        case .danger:
            return String(localized: "危险")
        }
    }
}

struct AuditFinding: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var severity: AuditSeverity
    var evidence: String
    var fixPlan: RunbookPlan?
}
