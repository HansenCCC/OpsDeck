import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileWorkspace: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        RemoteFilePlaceholder()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $session.isShowingNewRemoteDirectorySheet) {
                RemoteNameSheet(
                    title: String(localized: "新建远端文件夹"),
                    prompt: String(localized: "在 \(session.remoteDirectoryPath) 中创建文件夹"),
                    text: $session.newRemoteDirectoryName,
                    confirmTitle: String(localized: "创建"),
                    confirmAction: session.createRemoteDirectory
                )
            }
            .sheet(isPresented: $session.isShowingNewRemoteFileSheet) {
                RemoteNameSheet(
                    title: String(localized: "新建远端文件"),
                    prompt: String(localized: "在 \(session.remoteDirectoryPath) 中创建空文件"),
                    text: $session.newRemoteFileName,
                    confirmTitle: String(localized: "创建"),
                    confirmAction: session.createRemoteFile
                )
            }
            .sheet(item: $session.remoteRenameCandidate) { item in
                RemoteNameSheet(
                    title: String(localized: "重命名"),
                    prompt: item.path,
                    text: $session.remoteRenameName,
                    confirmTitle: String(localized: "重命名"),
                    confirmAction: session.renameRemoteCandidate
                )
            }
            .sheet(item: $session.remoteInfoCandidate) { item in
                RemoteInfoSheet(item: item)
                    .environmentObject(appState)
                    .environmentObject(session)
            }
        }
}

struct LocalFileList: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            LocalFileToolbar()
            Divider().overlay(Theme.Color.separator)

            if appState.localDirectoryURL == nil {
                LocalFolderEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.isLocalFileLoading {
                FileSkeletonRows()
            } else {
                localFileContent
            }
        }
        .frame(minWidth: 310)
        .background(Theme.Color.surface)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .stroke(Theme.Color.accent, lineWidth: 2)
                    .padding(3)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .alert("删除远端项目？", isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                if let item = session.remoteDeleteCandidate {
                    session.deleteRemoteFile(item)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(session.remoteDeleteCandidate?.path ?? "")
        }
        .sheet(isPresented: $session.isShowingNewRemoteDirectorySheet) {
            RemoteNameSheet(
                title: String(localized: "新建远端文件夹"),
                prompt: String(localized: "在 \(session.remoteDirectoryPath) 中创建文件夹"),
                text: $session.newRemoteDirectoryName,
                confirmTitle: String(localized: "创建"),
                confirmAction: session.createRemoteDirectory
            )
        }
        .sheet(isPresented: $session.isShowingNewRemoteFileSheet) {
            RemoteNameSheet(
                title: String(localized: "新建远端文件"),
                prompt: String(localized: "在 \(session.remoteDirectoryPath) 中创建空文件"),
                text: $session.newRemoteFileName,
                confirmTitle: String(localized: "创建"),
                confirmAction: session.createRemoteFile
            )
        }
        .sheet(item: $session.remoteRenameCandidate) { item in
            RemoteNameSheet(
                title: String(localized: "重命名"),
                prompt: item.path,
                text: $session.remoteRenameName,
                confirmTitle: String(localized: "重命名"),
                confirmAction: session.renameRemoteCandidate
            )
        }
        .sheet(item: $session.remoteInfoCandidate) { item in
            RemoteInfoSheet(item: item)
                .environmentObject(appState)
                .environmentObject(session)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { session.remoteDeleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    session.remoteDeleteCandidate = nil
                }
            }
        )
    }

    private var localFileContent: some View {
        VStack(spacing: 0) {
            if let error = appState.localFileError {
                LocalFileErrorBanner(message: error) {
                    appState.localFileError = nil
                }
                Divider().overlay(Theme.Color.separator)
            }

            if appState.localFiles.isEmpty {
                VStack(spacing: Theme.Space.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text("此文件夹为空")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileTableHeader(left: String(localized: "名称"), right: String(localized: "信息"))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.localFiles) { item in
                            LocalFileRow(item: item, isSelected: appState.selectedLocalFileID == item.id)
                                .contentShape(Rectangle())
                                .modifier(FastFileRowInteraction(
                                    selectAction: {
                                        appState.selectLocalFileItem(item)
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    },
                                    openAction: {
                                        appState.openLocalFileItem(item)
                                    }
                                ))
                            Divider().overlay(Theme.Color.separator.opacity(0.45))
                        }
                    }
                }
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    session.uploadDroppedLocalFile(url)
                }
            }
        }
        return accepted
    }

}

