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
            // The reminder actions' titles and the pending reminders' text are strings the SYSTEM
            // holds, resolved through `appLocalized` when they were handed over; nothing redraws
            // them the way SwiftUI redraws `Text`. Hand them over again in the new language
            // (RELEASE-1.4.0.md D4). The store is the one the launch opened, if it did.
            if selectedLanguage != oldValue {
                NotificationService.shared.languageDidChange(modelContainer: SharedModelContainer.opened)
            }
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
    ///
    /// Until 1.3.0 there was no en.lproj (English is the key), so picking English fell through to
    /// `.main` — which resolves in the SYSTEM language: English picked on a Japanese device still
    /// got Japanese from `appLocalized`. Shared/en.lproj now exists (it holds the English plural
    /// rules), so English resolves here like every other language. `String(localized:bundle:)`
    /// reads the lproj's Localizable.stringsdict as well — but it picks the plural FORM with its
    /// `locale:` argument, not with the bundle's language; see `stringLocale`.
    var bundle: Bundle {
        guard let code = locale?.identifier,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }

    /// The locale `appLocalized` resolves with: it chooses the stringsdict plural form and formats
    /// the interpolated numbers.
    ///
    /// `String(localized:bundle:)` defaults this to `.current`, and Foundation takes the plural
    /// category from THAT locale, whatever language the bundle is in. Japanese, Chinese and Korean
    /// only have "other", so English or Spanish picked in the app on such a device read "1 habits"
    /// and "Racha de 1 días" in every `appLocalized` string (restore preview, VoiceOver streak
    /// phrase, share text) while the SwiftUI `Text` beside them was right. The M1 tests passed only
    /// because the test Mac is en_US, and English and Spanish share one/other.
    ///
    /// - A picked language: that language's locale, the one SwiftUI already gets through
    ///   `.environment(\.locale)`, so a number formats the same in `Text` and `appLocalized`.
    /// - `.system`: the device locale while the app runs in the device language (no change). When
    ///   Stride has no localization for it (French, Russian…) the app falls back to English, and the
    ///   plural rule must be English too — French puts 0 in "one" ("0 habit"), Russian 21 ("21
    ///   habit"). The region is kept (en_FR), so numbers still format the French way.
    ///
    /// Not covered here: SwiftUI `Text` and the widget use `Locale.current` for that fallback case.
    /// If the OS hands the app fr_FR rather than en_FR there, they show "0 habit" (a scratch
    /// probe with fr_FR shows it; a French device was not tried). Changing the root
    /// `.environment(\.locale)` would also switch their dates to English month names, which is a
    /// product decision, not a fix. It needs a device language Stride does not ship AND a count
    /// of 0 (French, Portuguese) or 21, 31… (Russian, Polish).
    var stringLocale: Locale {
        if let locale { return locale }
        return Self.locale(forLocalization: Bundle.main.preferredLocalizations.first ?? "en", device: .current)
    }

    /// `device` when it already speaks `localization`, else `localization` in the device's region.
    /// Separate from `stringLocale` so a test can hand in any device locale.
    nonisolated static func locale(forLocalization localization: String, device: Locale) -> Locale {
        let resolved = localization == "Base" ? "en" : localization
        guard Locale.Language(identifier: resolved).languageCode != device.language.languageCode else { return device }
        guard let region = device.region?.identifier else { return Locale(identifier: resolved) }
        return Locale(identifier: "\(resolved)_\(region)")
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
    let manager = LanguageManager.shared
    return String(localized: value, bundle: manager.bundle, locale: manager.stringLocale)
}

/// The locale behind the in-app language picker, for date formatting that produces a plain
/// `String` (`Date.formatted`, `DateFormatter`). A `FormatStyle` without `.locale(_:)` formats in
/// the SYSTEM language, so a Japanese-picked app spoke "Monday, September 21" inside a Japanese
/// VoiceOver sentence.
@MainActor
var appLocale: Locale {
    LanguageManager.shared.locale ?? .current
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
