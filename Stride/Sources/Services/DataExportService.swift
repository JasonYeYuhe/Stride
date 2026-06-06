import Foundation

struct DataExportService {

    // Completion dates are day-keys (UTC-anchored) — format them in UTC so the
    // exported yyyy-MM-dd matches what the app shows. createdAt / exportDate are
    // wall-clock instants, so they use the local-zone formatter below.
    private static let dateFormatter: DateFormatter = HabitCalendar.dayStringFormatter

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - CSV Export

    static func exportCSV(habits: [Habit]) -> String {
        AnalyticsService.shared.send("exportPerformed", metadata: ["format": "csv"])
        var lines = ["habit_name,emoji,date,note,created_at"]

        let rows: [(name: String, emoji: String, date: Date, note: String?, createdAt: Date)] = habits.flatMap { habit in
            habit.records.map { record in
                (name: habit.name, emoji: habit.emoji, date: record.date, note: record.note, createdAt: habit.createdAt)
            }
        }

        let sorted = rows.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.date < $1.date
        }

        for row in sorted {
            let name = csvEscape(row.name)
            let emoji = csvEscape(row.emoji)
            let date = dateFormatter.string(from: row.date)
            let note = csvEscape(row.note ?? "")
            let createdAt = localDayFormatter.string(from: row.createdAt)
            lines.append("\(name),\(emoji),\(date),\(note),\(createdAt)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Export

    static func exportJSON(habits: [Habit]) -> String {
        AnalyticsService.shared.send("exportPerformed", metadata: ["format": "json"])
        let sortedHabits = habits.sorted { $0.name < $1.name }

        let habitDicts: [[String: Any]] = sortedHabits.map { habit in
            let completions: [[String: Any]] = habit.records
                .sorted { $0.date < $1.date }
                .map { record in
                    var entry: [String: Any] = ["date": dateFormatter.string(from: record.date)]
                    if let note = record.note, !note.isEmpty {
                        entry["note"] = note
                    }
                    return entry
                }

            return [
                "name": habit.name,
                "emoji": habit.emoji,
                "color": habit.colorHex,
                "createdAt": localDayFormatter.string(from: habit.createdAt),
                "isArchived": habit.isArchived,
                "completions": completions
            ] as [String: Any]
        }

        let exportDict: [String: Any] = [
            "exportDate": localDayFormatter.string(from: Date()),
            "habits": habitDicts
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: exportDict, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return jsonString
    }

    // MARK: - Helpers

    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
