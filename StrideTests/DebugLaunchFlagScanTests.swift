import XCTest
import Foundation

/// RELEASE-1.4.2.md D14 and Data safety 8: no DEBUG switch in Release. Each launch switch that
/// changes what the app draws or what it believes about Pro is read only inside `#if DEBUG`, so a
/// store build has no code that reads it. This reads the sources rather than a binary: Swift keeps
/// literals of up to 15 bytes inside the instructions, where no text search of a Release binary
/// finds them (`-demoPro` is 8). The binary's probe is the 24-byte sentinel, which W8's
/// `verify_archive.sh` looks for; this test also keeps the sentinel itself DEBUG-only.
///
/// A line counts as DEBUG-only when an enclosing `#if` (or `#elseif`) branch's condition is
/// `DEBUG`, or `DEBUG && …`; the `#else` of `#if DEBUG` is not. Whole-line comments are skipped,
/// so documentation may name the switches anywhere. A literal is the quoted switch, e.g.
/// `"-demoPro"`.
final class DebugLaunchFlagScanTests: XCTestCase {

    /// Directories scanned, relative to the repository root: everything a shipping target compiles.
    private static let sourceRoots = ["Stride/Sources", "StrideWidget/Sources", "Shared"]

    /// D14's switches and the sentinel, each of which must exist and be DEBUG-only.
    private static let d14Literals = ["-demoPro", "-paywallFixture", "-paywallScrollTo", "-inlineCard",
                                      "[StrideDebugLaunchFlags]"]

    /// Switches from before 1.4.2 that the same rule already covers (ContentView's `-paywall`,
    /// `prepareStore`'s `-demo`, DemoData's `-demoScenario`, StatsView's `-statsScrollTo`).
    private static let earlierLiterals = ["-paywall", "-demo", "-demoScenario", "-statsScrollTo"]

    func testEachD14SwitchIsReadOnlyInsideIfDebug() throws {
        let sites = try Self.literalSites(Self.d14Literals + Self.earlierLiterals)
        for literal in Self.d14Literals {
            XCTAssertFalse(sites.filter { $0.literal == literal }.isEmpty,
                           "\"\(literal)\" is in no source file: the scan is not reading what the app compiles")
        }
        let outside = sites.filter { !$0.insideDebug }.map { "\($0.location): \"\($0.literal)\"" }
        XCTAssertEqual(outside, [], "launch switches read outside #if DEBUG")
    }

    /// The `#if` tracking itself, on inline sources.
    func testTheConditionTrackingFollowsNestingAndElse() {
        let source = """
        let a = "-demoPro"
        #if DEBUG
        let b = "-demoPro"
        #if os(iOS)
        let c = "-demoPro"
        #else
        let d = "-demoPro"
        #endif
        #else
        let e = "-demoPro"
        #endif
        #if os(macOS)
        let f = "-demoPro"
        #elseif DEBUG
        let g = "-demoPro"
        #endif
        #if DEBUG && os(iOS)
        let h = "-demoPro"
        #endif
        #if !DEBUG
        let i = "-demoPro"
        #endif
        // let j = "-demoPro"
        """
        let sites = Self.literalSites(in: source, file: "inline", literals: ["-demoPro"])
        XCTAssertEqual(sites.map(\.insideDebug), [false, true, true, true, false, false, true, true, false])
    }

    // MARK: - Scanner

    struct Site {
        let literal: String
        let location: String
        let insideDebug: Bool
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func literalSites(_ literals: [String]) throws -> [Site] {
        var sites: [Site] = []
        for root in sourceRoots {
            let dir = repositoryRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil),
                                           "\(root) is not readable")
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = "\(root)/\(url.path.replacingOccurrences(of: dir.path + "/", with: ""))"
                sites += literalSites(in: text, file: name, literals: literals)
            }
        }
        return sites
    }

    /// Every quoted occurrence of each literal, with whether a `#if DEBUG` branch encloses it.
    static func literalSites(in source: String, file: String, literals: [String]) -> [Site] {
        // One entry per open `#if`: whether its current branch is a DEBUG branch.
        var stack: [Bool] = []
        var sites: [Site] = []
        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if line.hasPrefix("#if ") {
                stack.append(isDebugCondition(String(line.dropFirst(4))))
                continue
            }
            if line.hasPrefix("#elseif "), !stack.isEmpty {
                stack[stack.count - 1] = isDebugCondition(String(line.dropFirst(8)))
                continue
            }
            if line == "#else" || line.hasPrefix("#else "), !stack.isEmpty {
                stack[stack.count - 1] = false
                continue
            }
            if line.hasPrefix("#endif"), !stack.isEmpty {
                stack.removeLast()
                continue
            }
            for literal in literals where rawLine.contains("\"\(literal)\"") {
                sites.append(Site(literal: literal, location: "\(file):\(index + 1)", insideDebug: stack.contains(true)))
            }
        }
        return sites
    }

    /// `DEBUG`, or a conjunction that requires it. `!DEBUG` and any `||` do not count.
    private static func isDebugCondition(_ condition: String) -> Bool {
        let c = condition.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
        if c.contains("||") { return false }
        return c.components(separatedBy: "&&").contains { $0.trimmingCharacters(in: .whitespaces) == "DEBUG" }
    }
}
