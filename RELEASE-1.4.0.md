# Stride v1.4.0 — release record

App ID `6761262334`, bundle `yyh.stride.habittracker`. **In progress**: branch `m3/1.4.0`, cut
from `main` at `f706596` (the 1.3.1 merge), version 1.4.0 (22). This is
[DEV-PLAN-1.3.md](DEV-PLAN-1.3.md) M3: iPad and Mac as real shells, notification actions,
background sync, plus the backlog item "write the export file before presenting the share
sheet". Nothing from this branch has reached a user.

Build 22, not the plan's 20: 1.3.1 used 20 (uploaded, superseded) and shipped 21.

## Where things stood on 2026-10-10

- 1.3.1 (21) approved on both platforms. iOS released by the owner, macOS approved and waiting
  for the owner's release.
- **A shipped macOS bug found while mapping M3.** `StrideMac.entitlements` has the App Sandbox
  and no `com.apple.security.files.user-selected.*` entitlement. Without it, AppKit refuses to
  show an open or save panel in a sandboxed app. So Settings → "Restore from Backup…"
  (`.fileImporter`, SettingsView.swift:715) does nothing on the Mac, in 1.3.0 (live) and 1.3.1.
  - Verified 2026-10-10 with two throwaway ad-hoc-signed sandboxed probe apps (not Stride, no
    Stride data). The app with `files.user-selected.read-only` got the open panel's window, and
    the one without it did not.
  - The fix is the entitlement, `read-write`, which the menu Export below needs too. It ships
    in 1.4.0.
