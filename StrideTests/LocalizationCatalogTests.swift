import XCTest
import Foundation
import SwiftUI

/// The translation catalogs in Shared/*.lproj: `Localizable.strings` in es/ja/ko/zh-Hans/zh-Hant,
/// and since 1.3.0 `Localizable.stringsdict` (plural rules) in those five plus en.
///
/// Until 1.2.3 more than half of the UI had no entry in any of them — onboarding, templates, the
/// whole habit editor, Weekly Review, the paywall — and nothing noticed, because a missing key
/// silently renders the English source. These tests compare the catalogs with each other and
/// resolve plurals the way the app does at runtime; `LocalizationSourceScanTests` compares them
/// with the Swift source.
final class LocalizationCatalogTests: XCTestCase {
    private let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
    /// English has no Localizable.strings (the key IS the English text) but does have plurals.
    private let pluralLanguages = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

    private func catalog(_ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
                                "\(language).lproj/Localizable.strings is not in the test bundle", file: file, line: line)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) did not parse", file: file, line: line)
    }

    private func plurals(_ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: [String: Any]] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: language),
                                "\(language).lproj/Localizable.stringsdict is not in the test bundle", file: file, line: line)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: [String: Any]], "\(language) stringsdict did not parse", file: file, line: line)
    }

    /// The bundle `LanguageManager.bundle` hands to `appLocalized` for a picked language: the
    /// .lproj directory itself, opened as a bundle. Built the same way here because that type
    /// lives in the app target; what is under test is Foundation's lookup through such a bundle.
    private func lproj(_ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: language, ofType: "lproj"),
                                 "\(language).lproj is not in the test bundle", file: file, line: line)
        return try XCTUnwrap(Bundle(path: path), file: file, line: line)
    }

    // MARK: - Parity

    func testEveryLanguageHasTheSameKeys() throws {
        let reference = try catalog("ja")
        XCTAssertGreaterThan(reference.count, 250)
        for language in languages {
            let keys = Set(try catalog(language).keys)
            XCTAssertEqual(keys.subtracting(reference.keys).sorted(), [], "\(language) has keys ja lacks")
            XCTAssertEqual(Set(reference.keys).subtracting(keys).sorted(), [], "\(language) is missing keys")
        }
        let pluralReference = try plurals("ja")
        XCTAssertGreaterThanOrEqual(pluralReference.count, 20)
        for language in pluralLanguages {
            let keys = Set(try plurals(language).keys)
            XCTAssertEqual(keys.subtracting(pluralReference.keys).sorted(), [], "\(language) stringsdict has keys ja lacks")
            XCTAssertEqual(Set(pluralReference.keys).subtracting(keys).sorted(), [], "\(language) stringsdict is missing keys")
        }
    }

    /// When a key is in both files the stringsdict wins (`testTheStringsdictWinsOverStrings`), so
    /// a copy in Localizable.strings is dead text that silently drifts from what users see.
    func testNoKeyIsInBothFiles() throws {
        for language in languages {
            let both = Set(try catalog(language).keys).intersection(try plurals(language).keys)
            XCTAssertEqual(both.sorted(), [], "\(language): keep plural keys in Localizable.stringsdict only")
        }
    }

    // MARK: - Placeholders

    private static let specifierPattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|@|lf|d|%)")

    private func specifiers(_ s: String) -> [String] {
        Self.specifierPattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression) }
            .sorted()
    }

    func testPlaceholdersMatchTheirKey() throws {
        for language in languages {
            for (key, value) in try catalog(language) {
                XCTAssertEqual(specifiers(value), specifiers(key), "\(language): \"\(key)\" = \"\(value)\"")
            }
        }
    }

    /// A stringsdict entry is a format with `%#@name@` variables, each a dictionary of plural
    /// forms. Expanded, the format must take the same arguments as its key; each form may show the
    /// count once or not at all (the Stats unit keys are the unit alone, "day"/"days").
    func testPluralEntriesAreWellFormed() throws {
        let variablePattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?#@([A-Za-z]+)@")
        for language in pluralLanguages {
            for (key, entry) in try plurals(language) {
                let where_ = "\(language): \"\(key)\""
                let format = try XCTUnwrap(entry["NSStringLocalizedFormatKey"] as? String, where_)
                let names = variablePattern.matches(in: format, range: NSRange(format.startIndex..., in: format))
                    .map { String(format[Range($0.range(at: 1), in: format)!]) }
                XCTAssertEqual(names.count, 1, "\(where_): one plural variable per entry")
                let expanded = variablePattern.stringByReplacingMatches(in: format, range: NSRange(format.startIndex..., in: format),
                                                                        withTemplate: "%lld")
                XCTAssertEqual(specifiers(expanded), specifiers(key), "\(where_): format \"\(format)\"")
                XCTAssertEqual(Set(entry.keys), Set(["NSStringLocalizedFormatKey"] + names), "\(where_): stray keys")
                for name in names {
                    let rule = try XCTUnwrap(entry[name] as? [String: String], "\(where_): no dictionary for \(name)")
                    XCTAssertEqual(rule["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType", where_)
                    XCTAssertEqual(rule["NSStringFormatValueTypeKey"], "lld", "\(where_): counts are Int, so lld")
                    let forms = rule.filter { !$0.key.hasPrefix("NSString") }
                    // English and Spanish distinguish one from other; the CJK languages and Korean
                    // have a single form.
                    let expected: Set<String> = ["en", "es"].contains(language) ? ["one", "other"] : ["other"]
                    XCTAssertEqual(Set(forms.keys), expected, where_)
                    for (category, form) in forms {
                        XCTAssertTrue(specifiers(form) == ["%lld"] || specifiers(form).isEmpty,
                                      "\(where_) \(category): \"\(form)\" — at most one %lld, the count")
                    }
                }
            }
        }
    }

    // MARK: - Runtime lookup

    /// The acceptance sentences of M1: what users read in the two languages with a plural rule,
    /// resolved through the same bundle construction and API as `appLocalized` — including its
    /// `locale:` (`LanguageManager.stringLocale`: the picked language's own locale). Without that
    /// argument this test passed only on an en_US host: `-testLanguage ja -testRegion JP` failed
    /// it 19 times ("Racha de 1 días", "1 habits"), because Foundation takes the plural form from
    /// the locale, not from the bundle's language.
    func testPluralsResolveAtRuntimeInEnglishAndSpanish() throws {
        let bundles = ["en": try lproj("en"), "es": try lproj("es"), "ja": try lproj("ja")]
        let en = "en", es = "es", ja = "ja"
        func loc(_ value: String.LocalizationValue, _ language: String) -> String {
            String(localized: value, bundle: bundles[language]!, locale: Locale(identifier: language))
        }
        for n in [1, 2] {
            // Spanish "Racha de 1 días" is the defect this release fixes.
            XCTAssertEqual(loc("\(n) day streak", es), n == 1 ? "Racha de 1 día" : "Racha de 2 días")
            XCTAssertEqual(loc("\(n) week streak", es), n == 1 ? "Racha de 1 semana" : "Racha de 2 semanas")
            XCTAssertEqual(loc("\(n) check-ins", en), n == 1 ? "1 check-in" : "2 check-ins")
            XCTAssertEqual(loc("\(n) check-ins", es), n == 1 ? "1 registro" : "2 registros")
            XCTAssertEqual(loc("\(n) day streak", en), "\(n) day streak")
            XCTAssertEqual(loc("\(n) remaining", es), n == 1 ? "1 restante" : "2 restantes")
            XCTAssertEqual(loc("\(n) more habits", en), n == 1 ? "1 more habit" : "2 more habits")
            XCTAssertEqual(loc("\(n) habits", en), n == 1 ? "1 habit" : "2 habits")
            XCTAssertEqual(loc("\(n) groups", en), n == 1 ? "1 group" : "2 groups")
            // Unit-only keys: the number is drawn in its own Text next to them.
            XCTAssertEqual(loc("days (unit after \(n))", en), n == 1 ? "day" : "days")
            XCTAssertEqual(loc("weeks (unit after \(n))", en), n == 1 ? "week" : "weeks")
            XCTAssertEqual(loc("weeks (unit after \(n))", es), n == 1 ? "semana" : "semanas")
            XCTAssertEqual(loc("weeks (unit after \(n))", ja), "週")
            XCTAssertEqual(loc("\(n) day streak", ja), "\(n)日連続")
            // The share card draws the number and this label separately.
            XCTAssertEqual(loc("day streak (label under \(n))", es), n == 1 ? "día de racha" : "días de racha")
            XCTAssertEqual(loc("week streak (label under \(n))", en), "week streak")
        }
        // Several arguments: the plural follows the one it is attached to, and the others stay in
        // their positions.
        XCTAssertEqual(loc("\(0) of \(1) habits completed", en), "0 of 1 habit completed")
        XCTAssertEqual(loc("\(1) of \(3) habits completed", en), "1 of 3 habits completed")
        XCTAssertEqual(loc("\(1) of \(1) habits completed, \(100) percent", es), "1 de 1 hábito completado, 100 por ciento")
        XCTAssertEqual(loc("🏃 \(1)/\(3) habits done", en), "🏃 1/3 habits done")
        XCTAssertEqual(loc("🔥 All \(1) habits done!", en), "🔥 1 habit done!")
        XCTAssertEqual(loc("🔥 All \(4) habits done!", en), "🔥 All 4 habits done!")
        XCTAssertEqual(loc("\("Morning"), \(1) habits", es), "Morning, 1 hábito")
        XCTAssertEqual(loc("\("🏃") \("Run"): \(1) day streak", es), "🏃 Run: racha de 1 día")
        XCTAssertEqual(loc("\("🏃") \("Run"): \(3) week streak", ja), "🏃 Run：3週連続")
        XCTAssertEqual(loc("\("Run"), \(1) day streak, best streak \(9), 30-day rate \(80) percent, \(12) of the last 14 days completed", es),
                       "Run, racha de 1 día, mejor racha 9, tasa de 30 días 80 por ciento, 12 de los últimos 14 días completados")
        // Plain keys are unaffected by the new en.lproj: English is still the key itself.
        XCTAssertEqual(loc("Today", en), "Today")
        XCTAssertEqual(loc("Today", es), "Hoy")
    }

    /// Why `appLocalized` passes `locale:`, pinned whatever the host's locale: the Spanish bundle
    /// resolved with a Japanese locale (Spanish picked on a Japanese device, before the fix) gets
    /// Japanese plural rules, which have no "one".
    func testThePluralFormFollowsTheLocaleNotTheBundle() throws {
        let es = try lproj("es"), en = try lproj("en")
        let ja = Locale(identifier: "ja_JP")
        XCTAssertEqual(String(localized: "\(1) day streak", bundle: es, locale: ja), "Racha de 1 días")
        XCTAssertEqual(String(localized: "\(1) habits", bundle: en, locale: ja), "1 habits")
        XCTAssertEqual(String(localized: "\(1) day streak", bundle: es, locale: Locale(identifier: "es")), "Racha de 1 día")
        // The .system fallback: a French device runs Stride in English (no fr.lproj). French puts 0
        // in "one"; the English rule in the French region does not.
        XCTAssertEqual(String(localized: "\(0) habits", bundle: en, locale: Locale(identifier: "fr_FR")), "0 habit")
        XCTAssertEqual(String(localized: "\(0) habits", bundle: en, locale: Locale(identifier: "en_FR")), "0 habits")
        XCTAssertEqual(String(localized: "\(21) habits", bundle: en, locale: Locale(identifier: "en_RU")), "21 habits")
    }

    /// SwiftUI resolves `Text("\(n) day streak")` itself, through the environment locale that the
    /// in-app language picker sets — a different path from `String(localized:)`. It must reach the
    /// same stringsdict.
    @MainActor
    func testSwiftUITextResolvesTheSamePlurals() throws {
        let bundle = Bundle(for: Self.self)
        func resolve(_ text: Text, _ language: String) -> String {
            var environment = EnvironmentValues()
            environment.locale = Locale(identifier: language)
            // `_resolveText(in:)` is SwiftUI's own (underscored) resolution of a Text to the string
            // it draws; there is no public equivalent on iOS 17 / macOS 14.
            return text._resolveText(in: environment)
        }
        for n in [1, 2] {
            XCTAssertEqual(resolve(Text("\(n) day streak", bundle: bundle), "es"), n == 1 ? "Racha de 1 día" : "Racha de 2 días")
            XCTAssertEqual(resolve(Text("\(n) check-ins", bundle: bundle), "en"), n == 1 ? "1 check-in" : "2 check-ins")
            XCTAssertEqual(resolve(Text("weeks (unit after \(n))", bundle: bundle), "ja"), "週")
            XCTAssertEqual(resolve(Text("days (unit after \(n))", bundle: bundle), "en"), n == 1 ? "day" : "days")
        }
        XCTAssertEqual(resolve(Text("\(1) of \(1) habits completed", bundle: bundle), "en"), "1 of 1 habit completed")
    }

    /// The M2 (1.3.1) sync counts — Today's status line, Settings > Sync, the account screen and the
    /// restore hand-over — through both paths the app uses: `String(localized:bundle:locale:)` as
    /// `appLocalized` calls it, and SwiftUI's own `Text` resolution. Each one is an inline row a
    /// user reads with a count of 1 most of the time ("1 change can't sync"), which is exactly the
    /// case a missing plural entry gets wrong ("1 changes").
    @MainActor
    func testSyncCountsResolveOneAndOtherInEnglishAndSpanish() throws {
        let bundles = ["en": try lproj("en"), "es": try lproj("es"), "ja": try lproj("ja")]
        func loc(_ value: String.LocalizationValue, _ language: String) -> String {
            String(localized: value, bundle: bundles[language]!, locale: Locale(identifier: language))
        }
        let testBundle = Bundle(for: Self.self)
        func text(_ text: Text, _ language: String) -> String {
            var environment = EnvironmentValues()
            environment.locale = Locale(identifier: language)
            return text._resolveText(in: environment)
        }
        for n in [1, 2] {
            let one = n == 1
            // Today (SyncStatusRow).
            XCTAssertEqual(loc("Offline — \(n) changes waiting", "en"), one ? "Offline — 1 change waiting" : "Offline — 2 changes waiting")
            XCTAssertEqual(loc("Offline — \(n) changes waiting", "es"), one ? "Sin conexión — 1 cambio pendiente" : "Sin conexión — 2 cambios pendientes")
            XCTAssertEqual(loc("\(n) changes waiting to sync", "en"), one ? "1 change waiting to sync" : "2 changes waiting to sync")
            XCTAssertEqual(loc("\(n) changes can't sync — see Settings", "es"),
                           one ? "1 cambio no se puede sincronizar — consulta Ajustes" : "2 cambios no se pueden sincronizar — consulta Ajustes")
            XCTAssertEqual(text(Text("\(n) changes can't sync — see Settings", bundle: testBundle), "en"),
                           one ? "1 change can't sync — see Settings" : "2 changes can't sync — see Settings")
            XCTAssertEqual(text(Text("Offline — \(n) changes waiting", bundle: testBundle), "es"),
                           one ? "Sin conexión — 1 cambio pendiente" : "Sin conexión — 2 cambios pendientes")
            // Settings > Sync (SyncSectionView).
            XCTAssertEqual(loc("\(n) changes can't sync", "en"), one ? "1 change can't sync" : "2 changes can't sync")
            XCTAssertEqual(text(Text("\(n) changes can't sync", bundle: testBundle), "es"),
                           one ? "1 cambio no se puede sincronizar" : "2 cambios no se pueden sincronizar")
            XCTAssertEqual(text(Text("\(n) habits belong to another account", bundle: testBundle), "en"),
                           one ? "1 habit belongs to another account" : "2 habits belong to another account")
            XCTAssertEqual(loc("\(n) restored items were deleted on another device", "es"),
                           one ? "1 elemento restaurado se eliminó en otro dispositivo" : "2 elementos restaurados se eliminaron en otro dispositivo")
            XCTAssertEqual(text(Text("Recovered Edits (\(n))", bundle: testBundle), "en"), "Recovered Edits (\(n))")
            // A held row's explanation in the number its title counts (E2E S6: "1 restored habit
            // was deleted…" over "Restore them…"). The count picks the form and is not shown.
            XCTAssertEqual(loc("Restore them as new copies to bring them back to your account, or discard them. Your backup file keeps them either way. (\(n) held)", "en"),
                           one ? "Restore it as a new copy to bring it back to your account, or discard it. Your backup file keeps it either way."
                               : "Restore them as new copies to bring them back to your account, or discard them. Your backup file keeps them either way.")
            XCTAssertEqual(text(Text("Restore them as new copies to bring them back to your account, or discard them. Your backup file keeps them either way. (\(n) held)", bundle: testBundle), "es"),
                           one ? "Restáuralo como copia nueva para devolverlo a tu cuenta, o descártalo. Tu archivo de copia de seguridad lo conserva en ambos casos."
                               : "Restáuralos como copias nuevas para devolverlos a tu cuenta, o descártalos. Tu archivo de copia de seguridad los conserva en ambos casos.")
            XCTAssertEqual(text(Text("They came from another account's data, so this account can't sync them as they are. Restore them as new copies to add them to this account. (\(n) held)", bundle: testBundle), "en"),
                           one ? "It came from another account's data, so this account can't sync it as it is. Restore it as a new copy to add it to this account."
                               : "They came from another account's data, so this account can't sync them as they are. Restore them as new copies to add them to this account.")
            XCTAssertEqual(loc("They came from another account's data, so this account can't sync them as they are. Restore them as new copies to add them to this account. (\(n) held)", "es"),
                           one ? "Procede de los datos de otra cuenta, así que esta cuenta no puede sincronizarlo tal como está. Restáuralo como copia nueva para añadirlo a esta cuenta."
                               : "Proceden de los datos de otra cuenta, así que esta cuenta no puede sincronizarlos tal como están. Restáuralos como copias nuevas para añadirlos a esta cuenta.")
            XCTAssertEqual(loc("Restore them as new copies to bring them back to your account, or discard them. Your backup file keeps them either way. (\(n) held)", "ja"),
                           "新しいコピーとして復元してアカウントに戻すか、破棄してください。どちらの場合もバックアップファイルには残ります。")
            // The account screen and the restore hand-over.
            XCTAssertEqual(text(Text("\(n) deletions not yet synced", bundle: testBundle), "en"),
                           one ? "1 deletion not yet synced" : "2 deletions not yet synced")
            XCTAssertEqual(loc("\(n) recovered edits", "en"), one ? "1 recovered edit" : "2 recovered edits")
            XCTAssertEqual(text(Text("\(n) recovered edits", bundle: testBundle), "es"),
                           one ? "1 edición recuperada" : "2 ediciones recuperadas")
            // The restore hand-over counts the same queue with the account screen's key.
            XCTAssertEqual(loc("\(n) deletions not yet synced", "es"),
                           one ? "1 eliminación aún sin sincronizar" : "2 eliminaciones aún sin sincronizar")
            // A single form, the number inside the sentence.
            XCTAssertEqual(loc("\(n) changes waiting to sync", "ja"), "\(n)件の変更が同期待ち")
        }
        // Plain keys with an argument: the email stays where each language puts it.
        XCTAssertEqual(loc("This backup is from another account (\("a@example.com")). Its habits will be added to this account as new copies.", "ja"),
                       "このバックアップは別のアカウント（a@example.com）のものです。習慣は新しいコピーとしてこのアカウントに追加されます。")
        XCTAssertEqual(loc("Synced \("hace 2 minutos")", "es"), "Sincronizado hace 2 minutos")
    }

    /// Every plural entry in every language renders for 1 and 2 without leaving a specifier or
    /// "(null)" behind — a malformed entry fails here rather than on a user's screen.
    func testEveryPluralEntryFormats() throws {
        for language in pluralLanguages {
            let bundle = try lproj(language)
            for key in try plurals(language).keys {
                for n in [1, 2] {
                    let args: [CVarArg] = specifiers(key).isEmpty ? [] : Self.specifierPattern
                        .matches(in: key, range: NSRange(key.startIndex..., in: key))
                        .compactMap { match -> CVarArg? in
                            switch key[Range(match.range, in: key)!] {
                            case "%lld": return n
                            case "%@": return "X"
                            default: return nil
                            }
                        }
                    let format = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                    XCTAssertNotEqual(format, "MISSING", "\(language): \"\(key)\" not found")
                    let rendered = String(format: format, locale: Locale(identifier: language), arguments: args)
                    XCTAssertFalse(rendered.contains("%"), "\(language) \"\(key)\" n=\(n): \(rendered)")
                    XCTAssertFalse(rendered.contains("(null)"), "\(language) \"\(key)\" n=\(n): \(rendered)")
                    XCTAssertNotEqual(rendered, key, "\(language) \"\(key)\" rendered as its key")
                }
            }
        }
    }

    /// The rule `testNoKeyIsInBothFiles` relies on, checked on a scratch bundle rather than
    /// assumed: with the same key in both files, Foundation returns the stringsdict form.
    func testTheStringsdictWinsOverStrings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stride-l10n-\(UUID().uuidString)/es.lproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try #""%lld day streak" = "strings %lld";"#.write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let plural: NSDictionary = ["%lld day streak": [
            "NSStringLocalizedFormatKey": "%#@d@",
            "d": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                  "one": "stringsdict one %lld", "other": "stringsdict other %lld"],
        ]]
        try plural.write(to: dir.appendingPathComponent("Localizable.stringsdict"))
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        // `locale:` as appLocalized passes it; without it a ja host picks "other" for 1.
        let es = Locale(identifier: "es")
        XCTAssertEqual(String(localized: "\(1) day streak", bundle: bundle, locale: es), "stringsdict one 1")
        XCTAssertEqual(String(localized: "\(2) day streak", bundle: bundle, locale: es), "stringsdict other 2")
    }

    // MARK: - Coverage

    /// Strings from screens that used to be entirely untranslated, resolved as the app would.
    func testScreensThatUsedToRenderInEnglishAreTranslated() throws {
        let ja = try lproj("ja")
        for key in ["Measurable", "Times per week", "Weekly Review", "Habit Templates", "Welcome to Stride",
                    "Delete Account?", "%lld week streak", "Drink Water", "Health & Fitness",
                    "weeks (unit after %lld)", "Restore from Backup…", "Sync is paused for maintenance. Your data is safe on this device and will sync when the pause ends.",
                    // M2 (1.3.1): the sync rows and the account screen.
                    "Sync paused", "Sign in again to keep syncing", "%lld changes can't sync — see Settings",
                    "This Device's Habits", "Start from This Account's Data", "Recovered Edits (%lld)", "Before You Restore"] {
            let value = ja.localizedString(forKey: key, value: "MISSING", table: nil)
            XCTAssertNotEqual(value, "MISSING", "no ja entry for \"\(key)\"")
            XCTAssertNotEqual(value, key, "ja \"\(key)\" is still English")
        }
    }
}