private struct LocalFileToolbar: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Label("本地", systemImage: "macwindow")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                FileActionButton(systemName: "chevron.up", help: String(localized: "返回上级文件夹")) {
                    appState.navigateToParentLocalDirectory()
                }
                .disabled(!appState.canNavigateToParentLocalDirectory)

                FileActionButton(systemName: "arrow.clockwise", help: String(localized: "刷新本地文件夹")) {
                    appState.refreshLocalDirectory()
                }
                .disabled(appState.localDirectoryURL == nil)

                FileActionButton(systemName: "folder.badge.plus", help: String(localized: "选择本地文件夹")) {
                    appState.chooseLocalDirectory()
                }

                FileActionButton(systemName: "square.and.arrow.up", help: String(localized: "上传选中的文件")) {
                    session.uploadSelectedLocalFile()
                }
                .disabled(appState.selectedLocalFile?.isDirectory ?? true)
            }
            .frame(height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localDirectoryURL?.path(percentEncoded: false) ?? String(localized: "未选择文件夹"))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(Theme.Color.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .frame(height: 62)
    }
}

private struct LocalFolderEmptyState: View {
    @EnvironmentObject private var appState: AppState

    @EnvironmentObject private var session: ServerSession
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.Color.accent)
            VStack(spacing: Theme.Space.xs) {
                Text("选择本地文件夹")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("OpsDeck 会用 macOS 安全书签保存此文件夹权限。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("选择文件夹") {
                appState.chooseLocalDirectory()
            }
        }
        .padding(Theme.Space.xl)
    }
}

private struct LocalFileRow: View {
    let item: LocalFileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: item.iconSystemName)
                .foregroundStyle(isSelected ? selectedText.opacity(0.92) : (item.isDirectory ? Theme.Color.fileAmber : Theme.Color.textSecondary))
                .frame(width: 18)

            Text(item.name)
                .font(Theme.Font.body)
                .foregroundStyle(isSelected ? selectedText : Theme.Color.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(item.detailText)
                .font(Theme.Font.caption)
                .foregroundStyle(isSelected ? selectedText.opacity(0.82) : Theme.Color.textTertiary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 32)
        .background(SystemSelectionBackground(isSelected: isSelected))
    }

    private var selectedText: SwiftUI.Color {
        SwiftUI.Color(nsColor: .selectedMenuItemTextColor)
    }
}

private struct FileTableHeader: View {
    let left: String
    let right: String

    var body: some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
                .frame(width: 128, alignment: .trailing)
        }
        .font(Theme.Font.tiny.weight(.semibold))
        .foregroundStyle(Theme.Color.textTertiary)
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 24)
        .background(Theme.Color.surfaceRaised.opacity(0.65))
    }
}

private struct FileActionButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FastFileRowInteraction: ViewModifier {
    let selectAction: () -> Void
    let openAction: () -> Void

    func body(content: Content) -> some View {
        Button(action: selectAction) {
            content
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    openAction()
                }
        )
    }
}

private struct RemoteFileRowInteraction: ViewModifier {
    let selectAction: () -> Void
    let openAction: () -> Void
    let dragChangedAction: (DragGesture.Value) -> Void
    let dragEndedAction: () -> Void
    @State private var suppressSelection = false

