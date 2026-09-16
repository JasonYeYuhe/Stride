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

    @MainActor
    var displayName: String {
        switch self {
        case .system: return appLocalized("System Default")
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
            AnalyticsService.shared.send("languageChanged", metadata: ["language": selectedLanguage.rawValue])
        }
    }

    /// The locale to apply, or nil to use system default.
    var locale: Locale? {
        guard selectedLanguage != .system else { return nil }
        return Locale(identifier: selectedLanguage.rawValue)
    }

    /// The bundle UI strings must be resolved from.
    ///
    /// The picker only sets `.environment(\.locale)`, which SwiftUI applies to
    /// `LocalizedStringKey` — `Text("…")`, `.accessibilityLabel("…")`. `String(localized:)`
    /// ignores it and reads the SYSTEM language, and nothing here writes `AppleLanguages`, so
    /// relaunching does not help either. Running the app in Japanese on an English device
    /// therefore drew a Japanese screen under an English "Today" title. Anything that has to
    /// produce a plain `String` goes through `appLocalized` below.
    var bundle: Bundle {
        guard let code = locale?.identifier,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        self.selectedLanguage = AppLanguage(rawValue: stored) ?? .system
    }
}

/// `String(localized:)` that follows the in-app language picker, for the places that need a
/// plain `String` (VoiceOver announcements, values handed to non-`Text` API, notification
/// bodies). Everything that can be a `LocalizedStringKey` should be one instead — SwiftUI
/// resolves those through the environment locale on its own.
@MainActor
func appLocalized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: LanguageManager.shared.bundle)
}

/// A calendar whose weekday and month NAMES follow the in-app language picker. The week still
/// starts where the device region says it does — that is a regional convention, not a language
/// one, and `Calendar.current` already has it right.
@MainActor
var appCalendar: Calendar {
    var calendar = Calendar.current
    guard let locale = LanguageManager.shared.locale else { return calendar }
    let firstWeekday = calendar.firstWeekday   // set explicitly: it must survive the locale swap
    calendar.locale = locale
    calendar.firstWeekday = firstWeekday
    return calendar
}
