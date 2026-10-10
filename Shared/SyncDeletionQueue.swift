import Foundation

/// Deletion tombstones waiting to be sent to the server.
///
/// The app queues deletions in `UserDefaults.standard`. The widget and watch toggles run in
/// other processes, so they queue un-checked entries under one key in the app-group
/// defaults instead. A sync reads everything with `pending()` before pushing and trims the
/// queues with `acknowledge(_:)` only once the push has succeeded.
///
/// That ordering is the point of this type. The previous `consumeDeletedIds()` removed every
/// queue BEFORE the push. Any push that threw — offline, timeout, 401, 5xx, cancellation, or
/// the old 10kb body limit — destroyed them for good: the SwiftData objects were already
/// gone, so nothing could rebuild the list, the server never wrote a tombstone, and the
/// deleted habit came back on every other device and on reinstall. An unreliable network
/// made habits undeletable.
///
/// `acknowledge(_:)` removes exactly the ids that were sent rather than clearing the key, so
/// a deletion queued while the push was in flight survives to the next sync. The app-group
/// key is still a read-modify-write across processes — UserDefaults offers nothing atomic —
/// so a widget write landing in the same instant as `acknowledge` can still be lost; this
/// narrows that window, it does not close it.
///
/// From 1.3.1 the push is chunked (`SyncPushPlanner`): the ids are spread over the chunks by
/// encoded size — deleting a multi-year habit queues one entry id per check-in, and the server
/// caps no deletion list, only the 5 MB body — and each chunk's 200 acknowledges only the ids that
/// chunk carried (`SyncPushResolver.resolve`). A failure at chunk k leaves the ids of chunks ≥ k
/// queued for the retry.
struct SyncDeletionQueue {
    struct Batch: Equatable {
        var habits: [String] = []
        var entries: [String] = []
        var groups: [String] = []

        var count: Int { habits.count + entries.count + groups.count }
        var isEmpty: Bool { count == 0 }
    }

    static let habitsKey = "stride_deleted_habit_ids"
    static let entriesKey = "stride_deleted_entry_ids"
    static let groupsKey = "stride_deleted_group_ids"
    /// Written by the widget and watch toggles into the app-group defaults. The value must not
    /// change: ids queued under it by an older widget build still have to be read after upgrade.
    static let sharedEntriesKey = "stride_deleted_entry_ids_widget"

    let local: UserDefaults
    let shared: UserDefaults?

    static var live: SyncDeletionQueue {
        SyncDeletionQueue(
            local: .standard,
            shared: UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        )
    }

    func trackHabit(_ id: String) { append(id, key: Self.habitsKey, in: local) }
    func trackEntry(_ id: String) { append(id, key: Self.entriesKey, in: local) }
    func trackGroup(_ id: String) { append(id, key: Self.groupsKey, in: local) }

    /// For the widget and watch, which run in their own processes: queues into the app-group
    /// defaults, where the app's next sync reads it through `pending()`. (Their own
    /// `UserDefaults.standard` is a different store the app never sees.)
    func trackSharedEntry(_ id: String) {
        guard let shared else { return }
        append(id, key: Self.sharedEntriesKey, in: shared)
    }

    /// Everything queued, without removing anything.
    func pending() -> Batch {
        var entries = local.stringArray(forKey: Self.entriesKey) ?? []
        entries.append(contentsOf: shared?.stringArray(forKey: Self.sharedEntriesKey) ?? [])
        return Batch(
            habits: local.stringArray(forKey: Self.habitsKey) ?? [],
            entries: entries,
            groups: local.stringArray(forKey: Self.groupsKey) ?? []
        )
    }

    /// Call only after the server has accepted `sent`. Removes those ids and nothing else.
    func acknowledge(_ sent: Batch) {
        remove(Set(sent.habits), key: Self.habitsKey, in: local)
        remove(Set(sent.groups), key: Self.groupsKey, in: local)
        let sentEntries = Set(sent.entries)
        remove(sentEntries, key: Self.entriesKey, in: local)
        if let shared { remove(sentEntries, key: Self.sharedEntriesKey, in: shared) }
    }

    /// Forgets every queued id, the widget's included. Only for a device that starts from
    /// another account's data (M2, account isolation): the queue belongs to the account whose
    /// rows were deleted, and sent under another account its ids would be answered for rows that
    /// account never had. Sign-out does NOT clear it — re-login to the same account resumes.
    func clearAll() {
        local.removeObject(forKey: Self.habitsKey)
        local.removeObject(forKey: Self.entriesKey)
        local.removeObject(forKey: Self.groupsKey)
        shared?.removeObject(forKey: Self.sharedEntriesKey)
    }

    private func append(_ id: String, key: String, in defaults: UserDefaults) {
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.append(id)
        defaults.set(ids, forKey: key)
    }

    private func remove(_ ids: Set<String>, key: String, in defaults: UserDefaults) {
        guard !ids.isEmpty, let current = defaults.stringArray(forKey: key) else { return }
        let kept = current.filter { !ids.contains($0) }
        if kept.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(kept, forKey: key)
        }
    }
}
