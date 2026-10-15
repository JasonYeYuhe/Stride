import XCTest
import Foundation
import SwiftUI

/// Every literal UI string in the app and widget sources must have a Japanese entry.
///
/// Why this exists: 1.2.3 shipped `Text("weeks")` on the Stats card. The literal was in none of
/// the five catalogs, so every language showed the English word, and nothing noticed —
/// `LocalizationCatalogTests` can only compare the catalogs with each other, never with the
/// code. This test reads the Swift source, rebuilds the runtime key of each literal handed to a
/// localizing API, and looks it up in ja (`.strings` or `.stringsdict`). Japanese is the
/// reference because the parity tests keep the other four languages equal to it.
///
/// It is a regex-level scan, not a compiler: a key built across several lines, computed at
/// runtime (`Text(habit.name)`, `LocalizedStringKey(someVar)`) or passed through a helper is not
/// seen. That is accepted — the class that shipped is a plain literal with no entry. It also
/// fails on a string literal inside an interpolation (`"\(done ? "completed" : "…")"`), the other
/// 1.2.3 class: no catalog entry can translate words that reach the key as one `%@`.
///
/// Runtime keys are rebuilt the way `LocalizedStringKey` / `String.LocalizationValue` build them,
/// NOT from `xcodebuild -exportLocalizations`: on Xcode 27 that tool reported
/// `Text("\(n) check-ins")` as `"%@ check-ins"` when the app actually looks up
/// `"%lld check-ins"` (RELEASE-1.2.3.md, "Localization"). Each interpolation becomes the
/// specifier of its Swift type — Int `%lld`, String `%@`, Double `%lf` — which
/// `testInterpolationRuleMatchesTheRuntime` checks against this toolchain with `Mirror`. The type
/// of an interpolated expression is read from `expressionTypes` below or inferred from its shape
/// (`Int(…)`, `….count`); an expression it cannot type fails the test, so a new interpolation is
/// typed on purpose instead of guessed.
final class LocalizationSourceScanTests: XCTestCase {

    // MARK: - What is scanned

    /// Directories scanned, relative to the repository root.
    private static let sourceRoots = ["Stride/Sources", "StrideWidget/Sources"]

    /// Call sites whose first argument (or both branches of a top-level ternary) is a key.
    /// `Text(verbatim:)` and `Text(someString)` do not match: they are deliberately untranslated.
    private static let callPattern = [
        // SwiftUI views and modifiers that take a LocalizedStringKey title.
        "Text", "Label", "Button", "Section", "Toggle", "TextField", "SecureField", "Picker",
        "Stepper", "DatePicker", "LocalizedStringKey", "LocalizedStringResource",
        "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue",
        "confirmationDialog", "alert", "configurationDisplayName", "description",
        // Also LocalizedStringKey titles, in use or one edit away (a review found
        // `ProgressView("…")`, `LabeledContent("…")`, `Link("…")` and `prompt:` unscanned).
        "ProgressView", "LabeledContent", "Link", "NavigationLink", "ShareLink", "Menu",
        "ContentUnavailableView", "help", "navigationSubtitle", "prompt:",
        // App Intents: `AppShortcut(… shortTitle: "…")` is a LocalizedStringResource.
        "shortTitle:",
        // The Mac's menu bar (1.4.0, RELEASE-1.4.0.md D3). `CommandMenu("…")` takes a
        // LocalizedStringKey; `CommandGroup(` takes a placement, so it yields a key only if a
        // future one is ever titled. Their items' titles are `appLocalized`, matched below.
        "CommandMenu", "CommandGroup",
        // Plain-String paths: the in-app-language helper and Foundation.
        "appLocalized", "String\\(localized:", "@Parameter\\(title:",
        // Labelled arguments of this app's own views whose stored property is a
        // LocalizedStringKey (StatCard, PricingCard, OnboardingPage, EmptyState…).
        "title:", "subtitle:", "label:", "message:", "badge:", "a11yLabel:", "a11yValue:",
    ]

    /// `static var title: LocalizedStringResource = "…"` and friends (App Intents).
    private static let declaredTypes = ["LocalizedStringResource", "LocalizedStringKey", "IntentDescription"]

