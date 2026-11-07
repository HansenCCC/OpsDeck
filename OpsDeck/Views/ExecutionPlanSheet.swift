import AppKit
import Foundation
import SwiftUI

struct ExecutionPlanSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss

    let plan: RunbookPlan

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Color.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    planSummary
                    commandPreview
                }
                .padding(Theme.Space.lg)
            }

            Divider().overlay(Theme.Color.separator)
            footer
        }
        .frame(width: 680, height: 620)
        .background(Theme.Color.surface)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(riskColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(Theme.Font.windowTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(plan.summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(plan.risk.displayName)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(riskColor)
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, 3)
                .background(riskColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 72)
    }

    private var planSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("执行信息")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            PlanKeyValueRow(label: String(localized: "目标"), value: plan.targetDescription)
            PlanKeyValueRow(label: "sudo", value: plan.requiresSudo ? String(localized: "需要") : String(localized: "不需要"))
            PlanKeyValueRow(label: String(localized: "备份"), value: plan.backupDescription ?? String(localized: "不需要"))
            PlanKeyValueRow(label: String(localized: "回滚"), value: plan.rollbackDescription ?? String(localized: "无自动回滚"))
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("命令预览")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("\(index + 1). \(step.title)")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(step.command)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("取消不会执行任何远端命令。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
            Spacer()
            Button("取消") {
                session.cancelPendingRunbookPlan()
                dismiss()
            }
            Button(executeTitle) {
                session.executePendingRunbookPlan()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 56)
    }

    private var executeTitle: String {
        plan.risk == .readOnly ? String(localized: "执行（只读）") : String(localized: "确认执行")
    }

    private var iconName: String {
        switch plan.kind {
        case .dryRun:
            return "doc.text.magnifyingglass"
        case .service:
            return "switch.2"
        case .log:
            return "doc.text"
        case .nginx:
            return "network"
        case .install:
            return "shippingbox"
        case .docker:
            return "cube"
        case .database:
            return "externaldrive.connected.to.line.below"
        case .deployment:
            return "arrow.up.forward.app"
        case .audit:
            return "checkmark.shield"
        }
    }

    private var riskColor: SwiftUI.Color {
        switch plan.risk {
        case .readOnly:
            return Theme.Color.textSecondary
        case .low:
            return Theme.Color.success
        case .medium:
            return Theme.Color.warning
        case .high:
            return Theme.Color.danger
        }
    }
}

