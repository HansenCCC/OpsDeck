import AppKit
import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostEditorDraft

    init(draft: HostEditorDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Color.separator)
            form
            Divider().overlay(Theme.Color.separator)
            footer
        }
        .frame(width: 520)
        .background(Theme.Color.surface)
        .sheet(item: hostKeyChallengeBinding) { challenge in
            HostKeyTrustView(challenge: challenge)
                .environmentObject(appState)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.editingHostID == nil ? String(localized: "添加服务器") : String(localized: "编辑服务器"))
                    .font(Theme.Font.windowTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("凭据会保存在本机 Keychain。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.Space.lg)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                // Distinct key so the section header reads "Connection" (noun) rather
                // than the "连接" button's "Connect" (verb) — same Chinese, different English.
                section(String(localized: "hostEditor.connectionSection", defaultValue: "连接")) {
                    field(String(localized: "名称")) {
                        TextField("生产服务器", text: $draft.name)
                    }
                    field(String(localized: "IP 地址或主机名")) {
                        TextField("203.0.113.10", text: $draft.host)
                            .textContentType(.URL)
                    }
                    HStack(spacing: Theme.Space.md) {
                        field(String(localized: "端口")) {
                            TextField("22", text: $draft.portText)
                                .frame(width: 84)
                        }
                        field(String(localized: "用户名")) {
                            TextField("root", text: $draft.username)
                        }
                    }
                    Picker("分组", selection: $draft.groupID) {
                        Text("未分组").tag(UUID?.none)
                        ForEach(appState.groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                }

                section(String(localized: "认证")) {
                    Picker("方式", selection: $draft.authType) {
                        Text("密码").tag(HostAuthType.password)
                        Text("私钥").tag(HostAuthType.privateKey)
                    }
                    .pickerStyle(.segmented)

                    if draft.authType == .password {
                        SecureField(draft.editingHostID == nil ? String(localized: "密码") : String(localized: "留空则保留现有密码"), text: $draft.password)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            HStack {
                                Button {
                                    choosePrivateKey()
                                } label: {
                                    Label("选择私钥文件", systemImage: "key")
                                }
                                Spacer()
                            }
                            TextEditor(text: $draft.privateKeyText)
                                .font(Theme.Font.monoSmall)
                                .frame(height: 110)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                                        .stroke(Theme.Color.separator)
                                }
                            SecureField("私钥密码（可选）", text: $draft.privateKeyPassphrase)
                        }
                    }
                }

                section(String(localized: "备注")) {
                    TextField("可选备注", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                section(String(localized: "下载源")) {
                    Picker("境外下载源", selection: $draft.downloadMirrorPolicy) {
                        Text("跟随全局默认").tag(DownloadMirrorPolicy?.none)
                        ForEach(DownloadMirrorPolicy.allCases) { policy in
                            Text(policy.displayName).tag(DownloadMirrorPolicy?.some(policy))
                        }
                    }
                    Text("这台服务器安装 oh-my-zsh 等需从境外下载的操作走哪个源。留「跟随全局默认」即用设置里的全局选项。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                if let error = appState.hostEditorError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.danger)
                        .padding(Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.danger.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
                }

                if let message = appState.hostEditorTestMessage {
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.success)
                        .padding(Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Color.success.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
                }
            }
            .padding(Theme.Space.lg)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                appState.testHostEditorConnection(draft)
            } label: {
                if appState.isTestingHostEditorConnection {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("测试连接")
                }
            }
            .disabled(appState.isTestingHostEditorConnection)
            Spacer()
            Button("取消") {
                appState.closeHostEditor()
                dismiss()
            }
            Button("保存") {
                appState.saveHostDraft(draft)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isDraftValid)
        }
        .padding(Theme.Space.lg)
    }

    private var isDraftValid: Bool {
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled(draft.name), filled(draft.host), filled(draft.username) else { return false }
        guard let port = Int(draft.portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return false }
        return true
    }

    private var hostKeyChallengeBinding: Binding<KnownHostChallenge?> {
        Binding(
            get: { appState.pendingHostKeyChallenge },
            set: { value in
                if value == nil { appState.rejectPendingHostKey() }
            }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            content()
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            content()
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "选择私钥文件")
        if panel.runModal() == .OK, let url = panel.url {
            draft.privateKeyText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
