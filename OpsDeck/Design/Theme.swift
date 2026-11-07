import AppKit
import SwiftUI

enum Theme {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 6
        static let row: CGFloat = 6
        static let panel: CGFloat = 8
        static let window: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Font {
        static let windowTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let tiny = SwiftUI.Font.system(size: 10, weight: .regular)
        static let mono = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    enum Color {
        static let appBackground = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let sidebarBackground = dynamic(light: 0xF2F2F2, dark: 0x222326)
        static let surface = SwiftUI.Color(nsColor: .textBackgroundColor)
        static let surfaceRaised = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let toolbarBackground = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        static let textPrimary = SwiftUI.Color(nsColor: .labelColor)
        static let textSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let accent = SwiftUI.Color(nsColor: .controlAccentColor)
        static let accentSoft = SwiftUI.Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.14))
        static let rowHover = SwiftUI.Color(nsColor: .quaternaryLabelColor).opacity(0.10)
        static let rowSelected = SwiftUI.Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)
        static let fileAmber = dynamic(light: 0xB36B00, dark: 0xD59A31)
        static let success = dynamic(light: 0x248A3D, dark: 0x31C46B)
        static let warning = dynamic(light: 0xB36B00, dark: 0xD59A31)
        static let danger = dynamic(light: 0xC33A32, dark: 0xFF6961)
        static let terminalBackground = dynamic(light: 0x13171A, dark: 0x0F1315)
        static let terminalText = dynamic(light: 0xD7E1DD, dark: 0xD7E1DD)
        static let terminalChrome = dynamic(light: 0xF2F2F2, dark: 0x1B1B1D)
    }
}

extension SwiftUI.Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

func dynamic(light: UInt, dark: UInt, alpha: Double = 1) -> SwiftUI.Color {
    SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let value = isDark ? dark : light
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    })
}
