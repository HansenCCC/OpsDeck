import AppKit
import StoreKit
import SwiftUI

struct WelcomeView: View {
    static let contentSize = NSSize(width: 620, height: 520)

    let onAddServer: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Space.sm) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)
                Text("欢迎使用 OpsDeck")
                    .font(.system(size: 24, weight: .semibold))
                Text("在 Mac 上连接并管理你的服务器，无需安装服务端 Agent。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)

            Divider()

            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                welcomeRow(
                    symbol: "server.rack",
                    title: String(localized: "连接你的服务器"),
                    detail: String(localized: "SSH 凭据安全保存在本机 Keychain，OpsDeck 不会经过云端中转。")
                )
                welcomeRow(
                    symbol: "folder.badge.gearshape",
                    title: String(localized: "文件与终端在一起"),
                    detail: String(localized: "浏览、上传和编辑远端文件，需要时直接打开真实 SSH 终端。")
                )
                welcomeRow(
                    symbol: "checklist",
                    title: String(localized: "更改前先查看计划"),
                    detail: String(localized: "安装工具、管理服务等操作会先显示命令、风险和执行结果。")
                )
            }
            .padding(.horizontal, 54)
            .padding(.vertical, Theme.Space.xl)

            Spacer(minLength: Theme.Space.md)
            Divider()

            HStack(spacing: Theme.Space.sm) {
                Label("服务器地址、凭据和操作记录只保留在这台 Mac 上。", systemImage: "lock")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.md)
                Button("稍后再说", action: onClose)
                    .controlSize(.large)
                Button("添加第一台服务器", action: onAddServer)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            .layoutPriority(1)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Theme.Color.appBackground)
    }

    private func welcomeRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Color.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Categories

private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general, security, privacy, history, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .security: return String(localized: "安全")
        case .privacy: return String(localized: "隐私")
        case .history: return String(localized: "历史记录")
        case .about: return String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .security: return "lock.shield"
        case .privacy: return "hand.raised"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Root (sidebar + detail, Xcode / System Settings style)

