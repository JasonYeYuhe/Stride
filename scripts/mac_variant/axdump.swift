// What VoiceOver would read on the running Mac variant, without turning VoiceOver on: every
// window's element tree with its label, value and actions, flagging controls that have none.
//
//   swiftc -O -o "$TMPDIR/axdump" scripts/mac_variant/axdump.swift
//   "$TMPDIR/axdump" "$(pgrep -f 'mac-variant/DerivedData/Build/Products/Debug/Stride.app/Contents/MacOS/Stride')"
//
// Needs Accessibility for the host app (it prints `trusted:`). Reads the attributes VoiceOver
// speaks on macOS 27, which `osascript`/System Events cannot: SwiftUI puts the label in
// AXAttributedDescription and a row's value in AXValueDescription, and both read as empty there.
// A window on another Space still answers (through AXMainWindow); one that is busy can take a
// minute, hence the messaging timeout. Opaque groups (the icon and colour grids) list no
// children; check those in code.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: axdump <pid>"); exit(2)
}
print("trusted:", AXIsProcessTrusted())
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1.5)

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, n as CFString, &v)
    return v
}

func str(_ e: AXUIElement, _ n: String) -> String {
    guard let v = attr(e, n) else { return "" }
    if let s = v as? String { return s }
    if let a = v as? NSAttributedString { return a.string }
    return "\(v)"
}

let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTextField", "AXSlider",
                             "AXMenuButton", "AXLink", "AXIncrementor", "AXDateTimeArea", "AXSwitch", "AXUnknown",
                             "AXDisclosureTriangle", "AXComboBox"]
// Named by the system from their subrole; VoiceOver does not need a label for them.
let systemParts: Set<String> = ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton",
                                "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]

func walk(_ e: AXUIElement, _ depth: Int) {
    let role = str(e, "AXRole")
    var label = [str(e, "AXDescription"), str(e, "AXAttributedDescription"), str(e, "AXTitle")].first { !$0.isEmpty } ?? ""
    if label.isEmpty, let title = attr(e, "AXTitleUIElement") { label = "(titled by) " + str(title as! AXUIElement, "AXValue") }
    let value = [str(e, "AXValueDescription"), str(e, "AXValue")].first { !$0.isEmpty } ?? ""
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    let actions = ((names as? [String]) ?? []).map { $0.components(separatedBy: "\n")[0] }
        .filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
    if controls.contains(role) || ["AXStaticText", "AXHeading", "AXImage"].contains(role) {
        let unlabeled = controls.contains(role) && label.isEmpty && value.isEmpty
            && !systemParts.contains(str(e, "AXSubrole"))
        let indent = String(repeating: " ", count: min(depth, 12))
        print("\(unlabeled ? "!! UNLABELED " : "")\(indent)\(role) \"\(label)\" v=\"\(value.prefix(60))\" \(actions.isEmpty ? "" : actions.description)")
    }
    for kid in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(kid, depth + 1) }
}

var windows = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
if windows.isEmpty, let main = attr(app, "AXMainWindow") { windows = [main as! AXUIElement] }
for w in windows {
    print("=== WINDOW", str(w, "AXTitle"))
    walk(w, 0)
}