private struct PlanKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct RunbookResultSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss

    private let initialRun: RunbookRun
    private let logBottomID = "runbook-log-bottom"

    init(run: RunbookRun) {
        initialRun = run
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Color.separator)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if run.status == .running {
                            RunbookLiveProgressView(run: run)
                        }
                        if let failureSummary = run.failureSummary {
                            failureBanner(failureSummary)
                            if session.hasPackageRecovery(for: run) {
                                packageRecoveryCard
                            }
                        }
                        ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                            RunbookStepResultView(index: index, step: step)
                                .id(step.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(logBottomID)
                    }
                    .padding(Theme.Space.lg)
                }
                .onAppear {
                    scrollToLatestLog(using: proxy)
                }
                .onChange(of: run.combinedOutput) { _, _ in
                    guard run.status == .running else { return }
                    DispatchQueue.main.async {
                        scrollToLatestLog(using: proxy)
                    }
                }
            }

            Divider().overlay(Theme.Color.separator)
            footer
        }
        .frame(width: 760, height: 640)
        .background(Theme.Color.surface)
    }

    private var run: RunbookRun {
        if let active = session.activeRunbookRun, active.id == initialRun.id {
            return active
        }
        if let completed = session.runbookRuns.first(where: { $0.id == initialRun.id }) {
            return completed
        }
        if let selected = session.selectedRunbookRun, selected.id == initialRun.id {
            return selected
        }
        return initialRun
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: statusImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .font(Theme.Font.windowTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Theme.Space.xxs) {
                    Text(run.status.displayName)
                    Text("·")
                    RunbookResultElapsedText(run: run)
                    Text("· \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Text(run.risk.displayName)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 72)
    }

    private func failureBanner(_ message: String) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(OpsErrorHint.copyText(for: message), forType: .string)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let hint = OpsErrorHint.hint(for: message) {
                        Text("可能原因 / 解决：\(hint)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Theme.Space.xs)
                Text("点击复制")
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.danger.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击复制错误信息与建议")
    }

    private var packageRecoveryCard: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(Theme.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("可生成安全恢复计划")
                    .font(Theme.Font.bodyMedium)
                Text("将先备份并显示命令，不会直接修改服务器。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button("查看修复计划") {
                dismiss()
                DispatchQueue.main.async {
                    session.requestPackageRecovery(for: run)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Space.sm)
        .background(Theme.Color.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Button {
                appState.copyRunbookDetails(run)
            } label: {
                Label("复制执行详情", systemImage: "doc.on.doc")
            }
            if run.status == .running {
                Button {
                    session.cancelActiveRunbook()
                } label: {
                    Label("取消执行", systemImage: "stop.fill")
                }
                .help("停止当前远端命令，并把计划标记为已取消")
            }
            Spacer()
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 56)
    }

    private var statusImage: String {
        switch run.status {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "stop.circle.fill"
        case .planned, .running:
            return "clock.fill"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch run.status {
        case .succeeded:
            return Theme.Color.success
        case .failed:
            return Theme.Color.danger
        case .cancelled, .planned, .running:
            return Theme.Color.warning
        }
    }

    private func scrollToLatestLog(using proxy: ScrollViewProxy) {
        guard run.status == .running else { return }
        if let currentStep = run.currentStep {
            proxy.scrollTo(currentStep.id, anchor: .bottom)
        } else {
            proxy.scrollTo(logBottomID, anchor: .bottom)
        }
    }
}

private struct RunbookLiveProgressView: View {
    let run: RunbookRun

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                ProgressView()
                    .controlSize(.small)
                Text(run.progressDescription)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                if let step = run.currentStep {
                    Text(step.title)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("实时日志")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

            ProgressView(
                value: Double(run.completedStepCount),
                total: Double(max(run.steps.count, 1))
            )
            .progressViewStyle(.linear)
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

private struct RunbookResultElapsedText: View {
    let run: RunbookRun

    var body: some View {
        if run.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                durationText
            }
        } else {
            durationText
        }
    }

    private var durationText: some View {
        Text(formattedDuration)
            .monospacedDigit()
    }

    private var formattedDuration: String {
        let seconds = max(Int(run.duration), 0)
        if seconds >= 60 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return String(localized: "\(seconds) 秒")
    }
}

private struct RunbookStepResultView: View {
    let index: Int
    let step: RunbookStep

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text("\(index + 1). \(step.title)")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text(metadata)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

            Text(step.command)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Color.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            if !step.output.isEmpty || step.status == .failed {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("输出")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text(displayOutput)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(step.status == .failed ? Theme.Color.danger : Theme.Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Theme.Space.sm)
                .background(Theme.Color.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }
    }

    private var displayOutput: String {
        guard !step.output.isEmpty else { return String(localized: "（无输出）") }
        return String(step.output.suffix(64_000))
    }

    private var metadata: String {
        var values = [step.status.displayName]
        if let exitCode = step.exitCode {
            values.append("exit \(exitCode)")
        }
        if let duration = step.duration {
            values.append(String(format: "%.2fs", duration))
        }
        return values.joined(separator: " · ")
    }

    private var statusImage: String {
        switch step.status {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .running:
            return "clock.fill"
        case .cancelled:
            return "stop.circle"
        case .planned:
            return "circle"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch step.status {
        case .succeeded:
            return Theme.Color.success
        case .failed:
            return Theme.Color.danger
        case .running:
            return Theme.Color.warning
        case .planned, .cancelled:
            return Theme.Color.textTertiary
        }
    }
}
