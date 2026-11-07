import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var workspaceRefreshShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installWorkspaceRefreshShortcutMonitor()
        #if DEBUG
        if ScreenshotRenderer.isEnabled {
            // Headless visual regression runs do not always materialize the
            // WindowGroup, so drive the same idempotent startup explicitly.
            appState.start()
        } else {
            OpsDeckSmokeRunner.runIfRequested(appState: appState)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceRefreshShortcutMonitor {
            NSEvent.removeMonitor(workspaceRefreshShortcutMonitor)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.checkForAppUpdateIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // The main window is hidden (not closed) on Cmd+W by CloseToHideWindowDelegate,
        // so it still lives in `sender.windows`. Surface that existing window and return
        // `false` to suppress AppKit's default reopen — otherwise SwiftUI's WindowGroup
        // spawns an *additional* window on top of the one we just revived, and each dock
        // reactivation stacks up one more "home" (and one more DB browser window with it).
        //
        // Match by identifier, not `canBecomeMain/Key`: the welcome/help windows are
        // titled (so they satisfy those predicates too) and linger in `sender.windows`
        // after close (`isReleasedWhenClosed = false`, property never nil'd). Since
        // `windows` has no defined order, a stale welcome window could otherwise be
        // surfaced instead of the workspace. Mirrors AppState.showMainWindow().
        if let window = sender.windows.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("OpsDeckMainWindow")
        }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return false
        }
        // No revivable window (e.g. it was genuinely torn down) — let AppKit/SwiftUI
        // create a fresh one.
        return true
    }

    @objc func refreshCurrentWorkspace(_ sender: Any?) {
        appState.refreshCurrentWorkspace()
    }

    private func installWorkspaceRefreshShortcutMonitor() {
        workspaceRefreshShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard Self.isWorkspaceRefreshShortcut(event) else { return event }
            guard event.window?.isKeyWindow == true || event.window?.isMainWindow == true else { return event }
            self?.refreshCurrentWorkspace(nil)
            return nil
        }
    }

    private static func isWorkspaceRefreshShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        guard modifiers.subtracting([.command, .capsLock]).isEmpty else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "r"
    }
}
