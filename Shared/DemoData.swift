import SwiftData
import Foundation

enum DemoData {
    /// What `-demo` fills the store with. `standard` is the five-habit set the store screenshots and
    /// scripts/a11y_sweep.sh use; the others exist to put one exact number on screen for the 1.3.0
    /// plural acceptance checks (DEV-PLAN-1.3.md M1 acceptance (1) and (2)), which the standard set
    /// can never show — no habit in it has 1 check-in or a streak in weeks.
    ///
    /// The extra scenarios are DEBUG-only, like every other launch argument that changes what the
    /// app draws (`-paywall`, `-statsScrollTo`): a store build has no way to reach them.
    enum Scenario: String {
        case standard
        #if DEBUG
        /// One habit with exactly one check-in, today: Settings "1 check-in", Today and Stats
        /// "1 day streak" / "1 day", Spanish "Racha de 1 día". (The widget says "All done! 🎉",
        /// not "1 remaining" — that needs the habit NOT done today, which would break the rest.)
        case plurals
        /// One 3-times-a-week habit whose current streak (4 weeks) and best streak (5 weeks)
        /// differ, so the Stats card shows the weeks unit beside two different numbers.
        case weekly
        /// The standard set with what it never draws, for scripts/a11y_sweep.sh's `15_details_*`
        /// captures (RELEASE-1.4.1.md gate 8, 2026-10-17): Morning Run in Yellow — the palette's
        /// lowest contrast, as text on a card and under white — with a Description (D7) and notes
        /// on today's and two days back's check-ins (the note dot, D5); Drink Water counted, 8
        /// glasses a day, with 5 today (History's stepper, a ring under its goal).
        case details
        /// RELEASE-1.4.2.md D14: what `-demo -demoPro` seeds, and `-demoScenario pro`, which draws
        /// it for a FREE user (the locked card's preview). Every Pro surface has something true to
        /// show on whatever weekday it is launched (`insertProSet`). The free `.standard` set is
        /// untouched, so the free sweep's baselines hold.
        case pro
        #endif

        /// `-demoScenario <name>`; else `-demoPro`'s `.pro`; anything else (or nothing) is the
        /// standard set. An explicit `-demoScenario` wins: `-demoPro -demoScenario details` is the
        /// details set with Pro on.
        static func fromLaunchArguments(_ arguments: [String] = CommandLine.arguments) -> Scenario {
            #if DEBUG
            if let idx = arguments.firstIndex(of: "-demoScenario"), idx + 1 < arguments.count,
               let scenario = Scenario(rawValue: arguments[idx + 1]) {
                return scenario
            }
            if arguments.contains("-demoPro") { return .pro }
            #endif
            return .standard
        }
    }

    /// - Parameter now: the day `.pro` is laid out around (its tests pass each weekday). The other
    ///   sets read the clock themselves, as they always have.
    @MainActor
    static func populate(container: ModelContainer, scenario: Scenario = .standard, now: Date = Date()) {
        let context = container.mainContext

        // Clear EVERYTHING the store can hold, groups included. This used to delete only check-ins
        // and habits, so a group left behind by an earlier run (or by hand) survived `-demo`: on
        // 2026-09-27 a "Morning" group from a previous session drew a group header into the
        // default-size a11y sweep, and the sweep no longer matched its baseline. The same
        // fetch-and-delete as Settings → Erase Local Data, which also catches orphaned check-ins.
        try? DataBackup.eraseLocalData(in: context)

        switch scenario {
        case .standard:
            insertStandardSet(into: context)
        #if DEBUG
        case .plurals:
            insertPluralsSet(into: context)
        case .weekly:
            insertWeeklySet(into: context)
        case .details:
            insertDetailsSet(into: context)
        case .pro:
            insertProSet(into: context, now: now)
        #endif
        }

        try? context.save()
    }

    @MainActor
    @discardableResult
    private static func insertStandardSet(into context: ModelContext) -> [Habit] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let habits: [(String, String, String)] = [
            ("Morning Run", "\u{1F3C3}", "#34C759"),
            ("Read 30 min", "\u{1F4DA}", "#007AFF"),
            ("Drink Water", "\u{1F4A7}", "#FF9500"),
            ("Meditate", "\u{1F9D8}", "#AF52DE"),
            ("Journal", "\u{270D}\u{FE0F}", "#FF3B30"),
        ]

