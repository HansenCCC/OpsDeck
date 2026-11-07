import AppKit
import SwiftUI

struct RemoteTextEditorView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: ServerSession
    @State private var confirmingClose = false
    @State private var confirmingSave = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Color.separator)

            if session.isRemoteTextLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.remoteTextDocument != nil {
                editor
            } else {
                Text("未打开远端文件。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.Color.separator)
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.Color.surface)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: session.remoteTextDocument?.isReadOnly == true ? "doc.text.magnifyingglass" : "doc.text")
                .foregroundStyle(Theme.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.remoteTextDocument?.title ?? String(localized: "远端文件"))
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(session.remoteTextDocument?.path ?? "")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let document = session.remoteTextDocument {
                Text(document.isReadOnly ? String(localized: "只读") : (document.hasUnsavedChanges ? String(localized: "未保存") : String(localized: "已保存")))
                    .font(Theme.Font.caption)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 4)
                    .background(document.hasUnsavedChanges ? Theme.Color.warning.opacity(0.14) : Theme.Color.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 54)
        .background(Theme.Color.surfaceRaised)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let message = session.remoteTextDocument?.message {
                banner(message: message, systemImage: "info.circle")
            }
            if let error = session.remoteTextError {
                banner(message: error, systemImage: "exclamationmark.triangle")
            }

            CodeTextEditor(
                text: contentBinding,
                isReadOnly: session.remoteTextDocument?.isReadOnly == true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let document = session.remoteTextDocument {
                Text("已加载 \(ByteCountFormatter.editorFileSizeFormatter.string(fromByteCount: Int64(document.loadedByteCount)))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }

            Spacer()

            Button("关闭") {
                if session.remoteTextDocument?.hasUnsavedChanges == true {
                    confirmingClose = true
                } else {
                    session.closeRemoteTextDocument()
                }
            }
            .alert("放弃未保存的更改？", isPresented: $confirmingClose) {
                Button("放弃更改", role: .destructive) { session.closeRemoteTextDocument() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前文件有尚未保存的修改，关闭后将丢失。")
            }

            Button {
                guard let document = session.remoteTextDocument else { return }
                if SafetyService.shouldConfirmDangerousActions(settings: appState.settings) {
                    confirmingSave = true
                } else {
                    session.performSaveRemoteTextDocument(document)
                }
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .disabled(session.remoteTextDocument?.isReadOnly != false || session.remoteTextDocument?.hasUnsavedChanges != true || session.isRemoteTextSaving)
            // Confirm from WITHIN the editor sheet. The global dangerous-action alert
            // (in MainWindow) is anchored beneath this sheet and can't present over it,
            // so routing save through it made the button look dead.
            .alert("保存到服务器？", isPresented: $confirmingSave) {
                Button("保存", role: .destructive) {
                    if let document = session.remoteTextDocument {
                        session.performSaveRemoteTextDocument(document)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将写入服务器上的 \(session.remoteTextDocument?.path ?? "")。")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 48)
        .background(Theme.Color.surfaceRaised)
    }

    private func banner(message: String, systemImage: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(systemImage.contains("exclamationmark") ? Theme.Color.warning : Theme.Color.accent)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.Color.accentSoft.opacity(0.45))
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { session.remoteTextDocument?.content ?? "" },
            set: { newValue in
                guard var document = session.remoteTextDocument else { return }
                document.content = newValue
                session.remoteTextDocument = document
            }
        )
    }
}

private extension ByteCountFormatter {
    static let editorFileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

private struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isReadOnly: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(
            x: 0,
            y: 0,
            width: 760,
            height: 560
        ))
        textView.delegate = context.coordinator
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 760,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 560)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setText(text, in: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        let rulerView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.rulerView = rulerView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let contentWidth = max(scrollView.contentSize.width, 1)
        if abs(textView.frame.width - contentWidth) > 1 {
            textView.setFrameSize(NSSize(
                width: contentWidth,
                height: max(textView.frame.height, scrollView.contentSize.height)
            ))
            textView.textContainer?.containerSize = NSSize(
                width: contentWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.isEditable = !isReadOnly
        if textView.string != text {
            setText(text, in: textView, coordinator: context.coordinator)
        }
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    private func setText(_ value: String, in textView: NSTextView, coordinator: Coordinator) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        coordinator.isApplyingExternalText = true
        defer { coordinator.isApplyingExternalText = false }

        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: attributes))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var isApplyingExternalText = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText else { return }
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            rulerView?.needsDisplay = true
        }
    }
}

private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in _: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        if text.length == 0 {
            draw(lineNumber: 1, y: textView.textContainerInset.height, attributes: attributes)
            return
        }

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange), glyphIndex < layoutManager.numberOfGlyphs {
            var effectiveRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let line = lineNumber(in: textView.string, characterIndex: characterIndex)
            draw(
                lineNumber: line,
                y: lineRect.minY + textView.textContainerInset.height,
                attributes: attributes
            )
            glyphIndex = max(NSMaxRange(effectiveRange), glyphIndex + 1)
        }
    }

    private func draw(lineNumber: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let value = "\(lineNumber)" as NSString
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(
                x: ruleThickness - size.width - 10,
                y: y + 1
            ),
            withAttributes: attributes
        )
    }

    private func lineNumber(in text: String, characterIndex: Int) -> Int {
        let nsText = text as NSString
        let length = min(characterIndex, nsText.length)
        var line = 1
        for index in 0..<length where nsText.character(at: index) == 10 {
            line += 1
        }
        return line
    }
}
