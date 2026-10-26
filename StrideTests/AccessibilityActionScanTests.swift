import XCTest

/// Every `.onTapGesture` in the app and widget sources has an `.accessibilityAction` soon after it.
///
/// Why: a tap gesture is not an element's activation. VoiceOver's double-tap on iOS lands on the
/// element's centre, which is the wrong target for a grid, and on the Mac VoiceOver and Full
/// Keyboard Access activate through AXPress, which a tap gesture never receives. So a control
/// built from `.onTapGesture` plus `.isButton` announces a button that does nothing. Statistics'
/// habit chips shipped that way until gate 10's hands-on pass on the Mac variant (2026-10-20);
/// Today's day strip, Settings' group rename and the heatmap already carried the action.
///
/// The check is textual: an `.accessibilityAction` within `window` lines after the gesture, the
/// distance the existing sites need (the heatmap's is the longest). A site that is not meant to
/// be activated by assistive technology goes in `exempt` with its reason.
final class AccessibilityActionScanTests: XCTestCase {

    private static let sourceRoots = ["Stride/Sources", "StrideWidget/Sources"]
    private static let window = 30
    /// "<path>:<line of the gesture>" → why it needs no action. Empty today.
    private static let exempt: [String: String] = [:]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryTapGestureHasAnAccessibilityAction() throws {
        var sites = 0
        var missing: [String] = []
        let fm = FileManager.default
        for root in Self.sourceRoots {
            let dir = Self.repositoryRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: nil), "\(root) is not readable")
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                let name = "\(root)/\(url.path.replacingOccurrences(of: dir.path + "/", with: ""))"
                for (i, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), code.contains(".onTapGesture") else { continue }
                    sites += 1
                    let site = "\(name):\(i + 1)"
                    if Self.exempt[site] != nil { continue }
                    let after = lines[(i + 1)..<min(lines.count, i + 1 + Self.window)]
                    if !after.contains(where: { $0.contains(".accessibilityAction") }) {
                        missing.append(site)
                    }
                }
            }
        }
        // The scan must see the known sites, or a moved source root would pass it vacuously.
        XCTAssertGreaterThanOrEqual(sites, 4, "found only \(sites) .onTapGesture sites")
        XCTAssertEqual(missing, [], "an .onTapGesture with no .accessibilityAction within \(Self.window) lines: VoiceOver and Full Keyboard Access cannot activate it")
    }
}
