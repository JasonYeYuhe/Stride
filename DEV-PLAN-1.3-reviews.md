# DEV-PLAN-1.3 — external reviews (raw)

Both produced with `agy --model <id> --print=<prompt>` on 2026-09-24 against the first draft of DEV-PLAN-1.3.md; what was adopted or rejected is in the plan's Review log.

## Gemini 3.1 Pro (gemini-3.1-pro-high)

Here is the review of the 1.3.x–1.4.x Stride development plan.

### 1. Ordering
*   **Move Lossless Export to M2 formally:** The M2 text states export must be pulled forward so users have a backup before the sync engine changes, but the table and M4 scope still list it in M4. Move it to M2 and remove it from M4 entirely.
*   **Swap M4 and M3:** The iPad and macOS structural UI rewrites (M4) must happen *before* the massive M3 stats/history rewrite. Building complex new Pro cards, history views, and stat UI into the old shell only to rewrite the shell's core tab/sidebar navigation immediately after creates double work. 

### 2. Effort Honesty
*   **M2 (3.5 weeks) is a fantasy:** Building a custom chunked sync engine, a mixed-fleet reconciler, cursor management, and Universal Links is a 6-to-8-week minimum project for one developer. Edge cases (clock skew, background execution termination, SQLite locking) will destroy this estimate.
*   **M3 (4 weeks) is a lie:** You are scheduling a new EMA-based scoring algorithm, a custom caching layer tied to SwiftData lifecycle events, editable history UI, Pro cards, and StoreKit outcome handling. This is easily another 6 weeks of work. 
*   **M0 (2.5 weeks):** Retrofitting tests onto legacy, tightly-coupled singletons (`StoreService`, `SyncService`) is notoriously slow. You will spend more time mocking dependencies than writing tests.

### 3. Risk
*   **M4 Notification Crash:** Calling `markDone` on `SharedModelContainer.mainContext` from `UNUserNotificationCenterDelegate` is a guaranteed crash. The notification delegate fires in the background (not the main actor). You must use a background `ModelContext`.
*   **M3 UI Lockups:** Dropping the stats cache on *every* `ModelContext.didSave` is a disaster. When M2's background sync starts applying chunks of remote records, it will trigger constant `didSave` events. The UI will thrash and freeze if the user has the app open during a sync.
*   **M0 CI/Release Mismatch:** Building CI on Xcode 16 and shipping on a different version ("Xcode 27") invalidates the entire purpose of CI. If CI passes, you have zero guarantee the release build won't contain a compiler bug or SDK regression.

### 4. Scope
*   **Cut entirely (M2):** Universal Links for authentication. AASA files have unpredictable caching delays, and many email clients (like Gmail) proxy web links, breaking the deep link flow entirely. Stick to a standard custom URL scheme (`stride://`) with the copy-paste fallback.
*   **Cut entirely (M3):** The custom `didSave` stats cache. Cache invalidation is incredibly brittle. Instead, persist the computed `HabitStats` directly into the database schema and update them incrementally on check-in, or rely on lightweight SwiftData `@Query` optimizations.
*   **Missing (M2):** A "poison pill" guard for chunking. If chunk 2 contains a malformed row that consistently triggers a 500 error from the server, "stop at the first failure" guarantees that user's sync is permanently wedged.
*   **Missing (M4):** A background sync trigger. Completing a habit via a notification action updates local data, but without a background task trigger, that entry won't sync until the user manually foregrounds the app days later.

### 5. Acceptance Criteria
*   **Untestable (M0):** "green again a week later without anyone re-seeding" cannot gate a PR. You cannot block a branch for a week waiting for a cron job to fire.
*   **Untestable (M3):** "Today's body under ~16 ms... in Instruments" is a manual profiling step. It will be skipped. Replace this with an `XCTest` `measure` block on a synthesized 10-habit × 730-day store.
*   **Too weak (M2):** The mixed-fleet check tests a single tap. It must test a 1.2.3 snapshot payload hitting the server at the exact same millisecond as a 1.3.1 incremental payload to prove the LWW reconciler actually survives a race condition.

