import Foundation

/// Timestamps on the sync wire.
enum SyncTimestamp {
    /// Parses both `2026-09-15T17:33:18Z` and `2026-09-15T17:33:18.123Z`.
    ///
    /// A default `ISO8601DateFormatter` accepts only the first; one with `.withFractionalSeconds`
    /// accepts only the second. Up to 1.2.2 the reconciler used the default, while every
    /// timestamp the server stamps itself has milliseconds — the whole App Review demo account
    /// among them. Those parsed as nil, a downloaded habit fell back to `createdAt = Date()`, and
    /// on a freshly signed-in device the demo habits looked created today: the 30-day rate,
    /// Weekly Review and trend chart all started from today. (The server now sends whole seconds
    /// too, for the builds already installed.)
    ///
    /// The result is snapped to the millisecond grid `floorToMillisecond` uses, so a stamp this
    /// device wrote with `touch()`, sent with `millisecondString`, and read back from the server
    /// is the same `Date`, bit for bit — not merely within a microsecond of it.
    static func parse(_ string: String?) -> Date? {
        guard let string,
              let date = wholeSeconds.date(from: string) ?? fractionalSeconds.date(from: string)
        else { return nil }
        return floorToMillisecond(date)
    }

    /// Whole seconds, UTC: what 1.3.0 and earlier sent, and still the display string
    /// `stride_last_sync_time` holds. Pushes from 1.3.1 use `millisecondString(from:)`.
    static func string(from date: Date) -> String {
        wholeSeconds.string(from: date)
    }

    // MARK: - Millisecond stamps (1.3.1, DEV-PLAN-1.3.md M2 "Millisecond edit stamps")
    //
    // Up to 1.3.0 an edit went on the wire as whole seconds, and the server's LWW guard is
    // `client_updated_at >= stored` plus a values-differ check, so two different edits of one
    // row inside the same second resolved by push order, not by which was made later. From
    // 1.3.1 `touch()` stores the edit time floored to the whole millisecond and the push sends
    // exactly that number, so the store, the wire and the acknowledgement all hold one value and
    // an echo of this device's own push compares equal. A sub-millisecond `Date()` never equals
    // what comes back from the server.
    //
    // Comparisons go through `milliseconds(_:)` rather than `Date ==` / `<`: rows written by
    // 1.3.0 still carry sub-millisecond stamps, and a stamp that crossed the wire is only as
    // precise as its string.

    /// Whole milliseconds since 1970, floored. The microsecond of slack absorbs binary rounding:
    /// a `Date` meant to be exactly …18.123 can be stored as …18.12299999, and a plain floor
    /// would call it …18.122 — after a round trip through the 1970 / 2001 epochs, or through the
    /// store's Double, the same stamp could floor to two different numbers.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000 + 0.001).rounded(.down))
    }

    /// The instant at the start of `date`'s millisecond. Always built the same way, so two
    /// dates with the same `milliseconds` value are `==`.
    static func floorToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds(date)) / 1000)
    }

    /// Now, floored to the millisecond: what `touch()` and the model initialisers store.
    static func now() -> Date {
        floorToMillisecond(Date())
    }

    /// The stamp for an edit of a row whose stamp is `previous`: now, floored — or one
    /// millisecond past `previous` when now floors to the same millisecond.
    ///
    /// An edit must change the stamp: that is what makes a row pending again and what lifts a
    /// hold (`SyncDeliverable`). With whole-millisecond stamps, two edits inside one millisecond
    /// would share one, and if the push had read the row between them, its acknowledgement would
    /// mark the second edit delivered. Bumping only on a tie — not `max(now, previous + 1 ms)` —
    /// keeps a clock that stepped backwards from dragging every later edit into the old clock's
    /// future; the stamp then moves backwards, which the inequality rule already treats as an
    /// edit.
    static func nextStamp(after previous: Date?) -> Date {
        let current = now()
        guard let previous, sameMillisecond(previous, current) else { return current }
        return Date(timeIntervalSince1970: Double(milliseconds(current) + 1) / 1000)
    }

    /// Same millisecond, both nil, or neither: the delivery state's equality ("is the stamp the
    /// server acknowledged the stamp this row has now?").
    static func sameMillisecond(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return milliseconds(a) == milliseconds(b)
        default: return false
        }
    }

    /// Strictly later at millisecond precision — the reconciler's local-newer guard. Both sides
    /// are floored, so a whole-second stamp from an older app (…18.000) and this device's own
    /// echo compare the way the server compared them.
    static func isNewer(_ a: Date, than b: Date) -> Bool {
        milliseconds(a) > milliseconds(b)
    }

    /// What 1.3.1 sends: UTC with exactly three fractional digits, floored (never rounded up
    /// into the next millisecond, which would make an edit look later than it was). Built from
    /// the whole-second string rather than `.withFractionalSeconds`, whose rounding of the last
    /// digit is not something to rely on for a value that must round-trip exactly.
    /// The server stores it through `toISOString()` — the same fixed width as the `.000Z` it
    /// makes of an older app's whole seconds — so its string comparison stays chronological.
    static func millisecondString(from date: Date) -> String {
        let ms = milliseconds(date)
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000   // floor division
        let fraction = ms - seconds * 1000
        let whole = wholeSeconds.string(from: Date(timeIntervalSince1970: Double(seconds)))
        // "2026-09-15T17:33:18Z" -> "2026-09-15T17:33:18.123Z"
        return String(whole.dropLast()) + "." + String(format: "%03lld", fraction) + "Z"
    }

    fileprivate static let wholeSeconds = ISO8601DateFormatter()

    fileprivate static let fractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The `?since=` sent with each incremental pull.
///
/// It used to be this device's `Date()` taken after the pull finished, which left two holes:
/// anything another device wrote between the server's query and that moment was never pulled,
/// on every sync and with perfect clocks; and a device whose clock ran fast stored a cursor in
/// the server's future and silently skipped everything written in that window, tombstones
/// included. The cursor now comes from the server's own clock (`serverTime` in the pull
/// response), wound back by `overlap` so rows committed while the pull was being answered are
/// fetched again next time. Pulling a row twice is harmless: applying it is idempotent.
enum SyncCursor {
    static let overlap: TimeInterval = 60

    /// The cursor to store after applying a pull whose response carried `serverTime`, in the
    /// server's own millisecond format. nil if `serverTime` isn't a timestamp.
    static func next(afterServerTime serverTime: String) -> String? {
        guard let time = SyncTimestamp.parse(serverTime) else { return nil }
        return SyncTimestamp.fractionalSeconds.string(from: time.addingTimeInterval(-overlap))
    }
}
