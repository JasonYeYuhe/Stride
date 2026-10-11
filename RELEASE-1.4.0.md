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
| `HabitCheckIn.markDone` on `SharedModelContainer.mainContext` | No such member. The handle is `SharedModelContainer.opened?.mainContext`, nil when the store did not open | `ModelContext(opened)`, a fresh context saved in the same turn as the Siri intent does, with a store-unavailable no-op (D4) |
| Count habits: Done → "Add 1" via `markDone` | `markDone` adds nothing once a count day is complete | `HabitCheckIn.fromReminder` picks by the habit's *current* kind: count → `tap` (+1), yes/no → `markDone`; it never deletes (D4) |
| "awaits the save" | `ModelContext.save()` is synchronous | Write and save in one main-actor turn (D4) |
| Set the store's file protection to class C | Already the effective class: no data-protection entitlement (SyncRecoveryLog.swift:450-453). SwiftData has no option for it | Set explicitly on `Stride.store`, `-wal` and `-shm` after the app's open, iOS only. Defensive; documented as such (D5) |
| BGAppRefreshTask "after every check-in from a widget" | The widget's intent runs in the extension, and whether a WidgetKit extension may submit is unverified (the header says "some extensions") | The app submits a refresh when it goes to the background while signed in. A widget check-in made later is covered by that pending request (D5) |
| "reaches the server within the next background refresh", from a force-quit app | iOS does not run BGAppRefreshTask for a force-quit app | The notification action itself starts a bounded sync while the app is awake. Background refresh stays best-effort (D5) |
| The INFOPLIST_KEY_* route for new plist keys | `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` are not on Xcode 27's allowlist and would be dropped silently (the 1.2.0 SentryDSN trap) | A hand-written partial `INFOPLIST_FILE` for the iOS target, plus a product-check assertion (D5) |

## Design decisions (revised 2026-10-10 after the design review)

