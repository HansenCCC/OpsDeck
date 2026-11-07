import AppKit
import SwiftUI

// MARK: - Database browser as its own window (Navicat-style)
//
// The browser hosts a heavy 40-column NSTableView that re-lays-out on every
// scroll/resize frame. When it lived inside the main window's giant SwiftUI
// hosting view, each of those frames forced the top-level `AppKitWindowHostingView`
// to re-measure the ENTIRE app tree (sidebar + inspector + workspace) via
// `NSHostingView.minSize()` → `ViewGraph.sizeThatFits`, spiking a full core.
// Giving the browser its OWN `NSHostingController`/window shrinks that per-frame
// measure to just the browser's small tree, and matches the product shape
// (a database opens in its own window). State stays shared: the window's root
// observes the same `ServerSession` + `DBBrowserState`, so it is fully live.

/// Owns the browser's `NSWindow` and mirrors it to `DBBrowserState.dbBrowserTarget`.
/// Held as a `@StateObject` by `DatabasesPane`.
@MainActor
final class DatabaseBrowserWindowManager: ObservableObject {
    private static let frameAutosaveName = "OpsDeckDatabaseBrowserWindowFrame"
    private var controller: NSWindowController?
    private var closeObserver: NSObjectProtocol?

    /// Open the window when a target is set, close it when cleared.
    func sync(target: DatabaseTarget?, appState: AppState, session: ServerSession) {
        if target != nil {
            if controller == nil {
                open(appState: appState, session: session)
            } else {
                controller?.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            tearDown()
        }
    }

    private func open(appState: AppState, session: ServerSession) {
        let root = DatabaseBrowserView()
            .environmentObject(appState)
            .environmentObject(session)
            .environmentObject(session.dbState)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("opsdeck.database-browser")
        window.title = String(localized: "数据库 · \(session.host.name)")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 480)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_BROWSER_PERF_PREVIEW"] == "1" {
            window.setContentSize(NSSize(width: 1_440, height: 900))
            window.center()
        } else {
            restoreFrameOrApplyDefault(to: window)
        }
        #else
        restoreFrameOrApplyDefault(to: window)
        #endif

        // User closes the window (red button) → clear the target, which mirrors
        // back through `sync` and tears the controller down. Observe rather than
        // become the delegate so we don't fight SwiftUI's own window plumbing.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak session] _ in
            MainActor.assumeIsolated {
                session?.closeDatabaseBrowser()
            }
        }

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreFrameOrApplyDefault(to window: NSWindow) {
        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restoredFrame,
           let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            window.setContentSize(WorkspaceWindowSizing.databaseContentSize(for: visibleFrame))
            window.center()
        }
    }

    private func tearDown() {
        guard let controller else { return }
        self.controller = nil
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        // Delegateless close; the willClose observer is already removed, so this
        // won't re-enter `closeDatabaseBrowser`.
        controller.window?.orderOut(nil)
        controller.close()
    }
}