struct SettingsView: View {
    @State private var selection: SettingsCategory? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 196)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general: GeneralSettingsPane()
        case .security: SecuritySettingsPane()
        case .privacy: PrivacySettingsPane()
        case .history: HistorySettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - Panes

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingLanguage: AppLanguage?

    var body: some View {
        Form {
            Section("外观") {
                Picker("外观模式", selection: Binding(
                    get: { appState.selectedAppearanceMode },
                    set: { appState.setAppearanceMode($0) }
                )) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("语言") {
                Picker("界面语言", selection: Binding(
                    get: { AppLanguage.current },
                    set: { pendingLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text("切换语言需要重启 App 后生效。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("下载源") {
                Picker("默认下载源", selection: Binding(
                    get: { appState.settings?.downloadMirrorPolicy ?? .default },
                    set: { appState.setDefaultDownloadMirrorPolicy($0) }
                )) {
                    ForEach(DownloadMirrorPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Text("需要从 GitHub 等境外站点下载的运维操作（如安装 oh-my-zsh）走哪个源。境外服务器用「官方优先」最快；国内服务器可选「国内镜像优先」；已知官方源不通的服务器选「仅国内镜像」不再尝试官方、最省时间。单台服务器可在其编辑页覆盖此默认值。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("SSL 证书") {
                TextField("Let's Encrypt 邮箱", text: Binding(
                    get: { appState.settings?.acmeEmail ?? "" },
                    set: { appState.setAcmeEmail($0) }
                ))
                Text("申请 SSL 证书时用于到期提醒，会自动填入。留空也能申请。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("使用指南") {
                Button {
                    appState.showHelpGuide()
                } label: {
                    Label("打开使用指南", systemImage: "questionmark.circle")
                }
                Text("在独立窗口查看命令、文件管理和安全操作指南。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            #if DEBUG
            Section("截图尺寸 · Debug") {
                Text("把主窗口锁成固定尺寸，方便截统一尺寸的商品图（Retina 2× 即像素翻倍）。仅 Debug 构建可见。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                HStack {
                    Button("1280 × 800") { Self.resizeMainWindow(to: NSSize(width: 1280, height: 800)) }
                    Button("1440 × 900") { Self.resizeMainWindow(to: NSSize(width: 1440, height: 900)) }
                    Button("1360 × 860") { Self.resizeMainWindow(to: NSSize(width: 1360, height: 860)) }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .alert("切换界面语言", isPresented: Binding(
            get: { pendingLanguage != nil },
            set: { if !$0 { pendingLanguage = nil } }
        )) {
            Button("重启并切换") {
                pendingLanguage?.apply()
                pendingLanguage = nil
                AppLanguage.relaunch()
            }
            Button("取消", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("切换到「\(pendingLanguage?.displayName ?? "")」需要重启 App 才能生效。现在重启吗？")
        }
    }

    #if DEBUG
    /// Debug 专用：把主窗口（非设置窗口）锁成固定尺寸，方便截统一尺寸的商品图。
    static func resizeMainWindow(to size: NSSize) {
        let settingsWindow = NSApp.keyWindow
        guard let win = NSApp.windows.first(where: {
            $0 !== settingsWindow && $0.isVisible
                && $0.styleMask.contains(.titled) && $0.canBecomeMain
        }) else { return }
        var frame = win.frame
        let topLeftY = frame.maxY
        frame.size = size
        frame.origin.y = topLeftY - size.height   // 保持左上角不动
        win.setFrame(frame, display: true, animate: true)
    }
    #endif
}

private struct SecuritySettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("远端操作") {
                Toggle("危险远端操作前确认", isOn: Binding(
                    get: { appState.settings?.confirmDangerousActions ?? true },
                    set: { appState.setConfirmDangerousActions($0) }
                ))
                Text("删除、覆盖、执行高危命令等操作前弹出二次确认。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("本机保护") {
                Toggle("使用 Touch ID 保护敏感信息", isOn: Binding(
                    get: { appState.settings?.protectWithTouchID ?? false },
                    set: { appState.setProtectWithTouchID($0) }
                ))
                .disabled(!appState.isTouchIDAvailable && appState.settings?.protectWithTouchID != true)
                Text(appState.touchIDAvailabilityDetail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(appState.isTouchIDAvailable ? Theme.Color.textSecondary : Theme.Color.warning)
                if let error = appState.touchIDError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.danger)
                }
            }

            Section("已知服务器 Host Key") {
                if appState.knownHostRecords.isEmpty {
                    Text("首次确认服务器身份后，SHA-256 指纹会显示在这里。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                } else {
                    ForEach(appState.knownHostRecords) { record in
                        HStack(spacing: Theme.Space.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.endpoint)
                                    .font(Theme.Font.bodyMedium)
                                Text(record.fingerprint)
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.removeKnownHost(record)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除信任记录")
                            .accessibilityLabel("删除 \(record.endpoint) 的 Host Key 信任记录")
                        }
                    }
                    Button("删除全部信任记录", role: .destructive) {
                        appState.removeAllKnownHosts()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshTouchIDAvailability()
            appState.refreshKnownHosts()
        }
    }
}

private struct PrivacySettingsPane: View {
    var body: some View {
        Form {
            Section("凭据与数据") {
                Text("服务器凭据保存在本机 Keychain。OpsDeck 不运行云端中转，也不在服务器安装任何 Agent。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section {
                Button("隐私政策") { NSWorkspace.shared.open(Links.privacyPolicy) }
                Button("发送反馈") { NSWorkspace.shared.open(Links.feedback) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmingClearHistory = false

    var body: some View {
        Form {
            Section("本机历史") {
                Text("传输记录和命令历史只保存在这台 Mac。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Button("清空历史", role: .destructive) {
                    confirmingClearHistory = true
                }
                .disabled(appState.transferTasks.isEmpty && appState.commandRuns.isEmpty)
            }
        }
        .formStyle(.grouped)
        .alert("清空历史记录？", isPresented: $confirmingClearHistory) {
            Button("清空", role: .destructive) { appState.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机保存的所有传输记录和命令历史，此操作不可撤销。")
        }
    }
}

private struct AboutSettingsPane: View {
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var appState: AppState

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("OpsDeck", value: version)
            }

            Section("软件更新") {
                Button {
                    appState.checkForAppUpdateManually()
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        if appState.isCheckingForAppUpdate {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            appState.isCheckingForAppUpdate
                                ? String(localized: "正在检查…")
                                : String(localized: "检查更新…")
                        )
                    }
                }
                .disabled(appState.isCheckingForAppUpdate)

                if let message = appState.appUpdateStatusMessage {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                Text("仅向 Apple 查询 OpsDeck 的公开版本信息，不会发送服务器或 SSH 数据。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Section("评价 OpsDeck") {
                Text("如果 OpsDeck 帮到了你，欢迎给个好评，这是对我们最大的支持 🙏")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Button("给 OpsDeck 评分") { requestReview() }
                Button("前往 App Store 评价") { NSWorkspace.shared.open(Links.appStoreReview) }
            }
        }
        .formStyle(.grouped)
    }
}
