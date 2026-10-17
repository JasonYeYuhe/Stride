import XCTest
@testable import Stride

/// `appLocalized` through the real `LanguageManager`, which StrideTests cannot see (it lives in
/// the app target). LocalizationCatalogTests proves the catalogs; this proves the app hands them
/// the right locale.
///
/// The 1.3.0 review found English or Spanish picked in the app on a Japanese, Chinese or Korean
/// device still read "1 habits" and "Racha de 1 días" in every `appLocalized` string: the plural
/// form came from the SYSTEM locale, and the tests only passed because the test machines are
/// en_US. The assertions on `stringLocale` hold on any host; the resolved strings would have
/// caught it only under `-testLanguage ja -testRegion JP`, which is how the fix was checked.
@MainActor
final class AppLocalizedTests: XCTestCase {

    private var saved: AppLanguage = .system
    private var hadStoredLanguage = false
    private var notificationDefaults: ScratchDefaults?

    override func setUp() async throws {
        try await super.setUp()
        saved = LanguageManager.shared.selectedLanguage
        hadStoredLanguage = UserDefaults.standard.object(forKey: "stride_app_language") != nil
        // Since 1.4.0 a language change hands the reminder actions and the pending reminders to
        // the system again (`NotificationService.languageDidChange`): to a recording center here,
        // never the host app's real one.
        let scratch = ScratchDefaults("notifications.language")
        notificationDefaults = scratch
        NotificationService.testOverride = NotificationService(center: RecordingCenter(), defaults: scratch.defaults)
    }

    override func tearDown() async throws {
        LanguageManager.shared.selectedLanguage = saved
        if !hadStoredLanguage { UserDefaults.standard.removeObject(forKey: "stride_app_language") }
        NotificationService.testOverride = nil
        notificationDefaults?.remove()
        try await super.tearDown()
    }

    func testAPickedLanguageResolvesWithItsOwnPluralRules() {
        let manager = LanguageManager.shared

        manager.selectedLanguage = .spanish
        XCTAssertEqual(manager.stringLocale.language.languageCode, "es")
        XCTAssertEqual(appLocalized("\(1) day streak"), "Racha de 1 día")
        XCTAssertEqual(appLocalized("\(2) day streak"), "Racha de 2 días")
        XCTAssertEqual(appLocalized("\(1) habits"), "1 hábito")

        manager.selectedLanguage = .english
        XCTAssertEqual(manager.stringLocale.language.languageCode, "en")
        XCTAssertEqual(appLocalized("\(1) habits"), "1 habit")
        XCTAssertEqual(appLocalized("\(1) check-ins"), "1 check-in")
        XCTAssertEqual(appLocalized("\(1) groups"), "1 group")

        manager.selectedLanguage = .japanese
        XCTAssertEqual(manager.stringLocale.language.languageCode, "ja")
        XCTAssertEqual(appLocalized("\(1) day streak"), "1日連続")
    }

    /// `.system` keeps the device locale while the app runs in the device language, and swaps
    /// only the language when Stride falls back to English for a language it does not ship.
    func testTheSystemFallbackUsesTheLanguageTheAppRunsIn() {
        let fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(LanguageManager.locale(forLocalization: "en", device: fr).identifier, "en_FR")
        XCTAssertEqual(LanguageManager.locale(forLocalization: "Base", device: fr).identifier, "en_FR")
        let ja = Locale(identifier: "ja_JP")
        XCTAssertEqual(LanguageManager.locale(forLocalization: "ja", device: ja), ja)
        let zh = Locale(identifier: "zh_CN")
        XCTAssertEqual(LanguageManager.locale(forLocalization: "zh-Hans", device: zh), zh)

        // What the fallback buys: English plural rules, French number format.
        let enFR = LanguageManager.locale(forLocalization: "en", device: fr)
        let english = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "")
        XCTAssertNotNil(english, "Stride.app has no en.lproj")
        XCTAssertEqual(String(localized: "\(0) habits", bundle: english, locale: enFR), "0 habits")
        XCTAssertEqual(String(localized: "\(0) habits", bundle: english, locale: fr), "0 habit", "French puts 0 in \"one\"")
        XCTAssertTrue(String(format: "%.1f", locale: enFR, 1234.5).hasSuffix(",5"))
    }
}