    func body(content: Content) -> some View {
        Button {
            guard !suppressSelection else {
                suppressSelection = false
                return
            }
            selectAction()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    openAction()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    suppressSelection = true
                    dragChangedAction(value)
                }
                .onEnded { _ in
                    dragEndedAction()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        suppressSelection = false
                    }
                }
        )
    }
}

private struct SystemSelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? SwiftUI.Color(nsColor: .selectedContentBackgroundColor) : SwiftUI.Color.clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }
}

private struct TransferProgressStrip: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let progress: RemoteTransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: iconName)
                    .foregroundStyle(Theme.Color.textTertiary)
                Text(progress.title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(statusText)
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.canPause, !progress.isFinished {
                    Button {
                        progress.isPaused ? session.resumeActiveTransfer() : session.pauseActiveTransfer()
                    } label: {
                        Image(systemName: progress.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(progress.isPaused ? String(localized: "继续传输") : String(localized: "暂停传输"))
                }
                if progress.canCancel, !progress.isFinished {
                    Button {
                        session.cancelActiveTransfer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("取消传输")
                }
            }
            if let value = progress.fractionCompleted {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 6)
        .background(Theme.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(Theme.Color.separator.opacity(0.7), lineWidth: 0.5)
        }
    }

    private var iconName: String {
        switch progress.kind {
        case .upload:
            return "arrow.up.doc"
        case .download:
            return "arrow.down.doc"
        case .compress:
            return "archivebox"
        case .delete:
            return "trash"
        }
    }

    private var statusText: String {
        if progress.isFinished {
            return progress.detail
        }
        if progress.isPaused {
            return String(localized: "已暂停 · \(progress.detail)")
        }
        if let total = progress.totalUnitCount {
            return "\(progress.completedUnitCount)/\(total) · \(progress.detail)"
        }
        return String(localized: "\(progress.completedUnitCount) 个项目 · \(progress.detail)")
    }
}

private struct FileSkeletonRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Color.separator.opacity(0.55))
                        .frame(minWidth: 72, maxWidth: index.isMultiple(of: 3) ? 150 : 220)
                        .frame(height: 9)
                    Spacer(minLength: Theme.Space.xs)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Color.separator.opacity(0.35))
                        .frame(minWidth: 40, maxWidth: 80)
                        .frame(height: 9)
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 32)
                Divider().overlay(Theme.Color.separator.opacity(0.35))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct LocalFileErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Color.warning)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Color.textSecondary)
            .help("关闭提示")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.Color.accentSoft.opacity(0.55))
    }
}

