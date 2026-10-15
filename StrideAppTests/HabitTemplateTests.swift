import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// Templates with a kind, target and unit (RELEASE-1.4.1.md D15), hosted: the real sheet in a
/// window of its own on the host app's scene, over an in-memory store, driven through the
/// accessibility tree as VoiceOver would drive it. The save goes through an injected environment
/// (`\.habitTemplateAdd`) that records it and can be made to fail.
///
/// - A count template creates a count habit with its goal, and its unit in the app's language —
///   `Habit.unit` is shown as it is stored, so a Japanese user's water habit stores "杯".
/// - Every template's unit is a catalog key, translated in every shipped language: the unit, like
///   the name, is looked up through a variable, which LocalizationSourceScanTests cannot see.
/// - A pick saves, then calls `onAdded` once, then dismisses; a second tap adds nothing.
/// - A failed save says so ("Save Failed"), never calls `onAdded` or dismisses, and leaves nothing
///   pending to land later; the next try saves.
/// - From New Habit, a pick closes both sheets (`onAdded: { dismiss() }`).
@MainActor
final class HabitTemplateTests: XCTestCase {

    /// What happened outside the store, in order: "save", "onAdded", "dismissed".
    private final class Recorder {
        var events: [String] = []
        /// How many of the next saves throw before reaching the context.
        var failingSaves = 0
    }

    private struct InjectedSaveFailure: Error {}

    private var container: ModelContainer!
    private var context: ModelContext!
    private var recorder: Recorder!
    private var window: UIWindow?
    private var automation: Bool?

    /// As HabitHistoryTests: a hosted view's task can outlive its window, and a context whose
    /// container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    /// The six units W0 put in the catalogs for the templates.
    private static let unitKeys: Set<String> = ["glasses", "min", "steps", "words", "hours", "km"]

