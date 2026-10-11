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
/// key is still a read-modify-write across processes — UserDefaults offers nothing atomic — so
/// from 1.4.0 every write of it holds an `flock` on a lock file in the App Group container
/// (`sharedLock`), in the app and the widget alike (RELEASE-1.4.0.md D5). Until then the tombstone
/// of a widget un-check landing in the same instant as `acknowledge` could be written over: the
/// server never heard of the un-check, and the day stayed checked on every other device. 1.4.0
/// makes that likelier — the app now also syncs in the background, exactly when a widget tap on
/// the lock screen can land beside it.
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
    /// The file every process `flock`s while it reads, changes and writes `sharedEntriesKey`.
    /// nil: no lock — a queue with no shared defaults, and the tests that do not exercise it.
    let sharedLock: URL?

    init(local: UserDefaults, shared: UserDefaults?, sharedLock: URL? = nil) {
        self.local = local
        self.shared = shared
        self.sharedLock = sharedLock
    }

    /// The App Group's defaults through `SharedModelContainer.appGroupDefaults`, the one accessor
    /// the Mac test variant turns off (`STRIDE_MAC_VARIANT`), so the variant never reaches the
    /// real app's suite through this path either.
    static var live: SyncDeletionQueue {
        let shared = SharedModelContainer.appGroupDefaults
        return SyncDeletionQueue(local: .standard, shared: shared, sharedLock: shared == nil ? nil : sharedLockURL)
    }

    /// Every build of the app and the widget must lock the same file: never rename it.
    static let sharedLockFileName = "\(sharedEntriesKey).lock"

    /// In the App Group container, which every process that writes the key can reach. Without one
    /// (an unsigned simulator build: the "shared" suite is then the app's own), in the app's
    /// Library, beside its Preferences — only that process uses the suite then. Once per process.
    static let sharedLockURL: URL? = {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedModelContainer.appGroupIdentifier) {
            return group.appendingPathComponent(sharedLockFileName)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent(sharedLockFileName)
    }()

    func trackHabit(_ id: String) { append(id, key: Self.habitsKey, in: local) }
    func trackEntry(_ id: String) { append(id, key: Self.entriesKey, in: local) }
    func trackGroup(_ id: String) { append(id, key: Self.groupsKey, in: local) }

    /// For the widget and watch, which run in their own processes: queues into the app-group
    /// defaults, where the app's next sync reads it through `pending()`. (Their own
    /// `UserDefaults.standard` is a different store the app never sees.)
    func trackSharedEntry(_ id: String) {
        guard let shared else { return }
        withSharedLock(shared) { append(id, key: Self.sharedEntriesKey, in: shared) }
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
        if let shared {
            withSharedLock(shared) { remove(sentEntries, key: Self.sharedEntriesKey, in: shared) }
        }
    }

    /// Forgets every queued id, the widget's included. Only for a device that starts from
    /// another account's data (M2, account isolation): the queue belongs to the account whose
    /// rows were deleted, and sent under another account its ids would be answered for rows that
    /// account never had. Sign-out does NOT clear it — re-login to the same account resumes.
    func clearAll() {
        local.removeObject(forKey: Self.habitsKey)
        local.removeObject(forKey: Self.entriesKey)
        local.removeObject(forKey: Self.groupsKey)
        if let shared {
            withSharedLock(shared) { shared.removeObject(forKey: Self.sharedEntriesKey) }
        }
    }

    /// Runs one write of the shared key under an exclusive `flock` on `sharedLock`, held only for
    /// this synchronous call. The other process's read-modify-write waits for it, so neither can
    /// write back a list read before the other's change.
    ///
    /// `synchronize()` before the lock is released: UserDefaults hands a write to cfprefsd
    /// asynchronously, and that call "waits for any pending asynchronous updates" (its own
    /// header) — so the next holder's read, in the other process, finds this write.
    ///
    /// Fails open: if the file cannot be opened or locked, the write goes ahead unlocked, as every
    /// build before 1.4.0 did. A tombstone must never be dropped because of a lock.
    private func withSharedLock(_ shared: UserDefaults, _ write: () -> Void) {
        guard let sharedLock else { return write() }
        let fd = open(sharedLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return write() }
        defer { close(fd) }   // releases the lock too
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { return write() }
        }
        write()
        shared.synchronize()
        flock(fd, LOCK_UN)
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
