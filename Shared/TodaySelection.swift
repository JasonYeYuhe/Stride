import Foundation

/// Which day the Today screen shows after the calendar day has changed underneath it.
///
/// TodayView held `@State var selectedDate = Date()`, set once when the view was created and
/// never again. Open Stride at 23:50, background it, come back at 07:30: the screen still showed
/// yesterday, and every check-in was written to yesterday's day-key — today stayed unchecked, the
/// streak broke, and the widget and watch disagreed with the app. That is the most common way a
/// habit app is used.
enum TodaySelection {
    /// - Parameters:
    ///   - selected: the day currently shown.
    ///   - shownOn: the day it was "today" when `selected` was last anchored.
    ///   - now: the current time.
    /// - Returns: `now` if the user was looking at today and today has since changed, or if the
    ///   picked day has scrolled out of the seven-day week strip; otherwise `selected` unchanged —
    ///   a day the user deliberately picked in the strip stays picked.
    static func reanchored(selected: Date, shownOn: Date, now: Date, calendar: Calendar = .current) -> Date {
        guard !calendar.isDate(now, inSameDayAs: shownOn) else { return selected }
        if calendar.isDate(selected, inSameDayAs: shownOn) { return now }
        if let oldestInStrip = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           selected < oldestInStrip {
            return now
        }
        return selected
    }
}
