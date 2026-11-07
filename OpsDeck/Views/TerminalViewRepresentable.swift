import AppKit
import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif

#if canImport(SwiftTerm)
private final class LayoutAwareTerminalView: TerminalView {
    var onViewportReady: ((TerminalView) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onViewportReady?(self)
        }
    }
}

/// AppKit delegates can fire synchronously while SwiftUI is executing
/// `updateNSView`. Publishing observable state from those callbacks triggers
/// SwiftUI's "Publishing changes from within view updates" warning. Keep the
/// bridge one-way during the update, then publish the latest delegate values on
/// the next main-loop turn. Resize/title/directory updates are state snapshots,
/// so coalescing intermediate values is both safe and less noisy.
final class TerminalViewCallbackDispatcher {
    typealias ResizeHandler = (Int, Int, Int, Int) -> Void
    typealias TitleHandler = (String) -> Void
    typealias DirectoryHandler = (String?) -> Void

    private var pendingResize: (handler: ResizeHandler, columns: Int, rows: Int, width: Int, height: Int)?
    private var pendingTitle: (handler: TitleHandler, value: String)?
    private var pendingDirectory: (handler: DirectoryHandler, value: String?)?
    private var isFlushScheduled = false

    func scheduleResize(
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        handler: @escaping ResizeHandler
    ) {
        pendingResize = (handler, columns, rows, pixelWidth, pixelHeight)
        scheduleFlush()
    }

    func scheduleTitle(_ title: String, handler: @escaping TitleHandler) {
        pendingTitle = (handler, title)
        scheduleFlush()
    }

    func scheduleDirectory(_ directory: String?, handler: @escaping DirectoryHandler) {
        pendingDirectory = (handler, directory)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        let resize = pendingResize
        let title = pendingTitle
        let directory = pendingDirectory
        pendingResize = nil
        pendingTitle = nil
        pendingDirectory = nil

        if let resize {
            resize.handler(resize.columns, resize.rows, resize.width, resize.height)
        }
        if let title {
            title.handler(title.value)
        }
        if let directory {
            directory.handler(directory.value)
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let tabID: UUID
    let outputBytes: [UInt8]
    let fontSize: CGFloat
    let onInput: ([UInt8]) -> Void
    let onResize: (Int, Int, Int, Int) -> Void
    let onTitleChange: (String) -> Void
    let onCurrentDirectoryChange: (String?) -> Void

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: TerminalViewRepresentable
        private var renderedTabID: UUID?
        private var renderedByteCount = 0
        private let callbackDispatcher = TerminalViewCallbackDispatcher()

        init(parent: TerminalViewRepresentable) {
            self.parent = parent
        }

        func update(parent: TerminalViewRepresentable, view: TerminalView) {
            self.parent = parent
            let didChangeTab = renderedTabID != parent.tabID
            if didChangeTab || parent.outputBytes.count < renderedByteCount {
                view.getTerminal().resetToInitialState()
                renderedTabID = parent.tabID
                renderedByteCount = 0
            }

            if abs(view.font.pointSize - parent.fontSize) > 0.1 {
                view.font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            }

            if didChangeTab {
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }
                    view.window?.makeFirstResponder(view)
                }
            }

            renderPendingOutput(in: view)
        }

        func viewportDidBecomeReady(_ view: TerminalView) {
            renderPendingOutput(in: view)
        }

        private func renderPendingOutput(in view: TerminalView) {
            // SwiftUI creates NSViewRepresentable with a zero frame, then lays it
            // out. Feeding the terminal before that first real size makes
            // SwiftTerm construct an 80×25 buffer and immediately shrink it,
            // which can leave the initial scroll position outside the viewport.
            guard view.bounds.width > 0, view.bounds.height > 0,
                  parent.outputBytes.count > renderedByteCount else { return }
            let suffix = parent.outputBytes[renderedByteCount...]
            view.feed(byteArray: ArraySlice(suffix))
            renderedByteCount = parent.outputBytes.count
            view.needsDisplay = true
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let scale = source.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let pixelWidth = max(1, Int(source.bounds.width * scale))
            let pixelHeight = max(1, Int(source.bounds.height * scale))
            callbackDispatcher.scheduleResize(
                columns: newCols,
                rows: newRows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                handler: parent.onResize
            )
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            callbackDispatcher.scheduleTitle(title, handler: parent.onTitleChange)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            callbackDispatcher.scheduleDirectory(directory, handler: parent.onCurrentDirectoryChange)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            parent.onInput(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let string = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = LayoutAwareTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        view.onViewportReady = { [weak coordinator = context.coordinator] terminalView in
            coordinator?.viewportDidBecomeReady(terminalView)
        }
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        // SwiftTerm enables its partial-redraw workaround by default on modern
        // macOS. Inside a SwiftUI split panel the first layout can grow from a
        // zero-sized view, leaving the initial terminal buffer painted against
        // the old bounds. A full redraw keeps the first frame and later panel
        // resizes aligned with the actual viewport.
        view.disableFullRedrawOnAnyChanges = false
        view.nativeForegroundColor = NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.86, alpha: 1)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.06, green: 0.075, blue: 0.085, alpha: 1)
        view.caretViewTracksFocus = true
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.update(parent: self, view: nsView)
    }
}

enum TerminalResponderActions {
    static func copy() {
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }

    static func paste() {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }

    static func selectAll() {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }

    static func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }
}
#else
struct TerminalViewRepresentable: View {
    var body: some View {
        Text("此构建无法使用 SwiftTerm。")
            .font(Theme.Font.caption)
    }
}
#endif
