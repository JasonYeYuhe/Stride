import Foundation
import SwiftData

// Runs the SHIPPING reconciler against the live App Review demo account and prints what a
// reviewer's device would compute. Built and run by scripts/check_demo_account.sh — it needs
// the network and real data, so it is deliberately not a test target.
//
// Per habit: records, streak, best, 30-day rate and created (unchanged since 1.3), then
// strength 0–100, its Δ30 in points, the completed days of the last 30 and the top 3 runs.
// Exit codes: 1 no token or sign-in, 2 a broken account, 3 stale (every streak 0), 4 a habit
// done on at least 25 of the last 30 days scoring below 0.75 (RELEASE-1.4.1.md gate 2).
@MainActor
func run() async throws {
    guard let token = ProcessInfo.processInfo.environment["DEMO_TOKEN"] else {
        print("DEMO_TOKEN missing"); exit(1)
    }
    let base = "https://stride-api.colorarchive.me"
    var verify = URLRequest(url: URL(string: "\(base)/v1/auth/verify")!)
    verify.httpMethod = "POST"
    verify.setValue("application/json", forHTTPHeaderField: "Content-Type")
    verify.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
    let (vData, _) = try await URLSession.shared.data(for: verify)
    guard let session = (try JSONSerialization.jsonObject(with: vData) as? [String: Any])?["sessionToken"] as? String else {
        print("verify failed — is the demo token still valid?"); exit(1)
    }

    var pull = URLRequest(url: URL(string: "\(base)/v1/sync/pull")!)
    pull.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
    let (pData, _) = try await URLSession.shared.data(for: pull)
    let response = try JSONDecoder().decode(SyncPullResponse.self, from: pData)
    print("pulled: \(response.habits.count) habits, \(response.entries.count) entries")

    let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let context = container.mainContext
    // The 1.3.1 reconciler validates a full pull and reports what it would not apply. No
    // recovery log: the store starts empty, so its deletion pass has nothing to take.
    let report = try SyncReconciler.apply(response, to: context, isFullPull: true)

    let habits = try context.fetch(FetchDescriptor<Habit>())
    print("after reconcile: \(habits.count) habits (applied \(report.applied.habits) habits, \(report.applied.entries) entries, \(report.applied.groups) groups)")
    // A row the reconciler rejects (bad id, missing habit, two entries on one day, a date it
    // cannot parse) never reaches a reviewer's screen. Missing or mismatched `totals` only skip
    // the deletion pass, which cannot matter to an empty store — reported, not failed.
    let rowIssues = report.issues.filter { $0.reason != .totalsMissing && $0.reason != .totalsMismatch }
    for issue in report.issues {
        print("  issue: \(issue.reason.rawValue) \(issue.kind?.rawValue ?? "-") \(issue.id ?? "-")")
    }
    var zeroStreak = 0, zeroRate = 0, noHistory = 0, createdToday = 0
    let today = HabitCalendar.dayKey(for: Date())
    // Strength (RELEASE-1.4.1.md gate 2): one HabitStats per habit, from one fetch of live ids,
    // in this machine's zone (the script runs in the default zone and under
    // TZ=America/Los_Angeles).
    let live = HabitStats.liveRecordIDs(of: habits, in: context)
    var weak: [String] = []
    for habit in habits.sorted(by: { $0.name < $1.name }) {
        let streak = habit.currentStreak()
        let rate = Int(habit.completionRate() * 100)
        let best = habit.bestStreak()
        if streak == 0 { zeroStreak += 1 }
        if rate == 0 { zeroRate += 1 }
        if habit.records.isEmpty { noHistory += 1 }
        if HabitCalendar.dayKey(for: habit.createdAt) == today { createdToday += 1 }
        let created = ISO8601DateFormatter().string(from: habit.createdAt).prefix(10)
        print(String(format: "  %-20@ records=%3d streak=%2d best=%2d rate=%3d%% created=%@",
                     habit.name as NSString, habit.records.count, streak, best, rate, String(created)))

        let stats = HabitStats(habit: habit, liveRecordIDs: live)
        let monthAgo = HabitCalendar.utc.date(byAdding: .day, value: -29, to: stats.today) ?? stats.today
        let doneIn30 = stats.completedDayCount(from: monthAgo, to: stats.today)
        let unit = habit.schedule == .timesPerWeek ? "w" : "d"
        let top3 = stats.bestStreakRanges.prefix(3).map { run in
            let from = HabitCalendar.dayStringFormatter.string(from: run.start)
            let to = HabitCalendar.dayStringFormatter.string(from: run.end)
            return "\(from)..\(to) \(run.length)\(unit)\(run.isCurrent ? " (current)" : "")"
        }
        print(String(format: "  %-20@ strength=%3d (%.3f) Δ30=%+5.1f done30=%2d top3: %@",
                     "" as NSString, HabitScore.displayValue(stats.strength), stats.strength,
                     stats.strengthDelta30 * 100, doneIn30,
                     (top3.isEmpty ? "none" : top3.joined(separator: ", ")) as NSString))
        if doneIn30 >= 25 && stats.strength < 0.75 { weak.append(habit.name) }
    }
    print("no history: \(noHistory) | zero current streak: \(zeroStreak) | zero 30-day rate: \(zeroRate) | created today: \(createdToday) | rejected rows: \(rowIssues.count)")

    // Before any exit below, so a failing run doesn't leave a session behind.
    var logout = URLRequest(url: URL(string: "\(base)/v1/auth/logout")!)
    logout.httpMethod = "POST"
    logout.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
    logout.setValue("application/json", forHTTPHeaderField: "Content-Type")
    logout.httpBody = Data("{}".utf8)
    _ = try? await URLSession.shared.data(for: logout)

    if noHistory > 0 || createdToday > 0 || !rowIssues.isEmpty {
        print("FAIL: a reviewer would see a broken demo account (re-seed, or check the sync fixes)")
        exit(2)
    }
    if zeroStreak == habits.count, let latest = habits.flatMap(\.records).map(\.date).max() {
        // Seed data is generated relative to seed time and goes stale in days.
        let age = Calendar.current.dateComponents([.day], from: latest, to: Date()).day ?? 0
        print("STALE: every streak is 0 and the newest check-in is \(age) days old — re-seed before submitting:")
        print("  ssh … 'sudo bash -c \"cd /root/stride-server && node seed-demo.js\"'")
        exit(3)
    }
    if !weak.isEmpty {
        // Gate 2: a habit done on 25 or more of the last 30 days must read as strong.
        print("FAIL: strength below 75 on a habit done on at least 25 of the last 30 days: \(weak.joined(separator: ", "))")
        exit(4)
    }
}

try await run()
