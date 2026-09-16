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
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return wholeSeconds.date(from: string) ?? fractionalSeconds.date(from: string)
    }

    /// What the app sends: UTC, whole seconds.
    static func string(from date: Date) -> String {
        wholeSeconds.string(from: date)
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
