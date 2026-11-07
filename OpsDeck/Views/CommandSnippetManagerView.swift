import SwiftUI

struct CommandSnippetManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var title = ""
    @State private var command = ""
    @State private var group = "常用"
    @State private var requiresConfirmation = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(groupedKeys, id: \.self) { groupName in
                        Section(groupName) {
                            ForEach(snippets(in: groupName)) { snippet in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.title)
                                        .font(Theme.Font.bodyMedium)
                                    Text(snippet.command)
                                        .font(Theme.Font.monoSmall)
                                        .foregroundStyle(Theme.Color.textSecondary)
                                        .lineLimit(1)
                                }
                                .tag(snippet.id)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button {
                        beginNewSnippet()
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        if let selectedSnippet { appState.deleteSnippet(selectedSnippet) }
                        beginNewSnippet()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedSnippet == nil)
                    .help("删除片段")
                    .accessibilityLabel("删除命令片段")
                }
                .padding(Theme.Space.sm)
            }
            .frame(minWidth: 220, idealWidth: 250)

            Form {
                Section("命令片段") {
                    TextField("标题", text: $title)
                    TextField("分组", text: $group)
                    TextEditor(text: $command)
                        .font(Theme.Font.mono)
                        .frame(minHeight: 150)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .stroke(Theme.Color.separator)
                        }
                    Toggle("执行前始终确认", isOn: $requiresConfirmation)
                    Text("“插入”只把文本送到当前终端；“执行”会追加回车并遵守危险命令确认。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
        }
        .onChange(of: selectedID) { _, _ in loadSelection() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button(selectedSnippet == nil ? "添加" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.md)
            .background(Theme.Color.toolbarBackground)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 760, height: 520)
        .background(Theme.Color.surface)
    }

    private var selectedSnippet: CommandSnippet? {
        guard let selectedID else { return nil }
        return appState.snippets.first { $0.id == selectedID }
    }

    private var groupedKeys: [String] {
        Array(Set(appState.snippets.map { $0.group.isEmpty ? String(localized: "未分组") : $0.group })).sorted()
    }

    private func snippets(in groupName: String) -> [CommandSnippet] {
        appState.snippets.filter { ($0.group.isEmpty ? String(localized: "未分组") : $0.group) == groupName }
    }

    private func loadSelection() {
        guard let snippet = selectedSnippet else { return }
        title = snippet.title
        command = snippet.command
        group = snippet.group
        requiresConfirmation = snippet.requiresConfirmation
    }

    private func beginNewSnippet() {
        selectedID = nil
        title = ""
        command = ""
        group = String(localized: "常用")
        requiresConfirmation = false
    }

    private func save() {
        if let snippet = selectedSnippet {
            appState.updateSnippet(snippet, title: title, command: command, group: group, requiresConfirmation: requiresConfirmation)
        } else {
            appState.createSnippet(title: title, command: command, group: group, requiresConfirmation: requiresConfirmation)
        }
        beginNewSnippet()
    }
}