private struct RemoteFilePlaceholder: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var isDropTargeted = false
    @FocusState private var isRemotePathFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.Color.separator)

            if session.isRemoteFileLoading || session.connectionStatus == .connecting {
                FileSkeletonRows()
            } else if session.remoteFiles.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if let error = session.remoteFileError {
                        LocalFileErrorBanner(message: error) {
                            session.remoteFileError = nil
                        }
                        Divider().overlay(Theme.Color.separator)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                FileTableHeader(left: String(localized: "名称"), right: String(localized: "大小 / 权限"))
                                ForEach(session.remoteFiles) { item in
                                    RemoteFileInteractiveRow(
                                        item: item,
                                        isSelected: session.isRemoteFileSelected(item),
                                        scrollToItem: { targetID in
                                            proxy.scrollTo(targetID)
                                        }
                                    )
                                        .contextMenu {
                                            remoteItemContextMenu(for: item)
                                                .onAppear {
                                                    session.prepareRemoteContextSelection(item)
                                                }
                                        }
                                    Divider().overlay(Theme.Color.separator.opacity(0.45))
                                }
                            }
                        }
                        .contextMenu {
                            remoteFolderContextMenu
                        }
                    }
                }
            }
        }
        .frame(minWidth: 310)
        .background(Theme.Color.surface)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .stroke(Theme.Color.accent, lineWidth: 2)
                    .padding(3)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .contextMenu {
            remoteFolderContextMenu
        }
        .background(
            RemoteMouseNavigationHandler(
                goBack: session.navigateRemoteBack,
                goForward: session.navigateRemoteForward
            )
        )
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Label("远端", systemImage: "externaldrive.connected.to.line.below")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                if session.selectedRemoteFileIDs.count > 1 {
                    Text(String(localized: "已选择 \(session.selectedRemoteFileIDs.count) 项"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer(minLength: 0)
                FileActionButton(systemName: "chevron.left", help: String(localized: "返回上一目录")) {
                    session.navigateRemoteBack()
                }
                .disabled(!session.canNavigateRemoteBack)

                FileActionButton(systemName: "chevron.right", help: String(localized: "前进到下一目录")) {
                    session.navigateRemoteForward()
                }
                .disabled(!session.canNavigateRemoteForward)

                FileActionButton(systemName: "chevron.up", help: String(localized: "返回上级文件夹")) {
                    session.navigateToParentRemoteDirectory()
                }
                .disabled(session.connectionStatus != .connected || session.remoteDirectoryPath == "." || session.remoteDirectoryPath == "/")

                FileActionButton(systemName: "terminal", help: String(localized: "终端进入当前远端目录")) {
                    appState.changeTerminalToCurrentRemoteDirectory()
                }
                .disabled(session.connectionStatus != .connected)

                FileActionButton(systemName: "arrow.clockwise", help: String(localized: "刷新远端文件夹")) {
                    session.refreshRemoteDirectory()
                }
                .disabled(session.connectionStatus != .connected)

                FileActionButton(systemName: "folder.badge.plus", help: String(localized: "新建远端文件夹")) {
                    session.openNewRemoteDirectorySheet()
                }
                .disabled(session.connectionStatus != .connected)

                FileActionButton(systemName: "doc.badge.plus", help: String(localized: "新建远端文件")) {
                    session.openNewRemoteFileSheet()
                }
                .disabled(session.connectionStatus != .connected)

                FileActionButton(systemName: "square.and.arrow.up", help: String(localized: "上传文件或文件夹")) {
                    session.chooseFileForUpload()
                }
                .disabled(session.connectionStatus != .connected)

                FileActionButton(systemName: "pencil", help: String(localized: "重命名选中的远端项目")) {
                    session.requestRenameSelectedRemoteFile()
                }
                .disabled(!session.hasSingleRemoteFileSelection)

                FileActionButton(systemName: "square.and.arrow.down", help: String(localized: "下载选中的远端项目")) {
                    session.downloadSelectedRemoteItemToChosenDirectory()
                }
                .disabled(session.selectedRemoteFile == nil)

                FileActionButton(systemName: "doc.text", help: String(localized: "打开选中的文件")) {
                    session.openSelectedRemoteTextFile()
                }
                .disabled(!session.hasSingleRemoteFileSelection || session.selectedRemoteFile?.isEditableTextFile != true)

                FileActionButton(systemName: "trash", help: String(localized: "删除选中的远端项目")) {
                    session.requestDeleteSelectedRemoteFile()
                }
                .disabled(session.selectedRemoteFile == nil)
            }
            .frame(height: 28)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                remotePathField

                if let progress = session.activeTransferProgress {
                    TransferProgressStrip(progress: progress)
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: session.activeTransferProgress == nil ? 62 : 84)
    }

    private var remotePathField: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textTertiary)
            Text("路径")
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(Theme.Color.textSecondary)
            TextField("输入远端路径", text: $session.remotePathInput)
                .font(Theme.Font.monoSmall)
                .textFieldStyle(.plain)
                .focused($isRemotePathFocused)
                .onSubmit {
                    session.openRemotePathFromInput()
                    isRemotePathFocused = false
                }
                .disabled(session.connectionStatus != .connected)
            Button {
                session.openRemotePathFromInput()
                isRemotePathFocused = false
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(session.connectionStatus != .connected)
            .help("打开路径")
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(isRemotePathFocused ? Theme.Color.accent : Theme.Color.separator.opacity(0.9), lineWidth: isRemotePathFocused ? 1.2 : 0.7)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Theme.Color.textTertiary)
            Text(session.connectionStatus == .connected ? String(localized: "此文件夹为空") : String(localized: "连接服务器"))
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.textPrimary)
            if let error = session.remoteFileError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            } else if session.connectionStatus == .connected {
                Text("从 Finder 拖入文件或文件夹，或使用工具栏上传。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            } else if session.connectionStatus != .connected, appState.selectedHost != nil {
                Button {
                    appState.connectSelectedHost()
                } label: {
                    Label("连接", systemImage: "link")
                }
                .controlSize(.small)
            }
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            remoteFolderContextMenu
        }
    }

    @ViewBuilder
    private var remoteFolderContextMenu: some View {
        Button {
            session.openNewRemoteDirectorySheet()
        } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        .disabled(session.connectionStatus != .connected)

        Button {
            session.openNewRemoteFileSheet()
        } label: {
            Label("新建文件", systemImage: "doc.badge.plus")
        }
        .disabled(session.connectionStatus != .connected)

        Divider()

        Button {
            session.chooseFileForUpload()
        } label: {
            Label("上传...", systemImage: "square.and.arrow.up")
        }
        .disabled(session.connectionStatus != .connected)

        Button {
            session.refreshRemoteDirectory()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(session.connectionStatus != .connected)
    }

    @ViewBuilder
    private func remoteItemContextMenu(for item: RemoteFileItem) -> some View {
        if item.isDirectory {
            Button {
                session.selectRemoteFileItem(item)
                session.openRemoteFileItem(item)
            } label: {
                Label("打开", systemImage: "folder")
            }
        } else {
            if item.isEditableTextFile {
                Button {
                    session.selectRemoteFileItem(item)
                    session.openSelectedRemoteTextFile()
                } label: {
                    Label("打开", systemImage: "doc.text")
                }
            }

            if item.isSystemPreviewableFile {
                Button {
                    session.selectRemoteFileItem(item)
                    session.previewSelectedRemoteFile()
                } label: {
                    Label("预览", systemImage: "eye")
                }
            }

            if item.isEditableTextFile {
                Button {
                    session.selectRemoteFileItem(item)
                    session.openSelectedRemoteTailPreview()
                } label: {
                    Label("尾部预览", systemImage: "text.alignleft")
                }
            }
        }

        Divider()

        Button {
            session.prepareRemoteContextSelection(item)
            session.downloadSelectedRemoteItemToChosenDirectory()
        } label: {
            Label(contextSelectionCount(for: item) > 1 ? String(localized: "下载所选项目...") : String(localized: "下载..."), systemImage: "square.and.arrow.down")
        }

        Button {
            session.prepareRemoteContextSelection(item)
            session.requestCompressSelectedRemoteItem()
        } label: {
            Label(contextSelectionCount(for: item) > 1 ? String(localized: "压缩所选项目") : String(localized: "压缩"), systemImage: "archivebox")
        }

        Divider()
        remoteFolderContextMenu
        Divider()

        Button {
            session.selectRemoteFileItem(item)
            session.requestRenameSelectedRemoteFile()
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            session.openRemoteInfo(for: item)
        } label: {
            Label("显示简介", systemImage: "info.circle")
        }

        Button(role: .destructive) {
            session.prepareRemoteContextSelection(item)
            session.requestDeleteSelectedRemoteFile()
        } label: {
            Label(contextSelectionCount(for: item) > 1 ? String(localized: "删除所选项目") : String(localized: "删除"), systemImage: "trash")
        }
    }

    private func contextSelectionCount(for item: RemoteFileItem) -> Int {
        session.isRemoteFileSelected(item) ? session.selectedRemoteFileIDs.count : 1
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    session.uploadDroppedLocalFile(url)
                }
            }
        }
        return accepted
    }

}

