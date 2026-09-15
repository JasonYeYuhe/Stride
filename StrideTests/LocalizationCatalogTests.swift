import XCTest
import Foundation

/// The five translation catalogs in Shared/*.lproj.
///
/// Until 1.2.3 more than half of the UI had no entry in any of them — onboarding, templates, the
/// whole habit editor, Weekly Review, the paywall — and nothing noticed, because a missing key
/// silently renders the English source. These tests can't see the Swift source, so they can't
/// prove a new string was added; what they do catch is one language falling behind the others,
/// and a translation whose placeholders don't match its key (which crashes or garbles the text).
final class LocalizationCatalogTests: XCTestCase {
    private let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]

    private func catalog(_ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
                                "\(language).lproj/Localizable.strings is not in the test bundle", file: file, line: line)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) did not parse", file: file, line: line)
    }

    func testEveryLanguageHasTheSameKeys() throws {
        let reference = try catalog("ja")
        XCTAssertGreaterThan(reference.count, 250)
        for language in languages {
            let keys = Set(try catalog(language).keys)
            XCTAssertEqual(keys.subtracting(reference.keys).sorted(), [], "\(language) has keys ja lacks")
            XCTAssertEqual(Set(reference.keys).subtracting(keys).sorted(), [], "\(language) is missing keys")
        }
    }

    func testPlaceholdersMatchTheirKey() throws {
        let pattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|@|lf|d|%)")
        func specifiers(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression) }
                .sorted()
        }
        for language in languages {
            for (key, value) in try catalog(language) {
                XCTAssertEqual(specifiers(value), specifiers(key), "\(language): \"\(key)\" = \"\(value)\"")
            }
        }
    }

    /// Strings from screens that used to be entirely untranslated.
    func testScreensThatUsedToRenderInEnglishAreTranslated() throws {
        let ja = try catalog("ja")
        for key in ["Measurable", "Times per week", "Weekly Review", "Habit Templates", "Welcome to Stride",
                    "Delete Account?", "%lld week streak", "Drink Water", "Health & Fitness"] {
            let value = try XCTUnwrap(ja[key], "no ja entry for \"\(key)\"")
            XCTAssertNotEqual(value, key)
        }
    }
}
