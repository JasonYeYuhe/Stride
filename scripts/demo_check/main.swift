import Foundation
import SwiftData

// Runs the SHIPPING reconciler against the live App Review demo account and prints what a
// reviewer's device would compute. Built and run by scripts/check_demo_account.sh — it needs
// the network and real data, so it is deliberately not a test target.
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
    try SyncReconciler.apply(response, to: context, isFullPull: true)

    let habits = try context.fetch(FetchDescriptor<Habit>())
    print("after reconcile: \(habits.count) habits")
    var zeroStreak = 0, zeroRate = 0, noHistory = 0, createdToday = 0
    let today = HabitCalendar.dayKey(for: Date())
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
    }
    print("no history: \(noHistory) | zero current streak: \(zeroStreak) | zero 30-day rate: \(zeroRate) | created today: \(createdToday)")

    // Before any exit below, so a failing run doesn't leave a session behind.
    var logout = URLRequest(url: URL(string: "\(base)/v1/auth/logout")!)
    logout.httpMethod = "POST"
    logout.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
    logout.setValue("application/json", forHTTPHeaderField: "Content-Type")
    logout.httpBody = Data("{}".utf8)
    _ = try? await URLSession.shared.data(for: logout)

    if noHistory > 0 || createdToday > 0 {
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
}

try await run()