    /// Keys that are meant to render as written in every language, each with its reason. An
    /// entry the source no longer produces fails the test, so the list cannot quietly grow.
    private static let untranslated: Set<String> = [
        "%lld",         // a bare number, e.g. Text("\(count)")
        "%lld%%",       // a bare percentage, e.g. Text("\(rate)%")
        "%lld/%lld",    // "3/5" counters: digits and a slash read the same in every language
        "%@",           // a user-entered name, or a value already formatted for the locale
        "%@ %@",        // Today's week strip: weekday name + day number, both from appCalendar
                        // (WeekStripView — not Date.shortWeekday, which ignores the picker)
        "",             // .navigationTitle("") on the paywall: an intentionally empty title
        "iOS", "macOS", // Settings > About > Platform: product names
    ]

    /// Interpolated expressions whose type cannot be read off their shape. The value is the
    /// format specifier Swift puts into the runtime key for that type. When this test reports an
    /// expression it cannot type, check the declaration and add it here — and if it is not an
    /// Int, String or Double, think about what the key will look like at runtime first.
    private static let expressionTypes: [String: String] = {
        let ints = [
            "count", "streak", "current", "best", "completed", "total", "memberCount",
            "timesPerWeek", "currentStreak", "bestStreak", "completionRate", "percent", "habit.streak", "habit.timesPerWeek", "entry.completedCount",
            "entry.totalCount", "layout.more", "data.count", "preview.habits", "preview.checkIns",
            "preview.groups", "habit.weeklyCompletions(containing: date)",
            "currentPage + 1", "targetValue", "todayCount",
            "failure.code",   // StoreOpenFailure.code: the store error screen's number
        ]
        let strings = [
            "error", "newError", "email", "habitName", "habit.emoji", "habit.name", "unit",
            "group.name", "title", "weekday", "dayNumber", "logged", "target", "dateLabel",
            "point.spokenDate", "best.emoji", "best.name", "worst.emoji", "worst.name",
            "template.displayName",
            "Self.amount(result.loggedValue)", "Self.amount(habit.targetValue)", "status",
            "failure.domain", // StoreOpenFailure.domain, e.g. NSCocoaErrorDomain
        ]
        var table: [String: String] = [:]
        for e in ints { table[e] = "%lld" }
        for e in strings { table[e] = "%@" }
        return table
    }()

    // MARK: - Tests

    func testEveryLiteralKeyHasAJapaneseEntry() throws {
        let ja = try Self.japaneseKeys()
        var missing: [String] = []
        var untyped: [String] = []
        var nested: [String] = []
        var allowlisted: Set<String> = []
        let sites = try Self.scan()
        XCTAssertGreaterThan(sites.count, 300, "the scan found too few keys to be reading the sources")
        for site in sites {
            if !site.nestedLiterals.isEmpty {
                nested.append("\(site.location): \\(\(site.nestedLiterals.joined(separator: ", ")))")
            }
            guard let key = site.key else {
                untyped.append("\(site.location): \(site.unknownExpressions.map { "\\(\($0))" }.joined(separator: ", "))")
                continue
            }
            if Self.untranslated.contains(key) { allowlisted.insert(key); continue }
            if ja.contains(key) { continue }
            missing.append("\(site.location): \"\(key)\"")
        }
        XCTAssertEqual(missing, [], "literal keys with no ja entry (add them to all five catalogs)")
        XCTAssertEqual(untyped, [], "interpolations this test cannot type — add them to expressionTypes")
        XCTAssertEqual(Self.untranslated.subtracting(allowlisted).sorted(), [], "allowlisted keys no source produces any more — remove them")
        XCTAssertEqual(nested, [], """
            a string literal inside an interpolation is never translated: the whole \\(…) becomes \
            one %@ argument. Choose between two complete keys outside the interpolation instead.
            """)
    }

