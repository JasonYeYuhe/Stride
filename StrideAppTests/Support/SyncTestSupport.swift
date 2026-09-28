import Foundation
@testable import Stride

/// Who SyncService thinks is signed in, set by the test. The session carries the token every
/// sync request of a run must use (the gate captures it), so a test can switch accounts between
/// two chunks by assigning `session`. Tests that need the real sign-in path pass an AuthService
/// instead.
@MainActor
final class FakeSyncSessions: SyncSessionSource {
    var session: SyncSession?

    init(_ session: SyncSession?) { self.session = session }

    func currentSyncSession() -> SyncSession? { session }
    func resolveSyncSession() async -> SyncSession? { session }
}

extension SyncSession {
    static let accountA = SyncSession(token: "tok-123", account: SyncAccount(id: "7", email: "a@example.com"))
    static let accountB = SyncSession(token: "tok-B", account: SyncAccount(id: "8", email: "b@example.com"))
}

/// Pull bodies as server/routes/sync.js sends them, `totals` included (a full pull without
/// them is not validated, and its deletion pass is skipped).
enum SyncStubBodies {
    static func pull(serverTime: String = "2026-09-26T10:00:00.000Z",
                     habits: [String] = [], deletedHabitIds: [String] = []) -> String {
        #"""
        {"habits":[\#(habits.joined(separator: ","))],"entries":[],"groups":[],
         "deletedHabitIds":[\#(deletedHabitIds.map { "\"\($0)\"" }.joined(separator: ","))],
         "deletedEntryIds":[],"deletedGroupIds":[],"serverTime":"\#(serverTime)",
         "totals":{"habits":\#(habits.count),"entries":0,"groups":0}}
        """#
    }

    /// A habit row as the server serves it to a >= 1.3.1 client: millisecond stamps.
    static func habit(_ habit: Habit, name: String? = nil) -> String {
        #"""
        {"id":"\#(habit.id.uuidString)","name":"\#(name ?? habit.name)","emoji":"\#(habit.emoji)",
         "colorHex":"\#(habit.colorHex)","isArchived":false,"sortOrder":0,
         "createdAt":"\#(SyncTimestamp.millisecondString(from: habit.createdAt))",
         "updatedAt":"\#(SyncTimestamp.millisecondString(from: habit.stamp))"}
        """#
    }

    static let pushOK = #"{"ok":true}"#
}

/// The file recovery log over a directory of its own, so no test writes into the host app's
/// Application Support (SyncService's default is `SyncRecoveryLog.defaultDirectory`).
struct ScratchRecoveryLog {
    let directory: URL
    let log: SyncRecoveryLog

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-recovery-log-\(UUID().uuidString)", isDirectory: true)
        log = SyncRecoveryLog(directory: directory)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