### 6. The Sync Design (Incremental Push)
*   **The Kill Switch DDoS:** When the server is overwhelmed, flipping the kill switch returns `409 snapshot_required`. The client responds by marking ALL rows dirty. You are telling 10,000 clients to immediately chunk and upload their entire database (up to 5,000 entries per request). This is a self-inflicted DDoS that will obliterate your server.
*   **The Legacy Resurrection Bug:** You increased tombstone retention to 365 days. A 1.2.3 client (which has no 409 handler) will pull with `since=400 days`. The server will *not* return tombstones from days 365–400 because they were physically deleted. The 1.2.3 client will fail to delete those rows locally, and will re-upload (resurrect) them on its next snapshot push.
*   **The Full-Pull Deletion Flaw:** "A row absent from a full pull is deleted locally unless it has never been acknowledged." If a client goes offline, edits an *already acknowledged* row, and then its cursor expires, a full pull will delete its offline edit if the server no longer has that row. 

### 7. Contradictions
*   **Snapshot Code Paths:** M0 requires the client to send an optional body field `mode: 'incremental' | 'snapshot'`. However, M2 claims a snapshot is just "everything dirty: one code path". If the client chunks "everything dirty" into 5 requests, it conceptually doesn't know it's a "snapshot" and cannot accurately send the `mode` parameter.
*   **Export Scheduling:** The plan explicitly says to pull M4's export forward to M2, but leaves it fully scheduled in M4.
*   **No Nag Rule:** M4 flirts with a "fourth notification class... Sunday-evening nudge", which violates the "no unprompted UI/nags" constraint, even though it is deferred.

---

### The 10 Most Important Changes to Make

1. **Fix the Kill Switch DDoS:** Change the server's `409 snapshot_required` to trigger a client-side exponential backoff or maintenance mode, not a massive snapshot upload.
2. **Prevent Legacy Resurrection:** Do not delete server tombstones until the <=1.2.3 cohort is fully retired (the 426 floor), otherwise old clients will resurrect dead rows when they pull beyond the retention window.
3. **Fix the Notification Crash:** Update M4 to explicitly use a background `ModelContext` for `markDone` instead of `mainContext`.
4. **Reorder M4 before M3:** Do the iPad/Mac shell structural polish before building the massive stats UI to avoid doing the layout work twice.
5. **Add a Sync Poison Pill Guard:** Modify M2 chunking to skip and report chunks that fail consecutively, rather than stopping sync entirely and wedging the client.
6. **Move Lossless Export to M2:** Officially remove it from M4 and schedule it in M2 so users hold valid backups before the new sync engine activates.
7. **Redesign Stats Invalidation:** Remove the `didSave` cache drop in M3; either persist stats in SwiftData or decouple the cache invalidation from background network sync operations.
8. **Drop Universal Links:** Remove AASA and associated domains from M2. Use `stride://` to save time and eliminate email proxy bugs.
9. **Align CI and Release Environments:** Force CI to use the exact same Xcode version used for App Store submission in M0. 
10. **Automate Performance Testing:** Replace the M3 manual Instruments check with an `XCTest` `measure` block on a massive synthesized store to catch regressions in CI.


## Gemini 3.8 Flash (gemini-3.8-flash-high)

### 1. Ordering: What Should Move and Why

* **Move Lossless Export (and a basic disaster-recovery Import) into M1 immediately.**
  The plan admits in M2 that an export is needed before touching sync, yet leaves full export in M4. If M2’s lightweight SwiftData migration or reconciler corrupts data, an export feature shipped *in* M2 is too late for users already running 1.3.0. Ship JSON export in M1 so users have an escape hatch before their database schema and sync protocol change.
* **Decouple Universal Links from M2; move them to M1.**
  M2 is an overloaded, high-risk distributed systems milestone (schema migration, chunking, tombstone logic, reconciler). Bundling Apple App Site Association (AASA), domain entitlements, Apple CDN edge caching, and link routing into M2 conflates auth risk with sync engine debugging. Universal Links require zero database changes—ship them in M1.
* **The "M0 Soak Period" is an illusion.**
  M0 ships server support for incremental sync to "soak" during M1. But M1 clients (1.3.0) do **not** use incremental push or parse `skipped` responses; they still push full snapshots. The only code soaking in M0 is tombstone retention and sliding sessions. You are not de-risking the new sync protocol before M2.
