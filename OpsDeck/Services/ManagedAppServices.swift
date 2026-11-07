import Foundation

// MARK: - Firewall (UFW / firewalld)

actor FirewallService {
    func collect(profile: ServerProfileSnapshot?, config: SSHConnectionConfig, sshService: SSHService) async throws -> FirewallSnapshot {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let command = """
        if command -v ufw >/dev/null 2>&1; then
          echo 'FW=ufw'
          \(sudo)ufw status verbose 2>&1
          echo '===ADDED==='
          \(sudo)ufw show added 2>/dev/null || true
          echo '===PING==='
          cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo 0
        elif command -v firewall-cmd >/dev/null 2>&1; then
          echo 'FW=firewalld'
          echo "STATE=$(firewall-cmd --state 2>&1)"
          \(sudo)firewall-cmd --list-all 2>&1
        else
          echo 'FW=none'
        fi
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 64 * 1024)
        return parse(result.stdout)
    }

    private func parse(_ output: String) -> FirewallSnapshot {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var kind: FirewallKind = .none
        var active = false
        var pingBlocked = false
        var rules: [FirewallRule] = []
        var detailLines: [String] = []

        enum Section { case main, added, ping }
        var section: Section = .main

        for line in lines {
            if line.hasPrefix("FW=") {
                switch String(line.dropFirst(3)) {
                case "ufw": kind = .ufw
                case "firewalld": kind = .firewalld
                default: kind = .none
                }
                continue
            }
            switch line.trimmingCharacters(in: .whitespaces) {
            case "===ADDED===": section = .added; continue
            case "===PING===": section = .ping; continue
            default: break
            }
            switch section {
            case .main:
                if line.hasPrefix("STATE=") { active = line.contains("running"); continue }
                if line.localizedCaseInsensitiveContains("Status: active") { active = true }
                detailLines.append(line)
            case .added:
                if let rule = Self.parseAddedRule(line) { rules.append(rule) }
            case .ping:
                if line.trimmingCharacters(in: .whitespaces) == "1" { pingBlocked = true }
            }
        }
        let detail = detailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return FirewallSnapshot(
            kind: kind,
            active: active,
            pingBlocked: pingBlocked,
            rules: rules,
            detail: detail.isEmpty ? String(localized: "（无规则或未启用）") : detail
        )
    }

    /// Parse one `ufw show added` line, e.g. `ufw allow 22/tcp` or
    /// `ufw deny from 203.0.113.7 to any port 19990:19995 proto tcp comment 'x'`.
    /// number is 0 (queued, unnumbered); `raw` holds the delete spec (no comment).
    static func parseAddedRule(_ line: String) -> FirewallRule? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("ufw ") else { return nil }
        var rest = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        var comment = ""
        if let r = rest.range(of: " comment ") {
            comment = String(rest[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            rest = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let spec = rest // exact ufw spec for `ufw delete <spec>`
        var tokens = rest.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        let actionRaw = tokens.removeFirst().lowercased()
        guard ["allow", "deny", "reject", "limit"].contains(actionRaw) else { return nil }
        let action: FirewallAction = (actionRaw == "deny" || actionRaw == "reject") ? .deny : .allow
        var direction: FirewallDirection = .inbound
        if tokens.first == "in" { direction = .inbound; tokens.removeFirst() }
        else if tokens.first == "out" { direction = .outbound; tokens.removeFirst() }
        var source = "Anywhere"
        var port = ""
        var proto = "any"
        if let i = tokens.firstIndex(of: "from"), i + 1 < tokens.count { source = tokens[i + 1] }
        if let i = tokens.firstIndex(of: "port"), i + 1 < tokens.count { port = tokens[i + 1] }
        if let i = tokens.firstIndex(of: "proto"), i + 1 < tokens.count { proto = tokens[i + 1] }
        // Simple form: `allow 22/tcp` — first token is PORT[/proto] when no keywords.
        if port.isEmpty, let first = tokens.first, !["from", "to", "any", "port", "proto"].contains(first) {
            if let slash = first.lastIndex(of: "/") {
                port = String(first[..<slash]); proto = String(first[first.index(after: slash)...])
            } else { port = first }
        }
        return FirewallRule(number: 0, action: action, direction: direction, proto: proto, port: port, source: source.isEmpty ? "Anywhere" : source, comment: comment, isV6: false, raw: spec)
    }

    /// Enable/disable the firewall. On ENABLE we ALWAYS allow the SSH port we're
    /// currently connected through FIRST — enabling UFW with its default
    /// deny-incoming policy and no SSH rule is the classic way to lock yourself
    /// out of the server. `sshPort` is the port OpsDeck's live session uses.
    nonisolated func togglePlan(enable: Bool, sshPort: Int, kind: FirewallKind, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let steps: [RunbookStep]
        switch kind {
        case .ufw:
            steps = enable
                ? [
                    RunbookStep(title: String(localized: "放行当前 SSH 端口 \(sshPort)"), command: "\(sudo)ufw allow \(sshPort)/tcp comment 'SSH (OpsDeck 自动放行)'"),
                    RunbookStep(title: String(localized: "启用 UFW"), command: "\(sudo)ufw --force enable"),
                    RunbookStep(title: String(localized: "查看状态"), command: "\(sudo)ufw status verbose")
                ]
                : [RunbookStep(title: String(localized: "禁用 UFW"), command: "\(sudo)ufw disable")]
        case .firewalld:
            steps = enable
                ? [
                    RunbookStep(title: String(localized: "放行当前 SSH 端口 \(sshPort)"), command: "\(sudo)firewall-cmd --permanent --add-port=\(sshPort)/tcp"),
                    RunbookStep(title: String(localized: "启用 firewalld"), command: OpsShell.systemdEnableAndStart(serviceName: "firewalld", sudo: sudo)),
                    RunbookStep(title: String(localized: "重载规则"), command: "\(sudo)firewall-cmd --reload"),
                    RunbookStep(title: String(localized: "查看状态"), command: "firewall-cmd --state")
                ]
                : [RunbookStep(title: String(localized: "禁用 firewalld"), command: OpsShell.systemdDisableAndStop(serviceName: "firewalld", sudo: sudo))]
        case .none:
            steps = [RunbookStep(title: String(localized: "无防火墙"), command: "echo \(OpsShell.quote(String(localized: "未检测到 UFW/firewalld。"))); exit 1")]
        }
        return RunbookPlan(
            kind: .audit,
            title: enable ? String(localized: "启用防火墙") : String(localized: "禁用防火墙"),
            summary: enable
                ? String(localized: "启用 \(kind.displayName)。已自动放行当前 SSH 端口 \(sshPort)/tcp，避免把自己锁在门外。⚠️ 启用后除已放行的端口外，其他入站连接（网站 80/443、数据库端口等）都会被拦截——请确认它们已在规则里放行。")
                : String(localized: "禁用 \(kind.displayName)。禁用后服务器将不再有防火墙保护，所有入站端口都会开放。"),
            targetDescription: kind.displayName,
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: enable ? String(localized: "可再次禁用。") : String(localized: "可再次启用。"),
            steps: steps
        )
    }

    /// Per-port add steps (no trailing status/reload) — shared by add and edit.
    private nonisolated func addRuleSteps(action: FirewallAction, direction: FirewallDirection, proto: String, source: String, comment: String, portTokens: [String], kind: FirewallKind, sudo: String) -> [RunbookStep] {
        let src = source.trimmingCharacters(in: .whitespaces)
        let hasSource = !src.isEmpty && src.lowercased() != "anywhere"
        let cleanComment = comment.trimmingCharacters(in: .whitespaces)
        let act = action.rawValue // allow / deny
        var steps: [RunbookStep] = []
        switch kind {
        case .ufw:
            for token in portTokens {
                let ufwPort = token.replacingOccurrences(of: "-", with: ":") // accept 6000-6100 as a range too
                var cmd: String
                if !hasSource && direction == .inbound {
                    if proto == "tcp" || proto == "udp" {
                        cmd = "\(sudo)ufw \(act) \(OpsShell.quote("\(ufwPort)/\(proto)"))"
                    } else {
                        cmd = "\(sudo)ufw \(act) \(OpsShell.quote(ufwPort))"
                    }
                } else {
                    var c = "\(sudo)ufw \(act) \(direction.rawValue)"
                    if hasSource { c += " from \(OpsShell.quote(src))" }
                    c += " to any port \(OpsShell.quote(ufwPort))"
                    if proto == "tcp" || proto == "udp" { c += " proto \(proto)" }
                    cmd = c
                }
                if !cleanComment.isEmpty { cmd += " comment \(OpsShell.quote(cleanComment))" }
                steps.append(RunbookStep(title: String(localized: "添加规则 \(token)"), command: cmd))
            }
        case .firewalld:
            for token in portTokens {
                let fwProto = (proto == "tcp" || proto == "udp") ? proto : "tcp"
                let fwPort = token.replacingOccurrences(of: ":", with: "-")
                let verb = action == .allow ? "accept" : "drop"
                let srcClause = hasSource ? "source address=\(OpsShell.quote(src)) " : ""
                let rich = "rule family=\"ipv4\" \(srcClause)port port=\"\(fwPort)\" protocol=\"\(fwProto)\" \(verb)"
                steps.append(RunbookStep(title: String(localized: "添加规则 \(token)"), command: "\(sudo)firewall-cmd --permanent --add-rich-rule=\(OpsShell.quote(rich))"))
            }
        case .none:
            steps = [RunbookStep(title: String(localized: "无防火墙"), command: "echo \(OpsShell.quote(String(localized: "未检测到 UFW/firewalld。"))); exit 1")]
        }
        return steps
    }

    private nonisolated func refreshStep(kind: FirewallKind, sudo: String) -> RunbookStep {
        kind == .firewalld
            ? RunbookStep(title: String(localized: "重载规则"), command: "\(sudo)firewall-cmd --reload")
            : RunbookStep(title: String(localized: "查看规则"), command: "\(sudo)ufw status numbered")
    }

    /// Rich rule: 放行/拒绝 + 入/出站 + 协议 + 端口(单个/范围/多个逗号分隔) + 来源 IP/CIDR + 备注。
    nonisolated func addRulePlan(action: FirewallAction, direction: FirewallDirection, proto: String, ports: String, source: String, comment: String, kind: FirewallKind, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let src = source.trimmingCharacters(in: .whitespaces)
        let hasSource = !src.isEmpty && src.lowercased() != "anywhere"
        let portTokens = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var steps = addRuleSteps(action: action, direction: direction, proto: proto, source: source, comment: comment, portTokens: portTokens, kind: kind, sudo: sudo)
        if kind != .none { steps.append(refreshStep(kind: kind, sudo: sudo)) }
        return RunbookPlan(
            kind: .audit,
            title: "\(action.displayName) \(ports)\(proto == "tcp" || proto == "udp" ? "/\(proto)" : "")",
            summary: String(localized: "在 \(kind.displayName) 中添加\(action.displayName)规则（\(direction.displayName)\(hasSource ? String(localized: "，来源 \(src)") : "")）。放行会对外暴露端口，拒绝会切断相关访问，请确认。"),
            targetDescription: ports,
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可在规则列表中删除该规则。"),
            steps: steps
        )
    }

    /// Edit a rule = delete the old one + add the new one (UFW has no in-place edit;
    /// 宝塔/aaPanel do the same under the hood). UFW only; firewalld edits are asked
    /// to delete-then-add manually.
    nonisolated func editRulePlan(old: FirewallRule, action: FirewallAction, direction: FirewallDirection, proto: String, ports: String, source: String, comment: String, kind: FirewallKind, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        guard kind == .ufw else {
            return RunbookPlan(kind: .audit, title: String(localized: "编辑规则"), summary: String(localized: "firewalld 暂不支持一键编辑，请删除旧规则后重新添加。"), targetDescription: ports, risk: .medium, requiresSudo: !sudo.isEmpty, backupDescription: nil, rollbackDescription: nil, steps: [RunbookStep(title: String(localized: "不支持"), command: "echo \(OpsShell.quote(String(localized: "firewalld 请删旧建新"))); exit 1")])
        }
        let portTokens = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var steps: [RunbookStep] = []
        // 1. delete the old rule by spec (removes both its v4 and v6 lines).
        steps.append(RunbookStep(title: String(localized: "删除旧规则"), command: "\(sudo)ufw delete \(old.raw)"))
        // 2. add the new rule, then re-read.
        steps.append(contentsOf: addRuleSteps(action: action, direction: direction, proto: proto, source: source, comment: comment, portTokens: portTokens, kind: kind, sudo: sudo))
        steps.append(refreshStep(kind: kind, sudo: sudo))
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "编辑防火墙规则"),
            summary: String(localized: "UFW 无法原地改规则，将先删除旧规则再按新参数添加（\(action.displayName) \(ports)）。"),
            targetDescription: ports,
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可再次编辑或删除。"),
            steps: steps
        )
    }

    /// Delete a rule by its ufw spec (from `ufw show added`). `ufw delete <spec>`
    /// removes both the v4 and v6 lines, unlike delete-by-number.
    nonisolated func deleteRuleSpecPlan(spec: String, kind: FirewallKind, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let steps: [RunbookStep]
        switch kind {
        case .ufw:
            steps = [
                RunbookStep(title: String(localized: "删除规则"), command: "\(sudo)ufw delete \(spec)"),
                RunbookStep(title: String(localized: "查看待生效规则"), command: "\(sudo)ufw show added")
            ]
        default:
            steps = [RunbookStep(title: String(localized: "不支持"), command: "echo \(OpsShell.quote(String(localized: "仅 UFW 支持按规则删除待生效规则"))); exit 1")]
        }
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "删除待生效规则"),
            summary: String(localized: "删除尚未生效的规则「\(spec)」。"),
            targetDescription: spec,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可重新添加同样的规则。"),
            steps: steps
        )
    }

    /// 禁ping：通过 net.ipv4.icmp_echo_ignore_all 丢弃 ICMP echo，并持久化到 sysctl.d。
    nonisolated func setPingBlockedPlan(block: Bool, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let file = "/etc/sysctl.d/99-opsdeck-noping.conf"
        let steps: [RunbookStep]
        if block {
            steps = [
                RunbookStep(title: String(localized: "立即禁ping"), command: "\(sudo)sysctl -w net.ipv4.icmp_echo_ignore_all=1"),
                RunbookStep(title: String(localized: "持久化"), command: "printf 'net.ipv4.icmp_echo_ignore_all = 1\\n' | \(sudo)tee \(file) >/dev/null")
            ]
        } else {
            steps = [
                RunbookStep(title: String(localized: "恢复响应 ping"), command: "\(sudo)sysctl -w net.ipv4.icmp_echo_ignore_all=0"),
                RunbookStep(title: String(localized: "移除持久化"), command: "\(sudo)rm -f \(file)")
            ]
        }
        return RunbookPlan(
            kind: .audit,
            title: block ? String(localized: "禁ping") : String(localized: "恢复 ping 响应"),
            summary: block ? String(localized: "丢弃 ICMP echo 请求，服务器将不再响应 ping（探测更难，但监控类 ping 也会失败）。") : String(localized: "恢复对 ping 的正常响应。"),
            targetDescription: "ICMP echo",
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: block ? String(localized: "可再次恢复 ping 响应。") : String(localized: "可再次禁ping。"),
            steps: steps
        )
    }
}

// MARK: - PM2

actor PM2Service {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> PM2Snapshot {
        let command = "if command -v pm2 >/dev/null 2>&1; then pm2 jlist 2>/dev/null; else echo 'PM2_MISSING'; fi"
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 256 * 1024)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.contains("PM2_MISSING") || out.isEmpty {
            return PM2Snapshot(installed: !out.contains("PM2_MISSING"), processes: [])
        }
        return parse(out)
    }

    private func parse(_ json: String) -> PM2Snapshot {
        guard let start = json.firstIndex(of: "["),
              let data = String(json[start...]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return PM2Snapshot(installed: true, processes: [])
        }
        let processes: [PM2Process] = array.map { obj in
            let env = obj["pm2_env"] as? [String: Any]
            let monit = obj["monit"] as? [String: Any]
            let name = obj["name"] as? String ?? "?"
            let pmID = obj["pm_id"] as? Int
            let status = env?["status"] as? String ?? "unknown"
            let restarts = (env?["restart_time"] as? Int).map(String.init) ?? "0"
            let cpu = (monit?["cpu"] as? Int).map { "\($0)%" } ?? (monit?["cpu"] as? Double).map { "\(Int($0))%" } ?? "—"
            let memBytes = (monit?["memory"] as? Int) ?? 0
            let mem = memBytes > 0 ? String(format: "%.0f MB", Double(memBytes) / 1024 / 1024) : "—"
            return PM2Process(
                id: pmID.map(String.init) ?? name,
                name: name,
                status: status,
                cpu: cpu,
                memory: mem,
                restarts: restarts
            )
        }
        return PM2Snapshot(installed: true, processes: processes)
    }

    nonisolated func actionPlan(_ action: ServiceAction, process: PM2Process) -> RunbookPlan {
        let name = OpsShell.quote(process.name)
        let verb: String
        let risk: RunbookRisk
        switch action {
        case .start: verb = "start"; risk = .medium
        case .stop: verb = "stop"; risk = .high
        case .restart, .reload: verb = "restart"; risk = .high
        default: verb = "restart"; risk = .high
        }
        return RunbookPlan(
            kind: .deployment,
            title: String(localized: "\(action.displayName) PM2 进程 \(process.name)"),
            summary: String(localized: "通过 pm2 \(verb) 操作该进程。"),
            targetDescription: process.name,
            risk: risk,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "可执行相反的 pm2 动作恢复。"),
            steps: [
                RunbookStep(title: String(localized: "\(action.displayName)进程"), command: "pm2 \(verb) \(name)"),
                RunbookStep(title: String(localized: "查看进程列表"), command: "pm2 list")
            ]
        )
    }

    nonisolated func deletePlan(process: PM2Process) -> RunbookPlan {
        let name = OpsShell.quote(process.name)
        return RunbookPlan(
            kind: .deployment,
            title: String(localized: "从 PM2 移除 \(process.name)"),
            summary: String(localized: "pm2 delete 会从 PM2 进程表移除该应用（不删除代码文件）。"),
            targetDescription: process.name,
            risk: .high,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "需要重新 pm2 start 启动该应用。"),
            steps: [
                RunbookStep(title: String(localized: "移除进程"), command: "pm2 delete \(name)"),
                RunbookStep(title: String(localized: "查看进程列表"), command: "pm2 list")
            ]
        )
    }

    nonisolated func startApplicationPlan(name: String, scriptPath: String, workingDirectory: String) -> RunbookPlan {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanScript = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = cleanDirectory.isEmpty ? "" : "cd \(OpsShell.quote(cleanDirectory)) && "
        return RunbookPlan(
            kind: .deployment,
            title: String(localized: "用 PM2 启动 \(cleanName)"),
            summary: String(localized: "启动应用并保存当前 PM2 进程列表。不会自动配置开机启动。"),
            targetDescription: cleanScript,
            risk: .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "可执行 pm2 delete \(cleanName) 从进程列表移除。"),
            steps: [
                RunbookStep(title: String(localized: "检查脚本"), command: "test -f \(OpsShell.quote(cleanScript)) || { echo 'Script not found'; exit 1; }"),
                RunbookStep(title: String(localized: "启动应用"), command: "\(prefix)pm2 start \(OpsShell.quote(cleanScript)) --name \(OpsShell.quote(cleanName))"),
                RunbookStep(title: String(localized: "保存进程列表"), command: "pm2 save"),
                RunbookStep(title: String(localized: "验证进程"), command: "pm2 describe \(OpsShell.quote(cleanName))")
            ]
        )
    }
}

// MARK: - Certbot / SSL

actor CertbotService {
    func collect(profile: ServerProfileSnapshot?, config: SSHConnectionConfig, sshService: SSHService) async throws -> CertbotSnapshot {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let command = "if command -v certbot >/dev/null 2>&1; then \(sudo)certbot certificates 2>&1; else echo 'CERTBOT_MISSING'; fi"
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 64 * 1024)
        let out = result.stdout
        if out.contains("CERTBOT_MISSING") {
            return CertbotSnapshot(installed: false, certificates: [])
        }
        return CertbotSnapshot(installed: true, certificates: parse(out))
    }

    private func parse(_ output: String) -> [CertInfo] {
        var certs: [CertInfo] = []
        var name: String?
        var domains: String?
        var expiry: String?
        var validDays: String?

        func flush() {
            if let name {
                certs.append(CertInfo(
                    id: name,
                    name: name,
                    domains: domains ?? "—",
                    expiry: expiry ?? "—",
                    validDays: validDays
                ))
            }
            name = nil; domains = nil; expiry = nil; validDays = nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Certificate Name:") {
                flush()
                name = line.replacingOccurrences(of: "Certificate Name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Domains:") {
                domains = line.replacingOccurrences(of: "Domains:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Expiry Date:") {
                let value = line.replacingOccurrences(of: "Expiry Date:", with: "").trimmingCharacters(in: .whitespaces)
                expiry = value
                if let range = value.range(of: "VALID: "), let daysRange = value.range(of: " day", range: range.upperBound..<value.endIndex) {
                    validDays = String(value[range.upperBound..<daysRange.lowerBound])
                }
            }
        }
        flush()
        return certs
    }

    /// Obtain a new Let's Encrypt certificate. Requires: the domain's DNS A
    /// record already points to this server, and port 80 reachable. `staging`
    /// uses Let's Encrypt's test environment (no rate limits, but not trusted).
    nonisolated func obtainPlan(domains: [String], method: CertbotMethod, email: String?, staging: Bool, cloudflareToken: String?, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let domainArgs = domains.map { "-d \(OpsShell.quote($0))" }.joined(separator: " ")
        let emailArg: String = {
            if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
                return "-m \(OpsShell.quote(email))"
            }
            return "--register-unsafely-without-email"
        }()
        let stagingArg = staging ? "--test-cert" : ""
        let primary = domains.first ?? "?"
        var steps: [RunbookStep]

        switch method {
        case .nginx:
            steps = [RunbookStep(title: String(localized: "签发证书"), command: "\(sudo)certbot --nginx \(domainArgs) --redirect --non-interactive --agree-tos \(emailArg) \(stagingArg) 2>&1")]
        case .standalone:
            steps = [RunbookStep(title: String(localized: "签发证书"), command: "\(sudo)certbot certonly --standalone \(domainArgs) --non-interactive --agree-tos \(emailArg) \(stagingArg) 2>&1")]
        case .dnsCloudflare:
            let cred = "/etc/letsencrypt/cloudflare.ini"
            let token = cloudflareToken?.trimmingCharacters(in: .whitespaces) ?? ""
            steps = [
                RunbookStep(
                    title: String(localized: "安装 Cloudflare DNS 插件"),
                    command: OpsShell.unattendedAptInstall(
                        packages: ["python3-certbot-dns-cloudflare"],
                        sudo: sudo
                    )
                ),
                RunbookStep(title: String(localized: "写入 API 凭据（600 权限）"), command: "\(sudo)mkdir -p /etc/letsencrypt && printf 'dns_cloudflare_api_token = %s\\n' \(OpsShell.quote(token)) | \(sudo)tee \(cred) >/dev/null && \(sudo)chmod 600 \(cred) && echo \(OpsShell.quote(String(localized: "凭据已写入")))"),
                RunbookStep(title: String(localized: "签发证书（DNS 验证）"), command: "\(sudo)certbot certonly --dns-cloudflare --dns-cloudflare-credentials \(cred) --dns-cloudflare-propagation-seconds 30 \(domainArgs) --non-interactive --agree-tos \(emailArg) \(stagingArg) 2>&1")
            ]
        }

        let precondition = method.usesHTTP
            ? String(localized: "前置：域名 DNS 已指向本机公网 IP、80 端口对外开放。⚠️ 大陆未备案服务器会被云厂商拦截 80 端口，请改用 DNS 验证。")
            : String(localized: "前置：域名托管在 Cloudflare、已建好 API Token（权限 Zone.DNS:Edit）。不走 80 端口，大陆未备案也可签。")
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "申请证书 \(primary)\(staging ? String(localized: "（测试）") : "")"),
            summary: String(localized: "为 \(domains.formatted(.list(type: .and, width: .narrow))) 申请 Let's Encrypt 证书。\(method.detail)。\(precondition)\(staging ? String(localized: " 测试环境不受速率限制，但浏览器不信任。") : "")"),
            targetDescription: primary,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: method == .nginx ? String(localized: "会修改 Nginx 配置（certbot 自动备份）。") : nil,
            rollbackDescription: String(localized: "可用 certbot delete --cert-name \(primary) 删除。"),
            steps: steps
        )
    }

    nonisolated func renewPlan(certName: String?, dryRun: Bool, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        var command = "\(sudo)certbot renew"
        if let certName { command += " --cert-name \(OpsShell.quote(certName))" }
        if dryRun { command += " --dry-run" }
        let target = certName ?? String(localized: "全部证书")
        return RunbookPlan(
            kind: .audit,
            title: dryRun ? String(localized: "测试续期 \(target)") : String(localized: "续期 \(target)"),
            summary: dryRun
                ? String(localized: "以 --dry-run 演练续期，不会真正签发或改动证书。")
                : String(localized: "执行 certbot renew 续期证书；仅在临近到期时才会真正续签，通常安全。"),
            targetDescription: target,
            risk: dryRun ? .readOnly : .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: dryRun ? nil : String(localized: "certbot 会保留旧证书归档，可回滚。"),
            steps: [RunbookStep(title: dryRun ? String(localized: "演练续期") : String(localized: "续期证书"), command: command)]
        )
    }
}

// MARK: - Caddy

actor CaddyService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> CaddySnapshot {
        let command = """
        if ! command -v caddy >/dev/null 2>&1; then
          echo 'CADDY=missing'
          exit 0
        fi
        echo 'CADDY=installed'
        echo "VERSION=$(caddy version 2>/dev/null | head -n1)"
        for p in /etc/caddy/Caddyfile /etc/caddy/caddy.json /etc/caddy/conf.d; do
          [ -e "$p" ] && { echo "CONFIG=$p"; break; }
        done
        active="$(systemctl is-active caddy 2>/dev/null || true)"
        if [ "$active" != "active" ] && pgrep -x caddy >/dev/null 2>&1; then active=active; fi
        echo "ACTIVE=$active"
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 16 * 1024)
        var installed = false
        var version: String?
        var configPath: String?
        var active = false
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line == "CADDY=installed" { installed = true }
            else if line.hasPrefix("VERSION=") { version = String(line.dropFirst(8)).nilIfEmpty }
            else if line.hasPrefix("CONFIG=") { configPath = String(line.dropFirst(7)).nilIfEmpty }
            else if line.hasPrefix("ACTIVE=") { active = String(line.dropFirst(7)) == "active" }
        }
        return CaddySnapshot(installed: installed, version: version, configPath: configPath, active: active)
    }

    // The caddyfile adapter only applies to Caddyfile-format configs; a JSON
    // config must be validated/loaded WITHOUT it.
    private nonisolated static func caddyAdapter(for path: String) -> String {
        path.hasSuffix(".json") ? "" : " --adapter caddyfile"
    }

    nonisolated func validatePlan(configPath: String?) -> RunbookPlan {
        let path = configPath ?? "/etc/caddy/Caddyfile"
        return RunbookPlan(
            kind: .nginx,
            title: String(localized: "校验 Caddy 配置"),
            summary: String(localized: "运行 caddy validate 检查配置语法，不重载、不改动文件。"),
            targetDescription: path,
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [RunbookStep(title: String(localized: "校验配置"), command: "caddy validate --config \(OpsShell.quote(path))\(Self.caddyAdapter(for: path)) 2>&1")]
        )
    }

    nonisolated func reloadPlan(configPath: String?, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let path = configPath ?? "/etc/caddy/Caddyfile"
        return RunbookPlan(
            kind: .nginx,
            title: String(localized: "重载 Caddy"),
            summary: String(localized: "先 caddy validate 校验，通过后 reload（不中断现有连接）。"),
            targetDescription: path,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: String(localized: "编辑保存配置时应先备份。"),
            rollbackDescription: String(localized: "恢复备份后重新 reload。"),
            steps: [
                RunbookStep(title: String(localized: "校验配置"), command: "caddy validate --config \(OpsShell.quote(path))\(Self.caddyAdapter(for: path))"),
                RunbookStep(title: String(localized: "重载 Caddy"), command: "\(sudo)systemctl reload caddy")
            ]
        )
    }
}

