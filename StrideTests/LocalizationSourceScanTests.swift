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

    // MARK: - Catalog

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
