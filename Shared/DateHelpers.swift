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
    ///
    /// The Y/M/D are always Gregorian (`dayCalendar`), whatever calendar the device uses.
    static func dayKey(for date: Date = Date(), localCalendar: Calendar = .current) -> Date {
        if isDayKey(date) { return date }
        let c = dayCalendar(localCalendar).dateComponents([.year, .month, .day], from: date)
        return utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? utc.startOfDay(for: date)
    }

    /// The calendar a day-key takes its year, month and day from: `calendar` itself when it is
    /// Gregorian, otherwise a Gregorian calendar in `calendar`'s time zone (X2,
    /// docs/X2-non-gregorian-day-keys.md).
    ///
    /// Builds 1.2.0–1.4.0 read the Y/M/D in the DEVICE's calendar and wrote them as a Gregorian
    /// date: on a phone set to the Japanese calendar 2026-10-15 was stored, synced and backed up as
    /// 0008-10-15 (Reiwa 8), on a Buddhist one (Thailand's region default) as 2569-10-15, on a
    /// Hebrew one as 5787-02-04. Every key's weekday was wrong, so "specific days" and Monday weeks
    /// broke, and calendars whose months differ from Gregorian ones merged some days and skipped
    /// others. The device's calendar is for display only — symbols, day numbers, titles — and for
    /// its time zone, which decides where a day starts. Weekday NUMBERING (1 = Sunday) is the same
    /// in every calendar, so nothing else is copied. `DayKeyRepair` puts the keys those builds
    /// wrote back on their real days. Measured 0.47 µs a call against 0.62 µs before, so no cache.
    static func dayCalendar(_ calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Whether builds before 1.4.1 already wrote correct keys under `calendar`: Gregorian, or ISO
    /// 8601, whose year, month and day are Gregorian's. Any other calendar wrote keys that
    /// `DayKeyRepair` has to put back (and the widget waits for it, `ExtensionStoreOpen`).
    static func wroteGregorianKeys(_ calendar: Calendar) -> Bool {
        calendar.identifier == .gregorian || calendar.identifier == .iso8601
    }

    /// The first real day a stored key can name: 2025-01-01, before Stride existed (its first
    /// commit is 2026-03-27) and the floor of History's backfill (D8). A key before it — or more
    /// than two days after today — is one a non-Gregorian device wrote (`DayKeyRepair`), never a
    /// real check-in; the strength walk and History never reach past it.
    static let firstRealDayKey: Date = utc.date(from: DateComponents(year: 2025, month: 1, day: 1))!

    /// `firstRealDayKey` as a day number (whole days since 1970-01-01): 20089.
    static let firstRealDayNumber = Int(firstRealDayKey.timeIntervalSince1970 / 86_400)

    /// How far after today a key can still be a real day: a device in a zone already on tomorrow,
    /// or a check-in a top-up dated by UTC (D13), is one day ahead; one more for margin.
    static let realDaysAfterToday = 2

    /// The day numbers a stored key can name on the day `todayNumber`:
    /// [`firstRealDayNumber`, today + `realDaysAfterToday`]. Empty when the clock says today is
    /// before the floor (a clock that is badly wrong): then nothing is taken for a stray key.
    static func realDayNumbers(todayNumber: Int) -> ClosedRange<Int>? {
        let last = todayNumber + realDaysAfterToday
        return firstRealDayNumber <= last ? firstRealDayNumber...last : nil
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
    ///
    /// Gregorian Y/M/D in `calendar`'s time zone (`dayCalendar`).
    static func dayKey(forInstant instant: Date, calendar: Calendar = .current) -> Date {
        let c = dayCalendar(calendar).dateComponents([.year, .month, .day], from: instant)
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

    // 1.4.1 (D10) deleted `shortWeekday`, `dayNumber` and `monthYear`: nothing called them, and
    // each built a DateFormatter per call with a fixed pattern and no locale, so any new caller
    // would have drawn English in every language ("MMMM yyyy" read "September 2026" on a
    // Japanese-picked app). Names come from `appCalendar`; dates from a FormatStyle with
    // `appLocale`.

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
