import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// Statistics reading the cache (RELEASE-1.4.1.md D3, D5, D6, D10), hosted.
///
/// "The same render" (gate 3): a check-in committed through `HabitEntryCommit` — History's and
/// Today's one write path — changes what Statistics reads before anything else runs, because the
/// commit bumps the cache synchronously (D3 trigger 1). Every test here uses a `StatsCache` of
/// its own with NO observers installed, over an in-memory store, handed to the views through
/// `\.statsCache`: nothing but the commit's bump can tell it a record changed, so a stale number
/// fails the test instead of being rescued by a `didSave` a moment later. The rendered tests put
/// the real StatsView in a window of its own on the host app's scene and read it off the
/// accessibility tree (`AccessibilityAutomation`, as ShellTests).
///
/// The in-place case is the one that proves it: a count day raised to its target edits the kept
/// record and adds none, so the cache's fingerprint (record count, the habit's own fields; W2's
/// deviation) cannot see it, and only the bump can.
@MainActor
final class StatsRenderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: StatsCache!
    private var window: UIWindow?
    private var automation: Bool?
    /// As ShellTests: a hosted view's task can outlive its window, and a context whose container
    /// was released traps.
    private static var retiredContainers: [ModelContainer] = []

    private let calendar = Calendar.current
    private var todayKey: Date { HabitCalendar.dayKey(forInstant: Date(), calendar: calendar) }

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        cache = StatsCache()
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
        automation = nil
        if let container { Self.retiredContainers.append(container) }
        cache = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// The day-key `offset` days from today.
    private func day(_ offset: Int) -> Date {
        HabitCalendar.utc.date(byAdding: .day, value: offset, to: todayKey)!
    }

    /// A habit created 400 days ago with a record of `value` on each day of `values` (offsets from
    /// today), saved in mainContext.
    @discardableResult
    private func habit(_ name: String, kind: HabitKind = .binary, target: Double = 1,
                       values: [Int: Double]) throws -> Habit {
        let habit = Habit(name: name)
        habit.habitKind = kind
        habit.targetValue = target
        habit.createdAt = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-86_400 * 400))
        context.insert(habit)
        habit.records = values.sorted { $0.key < $1.key }.map { HabitRecord(date: day($0.key), value: $0.value) }
        try context.save()
        return habit
    }

    private func days(_ range: ClosedRange<Int>, value: Double = 1) -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: range.map { ($0, value) })
    }

    /// The app's commit over this test's store and cache: no tombstones, effects or Sentry reach
    /// the host app.
    private var commitEnvironment: HabitEntryCommit.Environment {
        let cache = self.cache!
        return HabitEntryCommit.Environment(
            save: { try $0.save() }, trackDeletedEntry: { _ in },
            effects: CheckInEffects(reloadWidgets: {}, updateBadge: { _ in }, cancelSnooze: { _ in },
                                    withdrawDelivered: { _ in }, submitRefresh: {}),
            bumpStats: { cache.bump(habitID: $0) }, reportSaveFailure: { _ in },
            now: { Date() }, calendar: { Calendar.current })
    }

    /// What the store holds for `habit`, through a context of its own.
    private func fresh(_ habit: Habit) throws -> HabitStats {
        let id = habit.id
        let other = ModelContext(container)
        let stored = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        return HabitStats(habit: stored, live: HabitStats.liveRecords(of: stored), calendar: calendar, today: Date())
    }

    // MARK: - The cached numbers

    /// Gate 3's shape: a day 20 days back ticked through the commit, then read at once — no
    /// `await`, no notification, the cache's observers never installed. The cell, the streak, the
    /// best streak, the rate and the strength have all moved, and they equal the store.
    func testACommitChangesTheCachedNumbersBeforeTheNextRead() throws {
        let read = try habit("Read 30 Minutes", values: days(-30...(-22)).merging(days(-20...(-1))) { a, _ in a })
        let before = cache.stats(for: read)
        XCTAssertFalse(before.isCompleted(on: day(-21)))
        XCTAssertEqual(before.currentStreak(), 20)
        XCTAssertEqual(before.bestStreak, 20)
        let rateBefore = before.completionRate(days: 30)
        let strengthBefore = before.strength

        let target = day(-21), context = self.context!
        let outcome = HabitEntryCommit.commit(habitID: read.id, day: target, in: context,
                                              environment: commitEnvironment) { undo in
            HabitCheckIn.setChecked(true, on: target, of: read, in: context, undo: undo)
        }
        guard case .committed = outcome else { return XCTFail("committed: \(outcome)") }

        let after = cache.stats(for: read)
        XCTAssertTrue(after.isCompleted(on: target), "the cell")
        XCTAssertEqual(after.currentStreak(), 30, "the streak")
        XCTAssertEqual(after.bestStreak, 30, "the best streak")
        XCTAssertGreaterThan(after.completionRate(days: 30), rateBefore, "the rate")
        XCTAssertGreaterThan(after.strength, strengthBefore, "the strength")

        let stored = try fresh(read)
        XCTAssertEqual(after.completedDayKeys, stored.completedDayKeys)
        XCTAssertEqual(after.strength, stored.strength)
        XCTAssertEqual(after.completionRate(days: 30), stored.completionRate(days: 30))
    }

    /// The in-place edit: a count day at 3 of 8 raised to 8 keeps its one record, so the record
    /// count does not move. The read right after the commit still has the day complete — only the
    /// bump can have said so.
    func testAnInPlaceEditReachesTheCacheThroughTheCommitsBump() throws {
        let water = try habit("Water", kind: .count, target: 8, values: days(-10...(-1), value: 8).merging([-11: 3]) { a, _ in a })
        let before = cache.stats(for: water)
        XCTAssertFalse(before.isCompleted(on: day(-11)))
        XCTAssertEqual(before.loggedValue(on: day(-11)), 3)
        XCTAssertEqual(before.currentStreak(), 10)
        let generation = cache.generation
        let records = water.records.count

        let target = day(-11), context = self.context!
        let outcome = HabitEntryCommit.commit(habitID: water.id, day: target, in: context,
                                              environment: commitEnvironment) { undo in
            HabitCheckIn.setValue(8, on: target, of: water, in: context, undo: undo)
        }
        guard case .committed = outcome else { return XCTFail("committed: \(outcome)") }
        XCTAssertEqual(water.records.count, records, "edited in place: the fingerprint's record count did not move")
        XCTAssertGreaterThan(cache.generation, generation, "bumped before the commit returned")

        let after = cache.stats(for: water)
        XCTAssertTrue(after.isCompleted(on: target))
        XCTAssertEqual(after.loggedValue(on: target), 8)
        XCTAssertEqual(after.currentStreak(), 11)
        XCTAssertEqual(after.bestStreak, 11)
        XCTAssertEqual(after.strength, try fresh(water).strength)
    }

    // MARK: - Through the real view

    /// StatsView in a window, the same in-place edit: before it, the heatmap's one element says 10
    /// of 84 days and a 10-day streak, the tiles 10 and the strength before; after the commit, with
    /// nothing else run, the next render says 11, 11 and the new strength.
    func testTheRenderAfterACommitShowsTheNewNumbers() async throws {
        let water = try habit("Water", kind: .count, target: 8, values: days(-10...(-1), value: 8).merging([-11: 3]) { a, _ in a })
        let shell = ShellState(launchArguments: [])
        let window = try host(StatsView(shell: shell))
        let strengthBefore = HabitScore.displayValue(try fresh(water).strength)

        try await waitUntil("the heatmap and the tiles before the edit") {
            self.gridValue(in: window) == self.summary(completed: 10, streak: 10)
                && self.numbers(startingWith: appLocalized("Current Streak"), in: window).contains(10)
                && self.numbers(startingWith: appLocalized("Strength"), in: window).contains(strengthBefore)
        }

        let target = day(-11), context = self.context!
        let outcome = HabitEntryCommit.commit(habitID: water.id, day: target, in: context,
                                              environment: commitEnvironment) { undo in
            HabitCheckIn.setValue(8, on: target, of: water, in: context, undo: undo)
        }
        guard case .committed = outcome else { return XCTFail("committed: \(outcome)") }
        let strengthAfter = HabitScore.displayValue(try fresh(water).strength)
        XCTAssertNotEqual(strengthAfter, strengthBefore, "the edit moves the strength shown")

        try await waitUntil("the heatmap and the tiles after the edit") {
            self.gridValue(in: window) == self.summary(completed: 11, streak: 11)
                && self.numbers(startingWith: appLocalized("Current Streak"), in: window).contains(11)
                && self.numbers(startingWith: appLocalized("Best Streak"), in: window).contains(11)
                && self.numbers(startingWith: appLocalized("Strength"), in: window).contains(strengthAfter)
        }
    }

    /// The heatmap is ONE element (D5) with an "Edit history" action, and VoiceOver's double-tap
    /// does the same: each opens History on today, through the shell. So does the detail card's
    /// visible Edit history button (D6), which carries the sim kit's identifier. No cell is an
    /// element of its own any more.
    func testTheGridsActionsAndTheEditHistoryButtonOpenHistoryOnToday() async throws {
        let read = try habit("Read", values: days(-5...(-1)))
        let shell = ShellState(launchArguments: [])
        let window = try host(StatsView(shell: shell))

        var grid: NSObject?
        try await waitUntil("the heatmap's element") {
            grid = self.gridElement(in: window)
            return grid != nil
        }
        let element = try XCTUnwrap(grid)
        XCTAssertEqual(element.accessibilityValue, summary(completed: 5, streak: 5))
        XCTAssertEqual(element.accessibilityHint, appLocalized("Opens History"))

        func expectHistoryOnToday(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case .history(let habitID, let day)? = shell.request else {
                return XCTFail("\(how): no History request, got \(String(describing: shell.request))", file: file, line: line)
            }
            XCTAssertEqual(habitID, read.id, how, file: file, line: line)
            XCTAssertTrue(calendar.isDateInToday(day), "\(how): on today", file: file, line: line)
            shell.request = nil
        }

        let actions = element.accessibilityCustomActions ?? []
        let edit = try XCTUnwrap(actions.first { $0.name == appLocalized("Edit history") },
                                 "an Edit history action among \(actions.map(\.name))")
        if let handler = edit.actionHandler {
            XCTAssertTrue(handler(edit))
        } else {
            let target = try XCTUnwrap(edit.target as? NSObject, "the action's target")
            _ = target.perform(edit.selector, with: edit)
        }
        expectHistoryOnToday("the Edit history action")

        XCTAssertTrue(element.accessibilityActivate(), "VoiceOver's double-tap")
        expectHistoryOnToday("the double-tap")

        let button = try XCTUnwrap(elements(in: window) {
            $0.accessibilityLabel == appLocalized("Edit history") && $0.accessibilityTraits.contains(.button)
        }.first, "the detail card's Edit history button")
        XCTAssertEqual(identifier(of: button), HabitDetailStatsCard.editHistoryIdentifier)
        XCTAssertTrue(button.accessibilityActivate(), "the button's tap")
        expectHistoryOnToday("the Edit history button")

        // The 84 cells were each an element ("Wednesday, October 15, completed"); today's is gone.
        let dateLabel = Date().formatted(.dateTime.weekday(.wide).month().day().locale(appLocale))
        let cellLabels: Set = [appLocalized("\(dateLabel), completed"), appLocalized("\(dateLabel), not completed")]
        XCTAssertEqual(elements(in: window) { cellLabels.contains($0.accessibilityLabel ?? "") }.count, 0)
    }

    // MARK: - The detail card's header (W3-1, W3-A11Y-1)

    /// What a line never breaks inside: the words, with the punctuation that touches them. A name
    /// written without spaces still splits, at its dictionary words.
    func testTheNamesUnbreakableRunsAreItsWordsWithTheirPunctuation() {
        let runs = DetailCardHeaderLayout.unbreakableRuns(of:)
        XCTAssertEqual(runs("Read 30 Minutes"), ["Read", "30", "Minutes"])
        XCTAssertEqual(runs("Leer 30 minutos"), ["Leer", "30", "minutos"])
        XCTAssertEqual(runs("Meditación"), ["Meditación"])
        XCTAssertEqual(runs("Read (30 min)"), ["Read", "(30", "min)"])
        XCTAssertEqual(runs("Don't snack, 100%"), ["Don't", "snack,", "100%"])
        XCTAssertEqual(runs("🏃‍♂️"), ["🏃‍♂️"], "no word at all: the name is one run")
        XCTAssertEqual(runs(""), [""])
        let japanese = "毎朝ストレッチを10分する"
        let split = runs(japanese)
        XCTAssertGreaterThan(split.count, 1, "\(split)")
        XCTAssertTrue(split.allSatisfy { japanese.contains($0) && $0.count < japanese.count }, "\(split)")
    }

    /// The header at the widths and sizes the review measured. Whatever it picks, the name is
    /// never narrower than its widest word (a word broken inside), it is read once, and the
    /// buttons stay inside the card at their full width. The buttons sit beside the name while
    /// its widest word fits there, and go under it when not. The card is 343 pt on a 375 pt iPhone
    /// (StatsView's padding), 370 pt on a 402 pt one, and 288 pt in a 320 pt compact iPad window.
    ///
    /// Run against the header before the fix (buttons beside the name below the accessibility
    /// sizes), the first three cases and the 288 pt one failed: "Meditación" got 52 pt of the
    /// 132 it needs, "Leer 30 minutos" 54 of 95 and "Read 30 Minutes" 66 of 95.
    func testTheHeaderNeverBreaksAWordOfTheName() async throws {
        enum Expect { case oneRow, stacked, either }
        struct Case {
            let name: String, size: DynamicTypeSize, language: String, card: CGFloat, expect: Expect
            var wraps = false
        }
        let cases = [
            // The review's scenarios (W3-1, W3-A11Y-1).
            Case(name: "Meditación", size: .xxxLarge, language: "es", card: 343, expect: .stacked),
            Case(name: "Leer 30 minutos", size: .xxxLarge, language: "es", card: 343, expect: .stacked),
            Case(name: "Read 30 Minutes", size: .xxxLarge, language: "en", card: 343, expect: .either),
            Case(name: "Meditate", size: .xLarge, language: "en", card: 343, expect: .either),
            Case(name: "Meditación", size: .large, language: "es", card: 343, expect: .either),
            // The default layout where it fits, a long name wrapping at its spaces beside the
            // buttons rather than pushed under them.
            Case(name: "Meditate", size: .large, language: "en", card: 370, expect: .oneRow),
            Case(name: "Drink a glass of water before breakfast", size: .large, language: "en",
                 card: 370, expect: .oneRow, wraps: true),
            // Narrow: the two buttons on their row still fit inside the card.
            Case(name: "Meditación", size: .xxxLarge, language: "es", card: 288, expect: .stacked),
            Case(name: "Meditate", size: .accessibility3, language: "en", card: 343, expect: .stacked),
        ]

        let subject = try habit("Header", values: days(-3...(-1)))
        subject.emoji = "\u{1F9D8}"
        let shell = ShellState(launchArguments: [])
        var window: UIWindow?
        for test in cases {
            subject.name = test.name
            let locale = Locale(identifier: test.language)
            let editLabel = try XCTUnwrap(localized("Edit history", language: test.language))
            // Above the card, the same button at its full width, to measure the card's against —
            // with the same tap area, which its accessibility frame is.
            let reference = Button {} label: {
                Label(editLabel, systemImage: "calendar").font(.subheadline.weight(.medium))
                    .tapTargetOutset(vertical: HabitDetailStatsCard.editHistoryTapOutset)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier(Self.referenceIdentifier)
            let card = VStack(alignment: .leading, spacing: 0) {
                reference
                HabitDetailStatsCard(habit: subject, stats: cache.stats(for: subject), shell: shell)
                    .frame(width: test.card)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .dynamicTypeSize(test.size)
            .environment(\.locale, locale)
            if let window {
                window.rootViewController = hostingController(card)
            } else {
                window = try host(card)
            }
            let shown = try XCTUnwrap(window)
            let what = "\"\(test.name)\" at \(test.size), \(test.language), \(Int(test.card)) pt"

            var found: (name: [NSObject], edit: NSObject, share: NSObject, reference: NSObject)?
            try await waitUntil("the header of \(what)") {
                let names = self.elements(in: shown) { $0.accessibilityLabel == test.name }
                let buttons = self.elements(in: shown) { $0.accessibilityTraits.contains(.button) }
                let identified = { (id: String) in buttons.first { self.identifier(of: $0) == id } }
                guard let edit = identified(HabitDetailStatsCard.editHistoryIdentifier),
                      edit.accessibilityLabel == editLabel,
                      let reference = identified(Self.referenceIdentifier),
                      let share = buttons.first(where: { $0 !== edit && $0 !== reference }),
                      !names.isEmpty, names.allSatisfy({ !$0.accessibilityFrame.isEmpty })
                else { return false }
                found = (names, edit, share, reference)
                return true
            }
            try await Task.sleep(for: .milliseconds(150))
            let elements = try XCTUnwrap(found)
            XCTAssertEqual(elements.name.count, 1, "\(what): the name is read once (the probe is hidden)")
            let name = elements.name[0].accessibilityFrame
            // The buttons as drawn: their accessibility frames are their tap areas, which reach
            // past the labels (`tapTargetOutset`, gate 8).
            let edit = elements.edit.accessibilityFrame.insetBy(dx: 0, dy: HabitDetailStatsCard.editHistoryTapOutset)
            let share = elements.share.accessibilityFrame.insetBy(dx: HabitDetailStatsCard.shareTapOutset.width,
                                                                  dy: HabitDetailStatsCard.shareTapOutset.height)
            // …and those areas are at least 44 pt (Share 44 × 44) at every size the cases take.
            XCTAssertGreaterThanOrEqual(elements.edit.accessibilityFrame.height, 43.5, "\(what): Edit history's tap area")
            XCTAssertGreaterThanOrEqual(elements.share.accessibilityFrame.height, 43.5, "\(what): Share's tap area")
            XCTAssertGreaterThanOrEqual(elements.share.accessibilityFrame.width, 43.5, "\(what): Share's tap area")

            let font = Font.title3.bold()
            let widest = DetailCardHeaderLayout.unbreakableRuns(of: test.name)
                .map { idealSize(of: Text(verbatim: $0).font(font), at: test.size, locale: locale).width }.max() ?? 0
            XCTAssertGreaterThanOrEqual(name.width + 1, widest, "\(what): a word of the name broke inside (\(name))")

            // The card starts at the window's leading edge; its padding is 16 pt each side.
            for (label, frame) in [("name", name), ("Edit history", edit), ("Share", share)] {
                XCTAssertGreaterThanOrEqual(frame.minX, 15.5, "\(what): \(label) inside the card (\(frame))")
                XCTAssertLessThanOrEqual(frame.maxX, test.card - 15.5, "\(what): \(label) inside the card (\(frame))")
            }
            // Never "Edit hi…": as wide as the reference. Only on a row of its own at the
            // accessibility sizes may it wrap, when the card is narrower than the two buttons.
            if test.expect != .stacked || !test.size.isAccessibilitySize {
                XCTAssertEqual(edit.width, elements.reference.accessibilityFrame.width, accuracy: 0.5,
                               "\(what): Edit history at its full width")
            }

            let stacked = edit.minY >= name.maxY - 0.5 && share.minY >= name.maxY - 0.5
            let beside = edit.minX >= name.maxX - 0.5 && edit.midY > name.minY && edit.midY < name.maxY
            switch test.expect {
            case .stacked: XCTAssertTrue(stacked, "\(what): the buttons under the name (name \(name), edit \(edit))")
            case .oneRow: XCTAssertTrue(beside, "\(what): the buttons beside the name (name \(name), edit \(edit))")
            case .either: XCTAssertTrue(stacked || beside, "\(what): name \(name), edit \(edit)")
            }
            if test.wraps {
                let line = idealSize(of: Text(verbatim: test.name).font(font), at: test.size, locale: locale).height
                XCTAssertGreaterThan(name.height, line * 1.5, "\(what): the name wraps at its spaces")
            }
        }
    }

    // MARK: - The cards' pure parts

    /// The change beside the score is the difference of the two scores as drawn, never the
    /// rounded difference: "74" over "+4" when it read 70 thirty days ago, although the raw change
    /// is 4.8 points.
    func testTheStrengthChangeIsTheDifferenceOfTheDrawnScores() {
        XCTAssertEqual(StrengthCard.displayedChange(current: 0.744, delta: 0.048), 4)
        XCTAssertEqual(StrengthCard.displayedChange(current: 0.74, delta: 0.05), 5)
        XCTAssertEqual(StrengthCard.displayedChange(current: 0.5, delta: -0.1), -10)
        XCTAssertEqual(StrengthCard.displayedChange(current: 0.3, delta: 0), 0)
        XCTAssertEqual(StrengthCard.displayedChange(current: 1, delta: 1), 100, "a habit younger than the window")
    }

    /// A run's dates: in UTC (a day-key is its day's UTC midnight; the Americas would draw the day
    /// before), one date for a one-day run, and the year only when the run is not all in this
    /// year.
    func testARunsDatesAreItsOwnDaysWithTheYearOnlyWhenNeeded() {
        let utc = HabitCalendar.utc
        func key(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
        func run(_ start: Date, _ end: Date) -> HabitStats.StreakRange {
            HabitStats.StreakRange(start: start, end: end, length: 1, isCurrent: false)
        }
        let en = Locale(identifier: "en_US"), today = key(2026, 10, 15)

        let september = BestStreaksCard.dates(of: run(key(2026, 9, 1), key(2026, 9, 12)), today: today, locale: en)
        XCTAssertTrue(september.contains("Sep") && september.contains("1") && september.contains("12"), september)
        XCTAssertFalse(september.contains("2026"), september)
        XCTAssertFalse(september.contains("Aug") || september.contains("31"), "never the day before: \(september)")

        XCTAssertEqual(BestStreaksCard.dates(of: run(key(2026, 9, 1), key(2026, 9, 1)), today: today, locale: en), "Sep 1")

        let lastYear = BestStreaksCard.dates(of: run(key(2025, 12, 28), key(2026, 1, 3)), today: today, locale: en)
        XCTAssertTrue(lastYear.contains("2025") && lastYear.contains("Dec") && lastYear.contains("Jan"), lastYear)

        let ja = BestStreaksCard.dates(of: run(key(2026, 9, 1), key(2026, 9, 12)), today: today,
                                       locale: Locale(identifier: "ja_JP"))
        XCTAssertTrue(ja.contains("9月1日"), ja)
    }

    /// The 8-week cards' weeks: 8 Mondays a week apart, oldest first, the last one this week's —
    /// the weeks `HabitStats.weeklyStrength` buckets.
    func testTheEightWeeksEndWithThisWeeksMonday() throws {
        let mondays = StatsWeeks.mondays(endingWithWeekOf: todayKey)
        XCTAssertEqual(mondays.count, 8)
        for monday in mondays { XCTAssertEqual(HabitCalendar.utc.component(.weekday, from: monday), 2) }
        for (a, b) in zip(mondays, mondays.dropFirst()) { XCTAssertEqual(b.timeIntervalSince(a), 7 * 86_400) }
        let last = try XCTUnwrap(mondays.last)
        XCTAssertLessThanOrEqual(last, todayKey)
        XCTAssertLessThan(todayKey.timeIntervalSince(last), 7 * 86_400)
        XCTAssertEqual(StatsWeeks.label.string(from: HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 28))!),
                       "9/28", "the bar label, in UTC")
    }

    // MARK: - Hosting

    /// `view` over this test's store and cache, in the picked language's locale, in a window of
    /// its own on the host app's scene, with the accessibility tree built.
    private func host(_ view: some View) throws -> UIWindow {
        automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hostingController(view)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    /// `view` over this test's store and cache, in the picked language's locale unless it sets
    /// its own: for a window `host` made, to show another view in.
    private func hostingController(_ view: some View) -> UIViewController {
        UIHostingController(rootView: AnyView(
            view
                .modelContainer(container)
                .environment(\.statsCache, cache)
                .environment(\.locale, LanguageManager.shared.locale ?? .current)))
    }

    /// The header test's full-width Edit history button, outside the card.
    private static let referenceIdentifier = "test.referenceEditHistory"

    /// `view` at its ideal size (a text on one line) at `size`, as SwiftUI lays it out.
    private func idealSize(of view: some View, at size: DynamicTypeSize, locale: Locale) -> CGSize {
        let measured = UIHostingController(rootView: view.fixedSize().dynamicTypeSize(size).environment(\.locale, locale))
        return measured.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    /// `key` in the app's catalog for `language` (the source string for English).
    private func localized(_ key: String, language: String) -> String? {
        guard language != "en" else { return key }
        return Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))?
            .localizedString(forKey: key, value: nil, table: nil)
    }

    /// The heatmap's VoiceOver value, as the app words it for a day-unit habit.
    private func summary(completed: Int, streak: Int) -> String {
        let total = HeatmapLayout.dayCount
        return appLocalized("\(completed) of \(total) days completed, \(streak) day streak")
    }

    /// The heatmap's one element: labelled Activity, with a value (the card's header shares the
    /// label and has none).
    private func gridElement(in window: UIWindow) -> NSObject? {
        elements(in: window) {
            $0.accessibilityLabel == appLocalized("Activity") && !($0.accessibilityValue ?? "").isEmpty
        }.first
    }

    private func gridValue(in window: UIWindow) -> String? { gridElement(in: window)?.accessibilityValue }

    /// The whole numbers spoken by the first element whose label starts with `prefix` (a tile:
    /// "Current Streak, 10, days").
    private func numbers(startingWith prefix: String, in window: UIWindow) -> [Int] {
        guard let element = elements(in: window, where: { ($0.accessibilityLabel ?? "").hasPrefix(prefix) }).first
        else { return [] }
        let spoken = [element.accessibilityLabel, element.accessibilityValue].compactMap { $0 }.joined(separator: " ")
        return spoken.split { !$0.isNumber }.compactMap { Int($0) }
    }

    /// An element's accessibility identifier, which SwiftUI's elements answer without adopting
    /// UIAccessibilityIdentification in their type.
    private func identifier(of element: NSObject) -> String? {
        if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The distinct accessibility elements under `root` that `matches`, in tree order.
    private func elements(in root: NSObject, where matches: (NSObject) -> Bool) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        collect(in: root, where: matches, seen: &seen, found: &found, depth: 0)
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
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
