import Foundation

/// Canonical "habit day" arithmetic.
///
/// A check-in is identified by the user's *local* calendar day at the moment of
/// logging, stored as that day's midnight in **UTC** (a stable "day-key"). All
/// streak / completion math is performed in this UTC-anchored space so a
/// check-in never slips to an adjacent day when the user travels across time
/// zones or through a DST transition (the previous code anchored to the device's
/// current time zone, which could duplicate or orphan entries after travel).
enum HabitCalendar {
    /// Calendar pinned to UTC — used for all day-key arithmetic.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Day-key for a local instant: take the user's local Y/M/D, anchor to UTC midnight.
    ///
    /// **Idempotent.** A value that is already a day-key is returned unchanged.
    /// This matters because the streak/schedule math re-keys values that are
    /// already keys (`Habit.isScheduled(on:)`, `weekStart(for:)` and
    /// `completionRate(from:to:)` all receive day-keys). Re-keying re-reads the
    /// instant in the *local* calendar, so in any negative-UTC-offset zone —
    /// i.e. all of the Americas — UTC midnight reads as the *previous* local
    /// day and the weekday shifted back one: every scheduled day looked
    /// unscheduled, every rest day looked scheduled, and `currentStreak()`
    /// returned 0 for every "Specific days" habit. UTC and positive offsets
    /// (Asia/Tokyo, Europe/*) are unaffected, which is why the whole suite
    /// stayed green — the bug was invisible from the machine it was written on.
    static func dayKey(for date: Date = Date(), localCalendar: Calendar = .current) -> Date {
        if isDayKey(date) { return date }
        let c = localCalendar.dateComponents([.year, .month, .day], from: date)
        return utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? utc.startOfDay(for: date)
    }

    /// Day-key for an instant the SYSTEM supplied — a notification's delivery date, a response's
    /// time: always that instant's local Y/M/D in `calendar`, anchored to UTC midnight.
    ///
    /// **Not idempotent, on purpose.** `dayKey(for:)` returns any instant that is exactly
    /// 00:00:00.000 UTC unchanged, taking it for a key that was already made. A whole-minute
    /// reminder in a negative UTC offset can be exactly that instant of the NEXT date: the default
    /// 20:00 reminder in US Eastern daylight time fires at 00:00Z, as do 19:00 EST and 16:00 PST.
    /// Through `dayKey(for:)` its Mark Done wrote tomorrow's record (RELEASE-1.4.0.md D4, the
    /// design review's one blocker; invisible from UTC+9). Use this for instants and `dayKey(for:)`
    /// for values that may already be keys — never the other way round: re-reading a stored key
    /// here would move it back a day in the Americas, the bug `dayKey(for:)` documents.
    static func dayKey(forInstant instant: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? utc.startOfDay(for: instant)
    }

    /// Normalize an already-stored record date (idempotent on day-keys).
    static func startOfKey(_ recordDate: Date) -> Date {
        utc.startOfDay(for: recordDate)
    }

    /// True if a stored record date falls on the same habit-day as a local instant.
    static func record(_ recordDate: Date, isOnSameDayAs localInstant: Date) -> Bool {
        startOfKey(recordDate) == dayKey(for: localInstant)
    }

    /// `true` if `recordDate` is already a UTC-midnight day-key (used by the
    /// one-time data migration to stay idempotent — see SharedModelContainer).
    static func isDayKey(_ recordDate: Date) -> Bool {
        let c = utc.dateComponents([.hour, .minute, .second, .nanosecond], from: recordDate)
        return c.hour == 0 && c.minute == 0 && c.second == 0 && (c.nanosecond ?? 0) == 0
    }

    /// `yyyy-MM-dd` serialization in UTC, matching the day-key representation.
    static let dayStringFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    var shortWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: self)
    }

    var dayNumber: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: self)
    }

    var monthYear: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: self)
    }

    static func daysInRange(from startDate: Date, to endDate: Date) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        var current = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        while current <= end {
            dates.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }

    static func lastNDays(_ n: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(n - 1), to: today) else { return [] }
        return daysInRange(from: startDate, to: today)
    }
}
