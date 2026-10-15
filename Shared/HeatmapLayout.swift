import Foundation
import CoreGraphics

/// The Stats heatmap's geometry, pure (RELEASE-1.4.0.md D2, "Heatmap"): which day goes in which
/// cell, and how big a cell is. StatsView's `HeatmapGrid` draws it. Since 1.4.1 (D5) also what a
/// cell shows, which day a tap lands on, and the grid's one accessibility summary.
///
/// Two defects it replaces:
/// - **The first column.** The grid split the 84 days into weeks at `firstWeekday` and padded
///   every short column at the BOTTOM. Only the newest week is short at the bottom (its days have
///   not happened yet); the oldest one starts mid-week, so its days were drawn from the top row
///   down — each one beside the wrong weekday letter, Thursday under "S" and so on, on every phone
///   and iPad, whenever the 84 days did not start on the first day of a week (six days in seven).
///   Here every day sits in the row of its own weekday, and the oldest week is padded at the TOP.
/// - **The size.** A fixed 14 pt `@ScaledMetric` cell drew the grid across about a quarter of an
///   iPad's card. At regular width (and on the Mac, which counts as regular) the cell now grows
///   to fill the card (`cellSize`).
enum HeatmapLayout {
    /// Twelve weeks of days, ending today.
    static let dayCount = 84
    /// The columns the size is computed for. 84 days fill 13 week columns, or 12 on the one day in
    /// seven when the oldest of them is the first day of a week; sizing for 13 always keeps the
    /// cell the same from one day to the next (on 12-column days the grid is trailing-aligned).
    static let sizingColumns = 13
    /// Between the letter column and the grid, and between week columns and between rows.
    static let spacing: CGFloat = 3
    /// The largest a width-derived cell gets (D2: "no upper clamp below 44 pt"). Only a Mac window
    /// wider than the 680 pt content cap could reach it.
    static let maximumCell: CGFloat = 44

    /// The days, oldest first: the `dayCount` local midnights ending with `today`'s, by
    /// `calendar` — consecutive calendar days, so a DST change never skips or repeats one.
    static func days(endingOn today: Date, calendar: Calendar) -> [Date] {
        let last = calendar.startOfDay(for: today)
        return (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }
    }

    /// The row a day belongs in: 0 for `calendar.firstWeekday`, … 6 for the day before it — the
    /// same order as the weekday letters (`(firstWeekday - 1 + row) % 7` into the symbols).
    static func row(of day: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
    }

    /// The days as week columns of exactly seven cells, top to bottom in the letters' order; nil
    /// is an empty cell. The oldest column is padded at the top (the days before the range), the
    /// newest at the bottom (days still to come). Each day's row comes from its own weekday, never
    /// from its position in the list, so a column can never start on the wrong row.
    static func columns(of days: [Date], calendar: Calendar) -> [[Date?]] {
        var columns: [[Date?]] = []
        var column: [Date?] = []
        for day in days {
            let row = row(of: day, calendar: calendar)
            if row < column.count {
                // A new week (or a day that does not follow the last — never from `days(…)`).
                columns.append(column + Array(repeating: nil, count: 7 - column.count))
                column = []
            }
            column += Array(repeating: nil, count: row - column.count)
            column.append(day)
        }
        if !column.isEmpty {
            columns.append(column + Array(repeating: nil, count: 7 - column.count))
        }
        return columns
    }

    /// The cell's side.
    /// - Compact width (phones, iPad slide-over): `scaled`, the existing `@ScaledMetric` cell, so a
    ///   phone is unchanged at every Dynamic Type size, strip mode included.
    /// - Regular width and the Mac: the size at which `sizingColumns` columns and the letters fill
    ///   `availableWidth` — the grid row's width, measured outside its horizontal ScrollView — but
    ///   never below `scaled` (the text-size floor; a narrow window keeps today's cell, and the
    ///   accessibility strip still scrolls) and never above `maximumCell`. At the 680 pt content
    ///   cap the card's inner width is 616 pt: 41 pt cells, a 613 pt grid, 99.5 % of it — the 28 pt
    ///   clamp of the first draft filled 70 % ("heatmap-clamp-fails-fills-card").
    static func cellSize(scaled: CGFloat, availableWidth: CGFloat, regular: Bool) -> CGFloat {
        guard regular, availableWidth.isFinite else { return scaled }
        let columns = CGFloat(sizingColumns)
        let fitted = ((availableWidth - columns * spacing) / (columns + 1)).rounded(.down)
        return max(scaled, min(maximumCell, fitted))
    }

    /// The grid's width at `cell`: the letter column plus `columns` week columns, `spacing` apart.
    /// 14·cell + 39 for 13 columns.
    static func gridWidth(cell: CGFloat, columns: Int = sizingColumns) -> CGFloat {
        CGFloat(columns + 1) * cell + CGFloat(columns) * spacing
    }

    // MARK: - Cells, taps and the one accessibility element (RELEASE-1.4.1.md D5)

    /// What a day's cell draws. The fill is an enum, not a flag, so M6's third visual — a hatched
    /// skipped day — is one more case here rather than a second Bool beside `completed`.
    struct Cell: Equatable {
        enum Fill: Equatable {
            case completed
            case notCompleted
        }

        var fill: Fill
        /// One of the day's check-ins carries a note: a `noteDot` in the cell.
        var hasNote: Bool

        init(completed: Bool, hasNote: Bool) {
            fill = completed ? .completed : .notCompleted
            self.hasNote = hasNote
        }
    }

    /// The side of a noted day's dot (D5): 4 pt at every cell size, so it reads as a mark on a
    /// 41 pt iPad cell and still leaves most of a 14 pt phone cell's colour showing.
    static let noteDot: CGFloat = 4

    /// The day under `point`, for the grid's one tap gesture (D5: a tap opens History on that
    /// day, at every width). `point` is in the week columns' own space: x = 0 at the first
    /// column's leading edge, y = 0 at the top row, as the columns' stack reports a tap — it
    /// scrolls with them, so the strip's offset never enters. The `spacing` after a cell counts
    /// as that cell, so a tap between two cells still lands on one; nil outside the grid and on
    /// an empty cell (before the twelve weeks, or after today).
    static func day(at point: CGPoint, in columns: [[Date?]], cell: CGFloat) -> Date? {
        guard cell > 0, cell.isFinite, point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0
        else { return nil }
        let pitch = cell + spacing
        let column = Int(point.x / pitch), row = Int(point.y / pitch)
        guard column < columns.count, row < 7, row < columns[column].count else { return nil }
        return columns[column][row]
    }

    /// The grid's days and how many of them `isCompleted` — what its one accessibility element
    /// says ("N of 84 days completed", D5), where per-day detail is History's month grid.
    static func tally(_ columns: [[Date?]], isCompleted: (Date) -> Bool) -> (completed: Int, total: Int) {
        var completed = 0, total = 0
        for column in columns {
            for case let day? in column {
                total += 1
                if isCompleted(day) { completed += 1 }
            }
        }
        return (completed, total)
    }
}