    /// The goals a count template may set. Every way to log a count adds exactly 1 (Today's ring
    /// and "Add 1", History's stepper, the widget, Siri, the reminder's action), so a template's
    /// goal is one a few taps reach — never Walk 10k Steps' 10,000 — and inside AddHabitView's
    /// own goal stepper (1...1000), where the user can still change it.
    private static let tapReachableGoals = 1...10

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        recorder = Recorder()
        automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
    }

    override func tearDown() async throws {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
        }
        window = nil
        if let automation { AccessibilityAutomation.restore(automation) }
        if let container { Self.retiredContainers.append(container) }
        context = nil
        container = nil
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func environment() -> HabitTemplateAdd.Environment {
        let recorder = self.recorder!
        return HabitTemplateAdd.Environment(save: { context in
            recorder.events.append("save")
            if recorder.failingSaves > 0 {
                recorder.failingSaves -= 1
                throw InjectedSaveFailure()
            }
            try context.save()
        })
    }

    private func template(_ name: String) throws -> HabitTemplate {
        try XCTUnwrap(HabitTemplateLibrary.templates.first { $0.name == name }, "a template “\(name)”")
    }

    /// The store's habits, through a context of their own.
    private func storedHabits() throws -> [Habit] {
        try ModelContext(container).fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.name)]))
    }

    // MARK: - The templates

    /// The count templates are the ones whose goal a few taps reach; the amounts no tap-by-tap
    /// count reaches in a day (10,000 steps, 500 words, 30 minutes) stay yes/no, as in 1.4.0.
    func testCountTemplatesCarryTheirGoalAndYesNoTemplatesStayYesNo() throws {
        let goals = Dictionary(uniqueKeysWithValues: HabitTemplateLibrary.templates
            .filter { $0.kind == .count }.map { ($0.name, "\($0.target) \($0.unit ?? "nil")") })
        XCTAssertEqual(goals, [
            "Morning Run": "5 km",
            "Drink Water": "8 glasses",
            "Sleep 8hrs": "8 hours",
        ])
        for template in HabitTemplateLibrary.templates where template.kind == .count {
            XCTAssertTrue(Self.tapReachableGoals.contains(template.target),
                          "\(template.name): a goal of \(template.target) is past what +1 taps reach in a day")
        }
        for name in ["Walk 10k Steps", "Write 500 Words", "Read 30min"] {
            XCTAssertEqual(try template(name).kind, .binary, "\(name): one check-in completes the day")
        }
        for template in HabitTemplateLibrary.templates where template.kind == .binary {
            XCTAssertEqual(template.target, 1, template.name)
            XCTAssertNil(template.unit, "\(template.name): a yes/no template has no unit")
        }
        let used = Set(HabitTemplateLibrary.templates.compactMap(\.unit))
        XCTAssertFalse(used.isEmpty)
        XCTAssertTrue(used.isSubset(of: Self.unitKeys), "the units are W0's catalog keys: \(used.subtracting(Self.unitKeys))")
    }

    /// Every unit is a key the ja catalog translates — and every shipped translation, which the
    /// catalog parity tests keep equal to ja — and so is every name and category: all three reach
    /// `appLocalized` through a variable, out of LocalizationSourceScanTests' sight.
    func testTemplateUnitsNamesAndCategoriesAreCatalogKeys() throws {
        for language in ["ja", "es", "ko", "zh-Hans", "zh-Hant"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: nil, localization: language),
                                    "Stride.app has no \(language) Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) did not parse")
            for template in HabitTemplateLibrary.templates {
                if let unit = template.unit {
                    XCTAssertNotNil(catalog[unit], "\(language): the unit “\(unit)” of “\(template.name)”")
                }
                XCTAssertNotNil(catalog[template.name], "\(language): the template “\(template.name)”")
            }
            for category in HabitTemplateLibrary.categories {
                XCTAssertNotNil(catalog[category], "\(language): the category “\(category)”")
            }
            // W0's units, used by a template or not: Walk 10k Steps, Write 500 Words and Read
            // 30min can take theirs back once a count can be logged by amount.
            for unit in Self.unitKeys {
                XCTAssertNotNil(catalog[unit], "\(language): the unit “\(unit)”")
            }
        }
    }

    /// In Japanese, a count template's habit is a count habit with its goal, named and unit-ed in
    /// Japanese — the unit stored as the translation, as AddHabitView's Unit field would hold it,
    /// never as the catalog key. A yes/no template's habit, Walk 10k Steps' among them, stays
    /// yes/no with no unit. The row's goal reads as the names do, with no space: "1日8杯".
    func testATemplateAddSavesItsKindTargetAndUnitInTheAppLanguage() throws {
        // A language change hands the reminder actions to the system again: to a recording
        // center here, never the host app's (as AppLocalizedTests).
        let scratch = ScratchDefaults("notifications.templates")
        NotificationService.testOverride = NotificationService(center: RecordingCenter(), defaults: scratch.defaults)
        let manager = LanguageManager.shared
        let savedLanguage = manager.selectedLanguage
        let hadStoredLanguage = UserDefaults.standard.object(forKey: "stride_app_language") != nil
        defer {
            manager.selectedLanguage = savedLanguage
            if !hadStoredLanguage { UserDefaults.standard.removeObject(forKey: "stride_app_language") }
            NotificationService.testOverride = nil
            scratch.remove()
        }
        manager.selectedLanguage = .japanese

        var outcomes: [String: HabitTemplateAdd.Outcome] = [:]
        let names = ["Drink Water", "Sleep 8hrs", "Walk 10k Steps", "Meditate"]
        for name in names {
            outcomes[name] = HabitTemplateAdd.add(try template(name), in: context, environment: environment())
        }

        let habits = Dictionary(uniqueKeysWithValues: try storedHabits().map { ($0.name, $0) })
        XCTAssertEqual(Set(habits.keys), ["水を飲む", "8時間眠る", "1万歩歩く", "瞑想する"], "named in Japanese")
        XCTAssertEqual(outcomes["Drink Water"], habits["水を飲む"].map { .added($0.id) })
        XCTAssertEqual(outcomes["Sleep 8hrs"], habits["8時間眠る"].map { .added($0.id) })
        XCTAssertEqual(outcomes["Walk 10k Steps"], habits["1万歩歩く"].map { .added($0.id) })
        XCTAssertEqual(outcomes["Meditate"], habits["瞑想する"].map { .added($0.id) })

        let water = try XCTUnwrap(habits["水を飲む"], "named in Japanese")
        XCTAssertEqual(water.habitKind, .count)
        XCTAssertEqual(water.targetValue, 8)
        XCTAssertEqual(water.unit, "杯", "the unit as the user reads it, not the key “glasses”")
        XCTAssertEqual(water.emoji, "\u{1F4A7}")
        XCTAssertEqual(water.colorHex, "#5AC8FA")

        let sleep = try XCTUnwrap(habits["8時間眠る"])
        XCTAssertEqual(sleep.habitKind, .count)
        XCTAssertEqual(sleep.targetValue, 8)
        XCTAssertEqual(sleep.unit, "時間")

        for name in ["1万歩歩く", "瞑想する"] {
            let habit = try XCTUnwrap(habits[name])
            XCTAssertEqual(habit.habitKind, .binary, name)
            XCTAssertEqual(habit.targetValue, 1, name)
            XCTAssertNil(habit.unit, name)
        }

        // The rows' goals, as the sheet's caption key resolves them in Japanese.
        for (name, expected) in [("Drink Water", "1日8杯"), ("Sleep 8hrs", "1日8時間"), ("Morning Run", "1日5km")] {
            let picked = try template(name)
            let targetValue = picked.target, unit = try XCTUnwrap(picked.displayUnit)
            XCTAssertEqual(appLocalized("\(targetValue) \(unit) a day"), expected, name)
        }

        XCTAssertEqual(recorder.events, Array(repeating: "save", count: names.count))
        XCTAssertFalse(context.hasChanges)
    }

    // MARK: - The sheet

    /// A pick: the save, then `onAdded` once, then the sheet's own dismissal — and the store holds
    /// the template's habit. A second tap while the sheet is going adds nothing.
    func testAPickSavesThenCallsOnAddedOnceThenDismisses() async throws {
        let water = try template("Drink Water")
        let window = try await hostTemplates()

        let row = try await element(labeled: addLabel(water), in: window)
        let targetValue = water.target, unit = try XCTUnwrap(water.displayUnit)
        XCTAssertEqual(row.accessibilityValue, appLocalized("\(targetValue) \(unit) a day"),
                       "the row speaks the goal it creates")
        XCTAssertTrue(row.accessibilityActivate(), "the row's tap")
        XCTAssertTrue(row.accessibilityActivate(), "a second tap before the sheet is gone")

        try await waitUntil("the sheet is dismissed") { self.recorder.events.contains("dismissed") }
        XCTAssertEqual(recorder.events, ["save", "onAdded", "dismissed"])

        let habits = try storedHabits()
        XCTAssertEqual(habits.map(\.name), [water.displayName], "one habit")
        let habit = try XCTUnwrap(habits.first)
        XCTAssertEqual(habit.habitKind, .count)
        XCTAssertEqual(habit.targetValue, 8)
        XCTAssertEqual(habit.unit, water.displayUnit)
        XCTAssertFalse(context.hasChanges)
    }

    /// A failed save: "Save Failed" with its message, no `onAdded`, no dismissal, and nothing left
    /// pending — an unrelated save afterwards does not write the template's habit. Then the user
    /// does as the alert says and tries again, and the pick goes through.
    func testAFailedSaveShowsTheErrorAndNeverCallsOnAdded() async throws {
        let water = try template("Drink Water")
        let window = try await hostTemplates()
        recorder.failingSaves = 1

        let row = try await element(labeled: addLabel(water), in: window)
        XCTAssertTrue(row.accessibilityActivate(), "the row's tap")

        let alert = try await alert(titled: appLocalized("Save Failed"))
        XCTAssertEqual(alert.message, appLocalized("Unable to save your habit. Please try again."))
        XCTAssertEqual(recorder.events, ["save"], "no onAdded, no dismissal")
        // Taken back out: not an insert any more. (SwiftData still reports `hasChanges` for an
        // unsaved model deleted again, until the next save, which writes nothing for it.)
        XCTAssertFalse(context.insertedModelsArray.contains { $0 is Habit }, "the habit is not left pending")
        XCTAssertEqual(try storedHabits().count, 0)

        context.insert(Habit(name: "Unrelated"))
        try context.save()
        XCTAssertEqual(try storedHabits().map(\.name), ["Unrelated"], "the failed add never lands later")
        XCTAssertFalse(context.hasChanges)

        try await answer(alert, appLocalized("OK"))
        XCTAssertEqual(recorder.events, ["save"])
        XCTAssertNotNil(window.rootViewController?.presentedViewController, "the sheet is still up")

        let again = try await element(labeled: addLabel(water), in: window)
        XCTAssertTrue(again.accessibilityActivate(), "the next try")
        try await waitUntil("the sheet is dismissed") { self.recorder.events.contains("dismissed") }
        XCTAssertEqual(recorder.events, ["save", "save", "onAdded", "dismissed"])
        XCTAssertEqual(Set(try storedHabits().map(\.name)), ["Unrelated", water.displayName])
    }

    /// New Habit → Browse Templates → a pick: AddHabitView's `onAdded: { dismiss() }` closes it
    /// along with the templates sheet, and the template's habit is the one saved.
    func testAPickFromNewHabitClosesBothSheets() async throws {
        let water = try template("Drink Water")
        let window = try host(AnyView(Presenter(recorder: recorder) { AddHabitView() }))
        try await waitUntil("New Habit is up") { window.rootViewController?.presentedViewController != nil }

        let browse = try await element(labeled: appLocalized("Browse Templates"), in: window)
        XCTAssertTrue(browse.accessibilityActivate(), "Browse Templates")
        try await waitUntil("the templates sheet is up over it") {
            window.rootViewController?.presentedViewController?.presentedViewController != nil
        }

        let row = try await element(labeled: addLabel(water), in: window)
        XCTAssertTrue(row.accessibilityActivate(), "the row's tap")

        try await waitUntil("both sheets are gone") {
            self.recorder.events.contains("dismissed") && window.rootViewController?.presentedViewController == nil
        }
        // One save, the template's: New Habit saved nothing of its own. Its presentation is only
        // ever set to closed — SwiftUI sets it once for New Habit's `dismiss` and may set it
        // again as the nested sheet goes with it — and nothing else was dismissed: the window
        // still shows the screen that presented it.
        XCTAssertEqual(recorder.events.first, "save")
        XCTAssertEqual(recorder.events.filter { $0 == "save" }.count, 1, "New Habit saved nothing of its own")
        XCTAssertEqual(Set(recorder.events.dropFirst()), ["dismissed"])
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertNotNil(window.rootViewController)
        let habits = try storedHabits()
        XCTAssertEqual(habits.map(\.name), [water.displayName])
        XCTAssertEqual(habits.first?.habitKind, .count)
        XCTAssertEqual(habits.first?.targetValue, 8)
    }

    // MARK: - Hosting

    /// A screen that presents `content` as a sheet as soon as it appears, and records the sheet's
    /// dismissal — its binding set back to false, by the sheet's own `dismiss` — as "dismissed".
    private struct Presenter<Content: View>: View {
        let recorder: Recorder
        @ViewBuilder let content: () -> Content
        @State private var isPresented = true

        var body: some View {
            Color.clear
                .sheet(isPresented: Binding(
                    get: { isPresented },
                    set: { presented in
                        if !presented { recorder.events.append("dismissed") }
                        isPresented = presented
                    }), content: content)
        }
    }

    /// The templates sheet as TodayView and AddHabitView present it, its `onAdded` recorded.
    private func hostTemplates() async throws -> UIWindow {
        let recorder = self.recorder!
        let window = try host(AnyView(Presenter(recorder: recorder) {
            HabitTemplatesView(onAdded: { recorder.events.append("onAdded") })
        }))
        try await waitUntil("the sheet is up") { window.rootViewController?.presentedViewController != nil }
        return window
    }

    private func host(_ view: AnyView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AnyView(
            view
                .modelContainer(container)
                .environment(\.habitTemplateAdd, environment())
                .environment(\.locale, LanguageManager.shared.locale ?? .current)))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    /// The row's label, as it speaks.
    private func addLabel(_ template: HabitTemplate) -> String {
        let name = template.displayName
        return appLocalized("Add \(name)")
    }

    // MARK: - The accessibility tree and alerts

    private func element(labeled label: String, in root: NSObject) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil("an element labelled “\(label)”") {
            found = self.elements(in: root) { $0.accessibilityLabel == label }.first
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// The alert up over the sheet, once its title is `title` and it has finished coming up.
    private func alert(titled title: String) async throws -> UIAlertController {
        var found: UIAlertController?
        try await waitUntil("an alert “\(title)”") {
            var controller = self.window?.rootViewController?.presentedViewController
            while let presented = controller {
                if let alert = presented as? UIAlertController, alert.title == title, !alert.isBeingPresented {
                    found = alert
                    return true
                }
                controller = presented.presentedViewController
            }
            return false
        }
        return try XCTUnwrap(found)
    }

    /// Taps the alert's button `title` the way UIKit handles a tap on it (HabitHistoryTests): the
    /// alert is dismissed, then SwiftUI's handler for the action runs and clears the presentation.
    private func answer(_ alert: UIAlertController, _ title: String) async throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try XCTUnwrap(alert.actions.first { $0.title == title }, "the alert's “\(title)”")
        let block = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?, "its handler")
        alert.dismiss(animated: false) { unsafeBitCast(block, to: Handler.self)(action) }
        try await waitUntil("the alert goes") { alert.presentingViewController == nil }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// The distinct accessibility elements under `root` that `matches`, in tree order — presented
    /// controllers included, as VoiceOver reaches a sheet.
    private func elements(in root: NSObject, where matches: (NSObject) -> Bool) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        var roots: [NSObject] = [root]
        if let window = root as? UIWindow {
            var presented = window.rootViewController?.presentedViewController
            while let controller = presented {
                roots.append(controller.view)
                presented = controller.presentedViewController
            }
        }
        for root in roots { collect(in: root, where: matches, seen: &seen, found: &found, depth: 0) }
        return found
    }

    private func collect(in root: NSObject, where matches: (NSObject) -> Bool,
                         seen: inout Set<ObjectIdentifier>, found: inout [NSObject], depth: Int) {
        guard depth < 80 else { return }
        if root.isAccessibilityElement, matches(root), seen.insert(ObjectIdentifier(root)).inserted {
            found.append(root)
        }
        if root.accessibilityElementsHidden { return }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView {
            guard !view.isHidden else { return }
            children += view.subviews
        }
        for child in children {
            collect(in: child, where: matches, seen: &seen, found: &found, depth: depth + 1)
        }
    }

    /// Lets SwiftUI and UIKit run until `condition` holds, or fails after five seconds.
    private func waitUntil(_ what: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
