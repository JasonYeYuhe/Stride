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
        #endif

        /// `-demoScenario <name>`; anything else (or nothing) is the standard set.
        static func fromLaunchArguments(_ arguments: [String] = CommandLine.arguments) -> Scenario {
            #if DEBUG
            if let idx = arguments.firstIndex(of: "-demoScenario"), idx + 1 < arguments.count,
               let scenario = Scenario(rawValue: arguments[idx + 1]) {
                return scenario
            }
            #endif
            return .standard
        }
    }

    @MainActor
    static func populate(container: ModelContainer, scenario: Scenario = .standard) {
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
        #endif
        }

        try? context.save()
    }

    @MainActor
    private static func insertStandardSet(into context: ModelContext) {
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

        for (i, info) in habits.enumerated() {
            let habit = Habit(name: info.0, emoji: info.1, colorHex: info.2)
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
    }

    #if DEBUG
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