// MARK: - Fail2ban

actor Fail2banService {
    func collect(profile: ServerProfileSnapshot?, config: SSHConnectionConfig, sshService: SSHService) async throws -> Fail2banSnapshot {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let command = """
        if ! command -v fail2ban-client >/dev/null 2>&1; then
          echo 'F2B=missing'
          exit 0
        fi
        echo 'F2B=installed'
        active="$(systemctl is-active fail2ban 2>/dev/null || true)"
        if [ "$active" != "active" ] && pgrep -x fail2ban-server >/dev/null 2>&1; then active=active; fi
        echo "ACTIVE=$active"
        jails="$(\(sudo)fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
        for j in $jails; do
          j="$(echo "$j" | tr -d '[:space:]')"
          [ -z "$j" ] && continue
          info="$(\(sudo)fail2ban-client status "$j" 2>/dev/null)"
          cb="$(printf '%s' "$info" | sed -n 's/.*Currently banned:[[:space:]]*\\([0-9]*\\).*/\\1/p' | head -n1)"
          tb="$(printf '%s' "$info" | sed -n 's/.*Total banned:[[:space:]]*\\([0-9]*\\).*/\\1/p' | head -n1)"
          ips="$(printf '%s' "$info" | sed -n 's/.*Banned IP list:[[:space:]]*//p' | head -n1)"
          printf 'JAIL=%s|%s|%s|%s\\n' "$j" "$cb" "$tb" "$ips"
        done
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 32 * 1024)
        var installed = false
        var active = false
        var jails: [Fail2banJail] = []
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line == "F2B=installed" { installed = true }
            else if line.hasPrefix("ACTIVE=") { active = String(line.dropFirst(7)) == "active" }
            else if line.hasPrefix("JAIL=") {
                let parts = String(line.dropFirst(5)).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let name = parts.first else { continue }
                let ips = parts.count > 3 ? parts[3].split(separator: " ").map(String.init).filter { !$0.isEmpty } : []
                jails.append(Fail2banJail(
                    name: name,
                    currentlyBanned: parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                    totalBanned: parts.count > 2 ? Int(parts[2]) ?? 0 : 0,
                    bannedIPs: ips
                ))
            }
        }
        return Fail2banSnapshot(installed: installed, active: active, jails: jails)
    }

    nonisolated func unbanPlan(jail: String, ip: String, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "解封 \(ip)"),
            summary: String(localized: "在 fail2ban 的 \(jail) 中解除对该 IP 的封禁。"),
            targetDescription: "\(jail) · \(ip)",
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "该 IP 再次触发规则会被重新封禁。"),
            steps: [
                RunbookStep(title: String(localized: "解封 IP"), command: "\(sudo)fail2ban-client set \(OpsShell.quote(jail)) unbanip \(OpsShell.quote(ip))"),
                RunbookStep(title: String(localized: "查看 jail 状态"), command: "\(sudo)fail2ban-client status \(OpsShell.quote(jail))")
            ]
        )
    }
}

// MARK: - Cron / 定时任务

actor CronService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> CronSnapshot {
        let command = """
        crontab -l 2>/dev/null | while IFS= read -r l; do
          case "$l" in
            '# OpsDeck disabled: '*) printf 'CRON_DISABLED=用户\\t%s\\n' "${l#\\# OpsDeck disabled: }" ;;
            ''|'#'*) ;;
            *) printf 'CRON=用户\\t%s\\n' "$l" ;;
          esac
        done
        for f in /etc/crontab /etc/cron.d/*; do
          [ -f "$f" ] || continue
          base="$(basename "$f")"
          grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | while IFS= read -r l; do
            printf 'CRON=%s\\t%s\\n' "$base" "$l"
          done
        done
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 64 * 1024)
        var jobs: [CronJob] = []
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let enabled: Bool
            let payload: String
            if line.hasPrefix("CRON=") {
                enabled = true
                payload = String(line.dropFirst(5))
            } else if line.hasPrefix("CRON_DISABLED=") {
                enabled = false
                payload = String(line.dropFirst(14))
            } else {
                continue
            }
            let parts = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            jobs.append(CronJob(source: parts[0], line: parts[1].trimmingCharacters(in: .whitespaces), enabled: enabled))
        }
        return CronSnapshot(jobs: jobs)
    }

    nonisolated func addUserJobPlan(schedule: String, command: String, label: String) -> RunbookPlan {
        let line = "\(schedule.trimmingCharacters(in: .whitespacesAndNewlines)) \(command.trimmingCharacters(in: .whitespacesAndNewlines))"
        let marker = "# OpsDeck: \(label.trimmingCharacters(in: .whitespacesAndNewlines))"
        let payload = "\(marker)\n\(line)"
        let install = "tmp=$(mktemp); crontab -l 2>/dev/null > \"$tmp\" || true; printf '%s\\n' \(OpsShell.quote(payload)) >> \"$tmp\"; crontab \"$tmp\"; rm -f \"$tmp\""
        return RunbookPlan(
            kind: .deployment,
            title: String(localized: "新增用户定时任务"),
            summary: String(localized: "向当前 SSH 用户的 crontab 追加一条带 OpsDeck 标记的任务。"),
            targetDescription: line,
            risk: .medium,
            requiresSudo: false,
            backupDescription: String(localized: "执行前会把原 crontab 输出到运行日志。"),
            rollbackDescription: String(localized: "按运行日志中的原内容恢复 crontab，或删除对应 OpsDeck 标记和下一行。"),
            steps: [
                RunbookStep(title: String(localized: "备份当前 crontab"), command: "crontab -l 2>/dev/null || true"),
                RunbookStep(title: String(localized: "写入定时任务"), command: install),
                RunbookStep(title: String(localized: "验证 crontab"), command: "crontab -l")
            ]
        )
    }

    nonisolated func editUserJobPlan(job: CronJob, schedule: String, command: String) -> RunbookPlan {
        let replacement = "\(schedule.trimmingCharacters(in: .whitespacesAndNewlines)) \(command.trimmingCharacters(in: .whitespacesAndNewlines))"
        return rewriteUserJobPlan(
            title: String(localized: "编辑用户定时任务"),
            original: storedLine(for: job),
            replacement: replacement,
            summary: String(localized: "只替换与所选任务完全一致的一行；若远端内容已变化则停止，不覆盖其他任务。"),
            risk: .medium
        )
    }

    nonisolated func setUserJobEnabledPlan(job: CronJob, enabled: Bool) -> RunbookPlan {
        rewriteUserJobPlan(
            title: enabled ? String(localized: "启用用户定时任务") : String(localized: "禁用用户定时任务"),
            original: storedLine(for: job),
            replacement: enabled ? job.line : "# OpsDeck disabled: \(job.line)",
            summary: enabled
                ? String(localized: "移除 OpsDeck 禁用标记并恢复该任务。")
                : String(localized: "通过注释保留原任务，便于随时恢复。"),
            risk: .medium
        )
    }

    nonisolated func deleteUserJobPlan(job: CronJob) -> RunbookPlan {
        rewriteUserJobPlan(
            title: String(localized: "删除用户定时任务"),
            original: storedLine(for: job),
            replacement: nil,
            summary: String(localized: "从当前 SSH 用户的 crontab 删除所选行；其他任务保持不变。"),
            risk: .high
        )
    }

    private nonisolated func storedLine(for job: CronJob) -> String {
        job.enabled ? job.line : "# OpsDeck disabled: \(job.line)"
    }

    private nonisolated func rewriteUserJobPlan(
        title: String,
        original: String,
        replacement: String?,
        summary: String,
        risk: RunbookRisk
    ) -> RunbookPlan {
        let old = OpsShell.quote(original)
        let new = OpsShell.quote(replacement ?? "")
        let keep = replacement == nil ? "0" : "1"
        let command = """
        current=$(mktemp); candidate=$(mktemp)
        cleanup() { rm -f "$current" "$candidate"; }
        trap cleanup EXIT
        crontab -l 2>/dev/null > "$current" || true
        old=\(old); new=\(new); keep=\(keep); found=0
        : > "$candidate"
        while IFS= read -r line || [ -n "$line" ]; do
          if [ "$line" = "$old" ]; then
            found=$((found + 1))
            if [ "$keep" -eq 1 ]; then
              printf '%s\\n' "$new" >> "$candidate"
            else
              last=$(tail -n 1 "$candidate" 2>/dev/null || true)
              case "$last" in
                '# OpsDeck: '*) trimmed=$(mktemp); sed '$d' "$candidate" > "$trimmed"; mv "$trimmed" "$candidate" ;;
              esac
            fi
          else
            printf '%s\\n' "$line" >> "$candidate"
          fi
        done < "$current"
        [ "$found" -eq 1 ] || { echo "目标任务匹配数量为 $found，远端内容可能已变化，已停止"; exit 1; }
        echo '--- crontab diff ---'
        diff -u "$current" "$candidate" || true
        crontab "$candidate"
        """
        return RunbookPlan(
            kind: .deployment,
            title: title,
            summary: summary,
            targetDescription: original,
            risk: risk,
            requiresSudo: false,
            backupDescription: String(localized: "执行详情保留变更前 crontab，并输出完整 diff。"),
            rollbackDescription: String(localized: "根据执行详情中的变更前内容恢复 crontab。"),
            steps: [
                RunbookStep(title: String(localized: "备份当前 crontab"), command: "crontab -l 2>/dev/null || true"),
                RunbookStep(title: String(localized: "显示差异并应用"), command: command),
                RunbookStep(title: String(localized: "验证 crontab"), command: "crontab -l 2>/dev/null || true")
            ]
        )
    }
}

// MARK: - Mirror sources 镜像源

struct MirrorService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> MirrorSnapshot {
        // Emit stable ASCII sentinels for "empty/missing" states so the Swift layer
        // can localize them (rather than baking Chinese into the shell output).
        let command = """
        apt="$(grep -rhE '^[[:space:]]*(URIs:|deb[[:space:]])' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null | grep -oE 'https?://[^ /]+' | grep -viE 'security' | sed -E 's@https?://@@' | sort -u | head -n1)"
        echo "APT=${apt:-__UNKNOWN__}"
        pip="$(python3 -m pip config get global.index-url 2>/dev/null || pip config get global.index-url 2>/dev/null || true)"
        echo "PIP=${pip:-__PIP_DEFAULT__}"
        if command -v npm >/dev/null 2>&1; then echo "NPM=$(npm config get registry 2>/dev/null)"; else echo "NPM=__NPM_MISSING__"; fi
        if command -v docker >/dev/null 2>&1; then
          dm="$(docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null)"
          echo "DOCKER=${dm:-__DOCKER_NONE__}"
        else
          echo "DOCKER=__DOCKER_MISSING__"
        fi
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 8 * 1024)
        var apt = String(localized: "未知"), pip = String(localized: "未知"), npm = String(localized: "未知"), docker = String(localized: "未知")
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("APT=") { apt = Self.localizedMirrorValue(String(line.dropFirst(4))) }
            else if line.hasPrefix("PIP=") { pip = Self.localizedMirrorValue(String(line.dropFirst(4))) }
            else if line.hasPrefix("NPM=") { npm = Self.localizedMirrorValue(String(line.dropFirst(4))) }
            else if line.hasPrefix("DOCKER=") { docker = Self.localizedMirrorValue(String(line.dropFirst(7))) }
        }
        return MirrorSnapshot(aptSource: apt, pipIndex: pip, npmRegistry: npm, dockerMirrors: docker)
    }

    /// Maps the collect script's ASCII sentinels to localized labels; passes real
    /// values (URLs/hosts) through unchanged.
    private static func localizedMirrorValue(_ raw: String) -> String {
        switch raw {
        case "__UNKNOWN__": return String(localized: "未知")
        case "__PIP_DEFAULT__": return String(localized: "默认（官方 pypi）")
        case "__NPM_MISSING__": return String(localized: "未安装 npm")
        case "__DOCKER_NONE__": return String(localized: "未配置")
        case "__DOCKER_MISSING__": return String(localized: "未安装 docker")
        default: return raw
        }
    }

    private func aptHost(_ provider: MirrorProvider, profile: ServerProfileSnapshot?) -> String {
        switch provider {
        case .aliyun: return "mirrors.aliyun.com"
        case .tuna: return "mirrors.tuna.tsinghua.edu.cn"
        case .ustc: return "mirrors.ustc.edu.cn"
        case .official:
            // Reset to the distro's official upstream (fast for overseas servers).
            let osID = (profile?.osID ?? profile?.osName ?? "").lowercased()
            return osID.contains("debian") ? "deb.debian.org" : "archive.ubuntu.com"
        }
    }

    private func pipURL(_ provider: MirrorProvider) -> String {
        switch provider {
        case .aliyun: return "https://mirrors.aliyun.com/pypi/simple/"
        case .tuna: return "https://pypi.tuna.tsinghua.edu.cn/simple"
        case .ustc: return "https://mirrors.ustc.edu.cn/pypi/web/simple"
        case .official: return "https://pypi.org/simple"
        }
    }

    func aptPlan(provider: MirrorProvider, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let host = aptHost(provider, profile: profile)
        // Known mirror hosts we know how to rewrite (Ubuntu default, Tencent/Aliyun
        // cloud mirrors, common CN mirrors). Kept in one constant so the "is this a
        // recognized mirror" probe and the rewrite stay in sync.
        let knownHosts = "mirrors\\.tencentyun\\.com|mirrors\\.cloud\\.tencent\\.com|[a-z0-9.-]*\\.ubuntu\\.com|[a-z0-9.-]*\\.debian\\.org|mirrors\\.aliyun\\.com|mirrors\\.tuna\\.tsinghua\\.edu\\.cn|mirrors\\.ustc\\.edu\\.cn"
        // Replace whatever active mirror host is in use with the chosen one across
        // all source files. Commented lines are left untouched. Distinguish three
        // outcomes so we never mislabel a recognized mirror as unknown: a real
        // change (apt update), already-on-target (no-op success), or no recognized
        // mirror at all (custom/unknown source → error). Identical backups from a
        // no-op are removed so they don't accumulate.
        let command = """
        found=0
        changed=0
        known=0
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
          [ -f "$f" ] || continue
          case "$f" in *.opsdeck-bak) continue;; esac
          found=1
          if grep -qE '^[[:space:]]*(URIs:|deb[[:space:]]).*//(\(knownHosts))' "$f"; then known=1; fi
          \(sudo)cp -a "$f" "$f.opsdeck-bak"
          \(sudo)sed -i -E '/^[[:space:]]*#/! s@//(\(knownHosts))@//\(host)@g' "$f"
          if \(sudo)cmp -s "$f" "$f.opsdeck-bak"; then \(sudo)rm -f "$f.opsdeck-bak"; else changed=1; fi
        done
        if [ "$found" = 0 ]; then echo \(OpsShell.quote(String(localized: "未找到 apt 源文件。"))); exit 1; fi
        if [ "$changed" = 1 ]; then \(OpsShell.unattendedAptGet(sudo: sudo)) update; exit 0; fi
        if [ "$known" = 1 ]; then echo \(OpsShell.quote(String(localized: "当前 apt 源已是所选镜像，无需修改。"))); exit 0; fi
        echo \(OpsShell.quote(String(localized: "源文件里的镜像 host 不在支持列表内，未做任何修改（当前源可能已是自定义/未知镜像）。"))); exit 1
        """
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "apt 换\(provider.displayName)源"),
            summary: String(localized: "备份后把 apt 源替换为\(provider.displayName)镜像（\(host)），再 apt update。"),
            targetDescription: "apt",
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: String(localized: "原源文件备份为 *.opsdeck-bak。"),
            rollbackDescription: String(localized: "恢复 *.opsdeck-bak 后 apt update 即可还原。"),
            steps: [RunbookStep(title: String(localized: "替换 apt 源并更新"), command: command)]
        )
    }

    func pipPlan(provider: MirrorProvider) -> RunbookPlan {
        let url = pipURL(provider)
        let command = "python3 -m pip config set global.index-url \(OpsShell.quote(url)) 2>&1 || pip config set global.index-url \(OpsShell.quote(url)) 2>&1"
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "pip 换\(provider.displayName)源"),
            summary: String(localized: "把 pip 的 index-url 设为\(provider.displayName)镜像。写入 pip 配置文件，不影响系统。"),
            targetDescription: "pip",
            risk: .low,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "pip config unset global.index-url 可还原。"),
            steps: [RunbookStep(title: String(localized: "设置 pip 源"), command: command)]
        )
    }

    func npmPlan(provider: MirrorProvider) -> RunbookPlan {
        let registry = provider.isOfficial ? "https://registry.npmjs.org" : "https://registry.npmmirror.com"
        let summary = provider.isOfficial
            ? String(localized: "把 npm registry 恢复为官方 registry.npmjs.org。")
            : String(localized: "把 npm registry 设为 npmmirror.com（淘宝镜像）。")
        return RunbookPlan(
            kind: .audit,
            title: provider.isOfficial ? String(localized: "npm 恢复官方源") : String(localized: "npm 换国内源"),
            summary: summary,
            targetDescription: "npm",
            risk: .low,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "npm config set registry https://registry.npmjs.org 可还原。"),
            steps: [RunbookStep(title: String(localized: "设置 npm 源"), command: "npm config set registry \(registry) && npm config get registry")]
        )
    }

    func dockerPlan(provider: MirrorProvider, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        // Official reset writes an empty config (no registry-mirrors → pulls straight
        // from Docker Hub); domestic writes accelerator mirrors.
        let jsonBody = provider.isOfficial ? """
        {
        }
        """ : """
        {
          "registry-mirrors": [
            "https://docker.m.daocloud.io",
            "https://docker.mirrors.ustc.edu.cn"
          ]
        }
        """
        let command = """
        \(sudo)mkdir -p /etc/docker
        [ -f /etc/docker/daemon.json ] && \(sudo)cp -a /etc/docker/daemon.json /etc/docker/daemon.json.opsdeck-bak
        \(sudo)tee /etc/docker/daemon.json >/dev/null <<'JSON'
        \(jsonBody)
        JSON
        \(sudo)systemctl restart docker
        opsdeck_restart_rc=$?
        if [ "$opsdeck_restart_rc" -ne 0 ]; then
          \(sudo)systemctl status docker --no-pager -l 2>&1 || true
          \(sudo)journalctl -u docker -n 40 --no-pager 2>&1 || true
          exit "$opsdeck_restart_rc"
        fi
        \(sudo)docker info --format 'Registry Mirrors: {{.RegistryConfig.Mirrors}}'
        """
        return RunbookPlan(
            kind: .docker,
            title: provider.isOfficial ? String(localized: "Docker 恢复官方源") : String(localized: "Docker 配置国内镜像加速"),
            summary: provider.isOfficial
                ? String(localized: "清空 /etc/docker/daemon.json 的 registry-mirrors 并重启 Docker，直连 Docker Hub。原文件已备份。")
                : String(localized: "写入 /etc/docker/daemon.json 的 registry-mirrors 并重启 Docker。若原有 daemon.json 会被覆盖（已备份）。"),
            targetDescription: "docker",
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: String(localized: "原 daemon.json 备份为 .opsdeck-bak。"),
            rollbackDescription: String(localized: "恢复 daemon.json.opsdeck-bak 后重启 docker。"),
            steps: [RunbookStep(title: String(localized: "配置镜像加速并重启"), command: command)]
        )
    }
}

// MARK: - Shell & PATH

actor ShellPathService {
    static let candidateDirs = ["$HOME/.local/bin", "$HOME/.cargo/bin", "$HOME/go/bin", "/usr/local/go/bin", "$HOME/bin"]

    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> ShellPathSnapshot {
        let dirs = Self.candidateDirs.joined(separator: " ")
        let command = """
        login="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
        [ -z "$login" ] && login="$SHELL"
        echo "LOGIN=$login"
        echo "PATH=$PATH"
        for s in bash zsh fish dash sh; do
          p="$(command -v "$s" 2>/dev/null || true)"
          [ -n "$p" ] && echo "SHELL=$p"
        done
        for d in \(dirs); do
          rd="$(eval echo "$d")"
          ex=no; [ -d "$rd" ] && ex=yes
          inp=no; case ":$PATH:" in *":$rd:"*) inp=yes;; esac
          echo "DIR=$rd|$ex|$inp"
        done
        [ -d "$HOME/.oh-my-zsh" ] && echo "OMZ=yes" || echo "OMZ=no"
        ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
        for gp in zsh-autosuggestions zsh-syntax-highlighting; do
          [ -d "$ZC/plugins/$gp" ] && echo "ZP=$gp"
        done
        command -v autojump >/dev/null 2>&1 && echo "ZP=autojump"
        if [ -f "$HOME/.zshrc" ]; then
          pl="$(grep -E '^[[:space:]]*plugins=\\(' "$HOME/.zshrc" | head -1 | sed -E 's/.*plugins=\\(//; s/\\).*//')"
          for p in git zsh-autosuggestions zsh-syntax-highlighting autojump; do
            case " $pl " in *" $p "*) echo "ZE=$p";; esac
          done
        fi
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 16 * 1024)
        var login = ""
        var path = ""
        var shells: [ShellInfo] = []
        var candidates: [PathCandidate] = []
        var ohMyZshInstalled = false
        var zshPluginsInstalled = Set<String>()
        var zshPluginsEnabled = Set<String>()
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("LOGIN=") { login = String(line.dropFirst(6)) }
            else if line.hasPrefix("PATH=") { path = String(line.dropFirst(5)) }
            else if line == "OMZ=yes" { ohMyZshInstalled = true }
            else if line.hasPrefix("ZP=") { zshPluginsInstalled.insert(String(line.dropFirst(3))) }
            else if line.hasPrefix("ZE=") { zshPluginsEnabled.insert(String(line.dropFirst(3))) }
            else if line.hasPrefix("SHELL=") {
                let p = String(line.dropFirst(6))
                // Login shell in /etc/passwd may be a different path to the same
                // binary (e.g. /bin/zsh vs /usr/bin/zsh), so match by basename.
                let isLogin = p == login || (p as NSString).lastPathComponent == (login as NSString).lastPathComponent
                shells.append(ShellInfo(path: p, name: (p as NSString).lastPathComponent, isLogin: isLogin))
            } else if line.hasPrefix("DIR=") {
                let parts = String(line.dropFirst(4)).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                candidates.append(PathCandidate(path: parts[0], exists: parts[1] == "yes", inPath: parts[2] == "yes"))
            }
        }
        return ShellPathSnapshot(
            loginShell: login,
            currentPath: path,
            shells: shells,
            candidates: candidates,
            rcFileForLoginShell: Self.rcFile(forShellPath: login),
            ohMyZshInstalled: ohMyZshInstalled,
            zshPluginsInstalled: zshPluginsInstalled,
            zshPluginsEnabled: zshPluginsEnabled
        )
    }

    /// The interactive rc file for a given shell, used for PATH edits.
    nonisolated static func rcFile(forShellPath shellPath: String) -> String {
        let name = (shellPath as NSString).lastPathComponent
        switch name {
        case "zsh": return "$HOME/.zshrc"
        case "bash": return "$HOME/.bashrc"
        case "fish": return "$HOME/.config/fish/config.fish"
        default: return "$HOME/.profile"
        }
    }

    nonisolated func setDefaultShellPlan(shell: ShellInfo, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let user = profile?.username ?? "$(id -un)"
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "设为默认 shell：\(shell.name)"),
            summary: String(localized: "用 chsh 把登录 shell 改为 \(shell.path)。下次登录生效；当前已开的会话不变。"),
            targetDescription: shell.name,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "再次 chsh 改回原来的 shell 即可。"),
            steps: [
                RunbookStep(title: String(localized: "修改登录 shell"), command: "\(sudo)chsh -s \(OpsShell.quote(shell.path)) \(user)"),
                RunbookStep(title: String(localized: "确认"), command: "getent passwd \(user) | cut -d: -f7")
            ]
        )
    }

    /// oh-my-zsh install. The upstream `install.sh` itself `git clone`s the repo
    /// (from `REMOTE`), so pointing only the *script* URL at a mirror is not
    /// enough — the clone must be mirrored too. We try both a Gitee mirror and
    /// GitHub, ordered by `preferChinaMirror`, and verify success by the presence
    /// of `~/.oh-my-zsh` (an empty `$(fetch …)` would make `sh -c ""` exit 0 and
    /// look like a false success otherwise).
    ///
    /// - Parameter policy: resolved download-source policy (per-host override or
    ///   global default). Controls the source order and whether the official
    ///   upstream is tried at all (`.mirrorOnly` skips it).
    nonisolated func installOhMyZshPlan(policy: DownloadMirrorPolicy = .default) -> RunbookPlan {
        // Shell `echo` output is surfaced verbatim in the runbook console, so every
        // user-facing message is localized in Swift and shell-quoted (translations
        // may contain apostrophes) before being baked into the command. Do NOT
        // hardcode Chinese inside the shell here — see MirrorService for the
        // sentinel-based variant when output must be parsed back.
        let mAlreadyInstalled = OpsShell.quote(String(localized: "oh-my-zsh 已安装。"))
        let mNeedZsh = OpsShell.quote(String(localized: "请先安装 zsh。"))
        let mNeedFetcher = OpsShell.quote(String(localized: "需要 curl 或 wget。"))
        let mDone = OpsShell.quote(String(localized: "安装完成。"))
        let mFailed = OpsShell.quote(policy == .mirrorOnly
            ? String(localized: "安装失败：国内镜像不可达（按设置未尝试官方源），请检查服务器网络或代理。")
            : String(localized: "安装失败：镜像与官方源均不可达，请检查服务器网络或代理。"))

        // (label, install.sh URL, REMOTE clone URL). `policy` decides the order and
        // whether the official source is included at all (`.mirrorOnly` drops it).
        let github = (String(localized: "官方源"), "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh", "https://github.com/ohmyzsh/ohmyzsh.git")
        let gitee = (String(localized: "Gitee 镜像"), "https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh", "https://gitee.com/mirrors/oh-my-zsh.git")
        let sources = policy.order(official: github, mirror: gitee)

        var attempts = ""
        for (label, scriptURL, remote) in sources {
            let attemptMsg = OpsShell.quote(String(localized: "=== 尝试\(label) ==="))
            attempts += """
            if [ ! -d "$HOME/.oh-my-zsh" ]; then
              echo \(attemptMsg)
              REMOTE=\(remote) RUNZSH=no CHSH=no sh -c "$(fetch \(scriptURL))" "" --unattended || true
            fi

            """
        }

        let command = """
        if [ -d "$HOME/.oh-my-zsh" ]; then echo \(mAlreadyInstalled); exit 0; fi
        if ! command -v zsh >/dev/null 2>&1; then echo \(mNeedZsh); exit 1; fi
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then echo \(mNeedFetcher); exit 1; fi
        fetch() { curl -fsSL "$1" 2>/dev/null || wget -qO- "$1" 2>/dev/null; }
        \(attempts)if [ -d "$HOME/.oh-my-zsh" ]; then
          echo \(mDone)
        else
          echo \(mFailed)
          exit 1
        fi
        """

        let summary: String
        switch policy {
        case .officialFirst:
            summary = String(localized: "为 zsh 安装 oh-my-zsh 框架（主题/插件）。优先 GitHub 官方源，失败自动回退 Gitee 镜像。不改默认 shell。")
        case .mirrorFirst:
            summary = String(localized: "为 zsh 安装 oh-my-zsh 框架（主题/插件）。优先 Gitee 国内镜像，失败回退官方源。不改默认 shell。")
        case .mirrorOnly:
            summary = String(localized: "为 zsh 安装 oh-my-zsh 框架（主题/插件）。仅用 Gitee 国内镜像，按设置不尝试官方源。不改默认 shell。")
        }
        return RunbookPlan(
            kind: .install,
            title: String(localized: "安装 oh-my-zsh"),
            summary: summary,
            targetDescription: "oh-my-zsh",
            risk: .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "删除 ~/.oh-my-zsh 目录即可卸载。"),
            steps: [RunbookStep(title: String(localized: "安装 oh-my-zsh"), command: command)]
        )
    }

    /// Curated zsh enhancements the user checks off and installs in one runbook.
    /// The two `zsh-users` plugins are oh-my-zsh custom plugins (git-clone, user
    /// level); `autojump` is a distro package. `id` is the exact token written
    /// into the `.zshrc plugins=(...)` line.
    nonisolated static let zshPlugins: [ZshPluginDef] = [
        ZshPluginDef(
            id: "zsh-autosuggestions", name: "zsh-autosuggestions",
            detail: String(localized: "输入时用灰字提示历史命令，→ 键即可补全。"),
            source: .gitClone(github: "https://github.com/zsh-users/zsh-autosuggestions.git",
                              gitee: "https://gitee.com/mirrors/zsh-autosuggestions.git"),
            recommended: true),
        ZshPluginDef(
            id: "zsh-syntax-highlighting", name: "zsh-syntax-highlighting",
            detail: String(localized: "命令行语法高亮，敲错的命令实时变红。"),
            source: .gitClone(github: "https://github.com/zsh-users/zsh-syntax-highlighting.git",
                              gitee: "https://gitee.com/mirrors/zsh-syntax-highlighting.git"),
            recommended: true),
        ZshPluginDef(
            id: "autojump", name: "autojump",
            detail: String(localized: "记录常去目录，j <关键字> 一步跳转。"),
            source: .package("autojump"),
            recommended: true)
    ]

    /// Install + enable the selected zsh plugins in one runbook: git-clones the
    /// oh-my-zsh custom plugins (official↔mirror per `policy`), installs any
    /// package-backed plugin (autojump), then merges the ids into the
    /// `~/.zshrc plugins=(...)` line — keeping `zsh-syntax-highlighting` last, as
    /// its docs require it to be sourced after everything else.
    ///
    /// Preconditions (first step, hard-fails): zsh present, `~/.oh-my-zsh` present
    /// (custom plugins live under it), and `git` if any git-clone plugin is chosen.
    nonisolated func installZshPluginsPlan(pluginIDs: [String], profile: ServerProfileSnapshot?, policy: DownloadMirrorPolicy = .default) -> RunbookPlan {
        // Preserve catalog order (autosuggestions, syntax-highlighting, autojump).
        let defs = Self.zshPlugins.filter { pluginIDs.contains($0.id) }
        let sudo = OpsShell.sudoPrefix(for: profile)
        let needsGit = defs.contains { if case .gitClone = $0.source { return true } else { return false } }
        let pkgs = defs.compactMap { d -> String? in if case let .package(p) = d.source { return p } else { return nil } }

        // Localized console messages — shell-quoted, never hardcoded in the shell.
        let mNeedZsh = OpsShell.quote(String(localized: "请先安装 zsh。"))
        let mNeedOmz = OpsShell.quote(String(localized: "请先安装 oh-my-zsh（自定义插件需装在它下面）。"))
        let mNeedGit = OpsShell.quote(String(localized: "需要 git 才能拉取插件。"))
        let mPreOk = OpsShell.quote(String(localized: "环境检查通过。"))

        var steps: [RunbookStep] = []

        var pre = "if ! command -v zsh >/dev/null 2>&1; then echo \(mNeedZsh); exit 1; fi\n"
        pre += "if [ ! -d \"$HOME/.oh-my-zsh\" ]; then echo \(mNeedOmz); exit 1; fi\n"
        if needsGit { pre += "if ! command -v git >/dev/null 2>&1; then echo \(mNeedGit); exit 1; fi\n" }
        pre += "echo \(mPreOk)"
        steps.append(RunbookStep(title: String(localized: "前置检查"), command: pre))

        // git-clone plugins, each with official↔mirror fallback.
        for def in defs {
            guard case let .gitClone(github, gitee) = def.source else { continue }
            let mExists = OpsShell.quote(String(localized: "\(def.name) 已存在，跳过。"))
            let mDone = OpsShell.quote(String(localized: "\(def.name) 拉取完成。"))
            let mFailed = OpsShell.quote(policy == .mirrorOnly
                ? String(localized: "\(def.name) 拉取失败：国内镜像不可达（按设置未尝试官方源）。")
                : String(localized: "\(def.name) 拉取失败：镜像与官方源均不可达。"))
            let sources = policy.order(official: (String(localized: "官方源"), github),
                                       mirror: (String(localized: "Gitee 镜像"), gitee))
            var attempts = ""
            for (label, url) in sources {
                let attemptMsg = OpsShell.quote(String(localized: "=== 尝试\(label) ==="))
                attempts += """
                if [ ! -d "$DEST" ]; then
                  echo \(attemptMsg)
                  git clone --depth=1 \(OpsShell.quote(url)) "$DEST" 2>/dev/null || true
                fi

                """
            }
            let command = """
            ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
            DEST="$ZC/plugins/\(def.id)"
            if [ -d "$DEST" ]; then echo \(mExists); exit 0; fi
            mkdir -p "$ZC/plugins"
            \(attempts)if [ -d "$DEST" ]; then echo \(mDone); else echo \(mFailed); exit 1; fi
            """
            steps.append(RunbookStep(title: String(localized: "拉取 \(def.name)"), command: command))
        }

        // Package-backed plugins (autojump) — portable across distros.
        if !pkgs.isEmpty {
            let pkgText = pkgs.map(OpsShell.quote).joined(separator: " ")
            let mNoPM = OpsShell.quote(String(localized: "未识别包管理器，请手动安装。"))
            let command = """
            if command -v apt-get >/dev/null 2>&1; then
              \(OpsShell.unattendedAptGet(sudo: sudo)) update && \(OpsShell.unattendedAptInstall(packages: pkgs, sudo: sudo))
            elif command -v dnf >/dev/null 2>&1; then
              \(sudo)dnf install -y \(pkgText)
            elif command -v yum >/dev/null 2>&1; then
              \(sudo)yum install -y \(pkgText)
            elif command -v pacman >/dev/null 2>&1; then
              \(sudo)pacman -Sy --noconfirm \(pkgText)
            elif command -v zypper >/dev/null 2>&1; then
              \(sudo)zypper --non-interactive install \(pkgText)
            elif command -v apk >/dev/null 2>&1; then
              \(sudo)apk add \(pkgText)
            else
              echo \(mNoPM); exit 1
            fi
            """
            steps.append(RunbookStep(title: String(localized: "安装软件包（\(pkgs.formatted(.list(type: .and, width: .narrow)))）"), command: command))
        }

        // Enable in .zshrc — syntax-highlighting appended last so it sources last.
        let enableOrder = defs.map(\.id).filter { $0 != "zsh-syntax-highlighting" }
            + (defs.contains { $0.id == "zsh-syntax-highlighting" } ? ["zsh-syntax-highlighting"] : [])
        let enableList = enableOrder.map(OpsShell.quote).joined(separator: " ")
        let mEnabled = OpsShell.quote(String(localized: "已写入 ~/.zshrc plugins()，重新登录或 source ~/.zshrc 后生效。"))
        let enableCommand = """
        ZSHRC="$HOME/.zshrc"
        touch "$ZSHRC"
        grep -qE '^[[:space:]]*plugins=\\(' "$ZSHRC" || printf '\\nplugins=(git)\\n' >> "$ZSHRC"
        plugin_present() {
          pl="$(grep -E '^[[:space:]]*plugins=\\(' "$ZSHRC" | head -1 | sed -E 's/.*plugins=\\(//; s/\\).*//')"
          case " $pl " in *" $1 "*) return 0;; *) return 1;; esac
        }
        add_plugin() {
          plugin_present "$1" && return 0
          sed -i.opsdeckbak -E "s/^([[:space:]]*plugins=\\([^)]*)\\)/\\1 $1)/" "$ZSHRC"
        }
        for p in \(enableList); do add_plugin "$p"; done
        echo \(mEnabled)
        """
        steps.append(RunbookStep(title: String(localized: "启用插件（写入 .zshrc）"), command: enableCommand))

        let names = defs.map(\.name).formatted(.list(type: .and, width: .narrow))
        var summary = String(localized: "安装并在 ~/.zshrc 启用：\(names)。已存在的自动跳过；zsh-syntax-highlighting 会放在插件列表末尾。改动在重新登录或 source ~/.zshrc 后生效。")
        if policy == .mirrorOnly {
            summary += String(localized: "\n下载源：仅用国内镜像（按设置不尝试官方源）。")
        } else if policy == .mirrorFirst {
            summary += String(localized: "\n下载源：优先国内镜像，失败回退官方源。")
        }
        return RunbookPlan(
            kind: .install,
            title: String(localized: "配置 zsh 插件（\(defs.count) 项）"),
            summary: summary,
            targetDescription: names,
            risk: .medium,
            requiresSudo: !pkgs.isEmpty && !sudo.isEmpty,
            backupDescription: String(localized: "修改前会把 .zshrc 备份为 .zshrc.opsdeckbak。"),
            rollbackDescription: String(localized: "从 .zshrc plugins() 里删掉对应名字；git 插件删 ~/.oh-my-zsh/custom/plugins/<名字> 目录，autojump 用包管理器卸载。"),
            steps: steps
        )
    }

    nonisolated func addPathPlan(dir: String, shellPath: String) -> RunbookPlan {
        let rc = Self.rcFile(forShellPath: shellPath)
        let name = (shellPath as NSString).lastPathComponent
        let exportLine: String
        if name == "fish" {
            exportLine = "fish_add_path \(OpsShell.quote(dir))"
        } else {
            exportLine = "export PATH=\"\(dir):$PATH\""
        }
        // Idempotent: only append if the dir isn't already referenced in the rc file.
        let command = "touch \(rc); grep -qF \(OpsShell.quote(dir)) \(rc) && echo \(OpsShell.quote(String(localized: "已存在，无需重复添加。"))) || { printf '\\n# added by OpsDeck\\n%s\\n' \(OpsShell.quote(exportLine)) >> \(rc); echo \(OpsShell.quote(String(localized: "已写入 \(rc)，重新登录或 source 后生效。"))); }"
        return RunbookPlan(
            kind: .audit,
            title: String(localized: "把 \(dir) 加入 PATH"),
            summary: String(localized: "幂等地写入 \(name) 的配置文件（\(rc)）——已存在则跳过，不重复添加。"),
            targetDescription: dir,
            risk: .low,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "从 \(rc) 删除对应行即可。"),
            steps: [RunbookStep(title: String(localized: "配置 PATH"), command: command)]
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