        let patterns: [[Bool]] = [
            [true, true, true, true, true],
            [true, true, true, false, true],
            [true, false, true, true, true],
            [true, true, true, true, false],
            [false, true, true, true, true],
            [true, true, true, true, true],
            [true, true, false, true, true],
            [true, true, true, true, true],
            [true, false, true, true, false],
            [true, true, true, false, true],
            [false, true, true, true, true],
            [true, true, true, true, true],
            [true, true, false, true, true],
            [true, false, true, true, false],
            [true, true, true, true, true],
        ]

        var inserted: [Habit] = []
        for (i, info) in habits.enumerated() {
            let habit = Habit(name: info.0, emoji: info.1, colorHex: info.2)
            inserted.append(habit)
            habit.createdAt = calendar.date(byAdding: .second, value: i, to: calendar.date(byAdding: .day, value: -30, to: today)!)!
            context.insert(habit)

            for (dayOffset, pattern) in patterns.enumerated() {
                if pattern[i] {
                    let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
                    let record = HabitRecord(date: date)
                    habit.records.append(record)
                }
            }
        }
        return inserted
    }

    #if DEBUG
    /// D14's Pro scenario (`-demo -demoPro`), laid out by Monday-anchored week and weekday around
    /// `now`'s local day, so each surface reads the same whatever weekday the sweep runs on
    /// (DemoDataProScenarioTests check all seven, in Tokyo and Los Angeles):
    /// - two groups, Health and Mind (Today's sections, the review's);
    /// - Morning Run, daily for 20 weeks (Statistics' habit, first in order): Insights' three lines
    ///   — 1 to 7 days from its record of 14, "Up" against last week's 86 %, toughest on Sunday
    ///   (3 or 4 of 12 recent Sundays against 10 of 12 Mondays) — Strength's 30- and 90-day
    ///   changes, and the best streaks;
    /// - Drink Water, started 10 days ago (D7: Strength "Not started" before the start, one "Since
    ///   start" tile, Insights' first-week or true line);
    /// - Read 30 min, 43 % the week before last and 86 % last week: last week's "Most improved";
    /// - Yoga, 3 times a week, none yet this week: at risk from Friday, by D10's rule (no
    ///   earlier: Monday to Thursday enough days are left);
    /// - Journal, 100 % then 43 %, so "Slipped", with notes on last week's three check-ins.
    /// Today: Morning Run and Read are done, the others not yet. Last week has a counted rate, so
    /// `-inlineCard week` draws the Today card with a number.
    @MainActor
    private static func insertProSet(into context: ModelContext, now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Monday of this week, by Habit.weekStart's rule (Monday-anchored whatever the region).
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        let thisMonday = calendar.date(byAdding: .day, value: -todayWeekday, to: today)!
        /// Day `weekday` (0 = Monday … 6 = Sunday) of the week `weeksBack` before this one.
        func day(_ weeksBack: Int, _ weekday: Int) -> Date {
            calendar.date(byAdding: .day, value: weekday - 7 * weeksBack, to: thisMonday)!
        }

        let health = HabitGroup(name: "Health", colorHex: "#34C759", sortOrder: 0)
        let mind = HabitGroup(name: "Mind", colorHex: "#AF52DE", sortOrder: 1)
        context.insert(health)
        context.insert(mind)

        var order = 0
        /// One habit from `start` through today. `done(weeksBack, weekday, daysAgo)` says which
        /// days are checked; `notes` puts a note on last week's check-in of that weekday.
        func add(_ name: String, _ emoji: String, _ hex: String, group: HabitGroup, start: Date,
                 notes: [Int: String] = [:], done: (Int, Int, Int) -> Bool) -> Habit {
            let habit = Habit(name: name, emoji: emoji, colorHex: hex)
            habit.createdAt = calendar.date(byAdding: .second, value: order, to: start)!
            habit.sortOrder = Double(order)
            habit.groupId = group.id
            order += 1
            context.insert(habit)
            let daysBack = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            for daysAgo in stride(from: daysBack, through: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                let offset = calendar.dateComponents([.day], from: date, to: thisMonday).day ?? 0
                // Days before this Monday: offset 1…7 is last week, and so on.
                let weeksBack = offset <= 0 ? 0 : (offset + 6) / 7
                let weekday = (calendar.component(.weekday, from: date) + 5) % 7
                guard done(weeksBack, weekday, daysAgo) else { continue }
                let note = weeksBack == 1 ? notes[weekday] : nil
                habit.records.append(HabitRecord(date: date, note: note))
            }
            return habit
        }

        // Sundays checked: this week's (when today is one), last week's, and weeks 5 and 6, whose
        // run from Monday of week 6 to Sunday of week 5 is the record, 14 (Monday of week 4 is
        // missed). Monday of last week is missed too, so the current run starts on its Tuesday:
        // 7 to 13 days, always 1 to 7 from the record, and last week reads 86 %.
        _ = add("Morning Run", "\u{1F3C3}", "#34C759", group: health, start: day(19, 0)) { week, weekday, _ in
            if weekday == 6 { return [0, 1, 5, 6].contains(week) }
            if weekday == 0 { return week != 1 && week != 4 }
            return true
        }
        _ = add("Drink Water", "\u{1F4A7}", "#FF9500", group: health,
                start: calendar.date(byAdding: .day, value: -10, to: today)!) { _, _, daysAgo in
            daysAgo != 0 && daysAgo != 6
        }
        _ = add("Read 30 min", "\u{1F4DA}", "#007AFF", group: mind, start: day(12, 0),
                notes: [5: "Finished the book"]) { week, weekday, _ in
            switch week {
            case 0: return true
            case 1: return weekday != 3
            case 2: return [0, 2, 4].contains(weekday)
            default: return weekday != 6
            }
        }
        let yoga = add("Yoga", "\u{1F9D8}", "#AF52DE", group: mind, start: day(12, 0)) { week, weekday, _ in
            switch week {
            case 0: return false
            case 2: return [0, 3].contains(weekday)
            default: return [0, 2, 4].contains(weekday)
            }
        }
        yoga.schedule = .timesPerWeek
        yoga.timesPerWeek = 3
        _ = add("Journal", "\u{270D}\u{FE0F}", "#FF3B30", group: mind, start: day(12, 0),
                notes: [1: "Wrote before bed", 3: "Two pages", 5: "Short one tonight"]) { week, weekday, daysAgo in
            switch week {
            case 0: return daysAgo > 0 && [0, 2, 3, 5].contains(weekday)
            case 1: return [1, 3, 5].contains(weekday)
            case 2: return true
            default: return ![2, 6].contains(weekday)
            }
        }
    }

    @MainActor
    private static func insertDetailsSet(into context: ModelContext) {
        let habits = insertStandardSet(into: context)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func key(daysBack: Int) -> Date {
            HabitCalendar.dayKey(for: calendar.date(byAdding: .day, value: -daysBack, to: today)!)
        }
        if let run = habits.first(where: { $0.name == "Morning Run" }) {
            run.colorHex = "#FFCC00"
            run.note = "Before breakfast, one lap of the park"
            for (daysBack, note) in [(0, "Felt strong"), (2, "Rain, so a shorter loop")] {
                run.records.first { $0.date == key(daysBack: daysBack) }?.note = note
            }
        }
        if let water = habits.first(where: { $0.name == "Drink Water" }) {
            water.habitKind = .count
            water.targetValue = 8
            water.unit = "glasses"
            for record in water.records {
                record.value = record.date == key(daysBack: 0) ? 5 : 8
            }
        }
    }

    @MainActor
    private static func insertPluralsSet(into context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let habit = Habit(name: "Read 30 min", emoji: "\u{1F4DA}", colorHex: "#007AFF")
        // Created today, so the 30-day rate is 100% of one day rather than 1 of 30.
        habit.createdAt = today
        context.insert(habit)
        habit.records.append(HabitRecord(date: today))
    }

    @MainActor
    private static func insertWeeklySet(into context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Monday of this week, by the same rule as Habit.weekStart (Monday-anchored whatever the
        // region's first weekday): Mon → 0 … Sun → 6 days back.
        let daysFromMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let thisMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!

        let habit = Habit(name: "Morning Run", emoji: "\u{1F3C3}", colorHex: "#34C759")
        habit.schedule = .timesPerWeek
        habit.timesPerWeek = 3
        habit.createdAt = calendar.date(byAdding: .day, value: -7 * 11, to: thisMonday)!
        context.insert(habit)

        // Weeks back from this one: 1–4 meet the goal (current streak 4 — this week is still in
        // progress, which never breaks it), 5 has a single run (breaks it), 6–10 meet the goal
        // (best streak 5). Mon/Wed/Fri of each week are all in the past whatever today is.
        for week in Array(1...4) + Array(6...10) {
            let monday = calendar.date(byAdding: .day, value: -7 * week, to: thisMonday)!
            for offset in [0, 2, 4] {
                habit.records.append(HabitRecord(date: calendar.date(byAdding: .day, value: offset, to: monday)!))
            }
        }
        let brokenWeek = calendar.date(byAdding: .day, value: -7 * 5, to: thisMonday)!
        habit.records.append(HabitRecord(date: brokenWeek))
        // And today, so this week reads "1/3 this week" rather than "0/3".
        habit.records.append(HabitRecord(date: today))
    }
    #endif
}
