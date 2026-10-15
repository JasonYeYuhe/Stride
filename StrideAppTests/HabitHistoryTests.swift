import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// History and Today's past days (RELEASE-1.4.1.md D6, D7, D8), hosted: the real views in a window
/// of their own on the host app's scene, over an in-memory store, driven through the accessibility
/// tree as VoiceOver would drive them. Every write goes through an injected commit environment
/// (`\.habitEntryCommit`): it saves this test's context and records the tombstones and effects, so
/// nothing reaches the host app's deletion queue, widgets, badge or notification store.
///
/// - History's editor writes a value alone: a note another device sent while it is open survives
///   (the editor even shows it), and so does a stored note longer than the 500-character cap.
/// - History closes when its habit is deleted by another context, writes nothing for it, and is
///   a shell sheet that survives a size-class crossing.
/// - Today on a past day lists only the habits that had started (O11); a History backfill moves a
///   habit's start, and the row appears.
/// - A Today row whose record another context deleted shows the stale state; a tap on it then
///   writes nothing — no record, no tombstone (Risk 4).
@MainActor
final class HabitHistoryTests: XCTestCase {

    /// What the commits did outside the store, in order.
    private final class Recorder {
        var events: [String] = []
    }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var recorder: Recorder!
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    private var automation: Bool?

    /// As ShellTests: a hosted view's task can outlive its window, and a context whose container
    /// was released traps.
    private static var retiredContainers: [ModelContainer] = []

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
        host = nil
        if let automation { AccessibilityAutomation.restore(automation) }
        if let container { Self.retiredContainers.append(container) }
        context = nil
        container = nil
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var today: Date { Date() }

    /// Today's day-key, as the setters key a local instant.
    private var todayKey: Date { HabitCalendar.dayKey(for: today) }

    private func environment() -> HabitEntryCommit.Environment {
        let recorder = self.recorder!
        return HabitEntryCommit.Environment(
            save: { context in
                recorder.events.append("save")
                try context.save()
            },
            trackDeletedEntry: { recorder.events.append("tombstone \($0)") },
            effects: CheckInEffects(
                reloadWidgets: { recorder.events.append("reload") },
                updateBadge: { _ in recorder.events.append("badge") },
                cancelSnooze: { _ in recorder.events.append("cancelSnooze") },
                withdrawDelivered: { _ in recorder.events.append("withdraw") },
                submitRefresh: { recorder.events.append("submitRefresh") }),
            // The app's own bump: the views read the shared cache.
            bumpStats: { StatsCache.shared.bump(habitID: $0) },
            reportSaveFailure: { _ in recorder.events.append("report") },
            now: { Date() },
            calendar: { .current })
    }

    private var saves: Int { recorder.events.filter { $0 == "save" }.count }
    private var tombstones: [String] { recorder.events.filter { $0.hasPrefix("tombstone") } }