    /// The Int / String / Double rule the scan relies on, checked against the Swift in use. If a
    /// toolchain ever changes the specifiers, this fails before the scan starts lying.
    func testInterpolationRuleMatchesTheRuntime() {
        let n = 3, s = "x", d = 1.5
        XCTAssertEqual(Self.runtimeKey(LocalizedStringKey("\(n) day streak")), "%lld day streak")
        XCTAssertEqual(Self.runtimeKey(LocalizedStringKey("Add one to \(s)")), "Add one to %@")
        XCTAssertEqual(Self.runtimeKey(LocalizedStringKey("\(d) km")), "%lf km")
        XCTAssertEqual(Self.runtimeKey(LocalizedStringKey("\(n)% vs last week")), "%lld%% vs last week")
        XCTAssertEqual(Self.runtimeKey(LocalizedStringKey("Save 44%")), "Save 44%")

        // The scanner's own reconstruction of the same literals.
        XCTAssertEqual(Self.keys(in: #"Text("\(count) check-ins")"#), ["%lld check-ins"])
        XCTAssertEqual(Self.keys(in: #"Text("\(count)% vs last week")"#), ["%lld%% vs last week"])
        XCTAssertEqual(Self.keys(in: #"Text("Save 44%")"#), ["Save 44%"])
        XCTAssertEqual(Self.keys(in: #"Text("We sent it to **\(email)**.\n\nPaste \"it\".")"#),
                       ["We sent it to **%@**.\n\nPaste \"it\"."])
        XCTAssertEqual(Self.keys(in: #".accessibilityLabel(entry.totalCount == 0 ? "No habits yet" : "\(entry.completedCount) of \(entry.totalCount) habits completed")"#),
                       ["No habits yet", "%lld of %lld habits completed"])
        XCTAssertEqual(Self.keys(in: #"Text(habit.streakUnit == "week" ? "\(streak) week streak" : "\(streak) day streak")"#),
                       ["%lld week streak", "%lld day streak"])
        XCTAssertEqual(Self.keys(in: #"Text(verbatim: "Stride") Text(habit.name) // Text("commented")"#), [])
        XCTAssertEqual(Self.keys(in: #"static var title: LocalizedStringResource = "Toggle Habit""#), ["Toggle Habit"])
        XCTAssertEqual(Self.keys(in: #"ProgressView("Processing...") LabeledContent("Version", value: v) Link("Terms of Use", destination: u)"#),
                       ["Processing...", "Version", "Terms of Use"])
        XCTAssertEqual(Self.keys(in: #".searchable(text: $q, prompt: "Search templates").help("Add") Menu("Sort") shortTitle: "List Habits","#),
                       ["Search templates", "Add", "Sort", "List Habits"])
        // `NavigationLink(` / `ShareLink(` are their own names, not a `Link(` match inside them.
        XCTAssertEqual(Self.keys(in: #"NavigationLink("Stats") { x } ShareLink(item: url)"#), ["Stats"])
        // Menu bar commands: a CommandMenu's title, and the in-app-language titles of the items
        // in a CommandGroup, whose own first argument is a placement.
        XCTAssertEqual(Self.keys(in: #"CommandMenu("Habits") { } CommandGroup(replacing: .newItem) { Button(appLocalized("New Habit")) { } }"#),
                       ["Habits", "New Habit"])
        XCTAssertEqual(Self.keys(in: #"CommandGroup(after: .newItem) { Item(.syncNow, title: appLocalized("Sync Now")) }"#),
                       ["Sync Now"])
        // The 1.2.3 class that no catalog entry can fix: the words are a %@ argument.
        let nested = Self.scan(#"Text("\(habit.name), \(done ? "completed" : "not completed")")"#, file: "inline")
        XCTAssertEqual(nested.first?.nestedLiterals, [#""completed""#, #""not completed""#])
    }

    /// The ternary branches are found past commas and braces nested in the condition. A comma
    /// inside `f(a, b)` used to end the scan, so neither "A" nor "B" was ever looked up.
    func testTernaryAfterNestedCommasIsScanned() {
        XCTAssertEqual(Self.keys(in: #"Text(f(a, b) ? "A" : "B")"#), ["A", "B"])
        XCTAssertEqual(Self.keys(in: #"Text(xs.contains(where: { $0.isOn }) ? "A" : "B")"#), ["A", "B"])
        // A top-level comma still ends it: the second argument is not the key.
        XCTAssertEqual(Self.keys(in: #"Text(title, tableName: flag ? "A" : "B")"#), [])
    }

    // MARK: - Pro claims (1.4.1 D11)

    /// What Advanced Analytics holds, word for word, on the paywall and on Statistics' locked card.
    private static let advancedAnalytics = "Insights, the 8-week trend, the strength chart and your top 5 streaks"

    /// Every place the app says what Stride Pro is names the same set (RELEASE-1.4.1.md D11):
    /// Habit Groups; Advanced Analytics (Insights, the 8-week trend, the strength chart and the top
    /// 5 streaks); Weekly Review. Until 1.4.1 the paywall put Weekly Review inside Advanced
    /// Analytics and the locked card named it too, though nothing behind that card is Weekly
    /// Review. The free detail card keeps its Best Streak tile, so no key may sell "best streaks".
    /// A grep, not a render: it pins the literals the three views pass, which is where the copy
    /// drifted. The store's six STRIDE PRO blocks are `testStoreDescriptionsSellD11sProSet`; the
    /// review notes are W9's to check by hand.
    func testProClaimsNameExactlyD11sSet() throws {
        // Every call in the app, so a second paywall row or locked card anywhere fails here too.
        let app = try Self.swiftFiles(under: "Stride/Sources")
        let paywall = try Self.captures(#"ProFeatureRow\(icon: "[^"]*", color: \.[A-Za-z]+, title: "([^"]*)", subtitle: "([^"]*)"\)"#, in: app)
        XCTAssertEqual(paywall, [
            ["Habit Groups", "Organize habits into collapsible groups"],
            ["Advanced Analytics", Self.advancedAnalytics],
            ["Weekly Review", "A look back at how your week went"],
        ], "the paywall's feature rows (ProPaywallView)")

        // Advanced Analytics only: Weekly Review is Pro, but Stats' toolbar button sells it.
        let lockedCards = try Self.captures(#"ProLockedCard\(\s*title: "([^"]*)",\s*message: "([^"]*)""#, in: app)
        XCTAssertEqual(lockedCards, [["Advanced Analytics", Self.advancedAnalytics]], "Statistics' ProLockedCard")

        // The paywall's three rows in one line, under "Upgrade to Pro".
        let upsell = try Self.captures(#"Text\("Upgrade to Pro"\)[\s\S]*?Text\("([^"]*)"\)"#, in: app)
        XCTAssertEqual(upsell, [["Habit groups, advanced analytics & weekly review"]], "Settings' Pro upsell")

        let keys = Set(try Self.scan().compactMap(\.key))
        XCTAssertEqual(keys.filter { $0.lowercased().contains("best streaks") }.sorted(), [],
                       "the free card keeps its Best Streak tile: Pro copy says \"your top 5 streaks\"")
        // The 1.4.0 subtitle that put Weekly Review under Advanced Analytics: used nowhere, kept
        // nowhere (the catalogs' parity test holds the other four to ja).
        let retired = "8-week trends, insights & weekly review"
        XCTAssertFalse(keys.contains(retired), "the source uses the retired Pro subtitle again")
        XCTAssertFalse(try Self.japaneseKeys().contains(retired), "the retired Pro subtitle is back in the catalogs")
    }

    /// The App Store descriptions (metadata/<locale>/description.txt, which push_metadata.py sends
    /// stripped): each fits App Store Connect's 4,000 characters, and each STRIDE PRO block lists
    /// D11's three things. The English block is D11's draft copy; the others must name the
    /// strength chart with the app's own word for Strength, and the statistics paragraph must
    /// mention History (the plan says "fix past days in your history", never "tap").
    func testStoreDescriptionsSellD11sProSet() throws {
        let locales = [("en-US", "en"), ("es-ES", "es"), ("ja", "ja"), ("ko", "ko"), ("zh-Hans", "zh-Hans"), ("zh-Hant", "zh-Hant")]
        for (locale, language) in locales {
            let url = Self.repositoryRoot.appendingPathComponent("metadata/\(locale)/description.txt")
            let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            // UTF-16 units: never fewer than the characters App Store Connect counts.
            XCTAssertLessThanOrEqual(text.utf16.count, 4000, "\(locale): App Store Connect refuses a description over 4,000 characters")
            let bullets = text.components(separatedBy: "\n").filter { $0.hasPrefix("• ") || $0.hasPrefix("・") || $0.hasPrefix("- ") }
            XCTAssertEqual(bullets.count, 3, "\(locale): the STRIDE PRO block lists exactly Habit Groups, Advanced Analytics and Weekly Review")
            guard bullets.count == 3 else { continue }
            // The app's own words (English has no Localizable.strings: the key is the text).
            let catalog: [String: String]
            if language == "en" { catalog = ["Strength": "Strength", "History": "History"] } else { catalog = try Self.catalog(language) }
            let strength = try XCTUnwrap(catalog["Strength"], "\(language) has no \"Strength\"").lowercased()
            let history = try XCTUnwrap(catalog["History"], "\(language) has no \"History\"").lowercased()
            let lowered = text.lowercased()
            XCTAssertTrue(bullets[1].lowercased().contains(strength) && bullets[1].contains("5"),
                          "\(locale): Advanced Analytics names the \(strength) chart and the top 5 streaks: \(bullets[1])")
            XCTAssertGreaterThanOrEqual(lowered.components(separatedBy: strength).count - 1, 2,
                                        "\(locale): Strength is named twice, the free score in the statistics paragraph and the Pro chart")
            XCTAssertTrue(lowered.contains(history), "\(locale): the statistics paragraph says past days are fixed in \(history)")
        }

        let en = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("metadata/en-US/description.txt"), encoding: .utf8)
        let lines = en.components(separatedBy: "\n")
        for line in ["Stride Pro adds three things:",
                     "• Habit Groups — organize habits into collapsible groups",
                     "• Advanced Analytics — Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks",
                     "• Weekly Review — a look back at how your week went"] {
            XCTAssertTrue(lines.contains(line), "en-US lacks D11's line \"\(line)\"")
        }
        XCTAssertTrue(en.contains("a strength score that recovers from a missed day"), "en-US statistics paragraph")
        XCTAssertTrue(en.contains("Fix past days in your history"), "en-US statistics paragraph")
        XCTAssertFalse(en.lowercased().contains("best streaks"), "en-US sells \"best streaks\"; the Best Streak tile is free")
    }

    /// The Swift files under a directory of the repository, sorted by path.
    private static func swiftFiles(under root: String) throws -> [URL] {
        let dir = repositoryRoot.appendingPathComponent(root)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil), "\(root) is not readable")
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// The capture groups of every match of `pattern`, file by file, in order. Whole-line
    /// comments are blanked first, as the scan does, so a doc comment quoting a call is no match.
    private static func captures(_ pattern: String, in files: [URL]) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        return try files.flatMap { url -> [[String]] in
            let text = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { stripComment(String($0)) }
                .joined(separator: "\n")
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
            }
        }
    }

    // MARK: - Catalog

    private static func catalog(_ language: String) throws -> [String: String] {
        let url = repositoryRoot.appendingPathComponent("Shared/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) Localizable.strings did not parse")
    }

    private static func japaneseKeys() throws -> Set<String> {
        let lproj = repositoryRoot.appendingPathComponent("Shared/ja.lproj")
        let strings = try XCTUnwrap(NSDictionary(contentsOf: lproj.appendingPathComponent("Localizable.strings")) as? [String: String],
                                    "ja Localizable.strings did not parse")
        let plurals = NSDictionary(contentsOf: lproj.appendingPathComponent("Localizable.stringsdict")) as? [String: Any] ?? [:]
        return Set(strings.keys).union(plurals.keys)
    }

    // MARK: - Scanner

    struct Site {
        let location: String
        let key: String?
        let unknownExpressions: [String]
        let nestedLiterals: [String]
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func scan() throws -> [Site] {
        var sites: [Site] = []
        let fm = FileManager.default
        for root in sourceRoots {
            let dir = repositoryRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: nil), "\(root) is not readable")
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = "\(root)/\(url.path.replacingOccurrences(of: dir.path + "/", with: ""))"
                sites += scan(text, file: name)
            }
        }
        return sites
    }

    /// Keys only — for the self-checks in `testInterpolationRuleMatchesTheRuntime`.
    static func keys(in text: String) -> [String] {
        scan(text, file: "inline").compactMap(\.key)
    }

    private static let callRegex: NSRegularExpression = {
        let calls = callPattern.map { $0.hasSuffix(":") ? $0 : "\($0)\\(" }.joined(separator: "|")
        let declared = declaredTypes.joined(separator: "|")
        // Either a call or labelled argument whose first argument follows it, or a declaration
        // typed as a localized value (`title: LocalizedStringResource = "…"`).
        return try! NSRegularExpression(pattern: "(?:(?<![A-Za-z0-9_.])\\.?(?:\(calls))\\s*)|(?:(?<![A-Za-z0-9_])(?:\(declared))\\s*=\\s*)")
    }()

    static func scan(_ source: String, file: String) -> [Site] {
        // Blank out whole-line comments (doc comments quote code, e.g. `Text("weeks")`) and the
        // tail of a line after `//` when that `//` is not inside a string literal.
        let text = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripComment(String($0)) }
            .joined(separator: "\n")
        let chars = Array(text.unicodeScalars)
        let ns = text as NSString
        var sites: [Site] = []
        for match in callRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // NSString offsets are UTF-16; convert to a scalar index.
            let prefix = ns.substring(to: match.range.location + match.range.length)
            var i = prefix.unicodeScalars.count
            let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
            let location = "\(file):\(line)"
            for literal in argumentLiterals(chars, from: &i) {
                sites.append(site(for: literal, at: location))
            }
        }
        return sites
    }

    /// The literal(s) an argument list starts with: one literal, or the two branches of a
    /// top-level ternary (`cond ? "a" : "b"`). Anything else (a variable, a call) yields none.
    private static func argumentLiterals(_ c: [Unicode.Scalar], from i: inout Int) -> [Literal] {
        func skipSpace() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }
        skipSpace()
        guard i < c.count else { return [] }
        if c[i] == "\"" {
            guard let lit = parseLiteral(c, &i) else { return [] }
            return [lit]
        }
        // Look for `?` at depth 0 on this line, skipping nested literals and parentheses.
        var depth = 0
        while i < c.count, c[i] != "\n" {
            switch c[i] {
            case "(", "[": depth += 1; i += 1
            case ")", "]":
                if depth == 0 { return [] }
                depth -= 1; i += 1
            // Only at depth 0 does a comma or brace end the first argument. Written as
            // `case ",", "{", "}" where depth == 0` the guard bound to "}" alone, so the comma in
            // `Text(f(a, b) ? "A" : "B")` ended the scan and both keys went unchecked.
            case ",", "{", "}":
                if depth == 0 { return [] }
                i += 1
            case "\"":
                guard parseLiteral(c, &i) != nil else { return [] }
            case "?" where depth == 0 && i + 1 < c.count && (c[i + 1] == " " || c[i + 1] == "\""):
                i += 1; skipSpace()
                guard i < c.count, c[i] == "\"", let first = parseLiteral(c, &i) else { return [] }
                skipSpace()
                guard i < c.count, c[i] == ":" else { return [] }
                i += 1; skipSpace()
                guard i < c.count, c[i] == "\"", let second = parseLiteral(c, &i) else { return [first] }
                return [first, second]
            default: i += 1
            }
        }
        return []
    }

    private struct Literal {
        /// Alternating text and interpolations, text already unescaped.
        var parts: [Part] = []
        enum Part { case text(String), expression(String, containsLiteral: [String]) }
    }

    /// Parses a single-line Swift string literal at `c[i] == "\""`, leaving `i` after its closing
    /// quote. Multi-line (`"""`) and raw (`#"…"#`) literals return nil.
    private static func parseLiteral(_ c: [Unicode.Scalar], _ i: inout Int) -> Literal? {
        guard c[i] == "\"" else { return nil }
        if i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" { return nil }
        i += 1
        var lit = Literal()
        var text = ""
        while i < c.count {
            let ch = c[i]
            if ch == "\n" { return nil }
            if ch == "\"" { i += 1; if !text.isEmpty { lit.parts.append(.text(text)) }; return lit }
            if ch == "\\", i + 1 < c.count {
                let next = c[i + 1]
                if next == "(" {
                    if !text.isEmpty { lit.parts.append(.text(text)); text = "" }
                    i += 2
                    var depth = 1
                    var expr = ""
                    var nested: [String] = []
                    while i < c.count, depth > 0 {
                        let e = c[i]
                        if e == "\n" { return nil }
                        if e == "\"" {
                            let start = i
                            guard parseLiteral(c, &i) != nil else { return nil }
                            let raw = String(String.UnicodeScalarView(c[start..<i]))
                            expr += raw
                            nested.append(raw)
                            continue
                        }
                        if e == "(" { depth += 1 }
                        if e == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                        expr.unicodeScalars.append(e)
                        i += 1
                    }
                    lit.parts.append(.expression(expr.trimmingCharacters(in: .whitespaces), containsLiteral: nested))
                    continue
                }
                switch next {
                case "n": text += "\n"
                case "t": text += "\t"
                case "0": text += "\0"
                case "\"": text += "\""
                case "'": text += "'"
                case "\\": text += "\\"
                case "u":
                    // \u{…}
                    var j = i + 3
                    var hex = ""
                    while j < c.count, c[j] != "}" { hex.unicodeScalars.append(c[j]); j += 1 }
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { text.unicodeScalars.append(s) }
                    i = j + 1
                    continue
                default: text.unicodeScalars.append(next)
                }
                i += 2
                continue
            }
            text.unicodeScalars.append(ch)
            i += 1
        }
        return nil
    }

    private static func site(for literal: Literal, at location: String) -> Site {
        let interpolated = literal.parts.contains { if case .expression = $0 { return true } else { return false } }
        var key = ""
        var unknown: [String] = []
        var nested: [String] = []
        for part in literal.parts {
            switch part {
            case .text(let t):
                // LocalizedStringKey / LocalizationValue escape `%` in the literal segments of an
                // interpolated key ("\(n)% vs last week" -> "%lld%% vs last week") and leave a
                // plain literal alone ("Save 44%").
                key += interpolated ? t.replacingOccurrences(of: "%", with: "%%") : t
            case .expression(let e, let literals):
                nested += literals
                // An expression holding string literals evaluates to a String (reported below).
                if !literals.isEmpty { key += "%@" }
                else if let spec = specifier(for: e) { key += spec } else { unknown.append(e); key += "%?" }
            }
        }
        return Site(location: location, key: unknown.isEmpty ? key : nil, unknownExpressions: unknown, nestedLiterals: nested)
    }

    private static func specifier(for expression: String) -> String? {
        if let known = expressionTypes[expression] { return known }
        if let range = expression.range(of: #"specifier:\s*"([^"]+)""#, options: .regularExpression) {
            // \(x, specifier: "%.1f") puts that specifier into the key verbatim.
            let match = String(expression[range])
            return match.components(separatedBy: "\"").dropFirst().first
        }
        if expression.hasPrefix("Int(") { return "%lld" }
        // `xs.count`, `xs.count - 4`: Int arithmetic on a count.
        if expression.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\.count(\s*[-+]\s*\d+)?$"#, options: .regularExpression) != nil { return "%lld" }
        if expression.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\.(count|habits\.count)\s*-\s*[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil { return "%lld" }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
        // `@available(*, deprecated, message: "…")` is a compiler message, not UI.
        if trimmed.hasPrefix("@available") { return "" }
        var inString = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" && previous != "\\" { inString.toggle() }
            if !inString, ch == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = ch
            index = line.index(after: index)
        }
        return line
    }

    // MARK: - Runtime key via Mirror

    /// The key SwiftUI looks up for a LocalizedStringKey. `Mirror` is the only way in: the
    /// struct keeps it in a stored property named `key`.
    static func runtimeKey(_ key: LocalizedStringKey) -> String? {
        Mirror(reflecting: key).children.first { $0.label == "key" }?.value as? String
    }
}
