import AppKit
import SwiftUI

struct SSHConfigImportPreview: Identifiable {
    let id = UUID()
    var sourcePath: String
    var entries: [SSHConfigEntry]
}

struct SSHConfigImportView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let preview: SSHConfigImportPreview
    @State private var selectedIDs: Set<UUID>

    init(preview: SSHConfigImportPreview) {
        self.preview = preview
        _selectedIDs = State(initialValue: Set(preview.entries.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("导入 SSH Config")
                    .font(Theme.Font.windowTitle)
                Text(preview.sourcePath)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("将按 user@host:port 去重。私钥只导入本机可读取的 IdentityFile；缺少凭据的服务器可导入后再编辑。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.lg)
            Divider()

            List(preview.entries, selection: $selectedIDs) { entry in
                Toggle(isOn: selectionBinding(for: entry.id)) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Theme.Color.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.alias)
                                .font(Theme.Font.bodyMedium)
                            Text("\(entry.username)@\(entry.hostname):\(entry.port)")
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Label(keyStatus(entry), systemImage: keyIcon(entry))
                            .font(Theme.Font.caption)
                            .foregroundStyle(entry.privateKeyText == nil ? Theme.Color.warning : Theme.Color.success)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button("全选") { selectedIDs = Set(preview.entries.map(\.id)) }
                    .disabled(selectedIDs.count == preview.entries.count)
                Button("全不选") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty)
                Spacer()
                Button("取消") { dismiss() }
                Button("导入 \(selectedIDs.count) 台") {
                    appState.importSSHConfig(preview.entries.filter { selectedIDs.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: 700, height: 520)
        .background(Theme.Color.surface)
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }

    private func keyStatus(_ entry: SSHConfigEntry) -> String {
        guard entry.identityFile != nil else { return String(localized: "待补凭据") }
        return entry.privateKeyText == nil ? String(localized: "私钥不可读") : String(localized: "已读取私钥")
    }

    private func keyIcon(_ entry: SSHConfigEntry) -> String {
        entry.privateKeyText == nil ? "exclamationmark.triangle" : "key.fill"
    }
}

struct HostGroupManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""
    @State private var renameValues: [UUID: String] = [:]
    @State private var groupPendingDelete: HostGroup?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务器分组")
                    .font(Theme.Font.windowTitle)
                Spacer()
            }
            .padding(Theme.Space.lg)
            Divider()

            List {
                ForEach(appState.groups) { group in
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.Color.textSecondary)
                        TextField("分组名称", text: renameBinding(for: group))
                            .onSubmit {
                                appState.renameGroup(group, to: renameValues[group.id] ?? group.name)
                            }
                        Text("\(appState.hosts.filter { $0.groupID == group.id }.count) 台")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                        Button(role: .destructive) {
                            groupPendingDelete = group
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除分组；服务器将移到未分组")
                        .accessibilityLabel("删除分组 \(group.name)")
                    }
                }
            }
            .overlay {
                if appState.groups.isEmpty {
                    ContentUnavailableView("暂无分组", systemImage: "folder", description: Text("创建分组后可在服务器编辑页或右键菜单中归类。"))
                }
            }

            Divider()
            HStack {
                TextField("新分组名称", text: $newGroupName)
                    .onSubmit(createGroup)
                Button("创建") { createGroup() }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: 520, height: 400)
        .background(Theme.Color.surface)
        .alert("删除分组？", isPresented: Binding(
            get: { groupPendingDelete != nil },
            set: { if !$0 { groupPendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let groupPendingDelete { appState.deleteGroup(groupPendingDelete) }
                groupPendingDelete = nil
            }
            Button("取消", role: .cancel) { groupPendingDelete = nil }
        } message: {
            Text("组内服务器会保留并移到“未分组”。")
        }
    }

    private func renameBinding(for group: HostGroup) -> Binding<String> {
        Binding(
            get: { renameValues[group.id] ?? group.name },
            set: { renameValues[group.id] = $0 }
        )
    }

    private func createGroup() {
        appState.createGroup(named: newGroupName)
        newGroupName = ""
    }
}