    @discardableResult
    private func habit(_ name: String, _ kind: HabitKind = .binary, createdDaysAgo: Int = 30,
                       records: [(daysAgo: Int, value: Double, note: String?)] = []) throws -> Habit {
        let habit = Habit(name: name)
        habit.habitKind = kind
        if kind == .count { habit.targetValue = 8 }
        let calendar = Calendar.current
        habit.createdAt = try XCTUnwrap(calendar.date(byAdding: .day, value: -createdDaysAgo, to: today))
        habit.sortOrder = Double(try context.fetchCount(FetchDescriptor<Habit>()))
        context.insert(habit)
        for record in records {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -record.daysAgo, to: today))
            habit.records.append(HabitRecord(date: day, note: record.note, value: record.value))
        }
        try context.save()
        return habit
    }

    /// The habit's records as the store holds them now, through a context of their own.
    private func stored(_ habit: Habit) throws -> [HabitRecord] {
        let id = habit.id
        let fresh = ModelContext(container)
        return try XCTUnwrap(fresh.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first).records
    }

    /// Another context — a sync's, the widget's — changes the habit's records and saves.
    private func elsewhere(_ habit: Habit, _ change: (Habit, ModelContext) throws -> Void) throws {
        let id = habit.id
        let other = ModelContext(container)
        let theirs = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        try change(theirs, other)
        try other.save()
    }

    // MARK: - History's editor (Data safety 1)

    /// The editor is open on a noted count day; another device's note arrives (a context of its
    /// own saves it), and the user steps the amount up before the editor has even redrawn: the
    /// value goes in alone and the pulled note survives. The untouched note field then follows
    /// the store, and Done writes nothing more.
    func testAPulledNoteSurvivesAnOpenEditor() async throws {
        let water = try habit("History Probe Water", .count, records: [(0, 3, "mine")])
        let window = try hostHistory(of: water)
        let noteLabel = appLocalized("Note")
        try await waitUntil("the editor shows the day's note") { self.value(of: noteLabel, in: window) == "mine" }
        let amount = try await element(labeled: appLocalized("Amount"), in: window)

        try elsewhere(water) { theirs, _ in
            let record = try XCTUnwrap(theirs.records.first)
            record.note = "pulled from the iPad"
            record.touch()
        }
        // The same turn: nothing has told the editor yet, and its field still says "mine".
        amount.accessibilityIncrement()

        try await waitUntil("the step is written") { (try? self.stored(water).map(\.value)) == [4] }
        XCTAssertEqual(try stored(water).map(\.note), ["pulled from the iPad"], "the pulled note survives")
        try await waitUntil("the untouched field follows the store") {
            self.value(of: noteLabel, in: window) == "pulled from the iPad"
        }

        let done = try await element(labeled: appLocalized("Done"), in: window)
        XCTAssertTrue(done.accessibilityActivate(), "Done")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(saves, 1, "one save, the value's: the untouched note is never written")
        XCTAssertEqual(tombstones, [])
        XCTAssertEqual(try stored(water).map(\.note), ["pulled from the iPad"])
    }

    /// A stored note longer than the cap on new input (another client's, or 1.4.0's uncapped note
    /// alert) is shown whole, accepted as it is, and kept whole by a value edit — while a NEW
    /// draft over the cap may not be written.
    func testASixHundredCharacterStoredNoteSurvivesAValueEdit() async throws {
        let long = String(repeating: "日記 note ", count: 75)
        XCTAssertEqual(long.count, 600)
        let water = try habit("History Probe Long", .count, records: [(0, 2, long)])
        let window = try hostHistory(of: water)
        let noteLabel = appLocalized("Note")
        try await waitUntil("the editor shows the whole note") { self.value(of: noteLabel, in: window) == long }

        XCTAssertTrue(HabitHistoryView.acceptsNoteDraft(long, stored: long), "the stored note, as it is")
        XCTAssertFalse(HabitHistoryView.acceptsNoteDraft(long + "!", stored: long), "new input past the cap")
        XCTAssertFalse(HabitHistoryView.acceptsNoteDraft(String(long.dropLast()), stored: long),
                       "an edit of it is new input, and still past the cap")
        XCTAssertTrue(HabitHistoryView.acceptsNoteDraft(String(repeating: "a", count: 500), stored: nil))
        XCTAssertFalse(HabitHistoryView.acceptsNoteDraft(String(repeating: "a", count: 501), stored: nil))
        XCTAssertFalse(HabitHistoryView.acceptsNoteDraft(String(repeating: "a", count: 501), stored: "short"))

        let amount = try await element(labeled: appLocalized("Amount"), in: window)
        amount.accessibilityIncrement()
        try await waitUntil("the step is written") { (try? self.stored(water).map(\.value)) == [3] }
        XCTAssertEqual(try stored(water).first?.note, long, "untruncated")

        let done = try await element(labeled: appLocalized("Done"), in: window)
        XCTAssertTrue(done.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(saves, 1, "the value's save only")
        XCTAssertEqual(try stored(water).first?.note, long)
    }

    /// A draft follows the store until the user changes it; a changed draft keeps the user's text
    /// against whatever the store says next, and a day with no record takes no note.
    func testAnUntouchedDraftFollowsTheStoreAndAChangedOneKeepsItsText() {
        var draft = HabitHistoryView.NoteDraft().refreshed(day: 10, stored: "mine", hasRecord: true)
        XCTAssertEqual(draft, .init(day: 10, seen: "mine", text: "mine"))
        XCTAssertFalse(draft.isDirty)
        draft = draft.refreshed(day: 10, stored: "pulled", hasRecord: true)
        XCTAssertEqual(draft.text, "pulled", "untouched: the pulled note shows")

        draft.text = "typed"
        draft = draft.refreshed(day: 10, stored: "pulled again", hasRecord: true)
        XCTAssertEqual(draft, .init(day: 10, seen: "pulled again", text: "typed"))
        XCTAssertTrue(draft.isDirty, "the user's text, until it is written")

        XCTAssertEqual(draft.refreshed(day: 11, stored: nil, hasRecord: true), .init(day: 11, seen: "", text: ""),
                       "another day starts from its own note")
        XCTAssertEqual(draft.refreshed(day: 10, stored: "x", hasRecord: false), .init(day: 10, seen: "", text: ""),
                       "no record, no note (D7)")
    }

    // MARK: - History's habit, gone

    /// The habit is deleted while History is open on it — a sync applying another device's
    /// tombstone, or Settings' Delete in the Mac's Settings window, both on mainContext, as every
    /// habit deletion in the app is: the sheet closes and the shell's request clears. A write
    /// that still reaches the model for it writes nothing.
    func testTheHabitDeletedWhileHistoryIsOpenClosesItAndWritesNothing() async throws {
        let read = try habit("History Probe Deleted", records: [(1, 1, nil)])
        let shell = ShellState(launchArguments: [])
        _ = try await hostShell(shell)
        let request = ShellRequest.history(habitID: read.id, day: today)
        shell.request = request
        try await waitUntil("History is presented") { self.host?.presentedViewController != nil }
        _ = try await element(labeled: appLocalized("Note"), in: try XCTUnwrap(window))

        let id = read.id
        context.delete(read)
        try context.save()
        try await waitUntil("History closes") { self.host?.presentedViewController == nil }
        try await waitUntil("and the request clears") { shell.request == nil }

        XCTAssertNil(HabitHistoryView.resolve(id, in: context))
        let result = HabitHistoryView.commit(.checked(true), habitID: id, dayKey: todayKey, in: context,
                                             environment: environment())
        XCTAssertEqual(result, .habitGone)
        XCTAssertEqual(recorder.events, [], "nothing saved, tombstoned or run")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<HabitRecord>()), 0,
                       "the cascade took the record; nothing was written back")
    }

    /// The same habit deleted by ANOTHER context (no app path does this today; a future one
    /// might): this context still holds the Habit, and the query still lists it for a moment, but
    /// its backing data is gone, and any read of it would trap. History resolves the habit from
    /// the store on every render, so it draws nothing of it, writes nothing for it and does not
    /// crash. (Hosted alone: Today's row reads `isCompletedOn` straight from the habit, D4, and
    /// that pre-existing read is not History's.)
    func testHistoryNeverReadsAHabitAnotherContextDeleted() async throws {
        let read = try habit("History Probe Elsewhere", .count, records: [(0, 3, "mine"), (2, 8, nil)])
        let window = try hostHistory(of: read)
        let noteLabel = appLocalized("Note")
        try await waitUntil("the editor is up") { self.value(of: noteLabel, in: window) == "mine" }

        let id = read.id
        try elsewhere(read) { theirs, other in other.delete(theirs) }
        try await waitUntil("History draws nothing of it") {
            self.count(labeled: noteLabel, in: window) == 0 && self.count(labeled: appLocalized("Amount"), in: window) == 0
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(HabitHistoryView.commit(.value(4), habitID: id, dayKey: todayKey, in: context,
                                               environment: environment()), .habitGone)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<HabitRecord>()), 0)
    }

    /// History is the shell's sheet (D6): it is up whatever tab is showing, and a compact↔regular
    /// crossing — which dismisses a tab's own sheets — leaves it up, on the same habit and day.
    func testHistoryIsAShellSheetThatSurvivesASizeClassCrossing() async throws {
        let read = try habit("History Probe Crossing")
        let request = ShellRequest.history(habitID: read.id, day: today)
        XCTAssertTrue(request.isSheet, "a shell sheet, never a push into the shared stack")
        let shell = ShellState(launchArguments: [])
        _ = try await hostShell(shell, regular: true)
        shell.request = request
        try await waitUntil("History is presented") { self.host?.presentedViewController != nil }
        let title = appLocalized("History")
        try await waitUntil("its title") { self.count(labeled: title, in: self.host!.presentedViewController!.view) > 0 }

        host?.traitOverrides.horizontalSizeClass = .compact
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(host?.presentedViewController, "still up after the crossing")
        XCTAssertEqual(shell.request, request)

        host?.traitOverrides.horizontalSizeClass = .regular
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(host?.presentedViewController, "and after crossing back")
        XCTAssertEqual(shell.request, request)
        try await waitUntil("History, on the same habit") {
            guard let sheet = self.host?.presentedViewController else { return false }
            return self.count(labeled: title, in: sheet.view) > 0
        }
    }

    // MARK: - Today on a past day (D8, O11)

    /// A habit created today is not on yesterday's Today — yesterday shows the habit that had
    /// started, and its count is out of one — until a History backfill of yesterday moves its
    /// start; then its row is there, checked, and the card counts it. Today lists both.
    func testAHabitCreatedTodayIsAbsentOnYesterdayAndPresentAfterAHistoryBackfill() async throws {
        let older = try habit("Filter Probe Older", createdDaysAgo: 10)
        let newer = try habit("Filter Probe Newer", createdDaysAgo: 0)
        let calendar = Calendar.current
        let yesterday = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today)))
        let shell = ShellState(launchArguments: [])
        shell.todayDate = yesterday   // picked in the week strip
        let window = try await hostShell(shell)

        let olderRow = appLocalized("\(older.name), not completed")
        let newerUnchecked = appLocalized("\(newer.name), not completed")
        let newerChecked = appLocalized("\(newer.name), completed")
        try await waitUntil("yesterday lists the habit that had started") { self.count(labeled: olderRow, in: window) == 1 }
        XCTAssertEqual(count(labeled: newerUnchecked, in: window), 0, "not the one created today")
        XCTAssertEqual(count(labeled: progress(0, of: 1), in: window), 1, "and counts out of one")

        let result = HabitHistoryView.commit(.checked(true), habitID: newer.id,
                                             dayKey: HabitCalendar.dayKey(for: yesterday), in: context,
                                             environment: environment())
        guard case .outcome(.committed) = result else { return XCTFail("\(result)") }
        try await waitUntil("the backfilled habit is on yesterday") { self.count(labeled: newerChecked, in: window) == 1 }
        XCTAssertEqual(count(labeled: olderRow, in: window), 1)
        XCTAssertEqual(count(labeled: progress(1, of: 2), in: window), 1)

        shell.todayDate = today
        try await waitUntil("today lists both") {
            self.count(labeled: appLocalized("\(newer.name), not completed"), in: window) == 1
                && self.count(labeled: olderRow, in: window) == 1
        }
        XCTAssertEqual(count(labeled: progress(0, of: 2), in: window), 1)
    }

    /// Every habit started after the picked day: no rows, no card, a line saying so — not the
    /// first-run "Start Your Journey".
    func testAPastDayBeforeEveryHabitSaysSo() async throws {
        _ = try habit("Filter Probe Only", createdDaysAgo: 0)
        let calendar = Calendar.current
        let shell = ShellState(launchArguments: [])
        shell.todayDate = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today)))
        let window = try await hostShell(shell)
        try await waitUntil("the line") {
            self.count(labeled: appLocalized("No habits had started by this day."), in: window) == 1
        }
        XCTAssertEqual(count(labeled: appLocalized("Start Your Journey"), in: window), 0)
        XCTAssertEqual(count(labeled: appLocalized("Filter Probe Only, not completed"), in: window), 0)
    }

    /// Today's progress card's label, as it speaks.
    private func progress(_ completed: Int, of total: Int) -> String {
        let percent = total > 0 ? completed * 100 / total : 0
        return appLocalized("\(completed) of \(total) habits completed, \(percent) percent")
    }

    // MARK: - A stale Today row (Risk 4)

    /// The widget's pattern: another context deletes today's check-in and saves, and the row has
    /// not caught up — it still reads checked. A tap on it asks for "unchecked", which the store
    /// already is: nothing is created and nothing is deleted, saved or tombstoned. Then the row
    /// catches up.
    func testAfterASecondContextDeleteATapOnTheRowCreatesAndDeletesNothing() async throws {
        let read = try habit("Stale Probe Read", records: [(0, 1, nil)])
        let shell = ShellState(launchArguments: [])
        let window = try await hostShell(shell)
        let checked = appLocalized("\(read.name), completed")
        let row = try await element(labeled: checked, in: window)

        try elsewhere(read) { theirs, other in
            for record in theirs.records { other.delete(record) }
        }
        // The same turn: the row still reads checked.
        XCTAssertTrue(read.isCompletedOn(today), "precondition: the row's state is stale")
        XCTAssertTrue(row.accessibilityActivate(), "the row's tap")

        XCTAssertEqual(recorder.events, [], "no save, no tombstone, no effects")
        XCTAssertEqual(try stored(read).count, 0, "nothing created")
        try await waitUntil("the row catches up") {
            self.count(labeled: appLocalized("\(read.name), not completed"), in: window) == 1
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(try stored(read).count, 0)
    }

    // MARK: - Hosting

    private func hostHistory(of habit: Habit) throws -> UIWindow {
        try host(AnyView(HabitHistoryView(habitID: habit.id, day: today)))
    }

    /// ContentView as the app shows it, over this test's store; compact (an iPhone host) unless
    /// `regular`.
    private func hostShell(_ shell: ShellState, regular: Bool = false) async throws -> UIWindow {
        let window = try host(AnyView(ContentView(shell: shell)))
        if regular { host?.traitOverrides.horizontalSizeClass = .regular }
        try await waitUntil("Today is created") { shell.tabCreations[.today] ?? 0 >= 1 }
        return window
    }

    private func host(_ view: AnyView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(
            view
                .modelContainer(container)
                .environment(\.habitEntryCommit, environment())
                .environment(\.locale, LanguageManager.shared.locale ?? .current)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        return window
    }

    // MARK: - The accessibility tree

    /// The value of the first element labelled `label` under `root`.
    private func value(of label: String, in root: NSObject) -> String? {
        elements(in: root) { $0.accessibilityLabel == label }.first?.accessibilityValue
    }

    private func count(labeled label: String, in root: NSObject) -> Int {
        elements(in: root) { $0.accessibilityLabel == label }.count
    }

    private func element(labeled label: String, in root: NSObject) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil("an element labelled “\(label)”") {
            found = self.elements(in: root) { $0.accessibilityLabel == label }.first
            return found != nil
        }
        return try XCTUnwrap(found)
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
