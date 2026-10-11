import XCTest
import Foundation
import CoreGraphics

/// The Stats heatmap's geometry (`HeatmapLayout`, Shared/HeatmapLayout.swift; RELEASE-1.4.0.md
/// D2): every day under its own weekday letter whichever day the week starts on, through a DST
/// change, and a cell that fills the card at regular width while phones keep theirs.
final class HeatmapLayoutTests: XCTestCase {

    private func calendar(_ zone: String, firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        return c
    }

    private func noon(_ c: Calendar, _ year: Int, _ month: Int, _ day: Int) -> Date {
        c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// The letter drawn beside row `row`, as HeatmapGrid picks it: weekday number
    /// `(firstWeekday - 1 + row) % 7 + 1`.
    private func letterWeekday(row: Int, _ c: Calendar) -> Int {
        (c.firstWeekday - 1 + row) % 7 + 1
    }

    /// The invariants every layout must keep, for any calendar and any today.
    private func assertLayout(_ c: Calendar, today: Date, file: StaticString = #filePath, line: UInt = #line) -> [[Date?]] {
        let days = HeatmapLayout.days(endingOn: today, calendar: c)
        XCTAssertEqual(days.count, 84, file: file, line: line)
        XCTAssertEqual(days.last, c.startOfDay(for: today), "ends today", file: file, line: line)
        for (a, b) in zip(days, days.dropFirst()) {
            XCTAssertEqual(c.dateComponents([.day], from: a, to: b).day, 1, "consecutive days \(a) \(b)", file: file, line: line)
        }
        let columns = HeatmapLayout.columns(of: days, calendar: c)
        XCTAssertTrue(columns.allSatisfy { $0.count == 7 }, file: file, line: line)
        XCTAssertEqual(columns.flatMap { $0 }.compactMap { $0 }, days, "every day once, in order", file: file, line: line)
        for column in columns {
            for (row, day) in column.enumerated() {
                guard let day else { continue }
                XCTAssertEqual(c.component(.weekday, from: day), letterWeekday(row: row, c),
                               "\(day) sits beside the wrong weekday letter", file: file, line: line)
            }
        }
        // Padding only before the first day and after today.
        let flat = columns.flatMap { $0 }
        let first = flat.firstIndex { $0 != nil }!
        let last = flat.lastIndex { $0 != nil }!
        XCTAssertTrue(flat[first...last].allSatisfy { $0 != nil }, "no gap inside the range", file: file, line: line)
        XCTAssertEqual(first, HeatmapLayout.row(of: days[0], calendar: c), "the oldest week is padded at the TOP",
                       file: file, line: line)
        return columns
    }

    // MARK: - Columns

    /// Sunday-first (the US): 84 days ending on a Wednesday start on a Thursday, so the oldest
    /// column holds Thu–Sat at rows 4–6, under their own letters. The old grid stacked them from
    /// the top row: Thursday beside "S".
    func testSundayFirstPadsTheOldestWeekAtTheTop() {
        let c = calendar("America/Chicago", firstWeekday: 1)
        let wednesday = noon(c, 2026, 7, 15)
        XCTAssertEqual(c.component(.weekday, from: wednesday), 4)
        let columns = assertLayout(c, today: wednesday)

        XCTAssertEqual(columns.count, 13)
        XCTAssertEqual(columns[0].prefix(4).compactMap { $0 }.count, 0, "Sun–Wed before the range are empty")
        XCTAssertEqual(columns[0].compactMap { $0 }.map { c.component(.weekday, from: $0) }, [5, 6, 7])
        XCTAssertEqual(columns[12].compactMap { $0 }.count, 4, "this week: Sun–Wed")
        XCTAssertEqual(columns[12][3], c.startOfDay(for: wednesday))
        XCTAssertNil(columns[12][4], "tomorrow is empty")
    }

    /// Monday-first (most of Europe, Japan's ISO users): the same days, rows shifted by one, each
    /// still under its own letter.
    func testMondayFirstKeepsEveryDayUnderItsLetter() {
        let c = calendar("Europe/Berlin", firstWeekday: 2)
        let wednesday = noon(c, 2026, 7, 15)
        let columns = assertLayout(c, today: wednesday)

        XCTAssertEqual(columns.count, 13)
        XCTAssertEqual(HeatmapLayout.row(of: wednesday, calendar: c), 2)
        XCTAssertEqual(columns[0].prefix(3).compactMap { $0 }.count, 0, "Mon–Wed before the range are empty")
        XCTAssertEqual(columns[12].compactMap { $0 }.count, 3, "this week: Mon–Wed")
    }

    /// Every today of a fortnight, both week starts: the invariants hold every day, and the one
    /// day in seven when the range starts on the first day of a week has 12 full columns.
    func testEveryDayOfTheWeekBothWeekStarts() {
        for firstWeekday in [1, 2] {
            let c = calendar("Asia/Tokyo", firstWeekday: firstWeekday)
            var twelve = 0
            for offset in 0..<14 {
                let today = c.date(byAdding: .day, value: offset, to: noon(c, 2026, 9, 1))!
                let columns = assertLayout(c, today: today)
                if columns.count == 12 {
                    twelve += 1
                    XCTAssertEqual(HeatmapLayout.row(of: today, calendar: c), 6, "12 columns only when today ends a week")
                    XCTAssertTrue(columns.allSatisfy { $0.allSatisfy { $0 != nil } })
                } else {
                    XCTAssertEqual(columns.count, 13)
                }
            }
            XCTAssertEqual(twelve, 2, "once a week, firstWeekday \(firstWeekday)")
        }
    }

    /// A DST week each way (New York: 8 March 2026 springs forward, 1 November falls back): the
    /// 23- and 25-hour days appear once each, consecutive, under their own letters.
    func testDSTWeeks() {
        let c = calendar("America/New_York", firstWeekday: 1)
        for today in [noon(c, 2026, 3, 12), noon(c, 2026, 11, 4)] {
            let days = HeatmapLayout.days(endingOn: today, calendar: c)
            let lengths = Set(zip(days, days.dropFirst()).map { $1.timeIntervalSince($0) / 3_600 })
            XCTAssertTrue(lengths.contains(23) || lengths.contains(25), "the range crosses a DST change: \(lengths)")
            _ = assertLayout(c, today: today)
        }
    }

    // MARK: - The cell

    /// At the 680 pt content cap the card's inner width is 616 pt: 41 pt cells, a 613 pt grid —
    /// at least 93 % of the card (acceptance (1), "the heatmap fills its card"; the first draft's
    /// 28 pt clamp filled 70 %).
    func testRegularWidthFillsTheCard() {
        let cell = HeatmapLayout.cellSize(scaled: 14, availableWidth: 616, regular: true)
        XCTAssertEqual(cell, 41)
        XCTAssertEqual(HeatmapLayout.gridWidth(cell: cell), 613)
        XCTAssertGreaterThanOrEqual(HeatmapLayout.gridWidth(cell: cell), 0.93 * 616)
        XCTAssertLessThanOrEqual(HeatmapLayout.gridWidth(cell: cell), 616, "and never wider than the card")
        XCTAssertEqual(HeatmapLayout.gridWidth(cell: 14), 14 * 14 + 39)
    }

    /// Compact width keeps the `@ScaledMetric` cell exactly, at every text size: phones unchanged.
    func testCompactIsTheScaledCell() {
        for scaled in [CGFloat(14), 17.5, 30, 50] {
            for width in [CGFloat(300), 616, 2_000] {
                XCTAssertEqual(HeatmapLayout.cellSize(scaled: scaled, availableWidth: width, regular: false), scaled)
            }
        }
    }

    /// Regular width never goes below the text-size cell (a narrow window, the accessibility
    /// strip) nor grows a width-derived cell past 44 pt; a width not yet measured is ignored.
    func testRegularWidthBounds() {
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: 300, regular: true), 18)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: 100, regular: true), 14)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: 0, regular: true), 14)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: 2_000, regular: true), 44)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 31, availableWidth: 616, regular: true), 41)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 50, availableWidth: 616, regular: true), 50, "never below scaled")
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: .infinity, regular: true), 14)
        XCTAssertEqual(HeatmapLayout.cellSize(scaled: 14, availableWidth: .nan, regular: true), 14)
    }
}