* **Pull Skip / Pause Days out of the backlog into M3; push the Weekly Review (M5) out.**
  From a product perspective, the #1 reason habit tracker users churn is broken streaks caused by illness or travel. M3 spends 4 weeks inventing a custom EMA decay score to make streak breaks feel softer, while deferring the actual user request (pause/skip days) to an unscheduled future release. Swap them.

---

### 2. Effort Honesty: Underestimated Work

This plan claims 17.5 developer-weeks (~4.5 months) for a solo developer. For a solo engineer maintaining production, running release mechanics, and handling customer support, this is off by at least **40–50%**.

* **M0: Underestimated by ~1 week (Realistic: 3.5 weeks).**
  Setting up a hosted test target (`StrideAppTests`) on CI, wiring StoreKit configuration schemes, debugging device-vs-simulator build destinations in GitHub Actions, writing on-host backup drills, and adjusting database constraints across edge cases is not a 2.5-week side task.
* **M1: Underestimated by ~1.5 weeks (Realistic: 4 weeks).**
  Refactoring 8–10 pt fixed typography to Dynamic Type across custom heatmaps, weekday grids, and legend swatches using `@ScaledMetric` without breaking horizontal layout boundaries on smaller devices (iPhone SE) is notoriously tedious. Pair that with pluralization across 6 languages in `stringsdict` and custom timeline rollover logic on widgets.
* **M2: Severely underestimated by ~2–3 weeks (Realistic: 5.5–6 weeks).**
  Rewriting a sync engine to support chunked push, per-chunk acknowledgement, bidirectional conflict resolution, cursor expiration, and two-device integration tests is the hardest software problem in the entire plan. In SwiftData, lightweight schema additions (`syncedAt: Date?`) frequently trigger runtime faults or migration crashes if context saves occur during sync transactions.
