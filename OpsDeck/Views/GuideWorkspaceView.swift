import AppKit
import SwiftUI

/// 指南 workspace — curated command tutorials (offline) plus an on-demand
/// `--help`/`man` lookup for any installed tool (requires a connection).
struct GuideWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    let session: ServerSession?
    @State private var selectedTopicID: String?
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(Theme.Color.sidebarBackground)
            Divider().overlay(Theme.Color.separator)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Color.surface)
        .onAppear {
            if appState.guideTopics.isEmpty {
                appState.refreshGuideTopics()
            }
            if selectedTopicID == nil {
                selectedTopicID = appState.guideTopics.first?.id
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textTertiary)
                TextField("搜索命令或工具", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 36)
            Divider().overlay(Theme.Color.separator)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(GuideCategory.allCases) { category in
                        let topics = filteredTopics(in: category)
                        if !topics.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(category.displayName, systemImage: category.systemImage)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .padding(.horizontal, Theme.Space.sm)
                                    .padding(.bottom, 2)
                                ForEach(topics) { topic in
                                    GuideTopicRow(
                                        topic: topic,
                                        isSelected: topic.id == selectedTopicID
                                    ) {
                                        selectedTopicID = topic.id
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.sm)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let topic = selectedTopic {
            GuideDetailView(topic: topic, session: session)
        } else {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "book")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Color.textTertiary)
                Text("选择左侧主题查看命令指南")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedTopic: GuideTopic? {
        appState.guideTopics.first { $0.id == selectedTopicID }
            ?? filteredAll.first
    }

    private var filteredAll: [GuideTopic] {
        guard !searchText.isEmpty else { return appState.guideTopics }
        return appState.guideTopics.filter { matches($0, searchText) }
    }

    private func filteredTopics(in category: GuideCategory) -> [GuideTopic] {
        appState.guideTopics.filter { topic in
            topic.category == category && (searchText.isEmpty || matches(topic, searchText))
        }
    }

    private func matches(_ topic: GuideTopic, _ query: String) -> Bool {
        let q = query.lowercased()
        if topic.title.lowercased().contains(q) || topic.summary.lowercased().contains(q) {
            return true
        }
        let allCommands = topic.quickStart + topic.sections.flatMap(\.commands)
        return allCommands.contains {
            $0.command.lowercased().contains(q) || $0.explanation.lowercased().contains(q)
        }
    }
}

private struct GuideTopicRow: View {
    let topic: GuideTopic
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(topic.title)
                .font(Theme.Font.body)
                .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row)
                        .fill(isSelected ? Theme.Color.rowSelected : SwiftUI.Color.clear)
                )
                .padding(.horizontal, Theme.Space.xs)
        }
        .buttonStyle(.plain)
    }
}

private struct GuideDetailView: View {
    @EnvironmentObject private var appState: AppState
    let topic: GuideTopic
    let session: ServerSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                // Header
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(topic.title)
                            .font(Theme.Font.windowTitle)
                            .foregroundStyle(Theme.Color.textPrimary)
                        Spacer()
                        if let binary = topic.helpBinary ?? topic.toolID {
                            Button {
                                session?.requestToolHelp(binary: binary, title: topic.title)
                            } label: {
                                Label("在服务器查看 --help", systemImage: "questionmark.circle")
                            }
                            .controlSize(.small)
                            .disabled(session?.connectionStatus != .connected)
                            .help(session?.connectionStatus == .connected
                                  ? String(localized: "在服务器上读取该工具的 --help / man（只读）")
                                  : String(localized: "连接服务器后可用"))
                        }
                    }
                    Text(topic.summary)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let doc = topic.externalDoc {
                        Text("官方文档：\(doc)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                            .textSelection(.enabled)
                    }
                }

                if !topic.quickStart.isEmpty {
                    GuideCommandGroup(heading: String(localized: "快速入门"), commands: topic.quickStart, highlighted: true)
                }

                ForEach(topic.sections) { section in
                    GuideCommandGroup(heading: section.heading, commands: section.commands, highlighted: false)
                }

                if topic.quickStart.isEmpty && topic.sections.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("这是一个自动收录的工具条目。点右上角「在服务器查看 --help」可直接读取它自带的帮助文档。")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .fill(Theme.Color.surfaceRaised)
                    )
                }
            }
            .padding(Theme.Space.lg)
        }
    }
}

private struct GuideCommandGroup: View {
    let heading: String
    let commands: [GuideCommand]
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(heading)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(highlighted ? Theme.Color.accent : Theme.Color.textPrimary)
            VStack(spacing: 0) {
                ForEach(commands) { command in
                    GuideCommandRow(command: command)
                    if command.id != commands.last?.id {
                        Divider().overlay(Theme.Color.separator.opacity(0.4))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(Theme.Color.surfaceRaised)
            )
        }
    }
}

private struct GuideCommandRow: View {
    let command: GuideCommand
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.command)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                Text(command.explanation)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let example = command.example {
                    Text("例：\(example)")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            Button {
                copy(command.command)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.Color.success : Theme.Color.textTertiary)
            }
            .buttonStyle(.plain)
            .help("复制命令")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
    }
}
