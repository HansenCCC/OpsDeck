import Foundation

/// Converts a small set of well-understood apt/dpkg failures into an explicit,
/// reviewable recovery runbook. Unknown failures deliberately return nil: a
/// package manager repair must never guess at destructive remediation.
struct PackageRecoveryPlanFactory {
    enum Diagnosis: Equatable, Sendable {
        case missingStatoverrideUser(String)
        case missingStatoverrideGroup(String)
        case interruptedDPKG
        case brokenDependencies
    }

    func diagnosis(for message: String) -> Diagnosis? {
        let lower = message.lowercased()
        if let user = capture(in: message, pattern: #"unknown system user ['\"]([^'\"]+)['\"] in statoverride file"#),
           isSafePrincipal(user) {
            return .missingStatoverrideUser(user)
        }
        if let group = capture(in: message, pattern: #"unknown system group ['\"]([^'\"]+)['\"] in statoverride file"#),
           isSafePrincipal(group) {
            return .missingStatoverrideGroup(group)
        }
        if lower.contains("dpkg was interrupted") || lower.contains("dpkg --configure -a") {
            return .interruptedDPKG
        }
        if lower.contains("unmet dependencies")
            || lower.contains("fix-broken")
            || lower.contains("dependency problems prevent configuration") {
            return .brokenDependencies
        }
        return nil
    }

    func plan(for message: String, profile: ServerProfileSnapshot?) -> RunbookPlan? {
        guard let diagnosis = diagnosis(for: message) else { return nil }
        let sudo = OpsShell.sudoPrefix(for: profile)
        let apt = OpsShell.unattendedAptGet(sudo: sudo)

        switch diagnosis {
        case .missingStatoverrideUser(let principal):
            return statoverridePlan(principal: principal, field: 1, kind: String(localized: "用户"), sudo: sudo, apt: apt)
        case .missingStatoverrideGroup(let principal):
            return statoverridePlan(principal: principal, field: 2, kind: String(localized: "用户组"), sudo: sudo, apt: apt)
        case .interruptedDPKG:
            return RunbookPlan(
                kind: .install,
                title: String(localized: "恢复中断的软件包配置"),
                summary: String(localized: "完成未结束的 dpkg 配置，再修复依赖关系。不会删除软件包。"),
                targetDescription: String(localized: "系统软件包数据库"),
                risk: .medium,
                requiresSudo: !sudo.isEmpty,
                backupDescription: nil,
                rollbackDescription: String(localized: "此流程只完成待配置软件包；可在执行详情中查看具体变更。"),
                steps: [
                    RunbookStep(title: String(localized: "完成 dpkg 配置"), command: "\(sudo)env DEBIAN_FRONTEND=noninteractive dpkg --configure -a"),
                    RunbookStep(title: String(localized: "修复依赖"), command: "\(apt) -f install -y"),
                    RunbookStep(title: String(localized: "验证软件包状态"), command: "\(sudo)dpkg --audit; test -z \"$(\(sudo)dpkg --audit)\"")
                ]
            )
        case .brokenDependencies:
            return RunbookPlan(
                kind: .install,
                title: String(localized: "修复软件包依赖"),
                summary: String(localized: "让 apt 修复不完整依赖，并完成待配置的软件包。"),
                targetDescription: String(localized: "系统软件包依赖"),
                risk: .medium,
                requiresSudo: !sudo.isEmpty,
                backupDescription: nil,
                rollbackDescription: String(localized: "apt 可能安装或移除冲突依赖；执行前请核对命令预览。"),
                steps: [
                    RunbookStep(title: String(localized: "修复依赖"), command: "\(apt) -f install -y"),
                    RunbookStep(title: String(localized: "完成 dpkg 配置"), command: "\(sudo)env DEBIAN_FRONTEND=noninteractive dpkg --configure -a"),
                    RunbookStep(title: String(localized: "验证软件包状态"), command: "\(sudo)dpkg --audit; test -z \"$(\(sudo)dpkg --audit)\"")
                ]
            )
        }
    }

    private func statoverridePlan(principal: String, field: Int, kind: String, sudo: String, apt: String) -> RunbookPlan {
        let quotedPrincipal = OpsShell.quote(principal)
        let source = "/var/lib/dpkg/statoverride"
        let backup = "/var/lib/dpkg/statoverride.opsdeck-backup"
        let database = OpsShell.quote(source)
        let backupPath = OpsShell.quote(backup)
        let accountLookup = field == 1 ? "passwd" : "group"
        let removalScript = """
        principal=\(quotedPrincipal)
        if getent \(accountLookup) "$principal" >/dev/null 2>&1; then
          echo "\(kind) $principal 已存在，未修改 statoverride"
          exit 0
        fi
        paths=$(awk -v p="$principal" '$\(field) == p { print $4 }' \(database))
        if [ -z "$paths" ]; then
          echo "没有找到匹配的 statoverride 项"
          exit 1
        fi
        for path in $paths; do
          echo "移除无效 override: $principal -> $path"
          dpkg-statoverride --remove "$path"
        done
        """

        return RunbookPlan(
            kind: .install,
            title: String(localized: "修复 dpkg statoverride"),
            summary: String(localized: "检测到 statoverride 引用了已不存在的\(kind)“\(principal)”。将先备份原文件，只移除该主体对应的无效项，再恢复 dpkg。"),
            targetDescription: "\(source) · \(principal)",
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: "\(source) → \(backup)",
            rollbackDescription: String(localized: "如需回滚：\(sudo)cp \(backupPath) \(database)，再运行 dpkg --configure -a。"),
            steps: [
                RunbookStep(
                    title: String(localized: "备份并确认无效项"),
                    command: "\(sudo)cp -a \(database) \(backupPath) && \(sudo)awk -v p=\(quotedPrincipal) '$\(field) == p { print }' \(database)"
                ),
                RunbookStep(
                    title: String(localized: "移除失效的 statoverride 项"),
                    command: "\(sudo)sh -eu -c \(OpsShell.quote(removalScript))"
                ),
                RunbookStep(title: String(localized: "完成 dpkg 配置"), command: "\(sudo)env DEBIAN_FRONTEND=noninteractive dpkg --configure -a"),
                RunbookStep(title: String(localized: "修复依赖"), command: "\(apt) -f install -y"),
                RunbookStep(title: String(localized: "验证软件包状态"), command: "\(sudo)dpkg --audit; test -z \"$(\(sudo)dpkg --audit)\"")
            ]
        )
    }

    private func capture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let resultRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[resultRange])
    }

    private func isSafePrincipal(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
    }
}