private struct RemoteFileInteractiveRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    let item: RemoteFileItem
    let isSelected: Bool
    let scrollToItem: (String) -> Void
    @State private var showsOpenAction = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var isDragSelecting = false
    @State private var lastDragTargetID: String?

    var body: some View {
        ZStack(alignment: .trailing) {
            RemoteFileRow(
                item: item,
                isSelected: isSelected,
                hidesDetail: showsOpenAction
            )
            .contentShape(Rectangle())
            .modifier(RemoteFileRowInteraction(
                selectAction: {
                    let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    session.selectRemoteFileItem(item, modifiers: modifiers)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                },
                openAction: {
                    session.selectRemoteFileItem(item)
                    session.openRemoteFileItem(item)
                },
                dragChangedAction: { value in
                    updateDragSelection(value)
                },
                dragEndedAction: {
                    session.endRemoteFileDragSelection()
                    isDragSelecting = false
                    lastDragTargetID = nil
                }
            ))

            if showsOpenAction {
                Button {
                    session.selectRemoteFileItem(item)
                    session.openRemoteFileItem(item)
                } label: {
                    Label(String(localized: "进入 \(item.name)"), systemImage: "arrow.right")
                        .font(Theme.Font.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 138)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.trailing, Theme.Space.md)
                .transition(.opacity)
                .help(String(localized: "打开文件夹 \(item.name)"))
            }
        }
        .onHover(perform: updateHoverState)
        .onDisappear {
            hoverTask?.cancel()
        }
        .animation(.easeOut(duration: 0.12), value: showsOpenAction)
    }

    private func updateDragSelection(_ value: DragGesture.Value) {
        if !isDragSelecting {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            session.beginRemoteFileDragSelection(at: item, modifiers: modifiers)
            isDragSelecting = true
            showsOpenAction = false
        }

        let rowStride: CGFloat = 33
        guard !session.remoteFiles.isEmpty,
              let startIndex = session.remoteFiles.firstIndex(where: { $0.id == item.id }) else { return }
        let indexOffset = Int(floor(value.location.y / rowStride))
        let targetIndex = min(max(startIndex + indexOffset, 0), session.remoteFiles.count - 1)
        let target = session.remoteFiles[targetIndex]
        session.updateRemoteFileDragSelection(through: target)
        if lastDragTargetID != target.id {
            lastDragTargetID = target.id
            scrollToItem(target.id)
        }
    }

    private func updateHoverState(_ isHovering: Bool) {
        hoverTask?.cancel()
        guard isHovering, item.isDirectory else {
            showsOpenAction = false
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            showsOpenAction = true
        }
    }
}

