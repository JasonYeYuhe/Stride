import SwiftUI

/// Supported app languages.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        }
    }
}

/// Manages in-app language override.
@MainActor
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private let key = "stride_app_language"

    var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: key)
        }
    }

    /// The locale to apply, or nil to use system default.
    var locale: Locale? {
        guard selectedLanguage != .system else { return nil }
        return Locale(identifier: selectedLanguage.rawValue)
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        self.selectedLanguage = AppLanguage(rawValue: stored) ?? .system
    }
}
