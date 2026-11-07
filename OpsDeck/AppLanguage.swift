import AppKit
import Foundation

/// In-app language override. macOS applies the choice via the `AppleLanguages`
/// default, which only takes effect on the next launch — so switching relaunches
/// the app. "system" clears the override and follows the OS language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ar
    case de
    case ru
    case fr
    case ko
    case ptBR = "pt-BR"
    case ja
    case tr
    case es

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ar: return "العربية"
        case .de: return "Deutsch"
        case .ru: return "Русский"
        case .fr: return "Français"
        case .ko: return "한국어"
        case .ptBR: return "Português (Brasil)"
        case .ja: return "日本語"
        case .tr: return "Türkçe"
        case .es: return "Español"
        }
    }

    static var supportedLocaleIdentifiers: [String] {
        allCases.filter { $0 != .system }.map(\.rawValue)
    }

    /// The language currently forced via AppleLanguages, or `.system` if none.
    static var current: AppLanguage {
        guard let codes = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let first = codes.first else {
            return .system
        }
        if first.hasPrefix("zh-Hant") || first.hasPrefix("zh-HK") || first.hasPrefix("zh-TW") { return .zhHant }
        if first.hasPrefix("zh") { return .zhHans }
        if first.hasPrefix("en") { return .en }
        if first.hasPrefix("ar") { return .ar }
        if first.hasPrefix("de") { return .de }
        if first.hasPrefix("ru") { return .ru }
        if first.hasPrefix("fr") { return .fr }
        if first.hasPrefix("ko") { return .ko }
        if first.hasPrefix("pt") { return .ptBR }
        if first.hasPrefix("ja") { return .ja }
        if first.hasPrefix("tr") { return .tr }
        if first.hasPrefix("es") { return .es }
        return .system
    }

    /// Persist the choice. Returns true if it differs from the current effective
    /// language (i.e. a relaunch is warranted).
    func apply() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        default:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    /// Relaunch the app so the new language takes effect.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
