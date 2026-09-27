import Foundation

/// Stored amounts, shown or converted without ever trapping.
///
/// `Int(Double)` traps on NaN, on ±infinity and on anything at or past ±2^63 (9.2e18). Today
/// and the Siri reply formatted a whole-number amount with `String(Int(value))`, and the habit
/// sheet read the target with `max(1, Int(targetValue))`. Those numbers are not only what this
/// device wrote: sync pulls whatever any device pushed, and /v1/sync/push stored `value` and
/// `targetValue` unchecked until the 1.3.0 server (JSON `1e999` parses to Infinity there, `1e19`
/// to itself). One such check-in on an account and Today — the first tab — trapped on every
/// launch, on every device signed into it, with deleting the app the only way out. Restore
/// already bounds what a backup may bring in (`DataBackup.maxAmount`); sync cannot bound what
/// is already on a device, so every conversion of a stored amount goes through here instead.
///
/// Rates and percentages computed from counts (completed ÷ scheduled) are finite by
/// construction and do not need this; anything read from a record or a habit does.
enum SafeNumber {
    /// Shown for an amount that is not a number (NaN, ±infinity). Not localized: a dash reads
    /// the same in every language, and VoiceOver says "dash".
    static let placeholder = "—"

    /// From here on an amount is shown in scientific notation rather than as digits. Doubles are
    /// exact integers only up to 2^53 (≈ 9.0e15), so past this the digits would be noise — and
    /// it keeps the whole-number path far below where `Int64(_:)` traps. The same line as
    /// `DataBackup.number` in the CSV export.
    static let largestPlainAmount = 1e15

    /// An amount as the app has always shown it — "8", "2.5", "1000000" — for any Double at all:
    /// NaN and ±infinity as `placeholder`, |value| ≥ 1e15 as "1e+19". Locale-independent, like
    /// the `%.1f` it replaces (the count label is "3/8", not prose).
    static func amount(_ value: Double) -> String {
        guard value.isFinite else { return placeholder }
        guard abs(value) < largestPlainAmount else { return String(format: "%.3g", value) }
        if value == value.rounded() { return String(Int64(value)) }
        return String(format: "%.1f", value)
    }

    /// `Int(value)` — truncated toward zero, as the conversion it replaces — clamped into
    /// `range`. NaN gives the lower bound, ±infinity the nearer bound. Never traps, whatever
    /// the range: the bounds are compared as Doubles first, and the result is clamped again
    /// because `Double(range.upperBound)` can round up past it (Int.max becomes 2^63).
    static func wholeNumber(_ value: Double, in range: ClosedRange<Int>) -> Int {
        guard !value.isNaN else { return range.lowerBound }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return min(max(Int(value), range.lowerBound), range.upperBound)
    }

    /// A fraction for a progress ring: clamped to 0…1, NaN as 0. `Habit.progress(on:)` caps at 1
    /// but has no floor, so a negative check-in pulled from sync handed `.trim(to:)` a negative
    /// (or -infinite) end.
    static func unitInterval(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }
}
