import Foundation

enum RunbookRisk: String, CaseIterable, Sendable, Equatable {
    case readOnly
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .readOnly:
            return String(localized: "只读")
        case .low:
            return String(localized: "低风险")
        case .medium:
            return String(localized: "中风险")
        case .high:
            return String(localized: "高风险")
        }
    }
}

enum RunbookStatus: String, Sendable, Equatable {
    case planned
    case running
    case succeeded
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .planned:
            return String(localized: "待执行")
        case .running:
            return String(localized: "执行中")
        case .succeeded:
            return String(localized: "成功")
        case .failed:
            return String(localized: "失败")
        case .cancelled:
            return String(localized: "已取消")
        }
    }
}

enum RunbookKind: String, Sendable, Equatable {
    case dryRun
    case service
    case log
    case nginx
    case install
    case docker
    case database
    case deployment
    case audit
}

struct RunbookStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var command: String
    var status: RunbookStatus = .planned
    var output: String = ""
    var exitCode: Int?
    var duration: TimeInterval?
}

struct RunbookPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    var kind: RunbookKind
    var title: String
    var summary: String
    var targetDescription: String
    var risk: RunbookRisk
    var requiresSudo: Bool
    var backupDescription: String?
    var rollbackDescription: String?
    var steps: [RunbookStep]
    /// Workbench module this operation belongs to (e.g. "pm2", "nginx"), so a
    /// pane can tell "a runbook is acting on me right now". Defaults nil; stamped
    /// centrally in AppState.presentRunbookPlan / requestInstallTool.
    var moduleID: String? = nil
    /// The specific installer tool id (e.g. "pm2") for install/uninstall runs, so
    /// the installer list can show per-row install state. nil for non-tool ops.
    var toolID: String? = nil
    var createdAt = Date()

    static func dryRun(title: String, command: String, target: String) -> RunbookPlan {
        RunbookPlan(
            kind: .dryRun,
            title: title,
            summary: String(localized: "只读检查，不修改远端服务器。"),
            targetDescription: target,
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [
                RunbookStep(title: title, command: command)
            ]
        )
    }
}

struct RunbookRun: Identifiable, Equatable, Sendable {
    var id: UUID
    var planID: UUID
    var hostID: UUID
    var title: String
    var kind: RunbookKind
    var risk: RunbookRisk
    var status: RunbookStatus
    var startedAt: Date
    var finishedAt: Date?
    var steps: [RunbookStep]
    var errorMessage: String?
    /// Module/tool this run belongs to (copied from the plan) so panes and the
    /// installer list can attribute a running/failed run to themselves.
    var moduleID: String?
    var toolID: String?
    /// The originating plan, kept so a failed run can be retried verbatim.
    let plan: RunbookPlan

    init(plan: RunbookPlan, hostID: UUID) {
        id = UUID()
        planID = plan.id
        self.hostID = hostID
        title = plan.title
        kind = plan.kind
        risk = plan.risk
        status = .planned
        startedAt = Date()
        steps = plan.steps
        moduleID = plan.moduleID
        toolID = plan.toolID
        self.plan = plan
    }

    var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .succeeded }.count
    }

    var currentStepIndex: Int? {
        steps.firstIndex { $0.status == .running }
    }

    var currentStep: RunbookStep? {
        guard let currentStepIndex else { return nil }
        return steps[currentStepIndex]
    }

    var progressDescription: String {
        guard let currentStepIndex else {
            return String(localized: "已完成 \(completedStepCount) / \(steps.count) 步")
        }
        return String(localized: "第 \(currentStepIndex + 1) / \(steps.count) 步")
    }

    var combinedOutput: String {
        steps
            .map { step in
                """
                # \(step.title)
                $ \(step.command)
                \(step.output)
                """
            }
            .joined(separator: "\n\n")
    }

    var failureSummary: String? {
        if let errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !errorMessage.isEmpty {
            return errorMessage
        }
        guard let step = steps.first(where: { $0.status == .failed }) else { return nil }
        let output = step.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        if let output {
            return String(localized: "\(step.title)失败：\(output)")
        }
        if let exitCode = step.exitCode {
            return String(localized: "\(step.title)失败（退出码 \(exitCode)）")
        }
        return String(localized: "\(step.title)失败")
    }

    func diagnosticReport(maxOutputPerStep: Int = 32_000) -> String {
        var lines = [
            String(localized: "OpsDeck Runbook 执行详情"),
            String(localized: "计划：\(title)"),
            String(localized: "状态：\(status.displayName)"),
            String(localized: "风险：\(risk.displayName)"),
            String(localized: "开始：\(startedAt.formatted(date: .numeric, time: .standard))"),
            String(localized: "耗时：\(String(format: "%.2f 秒", duration))")
        ]
        if let failureSummary {
            lines.append(String(localized: "错误：\(failureSummary)"))
        }

        for (index, step) in steps.enumerated() {
            lines.append("")
            lines.append(String(localized: "步骤 \(index + 1)：\(step.title)"))
            lines.append(String(localized: "状态：\(step.status.displayName)"))
            if let exitCode = step.exitCode {
                lines.append(String(localized: "退出码：\(exitCode)"))
            }
            if let duration = step.duration {
                lines.append(String(localized: "耗时：\(String(format: "%.2f 秒", duration))"))
            }
            lines.append(String(localized: "命令：\(step.command)"))
            let output = String(step.output.suffix(maxOutputPerStep))
            lines.append(String(localized: "输出："))
            lines.append(output.isEmpty ? String(localized: "（无输出）") : output)
        }
        return lines.joined(separator: "\n")
    }
}

/// The current runbook activity for a given workbench module / installer tool,
/// used by panes to render an in-progress or failed-with-retry state instead of
/// the plain idle empty state.
enum ModuleActivity: Equatable, Sendable {
    case idle
    case running(RunbookRun)
    case failed(RunbookRun)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var runningRun: RunbookRun? { if case .running(let r) = self { return r }; return nil }
    var failedRun: RunbookRun? { if case .failed(let r) = self { return r }; return nil }
}