private struct RemoteFileRow: View {
    let item: RemoteFileItem
    let isSelected: Bool
    let hidesDetail: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            RemoteFileIcon(item: item)

            Text(item.name)
                .font(Theme.Font.body)
                .foregroundStyle(isSelected ? selectedText : Theme.Color.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(item.detailText)
                .font(Theme.Font.caption)
                .foregroundStyle(isSelected ? selectedText.opacity(0.82) : Theme.Color.textTertiary)
                .lineLimit(1)
                .frame(width: 148, alignment: .trailing)
                .opacity(hidesDetail ? 0 : 1)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 32)
        .background(SystemSelectionBackground(isSelected: isSelected))
    }

    private var selectedText: SwiftUI.Color {
        SwiftUI.Color(nsColor: .selectedMenuItemTextColor)
    }
}

private struct RemoteFileIcon: View {
    let item: RemoteFileItem

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }

    private var icon: NSImage {
        if item.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (item.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else {
            return NSWorkspace.shared.icon(for: .data)
        }
        return NSWorkspace.shared.icon(for: type)
    }
}

private struct RemoteInfoSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @Environment(\.dismiss) private var dismiss
    let item: RemoteFileItem
    @State private var permissionMode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.md) {
                RemoteFileIcon(item: item)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(Theme.Font.windowTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(kindText)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                infoRow(String(localized: "位置"), item.path, isPath: true)
                infoRow(String(localized: "大小"), sizeText)
                if item.isDirectory {
                    infoRow(String(localized: "包含"), containedText)
                }
                infoRow(String(localized: "权限"), item.permissionsText)
                infoRow(String(localized: "所有者"), item.ownerName ?? "--")
                infoRow(String(localized: "用户组"), item.groupName ?? "--")
                if let target = item.symbolicLinkTarget {
                    infoRow(String(localized: "链接目标"), target, isPath: true)
                }
                infoRow(String(localized: "修改时间"), modifiedText)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("更改权限")
                    .font(Theme.Font.sectionTitle)
                HStack {
                    TextField("例如 644", text: $permissionMode)
                        .frame(width: 110)
                    Button("预览更改…") {
                        session.requestChangePermissions(for: item, mode: permissionMode)
                        session.remoteInfoCandidate = nil
                        dismiss()
                    }
                    .disabled(permissionMode.range(of: "^[0-7]{3,4}$", options: .regularExpression) == nil)
                }
                Text("执行前会显示完整 chmod 命令和当前权限，不会静默修改。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            if session.isRemoteInfoLoading {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在计算文件夹大小...")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }

            if let error = session.remoteInfoError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.warning)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    session.remoteInfoCandidate = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .background(Theme.Color.surface)
        .onAppear { permissionMode = item.permissionsText }
    }

    private func infoRow(_ label: String, _ value: String, isPath: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(isPath ? Theme.Font.monoSmall : Theme.Font.caption)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(isPath ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var kindText: String {
        switch item.kind {
        case .directory:
            return String(localized: "文件夹")
        case .file:
            return String(localized: "文件")
        case .symbolicLink:
            return String(localized: "符号链接")
        case .unknown:
            return String(localized: "未知项目")
        }
    }

    private var sizeText: String {
        guard let byteCount = session.remoteInfoSummary?.byteCount else {
            return item.isDirectory ? String(localized: "正在计算") : "--"
        }
        return ByteCountFormatter.remoteInfoSizeFormatter.string(fromByteCount: byteCount)
    }

    private var containedText: String {
        guard let summary = session.remoteInfoSummary else {
            if let childCount = item.childCount {
                return String(localized: "\(childCount) 项")
            }
            return String(localized: "正在计算")
        }
        if let directChildCount = summary.directChildCount {
            return String(localized: "\(directChildCount) 项（\(summary.fileCount) 个文件，\(summary.folderCount) 个文件夹）")
        }
        return String(localized: "\(summary.fileCount) 个文件，\(summary.folderCount) 个文件夹")
    }

    private var modifiedText: String {
        item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "--"
    }
}

private struct RemoteNameSheet: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let confirmTitle: String
    let confirmAction: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title)
                .font(Theme.Font.windowTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(prompt)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            TextField("名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    confirm()
                }
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button(confirmTitle) {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 380)
        .background(Theme.Color.surface)
    }

    private func confirm() {
        confirmAction()
        dismiss()
    }
}

private struct RemoteMouseNavigationHandler: NSViewRepresentable {
    let goBack: () -> Void
    let goForward: () -> Void

    func makeNSView(context _: Context) -> MouseNavigationView {
        let view = MouseNavigationView()
        view.goBack = goBack
        view.goForward = goForward
        return view
    }

    func updateNSView(_ nsView: MouseNavigationView, context _: Context) {
        nsView.goBack = goBack
        nsView.goForward = goForward
    }
}

private final class MouseNavigationView: NSView {
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return event }

            switch event.buttonNumber {
            case 3:
                goBack()
                return nil
            case 4:
                goForward()
                return nil
            default:
                return event
            }
        }
    }
}

private extension ByteCountFormatter {
    static let remoteInfoSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

#Preview {
    let app = AppState()
    let session = ServerSession(
        host: HostProfile(name: "Preview", host: "127.0.0.1", username: "preview"),
        app: app
    )
    return FileWorkspace()
        .environmentObject(app)
        .environmentObject(session)
}