The first draft was reviewed before any code by four independent lenses (data safety, Apple
API correctness, product rules, testability) plus Gemini, and every major claim was re-checked
by a skeptic against the code and the SDK. 13 major findings held (one blocker), 9 were
downgraded, 3 refuted. Everything below is the revised design. The adopted findings are in
[Design review](#design-review-2026-10-10).

**Placement rules** (what may go where; the compiler does not enforce all of them):

- **`Shared/` holds pure value logic only:** the router, the reminder planner and day resolver,
  `ShellTab`, the heatmap model, the backoff trigger.
  - It compiles into the iOS app, StrideMac, the widget extension, host-less StrideTests on
    macOS, and `scripts/sync_rehearsal.sh`'s bare `swiftc -O` CLI. That CLI is the only
    non-DEBUG compile of `Shared/` before an archive.
  - So: no `BGTaskScheduler`, even under `canImport` (the framework exists in the macOS SDK and
    the class is unavailable there); no `UIApplication`, which is unavailable to the widget as an
    app extension; no `Stride/Sources` symbols (`appLocalized`, `appCalendar`; pass a
    `Calendar`); both branches of any `#if DEBUG` must compile.
  - No top-level names that collide with the rehearsal's own: Scenario, Device, Report, Check,
    Account, Verdict, describe, unwrap.
  - `Shared/` is not localization-scanned, so no user-facing literals.
- **Platform and UI glue lives in `Stride/Sources`:** the action handler, background sync, the
  category builder, the export button.
- **A Swift 5.9 module with no strict concurrency.** Every hop to the main actor is written
  explicitly and asserted (`MainActor.assumeIsolated` where a callback's queue is ours to
  choose).

### D1 — Version

1.4.0 (22) on both platforms. MARKETING_VERSION 1.4.0, CURRENT_PROJECT_VERSION 22.

### D2 — The shell (iPad and macOS)

- **`ShellTab`** (Shared, pure) is `today = 0`, `stats = 1`, `settings = 2`. Its `-tab N` parsing
  is pinned by tests (missing, garbage and out-of-range values → today). On the Mac, `-tab 2`
  selects Today and opens Settings (`openSettings`, macOS 14).
- **`ShellState`** is `@Observable`, per scene: `@State` in ContentView, never a singleton, so iPad
  windows do not mirror each other.
  - It holds a **non-optional** `selection: ShellTab`, Today's selected date and anchor, the
    Stats habit, and an **item-based** pending request (`enum ShellRequest: Identifiable` = new
    habit | weekly review | export(json/csv)), cleared on dismiss. It is never a Bool that can
    stick at true.
  - It sits above the size-class branch, so a compact↔regular crossing (Pro Max rotation, iPad
    Split View or Stage Manager) keeps the date, the anchor and the habit.
  - Known limitation: a sheet a leaf view presented is dismissed by that crossing, as in 1.3.x.
- **Re-anchoring moves into ShellState** (`reanchor(now:)`, the TodaySelection rule). ContentView
  calls it above the size-class branch on scenePhase `.active` and `NSCalendarDayChanged`, and
  whenever Today becomes the active tab.
  - It is never gated on a tab being active.
  - Otherwise a Today that was never created, or was torn down, would show yesterday at the next
    visit and credit check-ins to it. That is the bug TodaySelection exists for: the old
    `switch` shell re-anchored implicitly by recreating TodayView.
- **Sidebar.** One `SidebarView` serves both platforms.
  - Rows: Today and Statistics, plus Settings on iOS only.
  - macOS: `List(selection: $shell.selection)`, the macOS 13 non-optional initializer that
    "cannot be deselected", as 1.3.x's SidebarView does. With an optional selection, a click in
    the empty sidebar area would blank the detail.
  - iOS: `List(selection: Binding<ShellTab?>)` with a nil-dropping projection.
- **Keep-alive: one NavigationStack.** At regular width and on the Mac the detail root is **one**
  NavigationStack, as today. Its content is a ZStack of the tabs visited so far, each created on
  first visit.
  - Hidden tabs get: opacity 0; `.allowsHitTesting(false)`; `.accessibilityHidden(true)`;
    `.disabled(true)`, which takes them out of keyboard focus (Full Keyboard Access, iPad
    hardware keyboards) and disables their shortcuts; and `\.shellTabIsActive == false`.
  - Never an `if/else` on isActive around a tab root: that would rebuild the subtree and lose
    scroll position and @State.
  - **Titles come from ContentView only**, from ShellState, and the views' own `.navigationTitle`
    is removed. Today's date title is computed from ShellState's date. On regular width it is set
    once on the ZStack, with `.navigationBarTitleDisplayMode(.inline)` on iPad: one
    UINavigationBar now spans up to three scroll views, and large-title collapse would track a
    hidden one. On compact iPhone it is set on each TabView stack's root, as today.
  - **Toolbar items are gated inside the builder**: `.toolbar { if isActive { ToolbarItem … } }`
    (`ToolbarContentBuilder.buildIf`, iOS 16 / macOS 13, as StatsView.swift:133 already does).
  - **"When shown" refreshes** (SettingsView's `.task`) become `.task(id: isActive)` gated on
    active.
  - Compact iPhone keeps its TabView, which already keeps each tab's state, bound to the same
    `shell.selection`.
- **Layout.**
  - iPad uses `.navigationSplitViewStyle(.balanced)` with the default (automatic) column
    visibility. Forcing `.all` would leave a 424 pt detail beside the sidebar on an iPad mini in
    portrait.
  - Today and Stats content is capped at 680 pt and centred. The cap goes **inside** each
    ScrollView (`.frame(maxWidth: 680).frame(maxWidth: .infinity)`, the AccountSwitchView
    pattern), so the full width still scrolls. It applies at regular width and on the Mac, which
    counts as regular. Settings (inset-grouped) is not capped.
- **Heatmap.**
  - Cell = `max(scaledCell, floor((W − 39) / 14))` at regular width and on the Mac, with W
    measured on the card row outside the horizontal ScrollView. Fixed 13 columns, so the size
    does not change from day to day. No upper clamp below 44 pt.
  - At W = 616 (the 680 cap) the grid fills ≥ 93 % of the card. Acceptance (1): "the heatmap
    fills its card".
  - Compact width keeps the existing `@ScaledMetric` cell, so phones are unchanged at every
    Dynamic Type size. Strip mode and the accessibility2 cap stay.
  - On 12-column days the grid is trailing-aligned.
  - **The first-column bug is fixed**: the oldest partial week is padded at the top, so each day
    sits under its weekday letter. This changes the phone Stats grid on purpose. The a11y
    `--size default` Stats capture and the store screenshot are re-baselined in the same change.
  - The column model and cell function are pure in Shared, with tests for firstWeekday 1 and 2,
    a DST week, and W = 616.
- **macOS duplicates removed.** The shell's toolbar "New Habit" goes; TodayView's + stays, and ⌘N
  moves to the File menu (D3).

### D3 — macOS menu commands, Settings window, Dock badge

- **File menu.**
  - `CommandGroup(replacing: .newItem)`: New Habit ⌘N.
  - `CommandGroup(after: .newItem)`: Sync Now ⌘R, Export Backup… ⇧⌘E (JSON), Export as CSV….
- **View menu.** Today ⌘1, Statistics ⌘2, Weekly Review ⇧⌘R. Weekly Review is Pro-gated (the
  paywall otherwise) and disabled with no habits, as in StatsView.
- **The main window stays reachable.**
  - Window menu: "Stride" ⌘0, via `CommandGroup(before: .windowList)` and always enabled. It
    brings the main window forward, or calls `openWindow(id: "main")` only when none exists. A
    @MainActor count is raised in ContentView's onAppear and lowered in onDisappear, macOS only.
  - The main scene becomes `WindowGroup(id: "main")`, so quit-on-close and the URL/external-event
    behaviour stay as in 1.3.x.
  - `NSWindow.allowsAutomaticWindowTabbing = false` at launch, so the tab bar's + cannot spawn a
    second main window.
- **Routing.**
  - The main window publishes `ShellCommands` with `.focusedSceneValue`. Window-scoped commands
    read it with `@FocusedValue` and are disabled when no main window is focused.
  - An action that arrives while that window has a sheet up (`NSApp.keyWindow?.attachedSheet !=
    nil`) beeps and does nothing. Requests are item-based (D2), so nothing gets stuck.
    - As built (W6): the test is `attachedSheet != nil || sheetParent != nil` on the key window.
      While a SwiftUI sheet, an alert or a save panel is up, the sheet itself is the key window
      (it takes the typing), so `attachedSheet` alone is nil exactly then. Every command but
      Window → Stride beeps (`MenuCommandRules.actsUnderSheet`, tested); ⌘0 never does.
  - Sync Now has the same rule as Settings' row: `showsAccountActions && !isSyncing`. It runs
    `SyncSectionActions.syncNow`, and a returned owner conflict goes through
    `AccountChoiceRouter`.
    - It is **not** window-scoped (settled in W1's code review). With Settings key, the menu item
      and the row in that window are enabled together. The sync runs on
      `SharedModelContainer.opened`'s main context, as the launch and activation syncs do, and
      needs no `@FocusedValue`. `AccountChoiceRouter`'s sheet hangs off the main window, so W6
      brings that window forward (⌘0's path) when a conflict comes back.
  - The enable rules are pure in Shared, with tests.
- **Menu Export.** Write first (D6), then **`.fileMover`** with the written URL: a save panel that
  moves the file, so no tmp copy is left. It needs `com.apple.security.files.user-selected.read-write`
  in StrideMac.entitlements, which is also the Restore fix.
  - As built (W6): ContentView writes on `.task(id: shell.request)`. Another command replacing the
    request during the write, or the window closing, cancels it and no panel appears; a sheet that
    came up meanwhile drops it with a beep. A failed write is an alert titled "Couldn't create the
    file. Try again.": a menu has no row to put the line under.
  - As built (W6 review): a file handed to no one is deleted at once
    (`DataExportService.removeUnsharedExport`, hosted-tested): the panel's Cancel, and both drops
    above. W6's first cut left them to the tmp sweeps, and on a Mac the launch sweep can be weeks
    away, so every ⇧⌘E → Cancel kept another full backup in tmp. A failed move is still the
    sweeps': a move to another volume copies, then deletes, and the file in tmp may be the only
    whole copy.
- **As built (W6, revised in its review): no count.** The main windows are held weakly (an
  `NSView` on the main scene's window root reports its window), because SwiftUI has no call that
  brings an existing WindowGroup window forward. On the root, not ContentView, so a window showing
  the store's error screen counts too and ⌘0 brings it forward instead of opening a second one.
  The held windows alone decide: ⌘0 brings forward one that is visible or minimized, and opens
  "main" only when there is none. W6's first cut also kept the onAppear/onDisappear count above
  and opened a window whenever it read 0. That count could only ever cause a second window, never
  prevent one: if SwiftUI delivers onDisappear when a window is minimized (unverified), ⌘0 would
  have opened a second window beside the one in the Dock. So it was removed.
- **Titles** come from `appLocalized`, so they follow the in-app language. AppKit's own items
  (Close, Edit, Window…) follow the system language, as every Mac app's do; this is a known,
  accepted mix. LocalizationSourceScanTests learns `CommandMenu` / `CommandGroup`.
- **Settings scene** gets a frame: min 460×520, ideal width 520.
- **Badge.**
  - `setBadgeCount` loses its `#if os(iOS)`. The Dock shows the "remaining" count under the same
    rule as iOS: the user's notification permission, which Stride asks for when a reminder is
    switched on, and the user's own Badges switch in System Settings.
  - A Mac user who never turned a reminder on sees no badge, exactly as on iOS. Acceptance (2) is
    read that way, and What's New says so.
  - Refreshed (both platforms, one pass, `refreshAfterDataChange`):
    - the existing throttled `didSave` / `habitDataChanged` observer;
    - macOS `didBecomeActive`;
    - `NSCalendarDayChanged`.

    The same pass cancels pending snoozes for habits completed today (D4).
  - As built (W6 review): on the Mac the three triggers belong to the process, not the window.
    `StrideApp.installProcessTriggers` subscribes them once, from `prepareStore` (so only once the
    real store has opened, including through Try Again), and the activation pass's entitlement
    re-read and sync moved with them. W6's first cut left them on the main window's ContentView,
    as on iOS. But a Mac app outlives its windows, and the Dock badge stays after ⌘W. With the main
    window closed, neither midnight nor the next morning's activation reached any observer, so the
    badge kept last night's count. A Sync Now from Settings or the menu that pulled a phone
    check-in did not cancel that habit's snooze. iOS keeps them on the window.
  - The rule is unchanged (unarchived, not done today) everywhere: the badge, the widget and
    Today's card. A schedule-aware "remaining" changes all five surfaces in one release; it is
    added to the plan's backlog next to M5's at-risk math, not done here.

### D4 — Notification actions

- **Categories.**
  - `stride.habit.binary`: Mark Done, Snooze 1 Hour.
  - `stride.habit.count`: Add 1, Snooze 1 Hour.

  Neither action uses `.foreground` or `.authenticationRequired`. Titles come from `appLocalized`
  ("Mark Done" and "Snooze 1 Hour" are new keys; "Add 1" exists). They are registered in
  `StrideApp.init` on both platforms through the `NotificationScheduling` seam (which gains
  `setNotificationCategories`), and again when the in-app language changes.
- **Content.** `categoryIdentifier` by kind, `userInfo["habitId"]`, and `threadIdentifier` = habit
  id. A kind change (local edit or pull) reschedules, and also withdraws the habit's delivered
  banners, so no wrong button stays visible.
- **The reminder planner** (`Shared/ReminderPlan.swift`, pure):
  - One daily trigger under the legacy id `stride.habit.reminder.<uuid>` for daily, timesPerWeek,
    mask 127, a malformed mask 0 (treated as every day, as AddHabitView does), and bits only above
    6.
  - Otherwise one weekly trigger per set bit, `stride.habit.reminder.<uuid>.<w>` (w = 1 Sun … 7
    Sat).
  - **A budget.** If the total planned requests would exceed 58 (64 − the 2 globals − 4 for
    snoozes), every specificDays habit falls back to its single daily trigger: it fires on rest
    days, as in 1.3.x, and nothing is dropped. A code-only diagnostic is logged.
- **One source for identifiers.**
  - Schedule removes every variant first.
  - `remove` removes every variant and the snooze, pending and delivered.
  - The launch prune builds `wanted` from the planner, including snoozes. A snooze is kept only for
    a habit that still has its reminder on.
- **Snooze.** A one-shot 3600 s request, `stride.habit.snooze.<uuid>`, carrying the category,
  `habitId` and `userInfo["day"]`: the `yyyy-MM-dd` day the original reminder was for. A snooze of
  a snooze copies it forward.
  - It is cancelled by any in-process check-in of that habit.
  - It is also cancelled by the `refreshAfterDataChange` pass (D3) when the habit is already done
    today, which catches check-ins from the widget and from other devices that arrived by sync.
- **Which day is credited.** `ReminderDay.resolve(userInfo:deliveredAt:respondedAt:calendar:)`, pure.
  The **banner's day** is `userInfo["day"]` (a snooze, parsed with the canonical range-checked
  parser), else the delivered **local** day. Then:
  1. the banner's day, if it is today;
  2. else the banner's day, if it is yesterday and the response came within 3 h after local
     midnight;
  3. else today (a stale banner, original or snooze, and a carried day in the future).

  The credit is always the banner's day or today, never a third day. *Narrowed in W1's code
  review:* the first wording made a carried day win at any age (a snooze banner left from Monday
  night, tapped on Friday, checked Monday) and any future day too, and step 3 credited yesterday
  whatever the banner was for (Monday's banner at 00:40 on Thursday checked Wednesday). A snooze
  stores what `resolve` returns when Snooze is tapped, so a snooze of a snooze copies its day
  forward while that day is still creditable.

  The resulting day is converted with a new non-idempotent `HabitCalendar.dayKey(forInstant:calendar:)`,
  which always reads the local Y/M/D. **Never pass a system date to `HabitCalendar.dayKey(for:)`:** it
  takes any exact UTC-midnight instant for an existing key, and the default 20:00 reminder in US
  Eastern daylight time fires at exactly 00:00 UTC of the next date.

  Tests pin America/New_York (20:00 EDT, 19:00 EST), America/Los_Angeles and Asia/Tokyo, a snooze
  across midnight, a next-morning action and a Thursday action on Monday's banner.
- **The router** (`Shared/NotificationRouter.swift`, pure) returns `.checkIn(habitId, day?) |
  .snooze(habitId, day?) | .none`, and **never a kind**. The default tap, dismiss, the global
  reminders, 1.3.x requests with no userInfo, an unknown category and a malformed or lower-case id
  all route to `.none`.
- **The write never deletes.**
  - `HabitCheckIn.fromReminder(habit, on:, in:)` (Shared) chooses by the habit's **current** kind:
    yes/no → `markDone`, count → `tap` (+1).
  - It can never un-check, so a stale "Add 1" banner on a habit that became yes/no changes
    nothing, and no tombstone is ever queued (asserted).
  - It writes through a fresh `ModelContext(container)` saved in the same main-actor turn, as the
    Siri intent does. It does not use `mainContext`, whose save would commit edits the UI holds
    unsaved.
- **Delegate.**
  - `NotificationActionHandler` is set in `StrideApp.init`, before launch finishes, and held
    strongly. It implements `didReceive` only. There is no `willPresent`, so a reminder firing
    while Stride is frontmost stays unshown, as today (acceptance 4).
  - Its environment is injected for tests: container provider, reload, badge, sync, refresh
    submitter, snooze scheduler, now, calendar. `UNNotificationResponse` cannot be constructed, so
    the delegate is a thin shim over `perform(route:delivered:responded:)`.
  - As built (fix pass; verification, blocker): the async `didReceive` is `@MainActor`. UIKit
    sends the completion-handler selector, and Swift's bridging thunk calls that completion
    wherever the async method returned. Nonisolated (a plain NSObject in this Swift 5.9 module),
    it returned on the cooperative pool. UIKit's completion for a response to a background scene
    asserts the main thread (`_performBlockAfterCATransactionCommitSynchronizes:`, "Call must be
    made on main thread"). So 8 of the E2E's 9 responses aborted the app right after the write:
    Mark Done, Add 1, Snooze and the default tap, from a terminated or suspended Stride. The
    writes survived, the action's sync did not. With the annotation the thunk hops to the main
    actor and calls the completion there (checked in SILGen). Pinned by a hosted test that sends
    the ObjC selector itself, with stand-ins for the response, and asserts the completion's
    thread; without `@MainActor` it fails. The response's two reads stay before the first await.
- **After the write.**
  1. Post `.habitDataChanged`, reload widgets, cancel the snooze and withdraw this habit's
     delivered banners, then await the badge.
  2. **Before returning** from `didReceive`, take `beginBackgroundTask` (iOS) or a
     `ProcessInfo` activity (macOS).
  3. Inside it: `await waitUntilIdle()`, then one `.background` sync, so the record is pushed even
     when a sync was already running.
  4. iOS: submit a refresh (D5).
  5. The Mac does the same sync, since its only other trigger is activation.

  As built (fix pass; verification, major): on iOS, steps 2–3 run the refresh's own
  `BackgroundSync.run`, through `NotificationActionHandler.Environment.sync(through:)`. A
  lock-screen action launches a terminated Stride with no scene, so no window's didSave
  observer exists, and W2's sync pulled other devices' changes with nothing after it. The widget
  kept the timeline it built before the pull. Its toggle acts on the store, so a tap on a habit
  the Mac had checked off deleted that check-in on every device (and a pulled un-check was
  re-checked). 1.3.x never changed the store without a window. `run` already waits out a sync in
  flight and syncs `.background`, and after it come the widgets, `refreshAfterDataChange`, the
  reminders and the badge (D5 below). The orphan prune runs only while the app is in the
  background (D5, "second fix pass"): an older banner answered from Notification Center over a
  frontmost Stride can meet a habit sheet that is saving. The Mac keeps the plain sync: its
  process-wide triggers see the pull's save. Hosted test: a Mark Done whose sync pulls another
  device's habit records the widgets' reload after the pull was saved, then the reminders and
  badge.

  As built (second fix pass; verification, minor): that test built its sync through
  `sync(through:)` itself, so it passed with `Environment.live` back on W2's plain closure. The
  hosted test of an action during a sync, which runs `Environment.live`, now also asserts the
  run's after-sync work on its recording center: the habit's reminder replaced, and the badge
  counted over the pulled habits. Checked by mutation: with the plain closure back, it fails.
- **Delivered-banner hygiene.** At launch, foreground and `NSCalendarDayChanged`, banners delivered
  before today are withdrawn. A check-in in the app, the intent or the handler withdraws that
  habit's banners.
- **Known limitations, documented, not fixed:**
  - "Add 1" tapped on two devices before either syncs keeps one increment (last-write-wins count
    merge; additive merge is in the backlog).
  - A snooze or a banner on a *second* device stays until that device's own refresh pass.

### D5 — Background sync (iOS; the Mac syncs on activation and after a notification action)

- **The `.background` trigger, in Shared:**
  - `SyncBackoffTrigger` gains `.background`, with exhaustive-switch properties `waitsOutWindow`
    (automatic, background) and `recordsNoAnswer` (not background).
  - `decision(for:)` uses `waitsOutWindow`. `record(_:for:trigger:)` takes the trigger, with no
    default, and skips only an offline outcome (no HTTP status, so cancellation and timeouts are
    included) for `.background`.
  - The engine passes the trigger. `SyncService.Trigger` gains `.background`; its mapping and the
    fast path are exhaustive switches, never `== .automatic`.
  - `finish` sets no `syncError` for a background offline outcome. A 429, a 5xx and the pause
    switch are still recorded and still respected.
  - Tests: SyncBackoffTests, SyncEngineTests, hosted SyncServiceTests, and a rehearsal case in
    S20.
- **Info.plist.** A hand-written partial `Stride/Stride-Info.plist`, merged with the generated
  one, on the iOS target only:
  - `UIBackgroundModes = [fetch]`;
  - `BGTaskSchedulerPermittedIdentifiers = [yyh.stride.habittracker.sync]`.

  `product_checks.sh` asserts both keys on iOS (parsing the arrays) and their absence on macOS.
  `verify_archive.sh` compares every top-level entitlement key of the project file against the
  signed app, so `files.user-selected.read-write` cannot silently go missing again.
- **Registration**, once per process, in `StrideApp.init`, `#if os(iOS)`:
  - `register(forTaskWithIdentifier:using: .main)` with `MainActor.assumeIsolated` inside, so a
    later queue change traps instead of racing.
  - The result is kept in a static. Hosted tests assert it is true, that the code's identifier
    constant is in the plist, and that `UIBackgroundModes` contains `fetch`.
- **The handler**, `BackgroundSync.start(task)` (@MainActor) over a testable
  `BackgroundSync.run(container:) async -> Bool`:
  - **Run:** the `.background` sync on `opened.mainContext`, then what a scene-less launch never
    attaches: reminders (`scheduleAll`, plus the prune), the badge, widgets.
  - **Resubmit before completing**, from a nonisolated helper, when a session is stored.
  - **Completion is claimed once**, with a lock-guarded flag. The **expiration handler** does only
    thread-safe work: `work.cancel()`, then complete with false. It never waits for the main
    actor.
  - As built (fix pass): the after-sync work is two parts. `refreshAfterSync` (widgets, then
    `refreshAfterDataChange`) is synchronous and runs whenever the sync returned, before the
    second cancellation guard. `afterSync` (reminders, then the badge, both awaited) runs only
    while the task is alive. Before, a task that expired just after a sync that pulled skipped the
    widget reload with the rest. The prune also runs only while the app is not active, for both
    callers (the refresh, and on iOS a reminder action's sync, D4). Hosted tests: a run cancelled
    right after its pull still reloads, over a store with the pulled habit in it, and awaits
    nothing.
  - As built (second fix pass; verification, minor): "not active" did not cover the case it was
    for. Notification Center pulled down over a frontmost Stride leaves the app `.inactive`, with
    a habit sheet still under it, so a Mark Done on an older banner there still pruned. And the
    state was read once, before a prune that waits for the center's pending list, so the user
    could bring Stride forward and save a sheet in between, and the prune removed the sheet's new
    reminder, missing from a keep set computed earlier. The prune now runs only while the app is
    in the **background**. The state is read before the reschedule and again once the center has
    answered, in the same main-actor turn as the removal
    (`rescheduleAllHabitRemindersAndWait(mayPrune:)`). In any other state the reminders are still
    replaced, and the next launch's pass prunes. Hosted test, over the shipping after-sync work
    with an injected state (`Environment.liveAfterSync`): `.active` and `.inactive` keep the
    orphan, `.background` prunes it, and background-then-inactive during the center's answer
    keeps it. Checked by mutation: the first fix pass's single `== .active` read fails it.
- **Submitting.** One entry point, `BackgroundRefresh.schedule(reason:)`, with an injected
  submitter.
  - It runs in a detached task: the iOS 27 async `submit` must not run on the main thread, and
    below 27 the deprecated synchronous one is used.
  - It logs `refresh submit <reason>: ok | <domain>/<code>` at notice level. On the Simulator the
    answer is `Unavailable (1)`, never `NotPermitted (3)`, and that is what the E2E asserts.
  - Reasons: the scene entering the background, a check-in (Today, the Siri intent, the action),
    and the handler's resubmit.
  - **"Signed in" here means a stored session** (`hasStoredSession`), never `isLoggedIn`.
- **Session after a background launch.** A background launch now creates `AuthService.shared`, and
  its one session check can fail offline. The process can then be resumed into the foreground
  with `currentUser == nil`, which 1.3.x's syncIfLoggedIn guard would read as signed out for the
  life of the process.
  - `waitForSessionRestore` never writes `isSessionRestored`; only the check does. On a deadline
    or cancellation it simply returns.
  - `syncIfLoggedIn` first calls a new `recheckStoredSessionIfNeeded()`: `restoreStoredSession`
    when a token is stored and no user is known. It does not touch LoginView's `isLoading` or
    `error`.
  - It then gates on `currentSyncSession() != nil`. It awaits `waitUntilIdle()` first, so a stale
    background run cannot turn the foreground sync away.
  - A hosted test fails the check, runs a background sync, then foregrounds with the stub
    answering.
  - As built (fix pass; verification, minor): the recheck turns `isLoggedIn` true with no one
    asking, and Settings stays alive to see it (iPad's kept tab, the iPhone's TabView, the Mac's
    Settings window). Its `onChange(isLoggedIn)` sync was `.userInitiated`, which goes through
    the owner's backoff window and the server's pause. `syncIfLoggedIn` then waited it out and
    ran its own. `AuthService.userLoadedBy` now records how the user was loaded: `.signIn`
    (`verifyToken`: a code or a login link) or `.restore` (the launch check, the recheck, a login
    link's or a sync's recheck). Settings syncs `.userInitiated` only after a sign-in, and
    `.automatic` otherwise (`SettingsView.syncTrigger(afterUserLoadedBy:)`). It is not skipped
    for a restore: a login link's recheck that finds the session alive ignores the link, and
    nothing else syncs then. Hosted test, Settings in a window and inside a paused window: a
    restore sends nothing, and a sign-in afterwards syncs at once.
- **The widget's deletion queue** (pre-existing race, now likelier): append and remove on the
  App Group key are guarded by an `flock` on a lock file in the App Group container, in both
  processes, held only inside the synchronous call. A StrideTests case uses two queue instances.
- **File protection.** After the app's open on iOS, `Stride.store`, `-wal` and `-shm` are set to
  `.completeUntilFirstUserAuthentication`. This is defensive: it is already the default.

### D6 — Export: write first, then share

- **Writers.** `writeBackupFile(container:account:) / writeCSVFile(container:) /
  writeRecoveredEditsFile(log:accountID:) async throws -> WrittenExport`.
  - The snapshot is taken on the main actor, the encode and write off it, into the same
    `tmp/StrideExport-<UUID>/` folders.
  - `WrittenExport` carries the URL and, for recovered edits, the archived total it contains,
    read under the export's own flock.
- **`ExportShareButton`** replaces every export ShareLink: Settings CSV/JSON, Delete Account, the
  account screen, and the four RecoveredEditsShareLink sites. Tap → the button is disabled with a
  spinner while writing. A failed write shows one inline line ("Couldn't create the file. Try
  again.", a new key). Then:
  - **iOS:** `UIActivityViewController` over an `NSItemProvider` that registers the written file
    with copy semantics (`fileOptions: []`). Every receiver gets its own copy, as 1.3.x's
    `SentTransferredFile` gave, so a later cleanup can never cut off an AirDrop in flight. No text
    item, so no text.txt.
    - As built (W4): the provider goes in through `UIActivityItemsConfiguration(itemProviders:)`
      (`UIActivityViewController(activityItemsConfiguration:)`, iOS 14), the documented way to hand
      the sheet item providers. The ShareLinks' `subject: "Stride Habits Export"` (a Mail subject
      only) is not carried over: no metadata is set, so nothing beside the file can turn into text.
    - As built (fix pass; iPad E2E, cosmetic): the header was a blank placeholder icon with no
      name, on the iPhone too. The configuration's `metadataProvider` now answers only
      `.linkPresentationMetadata`, an `LPLinkMetadata` whose title is the file's name, with no URL.
      It is the header's preview and adds no activity item. `.title` filled the header just as
      well on the Simulator, but whether an activity such as Mail takes it as a subject is not
      documented, so it is not used; `.messageBody` would be a text. Checked by screenshot on the
      iOS 26.5 Simulator: the name shows and the targets are unchanged (Save to Files, More).
      Hosted test: one item provider, the header's title, no title and no message body.
    - It is presented from the anchor's own view controller, after checking **at presentation
      time** that the anchor is still in a window and that the controller presents nothing.
      Otherwise the share is dropped quietly.
    - One factory sets `sourceView`/`sourceRect` (the iPad popover). A hosted test asserts it on
      the iPhone host, where the property exists too.
  - **macOS:** `.fileMover` save panel with the written URL, the same as the menu Export. Unlike
    1.3.x's share picker, it saves the backup to a folder the user picks, which is what 1.3.1's
    What's New told users to do.
    - As built (fix pass; verification, minor): the button now follows the menu Export's rule
      (D3, "As built (W6 review)"). A cancelled panel deletes its file at once
      (`removeUnsharedExport`). So does a write that finishes after the button's view is gone (a
      sheet dismissed, the Settings window closed): an `ExportButtonPresence` reference, set by
      `onAppear`/`onDisappear`, is read when the file is ready. Its panel used to be set on dead
      state, and every Settings → Export → Cancel kept a full backup in tmp until a launch weeks
      away. A failed move is still the sweeps'. No test host reaches the Mac's views: this is on
      D7's Mac pass.
    - As built (fix pass): a kept-alive hidden tab presents no share. At regular width a hidden
      Settings tab stays in the window at opacity 0 (D2), so "in a window" let an export that
      finished after the user moved to Today put its popover there, anchored to an invisible row.
      The button reads `\.shellTabIsActive` and hands it to its anchor (`ExportShareAnchor.isShown`).
      `ExportSharePresenter.present` drops the share, logged like the other drops, when the tab
      is hidden. Hosted tests: the presenter's drop, and the anchor following the environment
      both ways.
    - As built (second fix pass; verification, minor): the anchor test hosted a probe view that
      repeated the button's wiring, and `ExportShareAnchorView.isShown` defaulted to true, so the
      button's `isShown: isTabShown` could be dropped with no compile error and no failing test.
      The default is gone. The hosted test now hosts `ExportShareButton` itself (written into the
      test's directory through a new `in root:` parameter, tmp by default), taps it through its
      accessibility action, and checks shown → sheet, hidden → nothing, shown → sheet. Checked by
      mutation: the button wired to `isShown: true` fails it.
- **STRIDE-APPLE-7 and the iOS 6–7 s delay** go away: nothing is lazy.
- **Cleanup.**
  - The erase paths (Erase, Start from this account's data, account deletion) sweep only export
    folders older than 10 minutes, then schedule one deferred full sweep.
    - As built (W4): the deferred sweep runs 10 min + 5 s after the erase and itself spares the
      last 10 minutes. Everything that existed at the erase is past the window by then, so it is
      all taken, as a full sweep would; an export made after the erase (the new account's backup
      after Start, say) keeps its own window instead of being swept seconds after it was written.
  - The launch sweep still removes everything.
  - The two premise comments are updated.
  - As built (fix pass; verification, minor): a file a Mac save panel holds is spared by every
    sweep. The panel is a sheet on its own window, and Erase, Delete Account or Start can run in
    Settings meanwhile. The erase's deferred sweep, 10 min 5 s later, took a file whose panel had
    been open that long, and Save then failed with the backup of the erased data gone.
    `DataExportService.exportsInUse` (lock-guarded: the deferred sweep runs off the main actor)
    is held from the panel's offer to its answer, by the menu Export (ContentView) and by
    `ExportShareButton`, and `removeExportFiles` skips what it holds. The panel's answer releases
    it, and its Cancel deletes the file. Hosted test: the erase's sweep, the deferred one and the
    launch's spare a held file; released, it is swept.
  - As built (second fix pass; verification, minor): the menu Export's pass that clears the file
    of a panel that never came up now releases that file's hold too (without deleting it). Only
    the pass's next offer used to release it, so a pass that ended without one (cancelled, beeped
    away by a sheet, failed, or a request that is not an export) left a full backup held for the
    life of the Mac process, and Erase, Delete Account and Start never swept it. A panel's own
    close never reaches that branch: its binding clears the file before the request changes.
    Mac-only view code with no test host: on D7's Mac pass.
- **Recovered edits: Clear and Erase are bound to what was exported.**
  - The last exported total per owner is remembered.
  - If Clear or Erase is confirmed while the current total is above it, the existing "New
    recovered edits arrived. Export them, then try again." path runs instead of clearing. One
    line archived between the export and the confirmation can no longer be deleted unexported.
  - As built (W4): remembered in memory on `SyncService`, when the file is written (no share sheet
    reliably reports delivery), and forgotten whenever that owner's log is cleared. With no export
    remembered, Clear and Erase keep 1.3.1's rule (bound to the confirmation's total): clearing
    without exporting stays the user's choice, which both confirmations put to them. Delete
    Account's `recheck` is bound the same way: after one refusal its rebuilt step carried the new
    total, and the final button tapped again deleted the line the export never held.
- **As built (W4 review): nothing erases what an export is still writing.** 1.3.x's share sheet
  froze the screen until the file existed; write-first leaves it live for the ~0.5–2 s of the
  write, and Export → Delete My Account (or Clear, Erase, Start, Restore Anyway, Discard) ran the
  erase first, then dropped the share under the closed sheet or the confirmation.
  - `SyncService.exportWrites` counts every `DataExportService.write` from the tap to the written
    file. While it is above 0, Erase Local Data…, Clear Recovered Edits…, Discard…, Delete My
    Account, Restore Anyway and the account screen's choices (Start, Upload, Cancel: each closes
    the screen) are disabled.
  - A recovered-edits write still in flight for the owner counts as not exported
    (`hasRecoveredEditsNotExported`), so Clear, Erase and Delete Account's recheck refuse through
    the same path: an export tapped while an erase or a recheck was already waiting on a sync.
    Erase also asks again at the clear, after the sign-out's request, and keeps the log rather
    than clear it from under such an export.
  - The deferred sweep's delay is a DEBUG-settable `deferredExportSweepDelay`, and
    `removeExportFilesAfterErase` returns its task: the hosted tests await the sweep the erase
    itself scheduled.
- **Removed:** `ExportFileMemo` and the three lazy Transferables, together with their tests in the
  same commit. They are replaced by writer tests: one call → one file that decodes, the conflict
  owner recorded, the recovered-edits account id, and a failed write leaves nothing.
- **Kept:** the sweep anchors (`accountExport`, `deleteExport`, `deleteRecoveredEdits`) and the
  `StrideExport-*` naming.

### D7 — Verification (agent-run; no TestFlight, no device pass, per the 2026-10-07 waiver)

**Dev-time gate.** The branch is pushed and a draft PR into `main` is opened at once (the repo is
public, so macOS CI is free). Every push then gets drift, the iOS product check, StrideTests on
macOS, the StrideMac build and the hosted tests. Locally between pushes:
- `build-for-testing -scheme Stride -destination 'generic/platform=iOS Simulator'`;
- `build -scheme StrideMac`;
- `test -scheme StrideTests -destination platform=macOS`, in en and in ja/JP;
- `sync_rehearsal.sh` whenever `Shared/` changes.

A removed API lands in the same commit as its tests' migration.

**Host-less StrideTests:**
- the router matrix;
- the planner and budget;
- the day resolver and the `dayKey(forInstant:)` zone cases;
- `fromReminder` (never deletes);
- `ShellTab` and `-tab` parsing;
- the heatmap model;
- `.background` backoff;
- the D3 enable rules;
- the two-instance deletion queue;
- the catalog scan learning commands.

**Hosted StrideAppTests:**
- host wiring: the delegate, categories through the seam with localized titles and re-registration
  on a language change, BG registration and the plist keys;
- NotificationService: weekday requests, the shape switch, removal of all variants, the
  upgrade-shaped prune with snoozes;
- the action handler through injected seams: a stale Add 1 on yes/no is a no-op; count +1;
  archived, deleted and nil container are no-ops; a cross-process count; an action during a
  sync is pushed;
- SyncService `.background` and the session-after-background case;
- the export writers and the popover anchor;
- the shell: a regular-width `UIHostingController` with trait overrides keeps a tab's @State and a
  single creation across Today → Stats → Today, a compact↔regular flip keeps the date and habit,
  a Weekly Review request is honoured before Stats was ever visited, and hidden tabs are
  accessibility-hidden.

**Devices and locks.**
- Hosted tests move to the existing **iPhone 17** (`60AF3DEB-…`) under `/tmp/lock-iphone-17`, off
  the E2E kit's iPhone 17 Pro. A hosted run used to wipe the kit device's pending reminders and
  spend its once-per-install flags.
- `a11y_sweep.sh` locks under `/tmp`, with a sanitized slug (`ipad-pro-13-inch-m5`) and a 40-minute
  timeout instead of waiting forever.
- CLI Pulse's capture script takes no lock on the same iPad. Before using the iPad, Stride checks
  it is not busy, and shuts it down at wrap-up if this session booted it.

**Simulator E2E.** The kit (iPhone 17 Pro) gains `app.sh notify` (a `simctl push` with a category
and habitId) and launch arguments, with matching selftest stub cases.
- The router matrix by push.
- A real fire:
  - two reminders two minutes ahead: a daily one, and a specificDays one whose mask includes the
    run day's weekday;
  - the app **terminated** and the device locked, then the banner actions;
  - checks: the store row, the server push line, and the backoff prefs inspected first.
- Snooze.
- The DEBUG background-handler argument, giving a server sync line plus the
  `refresh submit … Unavailable` lines.
- Every export site: one file, no text.txt.
- The pending store is read from the device's `UserNotifications/<app>/PendingNotifications.plist`
  (scratch copy, plistlib), including acceptance (3)'s "exactly 3 pending weekday triggers".
- `upgrade.sh` from v1.3.1 and v1.3.0, with the widget, adds reminder assertions read the same way:
  a legacy daily id becomes `.2/.4/.6` for a Mon/Wed/Fri habit, a daily habit keeps its bare id,
  and both categories are registered.
  - As built (fix pass; E2E 2026-10-11): the run from v1.3.1 was a false FAIL. Its gate-order and
    delivery-marks checks assumed an old build without the gate and the migration. 1.3.1 already
    wrote marker 1 and `stride_delivery_migration_v1_done`, and the model did not change, so the
    widget was let in before the app's open and nothing was marked (`upgrades/e1-131to140-widget`).
    The run now saves the App Group prefs before the install. A widget open before the app's, at
    the schema the old build had marked, is a NOTE unless the model checksum then changed.
    Migration already done before the install is a NOTE too. The verdict says "did not open
    Stride.store" only for an actual failed open. New selftest cases cover these (102 in all);
    against the old `upgrade.sh`, 8 of them fail.
  - As built (second fix pass; verification, minor): two ways that excuse passed on nothing.
    - The excused widget-first open rested on the model checksum alone, and `"?" == "?"` read as
      "unchanged" when `Z_METADATA`, `writefile` or `plutil` could not be read on either side.
      An unread checksum is now unknown. With an excused widget-first open, the run fails ("the
      model checksum could not be read to rule out a migration"). The first fix pass's own
      selftest case had passed this way: its store fixture had no `Z_METADATA`. It now has one.
    - "Migration already done" passed even when the old build's marks still waited
      (`stride_delivery_marks_unproven` or `…_unverified` in `prefs-before.txt`, a 1.3.1 device
      upgraded from 1.3.0 that never made the full pull). The NOTE now needs no waiting mark.
      With one, the marks must still wait after the launch, or the first full pull must have
      asked `?deletionsSince=`. Otherwise the run fails: the marks were lost, and the next full
      pull can archive rows deleted elsewhere.
    - Selftest: 110 cases (8 new): an unread checksum, waiting marks kept, lost and proved. Against
      the first fix pass's `upgrade.sh`, 7 of the 8 fail; the eighth is a positive check.
  - The banner recipe (README): on the lock screen, swipe the banner left and tap View; on the
    home screen, pull it down. A long-press through the iOS Simulator MCP reveals nothing.
- **iPad Pro 13-inch (M5)**, unsigned Debug, under its lock:
  - the shell walk (sidebar highlight, Today → Stats → Today, the 680 cap, the heatmap fill, the
    inline bar tracking the visible tab);
  - one in-sheet and one in-List export popover;
  - a sheet dismissed mid-write: no crash, no presentation.
- **Pro Max:** Today → Stats → Today, scroll and date.

**macOS: a variant that cannot touch the real store.**
- On macOS `containerURL(forSecurityApplicationGroupIdentifier:)` is never nil (NSFileManager.h:993),
  so the first draft's "falls back to its own container" was false.
- `scripts/mac_variant/build.sh` builds StrideMac Debug with `PRODUCT_BUNDLE_IDENTIFIER=yyh.stride.habittracker.mactest`,
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) STRIDE_MAC_VARIANT'` and ad-hoc signing.
- Its entitlements are **generated from StrideMac.entitlements** minus the app group and
  associated domains. The build fails if any `com.apple.developer.*` key remains, so the panel
  checks prove the shipping file's `files.user-selected.read-write`.
- Under the flag:
  - the store location is forced to `.noAppGroup`;
  - App Group defaults and the deletion queue's suite resolve inside the variant;
  - the keychain service is the bundle id;
  - Sentry is off;
  - the launch preconditions: sandboxed (`APP_SANDBOX_CONTAINER_ID`), store under
    `NSHomeDirectory()`, bundle id ≠ the real one.
- Preflight before the first launch: codesign shows the variant id and no group or developer
  keys. After launch: the "outside the App Group" log line, and the store under
  `~/Library/Containers/yyh.stride.habittracker.mactest/`.
- Launch only by explicit path or `open -b`, never `open -a Stride`. Never `-demo` before the
  preflight passes.
- **Computer-use pass:**
  - ⌘, Settings and the sidebar without Settings;
  - one toolbar per tab, with no merging;
  - `-tab 2`;
  - every menu item and shortcut;
  - an empty-area and ⌘-click on the sidebar (the selection stays);
  - Settings open, main window closed, then the Dock and Window → Stride;
  - the main window minimized, then ⌘0: it comes out of the Dock, and no second window opens;
  - the main window closed (Stride still running): cross midnight (or change the clock's day) and
    activate the app, then check that the Dock badge counts the new day. Also: with only Settings
    open, a menu Sync Now that pulls a check-in made elsewhere updates the badge;
  - the Dock badge (after allowing notifications in the variant's own prompt);
  - Restore's open panel;
  - the Export save panels;
  - Mark Done on a Mac banner, with the app running and quit.

**Acceptance (3)'s "background refresh"** is not observable on a simulator. What is checked:
- registration returned true in the host;
- the constant matches the plist;
- each submit reason was attempted with the Simulator's Unavailable answer;
- `run` was exercised.

Real scheduling and delivery are covered by the waiver, not by a check.

**Release gates** are the standing ones (NEXT_SESSION_PROMPT.md, README "Tests and gates"),
unchanged.

### D8 — Release copy and store screenshots

- **What's New (six locales, in `release.py`)**, one bullet per change, scoped by platform:
  - Mark Done / Add 1 / Snooze on reminders.
  - **Reminders for specific-days habits now arrive only on those days.** This is a behaviour
    change; rest-day nudges stop.
  - iPhone/iPad: a check-in made from a reminder or the widget syncs in the background.
  - iPad: the sidebar keeps your place.
  - Mac: Settings moves to Stride → Settings… (⌘,); menu commands; the Dock badge, with how to turn
    it off; Restore from Backup now opens its file panel; Export saves a file.
  - Exports open instantly.
- **Description.** The reminders paragraph gains the action line, pushed with `push_metadata.py`
  in the same submission.
- **Store screenshots (D7b, owner-approved ASC writes).**
  - Read what is live first (read-only API).
  - Capture into a fresh `build/store-screenshots/1.4.0/…`, never the iCloud-synced
    `build/ios-screenshots` with its " 2.png" duplicates:
    - iPhone 6.7/6.9 and iPad 13 (2064×2752 is accepted as is) from the 1.4.0 Debug `-demo` build;
    - the Mac at an exact 16:10 size from the variant;
    - no Mac widget slide.
  - The Settings slide replaces the April captures. Those still show "Upgrade to Pro — Unlimited
    habits, widgets, smart reminders", a false Pro claim.
  - Upload with a new small uploader that resolves the version by platform and replaces only the
    named display types. **Never** `appstore_metadata.py` (it rewrites 1.0 metadata) or
    `update_screenshots.py` (it wipes every locale and picks a version without a platform).

## Design review (2026-10-10)

Adopted (the design above), by severity after verification:

- **Blocker.** Crediting `notification.date` through the idempotent `dayKey` → tomorrow, at the
  default 20:00 in US Eastern daylight time. Fixed by `dayKey(forInstant:)` and the resolver.
- **Major:**
  - the router's kind payload invited `tap` on a now-yes/no habit, un-checking it (→ `.checkIn`
    with no kind, plus `fromReminder`);
  - a background launch leaving the foreground signed out (→ the recheck and the gates);
  - per-tab NavigationStacks can't gate titles and nest bars (→ one stack, hoisted titles);
  - an optional Mac sidebar selection blanks the detail (→ the non-optional init);
  - the Mac variant would resolve the real store (→ the flag and generated entitlements);
  - stale-day and snooze-across-midnight credits (→ the resolver and the snooze `day`);
  - the heatmap clamp failing "fills its card" (→ the max formula);
  - store screenshots misrepresenting the shells, including a false Pro row (→ D8);
  - a background submit unobservable on the Simulator (→ seams, log lines, honest D7 wording).
- **Minor:**
  - the `.background` plumbing in Shared;
  - the BG completion and queue rules;
  - deferred sweeps instead of completion-time deletes;
  - copy-on-load item providers;
  - the anchor checked at presentation;
  - commands under sheets;
  - ⌘0 and window tabbing;
  - `fileMover` instead of `fileExporter`;
  - hidden tabs `.disabled`;
  - the request budget;
  - the snooze prune;
  - the cross-process deletion queue lock;
  - Clear/Erase bound to the exported total;
  - the Mac action sync;
  - the hosted-test device and locks;
  - a11y_sweep locks;
  - kit push and launch args;
  - the reminder fire on the run day's weekday;
  - archive entitlement and plist checks;
  - What's New scoping;
  - the placement rules;
  - the workstream order.

Refuted or not adopted:
- The Dock badge "nag" (refuted: same rule as every surface, opt-in permission). Changing only
  the badge and widget would desync Today.
- "The upgrade gate is blind to reminders" (refuted: the simulator keeps
  `PendingNotifications.plist`, which the gate now reads).
- "The iPad popover crashes" (refuted as written; the anchor checks were adopted anyway).
- Forcing the sidebar visible on iPad. Deleting files on share completion (it cuts off AirDrop).
- A production log line listing habit ids.

## Workstreams (in order; parallel only where files do not overlap)

- **W0 scaffold** (one commit, one `xcodegen generate` 2.45.3):
  - version 1.4.0 (22);
  - the empty partial plist wired on the iOS target;
  - the Mac entitlement;
  - every new file as a compiling stub;
  - every new localization key in all five catalogs;
  - push and open the draft PR.

  On any later pbxproj conflict: take either side and regenerate.
- **W1 Shared pure logic and tests:** router, planner, day resolver, `dayKey(forInstant:)`,
  `fromReminder`, `ShellTab`, heatmap model, `.background` backoff plus the rehearsal case,
  deletion-queue lock, D3 enable rules.
- **W2 notifications:** NotificationService (D4 and the D3 badge), handler, StrideApp.init
  (delegate and categories), and one `CheckInEffects.afterCheckIn` helper used by TodayView, the
  intent and the handler.
- **W3 background sync:** the plist keys and checks, registration, the handler, submits,
  SyncService `.background`, the AuthService recheck, file protection.
- **W4 export:** writers, `ExportShareButton`, every site, cleanup grace, Clear/Erase binding,
  tests, in one commit with the removals.
- **W5 shell:** ContentView, ShellState, Today/Stats/Settings, heatmap.
- **W6 macOS:** commands, ⌘0, Settings frame, badge triggers, `fileMover` export.
- **W7 tooling (parallel, scripts only):**
  - the a11y_sweep lock;
  - hosted-test device and lock;
  - kit notify and launch args plus selftest;
  - upgrade.sh reminder checks;
  - `scripts/mac_variant/` plus the `STRIDE_MAC_VARIANT` code paths;
  - the screenshot uploader.

Then: a whole-branch review, the E2E and Mac passes, release mechanics.

## As built: deviations not recorded inline

W4 and W6 wrote theirs into D3 and D6 ("As built"). The other workstreams' deviations from the
design are below. Each was checked by that workstream's reviewer.

- **W1 (Shared):**
  - The action ids are `stride.habit.action.markDone`, `.addOne` and `.snooze`, pinned by tests.
  - Either check-in action in either of our categories routes to `.checkIn`. The route carries no
    kind, so a mismatch cannot matter.
  - `fromReminder` also returns nil for an archived habit.
  - Heatmap cap: `max(scaled, min(44, floor((W − 39) / 14)))`, so a Dynamic Type cell is never
    shrunk.
  - Deletion-queue lock: the App Group container; without one, the app's Library (not
    cfprefsd's Preferences).
  - **The day resolver as finally built:**
    - a carried snooze day is credited only if it is today, or yesterday within the 3 h
      after-midnight grace;
    - an original banner credits yesterday only within that grace;
    - otherwise today, never a third day.

    This is stricter than D4's first wording, which would let last night's snooze back-fill
    yesterday at 09:00.
  - Menu Sync Now is not window-scoped. It needs no focused main window, the same as Settings'
    row.
- **W2 (notifications):**
  - The seam's `getDeliveredNotifications` returns a value type: `UNNotification` cannot be
    constructed in tests.
  - `setBadgeCount` goes through the seam, so hosted runs never touch the host's badge.
  - `CheckInEffects.afterCheckIn` takes an explicit `endsReminders:`. A back-fill of a past day
    does not cancel today's snooze or withdraw today's banners; the action handler and the Siri
    intent pass true.
  - An action on an already-done day is a complete no-op.
  - Kind changes, local or pulled, are handled generically by `refreshAfterDataChange`:
    - banners whose category no longer matches the habit's kind, or whose habit is gone or
      archived, are withdrawn;
    - snoozes in those states are cancelled, never re-added, because a pending trigger cannot say
      when it would fire.
  - `pruneDeliveredBeforeToday` withdraws only habit banners. The global evening and morning
    reminders have no buttons.
  - A single habit's schedule is budgeted together with its whole store.
  - A language change also re-adds the global reminders, whose text is localized.
  - The Snooze route waits for its add to complete before `didReceive` returns.
- **W3 (background sync):**
  - `run` awaits `waitUntilIdle()` before its `.background` sync, so a sync already in flight
    cannot drop the refresh's check-in.
  - `afterSync` runs `refreshAfterDataChange` and an awaited prune (`rescheduleAllHabitRemindersAndWait`).
  - The resubmit goes in **before** the run. Its answer is then awaited for at most 2 s, and not
    at all once the task has expired, so an expiring run cannot end the refresh chain.
  - `-runBackgroundSync` (DEBUG) goes through `handle()`, so it also logs the resubmit.
  - A launch check that fails after `recheckStoredSessionIfNeeded` succeeded no longer clears the
    user: users loaded are counted. That also closes the same pre-existing race with
    `verifyToken`.
  - Overlapping foreground passes are coalesced per SyncService instance.
  - Store file protection is applied in `AppStoreOpen.run` to whatever location was opened.
  - `verify_archive.sh --exported` compares entitlement values, not only presence. The 1.3.1 Mac
    export correctly fails it for lacking `files.user-selected.read-write`.
  - No `earliestBeginDate`: the system decides when.
- **W5 (shell):**
  - Today's title compares the selected date with ShellState's anchor, not the clock, so it
    redraws exactly when re-anchoring moves. Its formatter now follows the in-app language.
  - TodayView's own scenePhase and day-change re-anchor hooks are gone; ContentView re-anchors
    above the branch.
  - TodayView and StatsView take `init(shell:)`.
  - The newHabit and weeklyReview requests are presented by the shell above the size-class branch.
  - The Mac Settings scene sets its own title, because SettingsView no longer does.
  - Kept-alive Settings re-reads its reminder rows each time it is shown, and those reads write
    nothing back. Settings' `onChange(isLoggedIn)` sync is not gated on active, as in 1.3.x's
    compact TabView. Since the fix pass it is `.automatic` unless the user just signed in (D5).
  - Known, not fixed: with up to three scroll views on screen at regular width, tapping the status
    bar probably no longer scrolls to the top on iPad. SwiftUI has no public API for this.

## Progress log

- 2026-10-10: branch cut; codebase map; Mac Restore sandbox bug verified; design written, reviewed
  adversarially (4 lenses + Gemini, skeptic-verified) and revised.
- 2026-10-10/11: W0 scaffold; W1–W6 implemented one after another, each with an adversarial review of its
  diff and a fixer pass (several fixes confirmed by mutation checks); W7 tooling in parallel and
  cherry-picked. Gates on `148ac7a`:
  - StrideTests 540 (en and ja/JP, 2 known skips);
  - hosted 238;
  - sync_rehearsal 81/0/1;
  - drift clean;
  - iOS and Mac builds with no new warnings.

  PR JasonYeYuhe/Stride#7 opened as a draft.
- 2026-10-11:
  - **The disk filled to 100 %** in the middle of verification: this session's four scratch
    derived-data folders (~14 GB) plus the kit builds. Every tool failed with ENOSPC.
  - The workflow was stopped, and so were its kit server and the iPad it had booted. Its locks
    were released.
  - The owner approved a one-time permanent delete of exactly those four folders. Trashing frees
    nothing on the same volume. 13 GB was free afterwards.
  - The kit's partly written build (a truncated Sentry artifact) was trashed and rebuilt.
  - From here on, one build per session is reused everywhere.
  - CI's first full run failed one timing-sensitive test, `testAFinishedRunWaitsForTheResubmitsAnswerUpToItsBound`:
    the detached submit had not reached its stub within 300 ms on a loaded runner. The test now
    waits for the submit; the bound assertion is unchanged (`8e2ed8a`).
  - Whole-branch verification (adversarial review, iPhone and iPad E2E). One blocker: the app
    aborted on 8 of 9 notification responses (D4). One major: an action's sync pulled with no
    widget reload after it, in a scene-less launch (D4, D5). Minors: Settings' sign-in sync after
    a restore (D5), the Mac Export button's Cancel and dropped panel, hidden-tab shares and files
    swept from under an open panel (D6), the share header (D6), and a false FAIL in `upgrade.sh`
    from v1.3.1 (D7). All fixed in one pass, each with an "As built (fix pass)" note above. The
    new hosted tests were checked by mutation: the delegate without `@MainActor`, and the reload
    behind the cancellation guard, each fail them. The kit's new cases fail on the old script.
  - A second fix pass on the first pass's review (six minors). The prune runs in the background
    only, and checks again before it removes anything (D5). The action's live wiring and the
    Export button's tab wiring are now pinned by tests on the shipping code, not copies (D4, D6).
    The menu Export no longer holds a stale file for the life of the process (D6). `upgrade.sh`
    no longer excuses a widget-first open on an unread checksum, and no longer passes when an old
    build's waiting marks are lost (D7). Each fix has a "second fix pass" note above. Each new
    hosted test was checked by mutation, and the kit's new cases were run on the old script.
