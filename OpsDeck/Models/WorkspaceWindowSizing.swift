import AppKit

/// First-launch window sizing that prefers a spacious workbench without placing
/// content underneath the menu bar or Dock on smaller displays. Once a user
/// resizes a window, AppKit's frame autosave takes precedence.
enum WorkspaceWindowSizing {
    static let mainTarget = NSSize(width: 1_440, height: 900)
    static let mainMinimum = NSSize(width: 960, height: 640)
    static let databaseTarget = NSSize(width: 1_360, height: 840)
    static let databaseMinimum = NSSize(width: 820, height: 480)

    static func mainContentSize(for visibleFrame: NSRect) -> NSSize {
        preferredContentSize(target: mainTarget, minimum: mainMinimum, visibleFrame: visibleFrame)
    }

    static func databaseContentSize(for visibleFrame: NSRect) -> NSSize {
        preferredContentSize(target: databaseTarget, minimum: databaseMinimum, visibleFrame: visibleFrame)
    }

    static func preferredContentSize(target: NSSize, minimum: NSSize, visibleFrame: NSRect) -> NSSize {
        let availableWidth = max(minimum.width, visibleFrame.width - 48)
        let availableHeight = max(minimum.height, visibleFrame.height - 48)
        return NSSize(
            width: min(target.width, availableWidth),
            height: min(target.height, availableHeight)
        )
    }
}