* **M3: Underestimated by ~1.5 weeks (Realistic: 5.5 weeks).**
  The plan calls for derive-on-read stats memoisation invalidated on [`ModelContext.didSave`](file:///Shared/HabitStats.swift). SwiftData’s save notifications fire across arbitrary threads; thread-safe cache invalidation without causing UI stutter or race conditions on iOS 17 is difficult. Add interactive heatmap check-ins, sheet presentations, and StoreKit transaction listeners.
* **M4 & M5: Underestimated by ~2 weeks combined.**
  Restructuring SwiftUI navigation hierarchy on iPad/Mac to preserve tab state (`TabView`/`ZStack` opacity hacks) always introduces state lifecycle bugs (e.g., toolbar item duplication, sheet dismiss failures). Background notification execution (`UNUserNotificationCenterDelegate`) waking up a cold SwiftData container is prone to SQLite database locks.

---

### 3. Risk: Failure Modes and Missing Mitigations

* **M0: CI hosted test target fails to execute.**
  * *Failure Mode:* The plan specifies building for `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO` to avoid downloading simulator runtimes. However, **hosted unit tests (`TEST_HOST = Stride.app`) cannot execute on generic destinations**. They compile, but they cannot run without an active simulator runtime or attached physical device.
  * *Missing Mitigation:* Keep unit logic strictly decoupled in `Shared/` using the host-less `StrideTests` target compiling against macOS, or budget the CI runner cache to download and maintain an iOS Simulator runtime.
* **M1: Dynamic Type destroys Heatmap geometry.**
  * *Failure Mode:* Scaling 84 heatmap cells using `@ScaledMetric` at accessibility sizes (`accessibility-XXXL`) will push content off-screen horizontally or cause clipping, as an iPhone screen has fixed physical width.
  * *Missing Mitigation:* Add an explicit layout breakpoint: at accessibility sizes, collapse the 84-day 2D grid into a vertically scrolling list or a 7-day compact summary.
* **M2: SwiftData migration crash on launch.**
  * *Failure Mode:* Adding `syncedAt: Date?` relies on SwiftData lightweight migration. If a user on 1.2.3 has uncommitted transactions or slight metadata variations, the container initialization crashes with unrecoverable `SwiftDataCore` schema mismatch errors.
  * *Missing Mitigation:* CI must include an automated migration test: extract a real populated SQLite store from a 1.2.3 device build and assert that the 1.3.1 [`SharedModelContainer`](file:///Shared/SharedModelContainer.swift) opens and reads it cleanly.
* **M3: Stats cache invalidation O(N) bottleneck.**
  * *Failure Mode:* The plan keys the cache on `(habit.id, records.count, max records.updatedAt)`. Computing `max(records.updatedAt)` requires loading and traversing **all** records of a habit on every single check. This completely defeats the cache.
  * *Missing Mitigation:* Add a denormalized `lastRecordUpdatedAt: Date?` directly to `Habit`, updated only when a record is inserted, touched, or deleted.
* **M4: Background notification crash due to Data Protection.**
  * *Failure Mode:* Marking a habit "Done" from a background notification action when the phone is locked will fail or crash if the underlying SQLite database file has default iOS file protection (`NSFileProtectionComplete`), preventing background writes while locked.
  * *Missing Mitigation:* Set explicit database file protection to `NSFileProtectionCompleteUntilFirstUserAuthentication`.
* **M5: At-risk habit logic breaks around midnight/DST.**
  * *Failure Mode:* The hardcoded `after 18:00 local` check for daily habits causes notification spam or false "at-risk" status for night-shift users or across DST boundaries.
  * *Missing Mitigation:* Let users define their "day end" boundary or rely strictly on relative day progression.

---

### 4. Scope: What to Cut and What is Missing

#### What to Cut Entirely
1. **The Reflection/Mirror Source-Scanning Localization Test (`LocalizationSourceScanTests`).**
   Parsing Swift files via `#filePath` and using `Mirror` on `LocalizedStringKey` is brittle engineering theater. It breaks on string interpolation, variables, and multiline declarations. Use standard Xcode string catalogs (`.xcstrings`) or established linters (`SwiftLint` custom rules).
2. **The Complex EMA Square-Root Frequency Formula (`m = 0.5^(√freq / 13)`).**
   Deriving custom non-linear exponential moving averages is academic over-engineering for an indie habit tracker. Users do not understand non-linear decay; they understand rolling completion rates (e.g., 30-day percentage). Keep it simple, explainable, and cheap to compute.
3. **M5 Weekly Review Rebuild.**
   Weekly Review is a low-frequency, secondary surface behind a paywall. Polishing week-navigation rings and delta chips for two weeks while core daily interactions (like skip days) remain absent is misallocated effort.

#### What is Missing
1. **Disaster Recovery Import.**
   Export without import is only half a backup. If a user follows the advice to "export JSON before the sync update" and M2 corrupts their store, they have no way to restore that JSON file into Stride. A simple `importJSON` parser is mandatory.
2. **Skip / Pause / Sick Days.**
   This is the most requested feature across every habit app in the research survey. Forcing users to mark habits as failed when they are sick or on vacation directly punishes user engagement.
3. **App Intents / Desktop Widgets for macOS 14.**
   M1 adds Large Widgets, but Mac widgets on Sonoma require specific desktop container and tinted rendering adjustments to avoid looking broken.

---

### 5. Acceptance Criteria: Untestable or Weak Criteria

* **M1, Criterion 6: Clock-advancement testing for widget rollover.**
  * *Flaw:* Advancing the system clock on an iOS simulator does not reliably trigger WidgetKit timeline refreshes. The system throttles timeline reloads to conserve battery, and `.after(midnight + 1 h)` is a recommendation to the OS, not a guarantee.
  * *Fix:* Inject a `DateProvider` dependency into [`Shared/WidgetTimelinePlan.swift`](file:///Shared/WidgetTimelinePlan.swift) and test the generated timeline entries deterministically in unit tests.
* **M1, Criterion 7: Pixel-identical screenshot diffs after Dynamic Type changes.**
  * *Flaw:* *"Store screenshots at default text size are pixel-identical before/after the Dynamic Type change"*. Swapping hardcoded font points to `.caption2` or `@ScaledMetric` alters baseline alignment and text rendering sub-pixel bounds. This test will almost certainly fail.
  * *Fix:* Use perceptual image hashing with a defined tolerance threshold (e.g., ≥99% structural similarity index).
* **M3, Criterion 4: Instruments render timing assertion.**
  * *Flaw:* *"A 10-habit × 730-day store keeps Today's body under ~16 ms and Stats under ~50 ms in Instruments."* This cannot run in CI and is uncalibrated (a development M3 Max Mac will pass; an iPhone 11 will fail).
  * *Fix:* Define hardware-specific automated performance tests (`measure(metrics: [XCTCPUMetric(), XCTClockMetric()])`) targeting a specific simulator model in CI.
* **M4, Criterion 3: "Widget shows the habit checked within 5 s" from notification.**
  * *Flaw:* SpringBoard aggressively throttles `WidgetCenter.shared.reloadAllTimelines()` when invoked from background processes. 5-second latency cannot be guaranteed by any third-party app.
  * *Fix:* Assert that [`HabitCheckIn.markDone`](file:///Shared/HabitCheckIn.swift) wrote to the database and that `reloadTimelines` was dispatched, rather than asserting on SpringBoard's render latency.
* **M4, Criterion 4: Export round-trips through parser test.**
  * *Flaw:* Testing that an exported JSON can be decoded by a unit test does not verify that all entity relationships are preserved. Because [`HabitRecord`](file:///Shared/HabitRecord.swift) has no explicit `habitId` foreign key and relies on SwiftData relationships, decoding without checking child-parent linkage will mask data loss.
  * *Fix:* Assert that importing the exported JSON into a blank context results in identical graph traversal counts across all relationships.

---

### 6. The Sync Design: Vulnerabilities and Edge Cases

#### 1. Race Conditions During Chunked Push
* **In-Flight Record Mutation:** Chunk 1 sends dirty entries `1...2000`. While the HTTP request is in flight, the user edits entry `1500`. Chunk 1 returns `200 OK`. The client rule states: *"acknowledge per chunk — only rows whose updatedAt still equals what was sent"*. This correctly prevents entry `1500` from being marked clean.
* **Parent-Child Splitting:** The plan sends dirty habits in Chunk 1 and entries across Chunks 1 and 2+. If Chunk 1 succeeds but Chunk 2 fails, the server has new habits without their historical records. If another device pulls immediately, it pulls an empty habit. Ensure the reconciler on peer devices handles partially populated relationship graphs without resetting streak calculations.

#### 2. Re-login and Account Switching (Severe Data Leak)
* The plan states: *"`resetSyncState(context:)` sets `syncedAt = nil` on every row (called from `logout` / `deleteAccount`) so the next account signed in gets a full upload."*
* **Fatal Flaw:** If User A logs out and User B logs in on the same device, setting `syncedAt = nil` on existing local rows means **User A’s habits and check-in history will be uploaded into User B’s server account**.
* **Fix:** `logout` and `deleteAccount` must **wipe all local SwiftData records clean**, not just reset `syncedAt`.

#### 3. Chunking & Payload Size Bounds
* Chunk 1 includes *"deletions + all dirty groups + dirty habits + the first ≤ 2,000 entries"*.
* If an account has 600 dirty habits (e.g., imported or bulk modified), Chunk 1 will violate M0's server limit: *"explicit array caps (500 habits... → 400 with a message)"*. The client will receive an unhandled 400 Bad Request and sync will permanently halt.
* **Fix:** Chunk habits and groups against server caps just like entries.

#### 4. The Full-Pull Deletion Rule (Catastrophic Deletion Risk)
* The rule states: *"A row absent from a full pull is deleted locally unless it has never been acknowledged (`syncedAt == nil`)."*
* **Fatal Flaw:** What happens if the server returns a partial response, a network proxy truncates the payload, or a database query times out and returns an incomplete array? The client will assume all missing rows were deleted on another device and **permanently purge the user's local database**.
* **Fix:** The server must return a cryptographic digest or total row count header. The client must never execute bulk deletions on a full pull unless the payload checksum and count match the server's declared total.

#### 5. Backwards Compatibility with 1.2.3 Full-Snapshot Clients
* 1.2.3 clients push full snapshots on every sync.
* If a 1.2.3 client pushes an existing habit, does the server touch `updated_at`? The plan says M0: *"full-snapshot push after an incremental push bumps nothing (the mixed-fleet contract)"*.
* **The Catch:** 1.2.3 clients do not have `syncedAt` and frequently round timestamps or omit newer optional fields (e.g. `note` or `kind`). If the server's value-comparison logic detects any discrepancy between a 1.2.3 snapshot row and a 1.3.1 row, it will update `updated_at`. On the next pull, the 1.3.1 client will treat the row as updated, mark it dirty, and re-push. In a mixed-device household, this creates a **continuous sync loop**.

---

### 7. Contradictions in the Plan

1. **Hosted CI Tests vs. Generic Destination:**
   M0 claims CI will run `StrideAppTests` (hosted by `Stride.app`) while using `destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` to avoid downloading simulator runtimes. You cannot execute application-hosted tests on a generic destination; Xcode requires an active simulator or connected physical device.
2. **M0 Server Header Soak vs. M1 Client Deployment:**
   M0 configures `cursor_expired` gating on `X-Stride-Client ≥ 1.3.1` and logs the header. However, M1 is what introduces sending `X-Stride-Client` on the client. M0’s server logic cannot be verified in production by shipped 1.2.3 clients.
3. **Lossless Export Milestone Placement:**
   M2 states: *"pull M4's lossless JSON export forward into this release"*. Yet M4 still lists *"Lossless export v2 (free)"* as one of its primary deliverables. The plan never resolved its own merge conflict.
4. **"No Nags" Rule vs. Unprompted UI:**
   The plan establishes a strict rule: *"No milestone may add a modal, sheet, alert, banner or system prompt that appears without a user action."* Yet M2 adds a Today view re-auth banner row, M3 adds locked Pro placeholder cards with upsell triggers, and M3 introduces a lapsed subscription alert row in Settings.
5. **Cache Invalidation vs. Compute Cost:**
   M3 emphasizes optimizing performance by avoiding record scans on every render. But the chosen cache key (`(habit.id, records.count, max records.updatedAt)`) requires executing an aggregate scan over every record on every render pass just to evaluate whether the cache is valid.

---

### 8. The 10 Most Important Changes to Make (Prioritized)

1. **Purge Local Data on Logout to Prevent Account Data Leaks (M2):**
   Change [`resetSyncState(context:)`](file:///Shared/SyncService.swift) on logout/account deletion to completely wipe all SwiftData entities. Resetting `syncedAt = nil` on a shared device causes the prior user's habits to sync directly into the next signed-in user's account.
2. **Move Lossless Export and an Emergency Import into M1:**
   Do not modify the sync reconciler or schema in M2 without giving users a functional, local backup-and-restore tool. If M2’s sync engine fails in the wild, an export alone cannot restore their habits.
3. **Add Checksum/Count Protection to the Full-Pull Deletion Rule (M2):**
   Never delete local rows absent from a full pull without a server-provided manifest count and hash. A truncated response or gateway timeout must abort the sync, not wipe local user data.
4. **Denormalize `lastRecordUpdatedAt` on Habit to Fix Cache Invalidation (M3):**
   Do not compute `max(records.updatedAt)` across raw records to validate the stats cache. Store `lastRecordUpdatedAt: Date?` directly on [`Habit`](file:///Shared/Habit.swift) and bump it on check-in.
5. **Fix the CI Test Target Architecture (M0):**
   Do not attempt to run hosted tests (`StrideAppTests`) on a `generic/platform=iOS` CI destination. Keep test logic decoupled in `Shared/` using host-less tests on macOS runners, or provision a dedicated macOS runner with an installed iOS Simulator.
6. **Decouple Universal Links from M2 into M1:**
   Ship the AASA file, entitlement, and link routing in M1. Keep M2 focused strictly on SwiftData migration, chunking, conflict resolution, and reconciler correctness.
7. **Replace M3 EMA Decay Math with User-Requested Skip/Vacation Days:**
   Cut the complex `m = 0.5^(√freq / 13)` formula. Provide a simple rolling 30-day completion rate, and implement streak pause/skip functionality to address the single largest cause of user churn.
8. **Fix Database File Protection for Background Notifications (M4):**
   Set the SQLite store's data protection to `NSFileProtectionCompleteUntilFirstUserAuthentication`. Otherwise, background notification actions completed from the lock screen will crash when attempting to write to disk.
9. **Cap Habit and Group Arrays in Client Push Chunking (M2):**
   Update [`SyncPushPlanner`](file:///Shared/SyncPushPlanner.swift) to chunk dirty habits and groups against the server's hard limits (500 habits, 200 groups), preventing bulk modifications from triggering unhandled 400 errors.
10. **Drop the Mirror-Based Source Code Localization Scanner (M1):**
    Replace the hand-rolled XCTest `#filePath` AST scraper with standard Xcode String Catalogs (`.xcstrings`) to avoid maintaining a fragile custom parser that fails on multiline strings and interpolations.