- Codebase map: six parallel readers plus a completeness critic. The design below is built on
  their findings, and every spec claim they contradicted is listed under
  [Spec corrections](#spec-corrections).

## Spec corrections

What DEV-PLAN-1.3.md M3 says that the code or the SDK does not support, and what is done instead:

| Spec | Reality | Decision |
|---|---|---|
| `ContentView.swift :39-72, :105-113` | Stale since M1 (+16 lines). The iPad sidebar is `:55-88` (a VStack of Buttons, not a List) and the `detailView` switch is `:121-129` | Rewritten as a whole (D2) |
| "`List(selection:)` sidebar shared with the macOS `SidebarView`" | SidebarView is macOS-only. Its non-optional `List(selection: Binding<Int>)` is `@available(iOS, unavailable)` | Shared sidebar over `Binding<ShellTab?>`, with rows per platform |
| "hidden-bar `TabView` or `ZStack` with opacity", "the same keep-views-alive fix" on macOS | `.toolbar(.hidden, for: .tabBar)` is unavailable on macOS. `.sidebarAdaptable` needs iOS 18 / macOS 15, above the floors | A lazy ZStack keep-alive on both, with an `isActive` signal (D2) |
| "Add an iPad Pro 13" run to `scripts/screenshots.sh`" | screenshots.sh draws AppKit mock images and drives no simulator | iPad captures through `a11y_sweep.sh --device "iPad Pro 13-inch (M5)"` (D7) |
| `.commands` "beside ⌘N" | No `.commands` exists. ⌘N is a toolbar shortcut, and WindowGroup's File → New Window also claims ⌘N | `CommandGroup(replacing: .newItem)` (D3) |
| `NSApp.dockTile.badgeLabel` | `setBadgeCount` is available on macOS 13+ and respects the user's badge setting | `setBadgeCount` on both platforms (D3) |
| `HabitCheckIn.markDone` on `SharedModelContainer.mainContext` | No such member. The handle is `SharedModelContainer.opened?.mainContext`, nil when the store did not open | Same, with a store-unavailable no-op (D4) |
| Count habits: Done → "Add 1" via `markDone` | `markDone` adds nothing once a count day is complete | "Add 1" uses `tap`, which always adds one unit and never deletes for a count habit (D4) |
| "awaits the save" | `ModelContext.save()` is synchronous | Write and save in one main-actor turn, so a sync's rollback cannot discard the check-in (D4) |
| Set the store's file protection to class C | Already the effective class: no data-protection entitlement (SyncRecoveryLog.swift:450-453). SwiftData has no option for it | Set explicitly on `Stride.store`, `-wal` and `-shm` after the app's open, iOS only. Defensive; documented as such (D5) |
| BGAppRefreshTask "after every check-in from a widget" | The widget's intent runs in the extension, and whether a WidgetKit extension may submit is unverified (the header says "some extensions") | The app submits a refresh when it goes to the background while signed in. A widget check-in made later is covered by that pending request (D5) |
| "reaches the server within the next background refresh", from a force-quit app | iOS does not run BGAppRefreshTask for a force-quit app | The notification action itself starts a bounded sync while the app is awake. Background refresh stays best-effort (D5) |
| The INFOPLIST_KEY_* route for new plist keys | `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` are not on Xcode 27's allowlist and would be dropped silently (the 1.2.0 SentryDSN trap) | A hand-written partial `INFOPLIST_FILE` for the iOS target, plus a product-check assertion (D5) |

## Design decisions

### D1 — Version

1.4.0 (22) on both platforms. MARKETING_VERSION 1.4.0, CURRENT_PROJECT_VERSION 22.

### D2 — The shell (iPad and macOS)

- **`ShellTab`** (`today = 0`, `stats = 1`, `settings = 2`) keeps the `-tab N` contract that
  `a11y_sweep.sh` and the screenshot recipe use.
- **`ShellState`** is `@Observable` and per scene: it is `@State` in ContentView and never a
  singleton, because iPad windows must not mirror each other. It holds:
  - the selection;
  - Today's selected date and anchor;
  - the Stats habit;
  - window-scoped requests: new habit, Weekly Review, export.

  It sits above the size-class branch. A Pro Max rotation, iPad Split View or Stage Manager
  resize that crosses compact↔regular therefore keeps the date and the habit. Scroll position
  survives only within a branch.
- **Sidebar.** One `SidebarView` is used by both platforms:
  - `List(selection: Binding<ShellTab?>)`;
  - rows Today and Statistics, plus Settings on iOS only.

  macOS Settings is the ⌘, scene alone. `-tab 2` on the Mac selects Today and opens Settings
  (`openSettings`, macOS 14).
- **Keep-alive.** At regular width and on macOS, the detail is a ZStack of the tabs visited so
  far. Each tab is created on first visit and has its own NavigationStack. Hidden tabs are:
  - opacity 0;
  - `.allowsHitTesting(false)` and `.accessibilityHidden(true)`;
  - `\.shellTabIsActive == false`.

  Each view's `.toolbar` and `.navigationTitle` contribute only while active. On the Mac the
  toolbar is one NSToolbar per window, so otherwise all tabs' items would merge. Settings'
  "when shown" refreshes become `.task(id: isActive)` gated on active. Compact iPhone keeps
  its TabView, which already keeps state, bound to the same ShellState.
- **iPad layout.** `.navigationSplitViewStyle(.balanced)`, with column visibility `.all` so the
  sidebar shows in portrait. Today and Stats content is capped at 680 pt and centred at regular
  width. Settings (an inset-grouped List) is not capped.
- **Heatmap.** At regular width the cell size comes from the card width over a fixed 13
  columns, clamped to 14…28 pt and measured outside the horizontal ScrollView. Compact width
  stays exactly 14 pt. **The existing first-column bug is fixed**: the oldest partial week was
  drawn top-aligned, so its days sat under the wrong weekday letters (visible in
  `02_stats_ipad.png`). The accessibility strip mode and its accessibility2 cap are kept.
- **macOS duplicates removed.** The shell's toolbar "New Habit" button is gone. TodayView's +
  stays, and ⌘N moves to the File menu (D3).

### D3 — macOS menu commands, Settings window, Dock badge

- **File menu:**
  - `CommandGroup(replacing: .newItem)` → New Habit ⌘N. This also removes File → New Window,
    so one main window holds the per-window presenters; reopening from the Dock still works.
  - `CommandGroup(after: .newItem)` → Sync Now ⌘R, Export Backup… ⇧⌘E (JSON), Export as
    CSV….
- **View menu:**
  - Today ⌘1 and Statistics ⌘2.
  - Weekly Review ⇧⌘R. It is Pro-gated: the paywall shows otherwise, and the item is disabled
    with no habits, matching StatsView.
- **Routing.** The main window publishes a `ShellCommands` value with `.focusedSceneValue`.
  Commands read it with `@FocusedValue` and are disabled when no main window is focused.
  Sync Now:
  - is enabled under the same rule as Settings' row (`showsAccountActions && !isSyncing`);
  - runs `SyncSectionActions.syncNow`;
  - shows a returned owner conflict through `AccountChoiceRouter`, which every main window
    already presents.
- **Menu Export** writes the file first (D6) and then presents `.fileExporter` (a save panel),
  which needs the `files.user-selected.read-write` entitlement. That entitlement also fixes
  Restore (above).
- **Titles** come from `appLocalized` so they follow the in-app language.
  LocalizationSourceScanTests learns `CommandMenu` / `CommandGroup`.
- **Settings scene** gets a frame (min 460×520, ideal 520 wide).
- **Badge.**
  - `setBadgeCount` loses its `#if os(iOS)`, so the Dock shows the same "remaining" count iOS
    does, under the same notification permission and the user's own badge switch.
  - The count is refreshed in more places: the existing throttled `didSave` /
    `habitDataChanged` observer (sync pulls, adds, deletes, intents included), macOS
    `didBecomeActive`, and `NSCalendarDayChanged` (midnight).
  - The rule itself is unchanged in this release: unarchived habits not done today, the same in
    the badge, the widget and Today's card. A schedule-aware "remaining" is a stats question
    (M4).

### D4 — Notification actions

- **Categories.**
  - `stride.habit.binary`: Mark Done, Snooze 1 Hour.
  - `stride.habit.count`: Add 1, Snooze 1 Hour.

  Neither action uses `.foreground` or `.authenticationRequired`: the point is a lock-screen
  write, and marking a habit done is not sensitive. Titles come from `appLocalized`. Categories
  are registered in `StrideApp.init` on both platforms and again when the in-app language
  changes. "Mark Done" is a new key, because the existing "Done" is a dismiss button (es
  "Listo").
- **Content.** `categoryIdentifier` by kind, `userInfo["habitId"]`, and
  `threadIdentifier` = habit id.
- **Triggers** come from a pure planner, `Shared/ReminderPlan.swift` (Foundation only, so it
  builds in the widget, StrideTests on macOS and the sync_rehearsal CLI):
  - Daily, timesPerWeek, mask 127 and a malformed mask 0 (treated as every day, as AddHabitView
    does) get one daily trigger under the legacy id `stride.habit.reminder.<uuid>`.
  - specificDays get one weekly trigger per set bit, under `stride.habit.reminder.<uuid>.<w>`
    (w = 1 Sun … 7 Sat).
  - Bits above 6 are ignored.
- **Identifiers have one source.** Schedule removes every variant first, `remove` removes every
  variant plus the snooze, and the launch prune builds `wanted` from the same planner. Without
  this, the prune would delete the weekday requests on every launch.
- **Snooze** is a one-shot 3600 s trigger, `stride.habit.snooze.<uuid>`. It has its own prefix,
  so the reminder prune never touches it. Any check-in of that habit in this process cancels it.
- **Delegate.**
  - `NotificationActionHandler` is set in `StrideApp.init`, before launch finishes, and held
    strongly.
  - It implements `didReceive` only. There is no `willPresent`, so a reminder that fires while
    Stride is frontmost stays unshown, exactly as today. That is acceptance (4): no new
    interruptive UI.
  - `Shared/NotificationRouter.swift` is pure: `route(action:category:userInfo:) →
    .checkIn(id, .markDone | .addOne) | .snooze(id) | .none`. The default tap, dismiss, the
    global evening and morning reminders, 1.3.x requests with no userInfo, and malformed ids
    all route to `.none`.
- **The write**, on the main actor:
  1. `SharedModelContainer.opened` (nil → no-op).
  2. Fetch the unarchived habit by id (gone → no-op).
  3. The day is `response.notification.date`, the day the reminder was delivered.
  4. binary → `markDone` (never un-checks); count → `tap` (+1).
  5. `save()` in the same turn.
  6. Post `.habitDataChanged`, reload widgets, cancel the snooze, and await the badge.
  7. iOS: start the bounded background sync and submit a refresh (D5).
- **Known limitation, documented, not fixed:** "Add 1" tapped on two devices before either
  syncs keeps one increment. Count values merge last-write-wins (DEV-PLAN-1.3.md, additive
  merge in the backlog).

### D5 — Background sync (iOS only; the Mac syncs on activation as today)

- **Info.plist.** `Stride/Stride-Info.plist` is a partial plist, merged with the generated one,
  for the iOS target only:
  - `UIBackgroundModes = [fetch]`;
  - `BGTaskSchedulerPermittedIdentifiers = [yyh.stride.habittracker.sync]`.

  `scripts/ci/product_checks.sh` asserts both in the built app.
- **Registration.** `BGTaskScheduler.register` happens in `StrideApp.init`, once per process,
  under `#if os(iOS)`. It is manual rather than `.backgroundTask`, for an explicit expiration
  handler.
- **The handler.**
  1. Sync with a new trigger, `.background`, on `opened.mainContext`.
  2. Afterwards, refresh what a scene-less launch never attaches: reminders reschedule, badge
     and widgets.
  3. `setTaskCompleted`, and resubmit while signed in (one pending request at most; iOS
     decides when it runs).
- **`.background` trigger.** It waits out the backoff window like `.automatic`. A no-answer
  (offline/cancelled) result is **not** recorded as backoff and sets no `syncError`. Otherwise
  a run cut off by expiry would mark the device offline for a minute, and the very next
  foreground sync (`.automatic`) would be skipped.
- **Submit points:**
  - the scene entering the background while signed in;
  - after each check-in: TodayView, the Siri intent, the notification action.

  `submit` failures (the Simulator, an unsupported host) are swallowed. The deprecated
  synchronous `submit` is used below iOS 27, the async one from 27.
- **The notification action syncs at once.** After its save it runs one `.background` sync
  inside `beginBackgroundTask`, so a lock-screen Done reaches the server in seconds, force-quit
  or not, when the network allows.
- **`waitForSessionRestore`** stops on cancellation instead of spinning.
- **File protection.** After a successful app open on iOS, `Stride.store`, `-wal` and `-shm`
  are set to `.completeUntilFirstUserAuthentication`. This is defensive: it is the default
  already.

### D6 — Export: write first, then share

- **Writers.** `DataExportService` gains explicit
  `writeBackupFile(container:account:) / writeCSVFile(container:) / writeRecoveredEditsFile(log:accountID:) async throws -> URL`.
  - The snapshot is taken on the main actor, the encode and write off it.
  - Files go into the same `tmp/StrideExport-<UUID>/` folders, so the cleanup and the E2E kit
    are unchanged.
- **`ExportShareButton`** replaces every export ShareLink: Settings CSV/JSON, Delete Account,
  the account screen, and the four RecoveredEditsShareLink sites.
  1. Tap → the button is disabled with a spinner while the file is written.
  2. The platform share sheet is presented for that URL: `UIActivityViewController` from the
     button's own view controller, with the popover anchored to the button (iPad), or
     `NSSharingServicePicker` anchored to the button (Mac).
  3. One tap, one file. There is no text item, so no stray text.txt (E2E S6). STRIDE-APPLE-7
     (the Mac main thread waiting on a lazy provider) and the 6–7 s iOS delay go away because
     nothing is lazy.
- **Removed:** `ExportFileMemo` and the three `Transferable` items. Their tests become
  direct-writer tests, which check that each call writes exactly one file and that it decodes.
  The account semantics stay pinned: a conflict's backup records the conflict owner, and
  recovered edits use the right account id.
- **Kept:** the sweep anchors `accountExport`, `deleteExport` and `deleteRecoveredEdits`.

### D7 — Verification (no TestFlight, no device pass: agent-run, per the 2026-10-07 waiver)

- **Host-less StrideTests** (macOS CI):
  - NotificationRouter: every action, unknown category, missing or malformed id;
  - ReminderPlan: Mon/Wed/Fri → exactly 3 weekly triggers with weekday 2/4/6; 127 → 1 daily;
    0 → daily; ids;
  - heatmap column model (alignment) and cell-size function;
  - ShellTab mapping.
- **Hosted StrideAppTests:**
  - NotificationService with RecordingCenter: categories, userInfo, weekday requests, the
    prune keeping weekday ids, removal of all variants, snooze;
  - the action handler: DB write, widget reload, no-op paths;
  - export writers;
  - the regular-width shell in a UIWindow: Today → Stats → Today keeps the date.
- **Simulator E2E (scripts/sim_e2e):**
  - iPhone 17 Pro, plus the iPad Pro 13-inch (M5) under `/tmp/lock-ipad-pro-13-inch-m5`
    (shared with CLI Pulse);
  - the shell walk;
  - a reminder scheduled 2 minutes ahead, the device locked, the banner's action → the record
    in the store and on the local server;
  - export share sheets;
  - upgrade gate from 1.3.1 (and 1.3.0) with the widget.
- **macOS:** a test variant of StrideMac with a different bundle id, no App Group (the store
  falls back to its own sandbox container) and a test keychain service, so nothing touches the
  Stride data already on this Mac. Ad-hoc signed with the real sandbox entitlements and driven
  with computer use: ⌘, Settings, the menus, the Dock badge, Restore's open panel and Export's
  save panel.
- **Acceptance (3)'s "background refresh"** is not observable on a simulator. The run checks
  the request is submitted and that the handler's code path works when invoked directly (a
  DEBUG launch argument). Delivery runs through the action's own sync and the foreground.

## Progress log

- 2026-10-10: branch cut; codebase map; Mac Restore sandbox bug verified; this design written.
