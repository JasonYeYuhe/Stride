# Stride 1.5.0 — the daily loop, and any week at a glance

App ID `6761262334`, bundle `yyh.stride.habittracker`. **Plan dated 2026-11-27.** Every code
citation is at `b206186`, the `m5/1.4.2` tip after 1.4.2 (24) went live on iOS and Mac (11-26).
The spec it builds on is RELEASE-1.4.2.md: D9 and D10 (Wave B), D17 (the daily loop), the 1.5.0
section (`:1215-1245`), W10 and W11. Where this file and that one disagree, this file wins.

- **Branch:** `release/1.5.0`, cut from `m5/1.4.2` at `b206186` on 2026-11-27. It carries 1.4.2's two
  post-merge commits (22d9446 O3 script, b206186 gate 14 and O14), which `main` does not have yet.
- **Version:** **1.5.0 (25)**. project.yml:19-20 still says 1.4.2 (24); V0 bumps it.
- **The split (owner, P1, 2026-11-27).** The 1.5.0 of RELEASE-1.4.2.md is now two releases:
  - **1.5.0 (25)**: X0 (Weekly Review step 2, and Today's at-risk words) and X2 (the free daily
    loop), plus the X4 carry-overs. Frozen **12-11**, both platforms submitted by **12-15**, so it
    is live before New Year: January is when people install habit trackers, and Apple slows down
    in late December.
  - **1.5.1 (26)**: X1 (Groups worth paying for) and X3 (the opt-in review notification), with O18.
    Cut at 1.5.0's submission, submitted by **2027-02-12** (the old 1.5.0 date). Sketched at the end.
- **M6 (skip days)** keeps its gate (D18): checked on this cut day and **not met**. There is no 426
  floor at ≥ 1.3.1 on the server (only payload-shape refusals, server/routes/sync.js:459), and the
  gate needs both the floor and eight quiet weeks. Checked again at 1.5.1's cut.
- **No `@Model` change, no wire change, no server deploy** in 1.5.0.
- **Process (unchanged):** no TestFlight and no owner device checks (the agent tests: hosted,
  `scripts/sim_e2e`, the a11y sweep, `scripts/mac_variant`); MANUAL releases; six locales for
  every string; worktree implementers, then review lenses, then an adversarial verify; Gemini only
  through agy on a throwaway `git archive` copy.

## Where things stand on 2026-11-27

- **1.4.2 (24)** is live on iOS and Mac (released 11-26). PR #12 merged (434c6c8), tag `v1.4.2`.
  The Yearly 7-day free trial is live in 175 territories; gate 14 passed on the real offer; the
  promotional text ×6 says so.
- **Weekly snapshot, 2026-11-26** (`metrics_snapshot.py`, kept in
  `~/Library/Caches/Stride-build/plan-1.5.0/snapshot-2026-11-27.txt`): 8 weeks, 93 devices,
  720 sessions, 100 % crash-free. First downloads 30, re-downloads 3, updates 50. No Pro unit, no
  subscription event, 0 active subscriptions or trials. 1.4.2+24: 3 devices so far. Written
  reviews: 1. Per D15, none of this decides anything but breakage and existence.
- **The X2 spike ran (2026-11-27). Answer: yes.** See D3.

## Scope

| X | 1.5.0 scope | Free or Pro |
|---|---|---|
| **X0** | Weekly Review step 2 (D9 as corrected in D6 here): any week with ‹ ›, a 7-cell strip per habit, the strength chip, group sections with their rates, "At risk this week", and the week's perfect days. (Notes and the share image moved to 1.5.1 on 11-27: Gemini A8.) Today's rows: "N more", at-risk words, "Due today", at-risk first in their section (D7) | Review: Pro. Today's words and order: free |
| **X2** | One pure `DailyProgress` for Today's card, the badge, the Dock and the widget (D1, D2). Reminders quiet once a habit is done, from the app and from the widget (D3, D4). The Daily Reminder skips a perfect day. A reminder offer that asks for permission on the tap (D5). A "missed yesterday?" card that shows yesterday on Today (D5) | Free |
| **X4** | Carried from 1.4.2: the hosted `dockLabel` test (in V2), the Mac paywall at minimum width and its top band (V6), the white-on-green contrast list (V5), the variant harness launching through `one.sh` (V5), and the owner's two Mac checks (gate 9) | — |

Out of 1.5.0: X1, X3, O18 (1.5.1); X5 (owner, later); everything in RELEASE-1.4.2.md's "Out of
scope", which still holds.

## Spec corrections (RELEASE-1.4.2.md against `b206186`)

| Spec says | Now |
|---|---|
| W4 adds `shell.todayFocusHabitID` | Not done (N1). ShellState.swift:16-206 has none; V4 adds it |
| W1's `weekRange`, `atRisk`, remaining, daysLeft, group section rates | **All exist** in Shared/WeeklyReviewMath.swift (`weekRange(containing:in:)` :50-52, `sections` :196-204 and :320-341, `weekGoal` :404-422, `isAtRisk` :430-449, `eveningTime` :376-378). No view calls them yet |
| `ShellRequest.history`, ShellState.swift:145 | :229 (enum :210-265) |
| `HabitRecord.outranks`, HabitCheckIn.swift:29-36 | Shared/Habit.swift:327-334. Ghost-safe kept records: `HabitCheckIn.liveRecords(of:onDays:)` :379-388 |
| `strengthSeries` HabitStats.swift:746-752; `score(on:)` HabitScore.swift:52-54 | HabitStats.swift:784-787 (and `strengthWeekEnds` :808); HabitScore.swift:53-55. The chip is `WeeklyReviewMath.strengthChangePoints` :347-351 |
| ⇧⌘R on iPad goes on the Stats toolbar button (W4) | Already done: StatsView.swift:195-218 |
| Today's row "1/3 this week", TodayView.swift:706-710; orange :720-724; label :652-660 | Text :787-794; readable orange :807; label :694, value `spokenDetail` :731-753 (the at-risk words go in the value, since the label is completion only) |
| D10 calls "1/3 this week · 2 more" a two-number string | It has three numbers. D7 keys it as one three-argument string |
| D10's at-risk rule "remaining ≥ daysLeft" | The code uses the creation week's share (`owed`, WeeklyReviewMath.swift:414-421), stricter on purpose; but `remaining` is still the whole goal, so a 3×/week habit made on Friday would read "3 more · 2 days left" on Saturday. D7 prints `owed` |
| D10: Daily Reminder NotificationService.swift:116-131 | :119-149; `reminderHour` defaults to 20 when unset (:131-135); not observable, so Today reads it per render |
| D17: "remaining" counts rest days on five surfaces (TodayView.swift:109-111; NotificationService.swift:648) | Card TodayView.swift:104-123, "Perfect day!" :504; badge NotificationService.swift:645-649 and :718-721; Dock `dockLabel` :768-771; widget StrideWidget.swift:30-55 and :605-648; group headers TodayView.swift:330-376 (a member count only). None reads a schedule |
| D17: the badge and Today agree | They use two code paths: the badge `Habit.isCompletedOn` (record scan), Today and the widget `HabitStats`. D1 puts all of them on `HabitStats` |
| D17: `.timeSensitive` at NotificationService.swift:274 | Gone (O24 shipped in 1.4.2) |
| D11: StoreService.swift:531; LocalizationSourceScanTests.swift:196, :232 | Subtitles ProPaywallView.swift:449-457 (`.weeklyReview` :453), rows :484-497 (Weekly Review :495); pins :199-227, :232-258 (:244), :266-334 (en-US Weekly Review line :325) |
| W10 file list | Also ShellState.swift, ContentView.swift, Shared/*.lproj, StatsPerformanceTests.swift, StrideApp.swift and a11y_sweep.sh (an any-week sweep flag) |
| W11 "Hosted TodayRenderTests" | No such file, and TodayView has no clock or cache seam (`Date()` :101, `StatsCache.shared` :29 and :554). V3 adds the seam, as WeeklyReviewView has it (:9, :32-38) |
| X3's budget "64 − 3 − 4" | 1.5.1. In 1.5.0 the budget stays `64 - 2 - 4` = 58 (ReminderPlan.swift:35); D4 spends it differently |

## Design decisions

**D1 — `DailyProgress`: one rule for every daily surface (Shared, pure).**
- **Input:** a habit's `HabitStats`, a day-key, `now`, the calendar. Day-keys only: "today" comes from
  `HabitCalendar.dayKey(forInstant:)` / `WidgetTimelinePlan.dayKey(of:in:)`, never `dayKey(for:)` on a
  live instant (20:00 EDT is 00:00Z). NotificationService's `startOfDay` → `isCompletedOn`
  (:647-648) moves to it.
- **State per habit and day:** `.done`; `.due` (scheduled and open); `.rest` (a specific-days
  off-day); `.metForWeek` (times-per-week, the Monday week's goal reached, `weekGoal.remaining == 0`,
  not done that day); `.notStarted` (`startDay` after the day). Archived habits are never passed in.
- **Counts:** `due = done + open`, where `done` counts only habits that were due or done (a done rest
  day is `.done` and counts in both, so the ratio never passes 1); `remaining = open`;
  `isPerfect = due > 0 && open == 0`.
- **A day with nothing due** is not a perfect day. Today's card reads **"Rest day"** (existing key) and
  draws an empty ring; the badge and the Dock show nothing; the widget reads "Rest day".
- **Count habits:** "done" is "target reached", as both paths agree today; a target of 0 is never done,
  and the widget no longer draws a full ring for it.
- **`WeeklyReviewMath.isAtRisk`** and the review's perfect-day count call `DailyProgress`, so the rule
  is written once. `isAtRisk`'s existing tests stay unchanged.

**D2 — The surfaces.**
- **Today's card** (TodayView.swift:104-123, :455-510): `done/due` for the selected day; "All done!
  Perfect day!" only when `isPerfect`. Past days still filter by `startDay` (:79-89); today now does
  too, through `.notStarted`.
- **Badge and Dock:** `remaining` for today. `dockLabel` keeps its rule (nil at 0 or with Badges off),
  and finally gets its hosted test (X4).
- **Widget:** each timeline entry asks `DailyProgress` for **its own** day-key, so the midnight entry
  shows tomorrow's rest days and a week reset on Monday. `WidgetTimelinePlan.Status` gains the state.
  `HabitEntry`'s `completedCount`, `totalCount` (now `due`), `progress` and `statusText`
  (StrideWidget.swift:30-55) come from `DailyProgress`, and so does every view that reads them: the
  small, medium and large rings (:240-254, :283-296, :383-415), the three lock-screen views
  (:604-680) and their VoiceOver labels. With nothing due they read "Rest day" and hide "0 of 0".
- **Group headers** stay a member count in 1.5.0. "2/3" is X1 (1.5.1) and will read `DailyProgress`.
- **Parity test:** one fixture (a daily, a Mon/Wed/Fri on a Tuesday, a 3×/week met on Thursday, a count
  habit at target 0, a habit created today) yields the same remaining on the card, the badge, the Dock
  and both widget entries.

**D3 — The spike (2026-11-27): the widget can change the app's pending reminders.**
- **Setup:** a throwaway app (`yyh.spike.notifwidget`) and its widget extension, iOS 27.0 simulator
  (iPhone 17 Pro), notifications allowed. The app scheduled two repeating daily requests and one
  one-shot; the widget's `Button(intent:)` ran `removePendingNotificationRequests` for two of them and
  `add` for a new one, in the extension process.
- **Result:**
  - the extension's `pendingNotificationRequests()` lists the app's three requests (it reads the
    app's store), and reports authorization `.authorized`;
  - after the tap, the extension, the app (relaunched) and the system's own store on disk
    (`PendingNotifications.plist` under the app's bundle id, read with `notifications.py`) all agree:
    the two were removed, the extension's request was added under the app, the third was untouched.
- **Evidence:** `~/Library/Caches/Stride-build/plan-1.5.0/spike-widget-notifications/` (log, the
  plist, the source). The spike app was uninstalled.
- **What it does not show:** a real device (Apple documents the shared center for extensions, and
  there is no TestFlight here); an extension that is suspended mid-write. D4 guards both: every
  write is followed by a read-back before `perform` returns, and the app re-plans from scratch on its
  next run, so a lost widget write only over-fires.

**D4 — Quiet when done: an overlay on the done day (owner, P2).**
- **The problem:** a repeating trigger cannot skip one day. Removing it and adding it back fires it
  again today if the time is still ahead.
- **Base plan (unchanged):** a daily or times-per-week reminder is one repeating daily request (bare
  id); a specific-days reminder is one weekly request per scheduled weekday (`.<w>`, 1 = Sunday); the
  Daily Reminder is `stride.daily.evening`; over budget, every specific-days habit falls back to one
  daily request (ReminderPlan.swift:152-160).
- **The overlay** is decided **per quiet day**, not per habit. A day is quiet when its state is
  `.done` or `.metForWeek` (`.rest` is already quiet). Today is overlaid only while its reminder time
  is still ahead (after it, today's request is plain weekly: nothing is left to silence); every
  quiet **future** day of this Monday week is overlaid regardless of the hour:
  - a daily-shaped habit's bare request becomes weekly requests for its non-quiet weekdays (`.<w>`,
    repeating) and, for each quiet weekday, a one-shot on the same weekday next week (`.n<w>`);
  - a specific-days habit's request for a quiet weekday becomes that one-shot;
  - **times-per-week met:** today (if its time is ahead) and every remaining day of the week are
    quiet, so each of those weekdays gets its one-shot for next week;
  - the Daily Reminder gets the same overlay on a perfect day (`stride.daily.evening.<w>` and
    `.n<w>`). The morning reminder is unchanged.
- **Dates and zones:** the weekday and next week's date come from today's day-key through
  `HabitCalendar.utc` (`date(byAdding: .day, value: 7, …)`, never `+ 7 × 86 400 s`, which lands on
  day 6 across a fall-back night); the one-shot's `DateComponents` carry year, month, day, hour and
  minute with **no time zone** (floating, like today's repeating triggers); "still ahead" compares
  `now` in the local calendar. A time-zone change (`NSSystemTimeZoneDidChange`,
  `significantTimeChangeNotification`) triggers a full plan, as the day change does.
- **One planner, always the whole store (Gemini A2).** Every pass, including `refreshAfterDataChange`,
  a single habit's edit, an un-check, a check-in synced from another device and a notification
  action, runs the full `ReminderPlan.plan` over every reminder-on habit plus the Daily Reminder, with
  each habit's quiet days as input, then replaces only the habits whose request set changed. A
  per-habit re-plan could not keep the budget order or the evening overlay, and would leave a stale
  `.n<w>` after an undo or a synced un-check.
- **Restore:** the plan is computed from scratch from the habits and today's day-key, so the next plan
  on a later day (launch, foreground, Mac activation, day change, a save, a notification action,
  background refresh) has no stale overlay: the bare request comes back and the one-shots go. An
  un-check today removes today's overlay at once.
- **Never under-fires** (the test's definition): for every reminder habit and every due day from
  tomorrow to today+7, some kept request fires that day. The one residual: if the app does not run at
  all for 8 or more days after a quiet day, that weekday is silent from the second week until the
  next run. Recorded as risk 1.
- **Budget:** the base plan is placed first, exactly as today. Overlays, **the Daily Reminder's
  included** (it reserves only its one base slot in `64 - 2 - 4`), are added in order of today's
  reminder time while the total stays ≤ 58; a habit whose overlay does not fit keeps its base request
  (it over-fires today). **When the base plan alone is over budget, nothing is overlaid and the plan is
  exactly today's.**
- **Ids and the prune (Gemini A1, confirmed at NotificationService.swift:452-505).** The prune's keep
  set is computed before the center answers, so a widget overlay written in that window would be
  removed as an orphan and the habit would have **no** request. So:
  - `ReminderPlan.allIdentifiers(for:)` gains `.n1`…`.n7`; a new `allEveningIdentifiers` lists
    `stride.daily.evening`, `.1`…`.7` and `.n1`…`.n7`, and `scheduleReminders`, `removeAllReminders`
    and every evening transition remove all of them first;
  - `Result.keep` names **every possible id** of every reminder-on habit (and the snooze), not only
    the ones planned, so the prune removes only orphans of deleted, archived or reminder-off habits;
  - stale shapes of a live habit are removed by its own replace step (`replaceReminder`, :406-414),
    on the center's serial queue, which diffs against what is pending.
- **The late-night grace:** a reminder credit for yesterday before 03:00 (`ReminderDay.lateNightGrace`,
  ReminderPlan.swift:199) quiets yesterday, never today.
- **`refreshAfterDataChange`'s contract changes:** it now re-plans the habit it is told about. Its
  comment (:643-644) and `testRefreshAfterADataChangeSetsTheBadgeAndClearsWhatIsDone`
  (NotificationServiceTests.swift:573-594) change with it.
- **The sheet-save race** during a prune (NotificationService.swift:506-511) applies to the new pass
  too; the overlay is applied per habit, never by a global remove-all.

**D5 — From the widget, and the two Today cards.**
- **Widget check-in** (`ToggleHabitIntent.perform`, StrideWidget.swift:95-149): after the save, it
  runs the same full plan as D4 (every reminder habit and the Daily Reminder, so a widget tap that
  makes or breaks a perfect day moves the evening overlay too), applies the changed habits, and reads
  the result back before returning.
  - It never builds notification text: for each changed habit it copies the content of **any** of
    that habit's pending reminder requests (bare, `.<w>` or `.n<w>`, never the snooze), with
    `userInfo["day"]` removed; for the evening, any pending `stride.daily.evening*` request. So the
    widget process never needs the app's language.
  - A habit (or the evening) with nothing pending to copy from is left alone: the app's next plan
    rebuilds it. That only over-fires or waits, never deletes.
  - When a habit becomes done, the widget also removes its snooze and withdraws its delivered banners,
    as `CheckInEffects.afterCheckIn` does in the app.
  - The planner moves into Shared (`ReminderPlan` is already there); the content builders stay in
    the app.
- **Inline cards** (one at a time, `InlinePrompts`, TodayCards.swift:19-31), in priority order:
  1. **Missed yesterday** (owner, P3): when today is selected and yesterday had at least one `.due`
     habit left open (not rest, not met, not started), on any day after the first check-in ever.
     "%lld habits not checked yesterday" with a "Show yesterday" button that re-anchors Today to
     yesterday (`shell.todayDate`), where each can be checked in place. Nothing is written until the
     user checks something. "Not now" hides it for the day. The late-night grace does not change it.
  2. **The week card** (Monday–Tuesday), unchanged.
  3. **Reminder offer:** when the system permission is not determined, no reminder is on, and the
     user has checked in on at least two different days. "Get a reminder each evening" with "Turn
     on": the tap calls `ensureReminderPermission` (the system prompt appears on the tap, which is
     rule 4's own exception) and turns on the Daily Reminder at its time (default 20:00). Declined
     or "Not now": never shown again on this device. On `.denied`, it is not shown.
- Dismissals stay in `UserDefaults.standard` and are read-only in automated runs (TodayView.swift:270-283).

**D6 — Weekly Review, step 2 (D9 of 1.4.2, corrected).**
- **Navigation:** ‹ and › from the week containing the earliest habit's `startDay` to this week. The
  selected week is `@State`; stats are read once from the cache for today and every week is read from
  that one entry (no rebuild per page). ‹ and › have `.help`, keyboard reach on Mac, and a11y labels
  "Previous week" / "Next week". A sweep flag `-openReview <yyyy-mm-dd>` opens any week.
- **The strip** (pure, `WeeklyReviewMath.dayStates`): done, missed, rest, before the start, future,
  today not yet done. Times-per-week: a day without a check-in is neutral, never missed. A count
  habit's partial day is missed in the past and open today. The strip agrees with the row's counted
  rate, or a user can disprove it (a test). It is **one accessibility element** with a summary value
  ("5 of 7 done, 1 rest day"): "of N" counts the days begun except today while it is open, and the
  rest days are every unscheduled day, a checked one included (11-27). Labels format day-keys with `HabitCalendar.utc` as `dates(of:)` does.
- **The strength chip:** `strengthChangePoints`, in `Color.readableText`.
- **Sections by group**, Ungrouped last, headers with the members' mean counted rate (the view passes
  `groupOrder`, which it does not today: WeeklyReviewView.swift:75-76).
- **At risk this week** (this week only): a tap dismisses the review, selects Today, re-anchors it to
  today, expands a collapsed group if the habit is in one (a UI preference write, allowed), and sets
  `shell.todayFocusHabitID`; Today consumes it with `.task(id:)` (it may be created after the value is
  set), scrolls, moves VoiceOver focus, then clears it. It writes nothing to the store.
- **Notes of the week and share as an image: moved to 1.5.1 (11-27, Gemini A8).** Notes need a
  kept-record note read inside HabitStats (the heatmap dot today means "any live record has a note",
  HabitStats.swift:76-78, :401-404), which is the riskiest change in X0 for the smallest gain. Their
  spec (RELEASE-1.4.2.md D9, and this file's history) moves with them.
- **Perfect days:** "N perfect days" for the week, from `DailyProgress` per day.
- **Mac:** the sheet's 420-pt minimum width holds the strip, the rate and the chip at the default
  size; at AX sizes the row wraps (a capture proves it).

**D7 — Today's at-risk words and order (D10 of 1.4.2, corrected).**
- **When at risk:** `WeeklyReviewMath.isAtRisk` (times-per-week by the creation week's share;
  daily and specific days: due, not done, past the evening time: the habit's reminder, else the
  Daily Reminder's, else 18:00). **Amended 11-27 (branch review):** a times-per-week habit is at
  risk only while its goal is still reachable and every remaining day is needed (`owed ==
  daysLeft`); out of reach (`owed > daysLeft`), the row reads the plain "1/3 this week" and the
  review does not list it, since "3 more · 2 days left" asks for what cannot be done.
- **Row words** (TodayView.swift:787-809 and `spokenDetail` :731-753), only when the selected day is
  today:
  - a times-per-week row not yet met: "1/3 this week · 2 more" (one key, `%1$lld/%2$lld this week ·
    %3$#@more@`);
  - at risk: "2 more · 2 days left" in `Color.readableText(hex: "#FF9500", …)`; "more" prints `owed`
    in the creation week; on the last day it reads "1 more · today", never "0 days left";
  - on a past selected day, "this week" counts from that Monday through the selected day, as the
    card above it does;
  - a daily or specific-days habit at risk: "Due today";
  - no copy names a weekday. The same words go in the row's accessibility value.
- **Order:** at-risk rows first within their section, latched in `@State` and recomputed only when Today
  becomes the active tab (`shellTabIsActive`, since iPad and Mac keep Today alive), the day changes,
  or the scene becomes active: the triggers ContentView already funnels into `shell.reanchor`
  (ContentView.swift:82-99). A check-in never moves a row in the same pass; new and deleted habits
  still appear and disappear.
- **Pro off:** identical (these words are free).

**D8 — Pro claims (D11′).**
- The Weekly Review sentence becomes "Weekly Review — any week at a glance: what improved and what is
  at risk." ("and your notes" joins it in 1.5.1, with the notes) on the paywall row (ProPaywallView.swift:495), the `.weeklyReview` subtitle
  "Look back at any week" (:453), the six STRIDE PRO blocks, the review notes and the IAP review notes
  (iap_copy.py, owner's go), with the test pins (:203-207, :244, :325) extended to the body in all 6
  locales.
- Habit Groups and Advanced Analytics stay word for word until 1.5.1.

**D9 — DEBUG seams.** TodayView gets the WeeklyReviewView pattern: `@Environment(\.statsCache)` and a
DEBUG `now`. NotificationService is injected (it is not `@Observable`). No DEBUG switch reaches a
Release build (`verify_archive.sh` already probes the sentinel).

## Data safety (each has a test)

1. The review, its taps, the cards and the at-risk order write nothing to the store: row counts and
   every `updatedAt` unchanged after each tap (hosted; no such test exists yet).
2. A widget check-in that loses its notification write leaves the store right; the app's next plan
   repairs the requests.
3. The upgrade from 1.4.2 keeps every reminder: `upgrade.sh --reminders` from 1.4.2 (24) on a
   non-quiet day sees the same ids as before; on a quiet day it sees the overlay and no bare id.
4. A lapsed or free user's Today is identical with Pro off (X0's words are free).

## Workstreams (exclusive files while running; `Shared/*.lproj` belongs to the integrator)

| V | Scope | Files | Tests | Size |
|---|---|---|---|---|
| **V0** scaffold | 1.5.0 (25) in project.yml; baselines on Xcode 27.1 (StrideTests in both zones, hosted, a11y); this file; the draft PR into `main` | project.yml, RELEASE-1.5.0.md | baselines recorded | S |
| **V1** pure rules | D1 `DailyProgress`; `isAtRisk` and perfect days through it; `WeekGoal` prints `owed`; the strip `dayStates` and its summary; navigation bounds | Shared/DailyProgress.swift (new), Shared/WeeklyReviewMath.swift, StrideTests/DailyProgressTests.swift (new), StrideTests/WeeklyReviewMathTests.swift | every state × binary/count × zones; tpw met Fri–Mon; created today; exact-UTC-midnight key; strip = counted rate | M, first |
| **V2** reminders and badge | D2's badge, Dock and widget; D4; D5's widget write; the `dockLabel` test; `upgrade.sh --reminders` and its README learn the overlay | Shared/ReminderPlan.swift, NotificationService.swift, StrideWidget/Sources/StrideWidget.swift, Shared/WidgetTimelinePlan.swift, scripts/sim_e2e/upgrade.sh, scripts/sim_e2e/README.md, their tests | ReminderPlanTests (overlay per state, `keep`, over budget unchanged, never-under-fires, zones and DST, the grace); WidgetTimelinePlanTests (entry day-keys, Monday reset); NotificationServiceTests (badge, check-in re-plan, perfect-day evening, `dockLabel`); NotificationActionHandlerTests | L, after V1 |
| **V3** Today | D2's card and "Rest day"; D5's two cards; D7's words, order and focus target; D9's seam | TodayView.swift, Views/TodayCards.swift, Shared/InlinePrompts.swift, StrideAppTests/TodayRenderTests.swift (new), TodayWeekCardTests | card = DailyProgress; card priority; no writes; words and readable orange; order latched across a check-in; focus scrolls and moves VoiceOver; Pro off identical | M–L, after V1 |
| **V4** Weekly Review | D6; `todayFocusHabitID` | WeeklyReviewView.swift, ShellState.swift, ContentView.swift, StrideApp.swift (`-openReview <date>`), WeeklyReviewRenderTests, ShellTests, StatsPerformanceTests | ‹ › bounds; rows = WeeklyReviewMath; strip one element; sections; the at-risk tap writes nothing; the any-week bound holds | M, after V1 |
| **V5** verification | D14-style `-demoPro` scenario additions (a missed yesterday, a met 3×/week, a perfect day); a11y sweep frames for any week, the cards and the at-risk rows; `mac_variant` captures in 6 locales; the contrast list; every variant tool through `one.sh` | Shared/DemoData.swift, scripts/a11y_sweep.sh, scripts/mac_variant/*, scripts/demo_check | free baselines unchanged; new frames; blank-frame check | M, after V3 and V4 |
| **V6** release | D8 lockstep; strings ×6 (integrator); What's New ×6; metadata; review notes; the Mac paywall at minimum width and its top band; DEV-PLAN and RELEASE-1.4.2 pointers; progress log | ProPaywallView.swift, metadata/, scripts/release.py, docs/review-notes-1.5.0.md, LocalizationSourceScanTests, this file | gates | M |

- **Critical path:** V0 → V1 → V2 → gate 3 (upgrade) → V6. V3 and V4 run beside V2 (no shared file).
- **Cut order at the 12-11 freeze** (the share image and notes already moved to 1.5.1): the reminder
  offer card; then any-week navigation (this week and last week stay); then the review's strip (rates
  and chips stay). X2's D1–D4 and the missed-yesterday card are not
  cut: they are the point of 1.5.0. If V2's overlay is not green, 1.5.0 ships D1–D2 and the cards, and
  D4 moves to 1.5.1 (reminders unchanged: they over-fire, as they do now).
- **Reviews:** a whole-branch review at the freeze: Gemini 4 Argon High and Gemini 3.8 Flash High via
  agy on a throwaway copy; Claude lenses: "a sentence a user can disprove" (strips, words, perfect
  days, Rest day), week and day boundaries in both zones, reminders never under-firing, rule 4, D11
  drift, l10n.
- **Builds and simulators:** one derived-data root per session; the persistent roots in
  `~/Library/Caches/Stride-build/` stay; devices by UDID from the global table with their locks; below
  30 GB free no device is booted (the owner empties the Trash).

## Release gates (1.5.0)

1. **Tests:** StrideTests in Tokyo and `TEST_RUNNER_TZ=America/Los_Angeles`; hosted; the server suite
   and `sync_rehearsal.sh` unchanged and green; kit selftest; CI green; xcodegen drift clean; the
   performance bounds hold.
2. **Parity (D2):** the fixture's remaining is equal on the card, the badge, the Dock label and both
   widget entries, in both zones.
3. **Reminders end to end** (iOS simulator, `notifications.py` on the pending store):
   - `upgrade.sh --reminders` from 1.4.2 (24), with the widget placed;
   - after a Today check-in, a widget check-in and a Mark Done: that habit's overlay is present and
     no other habit's requests changed;
   - a widget check-in during the app's launch prune (the A1 race, forced with a DEBUG delay): the
     overlay survives;
   - a time-zone change (`simctl` sets the zone): a full plan runs, every due day still has a request;
   - after a day change: the bare request is back;
   - a perfect day: the evening overlay; the next day: the bare evening request.
4. **Review (WR2/WR3 of 1.4.2, plus):** with `-demoPro`, ‹ once from this week: each habit's rate,
   strip and chip equal demo_check's last-week block; Yoga's strip shows no miss in a met week; the
   at-risk tap lands on Yoga on Today with VoiceOver focus.
   Without `-demoPro`: the review opens the paywall and Today's words still show.
5. **Captures:** a11y sweep (default and AX5) on iPhone 17 Pro Max and iPad Pro 13" for the review on
   three weeks, the cards and the at-risk rows; `mac_variant` in 6 locales at full and minimum width,
   the paywall included (the X4 fix). A review lens reads the PNGs.
6. **Rule 4:** no prompt or card appears unasked; the permission prompt appears only on the offer's tap
   or a reminder toggle; no `requestReview` change.
7. **D8:** the pins in 6 locales; ProLockedCard count unchanged.
8. **l10n:** every new key ×6 with plurals; a back-translation lens on the at-risk and card strings in
   ja and ko.
9. **[owner] Mac, carried (X4):** Badges off by hand once; `gate10-mac/tools/banner_check.sh`'s
   app-quit half (Mark Done on a banner with the app quit). Neither blocks submission; both are
   logged.
10. **Release mechanics:** signing preflight (`security show-keychain-info` and the 1-second codesign
    probe); `verify_archive --exported`; demo account check.

## Submission checklist (1.5.0)

- [ ] Gates 1–8 and 10 green on the final tree.
- [ ] `WHATS_NEW_BY_VERSION["1.5.0"]` ×6, then `release.py prepare 1.5.0`.
- [ ] `push_metadata.py 1.5.0` (D8's description blocks; the trial clause and keywords unchanged).
- [ ] Screenshots: only if a frame changed (the review's any-week frame is new; the others keep).
- [ ] `review_notes.py 1.5.0 --yes`: where the review is; that reminders stay quiet once a habit is done.
- [ ] IAP review notes, D8's sentence (`iap_copy.py`, owner's go).
- [ ] `build-appstore.sh all --upload`. **Never `ship.sh`.**
- [ ] `release.py finish 1.5.0 25 --platform IOS` and `--platform MAC_OS`.
- [ ] After approval: `release.py release 1.5.0`, merge to `main` with `--no-ff`, tag `v1.5.0`
      (annotated, on the tip), cut `release/1.5.1`.

## Calendar

| Date | Step |
|---|---|
| 11-27 | Cut, spike, plan (this file), owner P1–P3 |
| 11-28 to 12-02 | V0, V1; V2/V3/V4 start as V1 merges |
| 12-03 to 12-10 | V2, V3, V4; V5 captures as they land; V6 strings |
| **12-11** | Freeze; whole-branch review |
| 12-12 to 12-14 | Fixes; gates 1–10 |
| **12-15** | Submit iOS and Mac (fallback 12-17) |
| Approval | Release, merge, tag; 1.5.1 cut |
| 2027-01-11 | Readout 1 (D15 of 1.4.2: breakage and existence only) |
| **2027-02-12** | 1.5.1 submitted |

## Risks

1. **A weekday silent after 8+ days without the app** (D4's residual). It needs a quiet day followed by
   eight days without a launch, a foreground or a background refresh; the reminder returns at the next
   run. Accepted: the alternative (always seven requests) caps reminders at about 8 habits.
2. **Widget writes on a real device.** The spike ran on the simulator only. D5 reads back, and the app
   re-plans from scratch, so the failure mode is over-firing.
3. **iOS drops requests past 64 silently.** The budget test and the over-budget-unchanged test guard it.
4. **TodayView.swift is the hot file** (V3 alone in 1.5.0; X1 edits it in 1.5.1).
5. **The widget and the app plan at the same time.** Both run the full plan and replace only changed
   habits; the A1 keep rule stops the prune from deleting the other's writes; the worst case is one
   habit re-replaced by the next pass.
6. **The freeze is two weeks out.** 1.4.2's estimates ran 35–50 % low; the cut order protects 12-15.
7. **Apple's late-December slowdown.** Submitting on 12-15 leaves a week; if review stalls, 1.5.0 goes
   live in early January, still in season.

## Owner decisions

| # | Question | Answer |
|---|---|---|
| P1 | Split the old 1.5.0 so the daily loop is live before New Year? | **Yes (2026-11-27):** 1.5.0 = X0 + X2; 1.5.1 = X1 + X3 by 02-12 |
| P2 | Quiet when done: an overlay on the done day, always seven weekday requests, or not in 1.5.0? | **Overlay on the done day (2026-11-27)** (D4) |
| P3 | "Missed yesterday?": show yesterday on Today, or History per habit? | **Show yesterday on Today (2026-11-27)** (D5) |
| P4 | X5 (often together, two-column Pro cards, alternate icons, O17's group widget, offer codes) | Not in 1.5.0 or 1.5.1 by default |

Every ASC write and production step keeps its rule (the owner's standing delegation covers release
mechanics; credentials stay the owner's).

## 1.5.1 (26): Groups worth paying for, and the review notification (sketch)

Planned in full at its cut. Also in 1.5.1: the Weekly Review's notes (with a kept-record note read in
HabitStats, the heatmap dot's meaning aligned, HabitStatsParityTests and the performance bound with
notes) and the share image, moved from 1.5.0 on 11-27; D8's sentence gains "and your notes" then.
From the code survey of 11-27:
- **X1 needs no `@Model` and no wire change.** `HabitGroup` has `colorHex`, `sortOrder` and `touch()`
  (Shared/Habit.swift:338-380), and the push, pull, server upsert and schema carry both
  (SyncPushPlanner.swift:500-509; SyncReconciler.swift:477-484; server/routes/sync.js:778-792;
  server/db.js:76-85). Recolour and reorder are field writes plus `touch()`, as `reorderHabits` does
  (SettingsView.swift:1274-1286).
- Stats selection is a habit UUID (ShellState.swift:51); "All / groups / habits" chips widen it (view
  state only). Stats already reads the cache twice per render (OverallStatsCard :265 and the detail
  :137): "one cache read per render" becomes "one read feeds the summary and the Overview".
- A second ProLockedCard breaks the "exactly one" pin (LocalizationSourceScanTests.swift:210-211)
  unless it changes in the D11 commit.
- The rehearsal digest compares groups as `name|sortOrder` only (scripts/sync_rehearsal/Harness.swift:
  363-364, :378-379): `colorHex` joins it before the recolour scenario, or a failed recolour passes.
- Today's "2/3" reads `DailyProgress` (D1).
- **X3:** no notification tap reaches the shell today (Shared/NotificationRouter.swift:64-82 routes
  global ids to `.none`); it needs a route, a Pro issuer and a bridge to the window. The review
  request is removed only after a StoreKit refresh, never from the cold `isPro == false`. The budget
  becomes 57 (ReminderPlanTests.swift:132-133 pin 58).
- **O18:** `server/ops/demo-add-habits.js` creates no `habit_groups` row; the demo group is an ops
  script change, add-only, while no review is open.

## Review log (Gemini 4 Argon High via agy, throwaway copy of `348a896`, 2026-11-27)

The first pass timed out at 15 minutes after one finding; a narrowed second pass returned eight. Each
was checked against the code by Claude before it was folded in.

| # | Finding | Verdict | Where it went |
|---|---|---|---|
| A0 | The Daily Reminder's overlay (+6) is outside the 58 budget | Accepted | D4 Budget |
| A1 | The prune's keep set is computed before the center answers; a widget overlay written in that window is pruned and the habit has no request (NotificationService.swift:452-505; ReminderPlan.swift:166-168) | **Accepted, confirmed in code** | D4 Ids and the prune; gate 3 |
| A2 | Re-planning one habit cannot handle undo, synced check-ins, a time edit on a quiet day, the budget order or the evening | Accepted | D4 One planner |
| A3 | `allIdentifiers(for:)` (ReminderPlan.swift:107-111) lacks `.n<w>`; the evening's removals name only the bare id | Accepted | D4 Ids |
| A4 | Gating the whole overlay on "today's time is ahead" breaks a week met after that time | Accepted | D4 per quiet day |
| A5 | Weekday and next-week date from a UTC key with the local calendar; `+7 × 86 400 s` across DST; no re-plan on a zone change | Accepted | D4 Dates and zones; gate 3 |
| A6 | The widget copies content from the bare request only; a snooze's `userInfo["day"]`; no evening; no snooze cancel | Accepted | D5 |
| A7 | Widget views read `completedCount`/`totalCount` directly | Accepted | D2 |
| A8 | Two weeks is short for V0–V6; pre-cut the share image, the notes and the reminder offer | Partly: share image and notes moved to 1.5.1; the reminder offer stays (small, free, the daily loop's point) | Scope, D6, D8, cut order |

## Progress log

- 2026-11-27, **cut and Phase 0.**
  - `release/1.5.0` cut from `m5/1.4.2` at `b206186`.
  - M6's gate checked: not met (no 426 floor ≥ 1.3.1).
  - Weekly snapshot run (see "Where things stand").
  - Three read-only code surveys (X0, X2, X1/X3) against `b206186`; their corrections are folded into
    "Spec corrections" and the 1.5.1 sketch.
  - **The X2 spike: yes** (D3).
  - Owner P1–P3 answered as recommended.
  - Gemini 4 Argon High reviewed the plan (Review log); A0–A7 accepted, A8 in part. The Weekly
    Review's notes and share image moved to 1.5.1.
- 2026-11-27, **V0–V4 merged** (worktree implementers, integrator review; StrideTests 864 → 895 in Tokyo
  and Los Angeles, 2 known skips; hosted suites compiled with build-for-testing, first run in CI: no
  simulator was booted, the disk was 16–21 GB free).
  - **V0** a47101c: 1.5.0 (25); draft PR JasonYeYuhe/Stride#13.
  - **V1** f56ec70 + cbd0e28: `DailyProgress`; strip, perfect days, bounds, `owed` and `isLastDay`.
    Integrator's call: `.metForWeek` reads `owed == 0`, so a first week's met share is never counted
    as remaining while the row prints no "more".
  - **V4** 4f1e6e7: the review pages any week (⌘← ⌘→), one strip element per habit, the strength
    chip, group sections, perfect days, at risk → `shell.focusOnToday`. Strings ×6 d73f09a.
  - **V2** merged at 932da3f: badge, Dock and widget from `DailyProgress`; the D4 overlay planner;
    the widget's write; `upgrade.sh --reminders` learns quiet days (`STRIDE_E2E_REMINDER_QUIET`).
    `CheckInEffects.live` re-plans before the badge, so a lock-screen Mark Done goes quiet too.
  - **Adversarial review of V2** (Claude, read-only): no under-fire when every write completes.
    Fixed in 5e4eac4: the Daily Reminder is restored when nothing of it is pending (permission
    granted later, a cut-off widget write); both writers add before they remove; the widget and the
    app re-read the switches before writing; the evening is removed while off; snoozes beyond four
    shrink the overlays' budget; archived habits' ids are removed in the full pass. Accepted: an
    un-check in the last second before the reminder minute can lose that day's fire.
  - **V3** merged at dfefb96: Today's card from `DailyProgress` ("Rest day"), the three cards
    (missed yesterday → week card → reminder offer), the D7 words and the latched order, the focus
    target, the D9 seam. Integrator's call (acc6a48): with no day left to check in, the row reads
    the plain "1/3 this week", never "1 more · today". Strings ×6.
  - **Left for V5/V6:** `-inlineCard missed|reminder` sweep flags, the `-demoPro` scenario
    additions, captures (need a simulator: the disk must be back above 30 GB), D8's lockstep, the
    Mac paywall at minimum width, What's New, metadata, review notes.
- 2026-11-27, **V6 copy** (no ASC write, nothing pushed). StrideTests 895 / 2 skipped / 0 in Tokyo
  and Los Angeles; StrideMac builds; `test_release.py` 18 OK.
  - **D8 lockstep** 6cc0f0f: the paywall row, the `.weeklyReview`/`.today` subtitle "Look back at
    any week", the catalogs ×5 (the two retired keys replaced in place), the six STRIDE PRO
    bullets, `iap_copy.py`'s note text, and the pins (the Weekly Review body word for word ×6).
    en-US and es-ES were at 3,991 and 3,981 characters, so each lost a few words elsewhere (en:
    "or a fresh start"; es: four small cuts) and is at 3,997 and 3,996.
  - **What's New** 4b0f424: five lines ×6, free first, no trial.
  - **Review notes** `docs/review-notes-1.5.0.md`: the trial sentence now says Yearly has the
    7-day trial (live since 11-26), still conditional on StoreKit and eligibility.
  - **Left:** the Mac paywall at minimum width (needs a capture), the ja/ko back-translation lens
    on the new copy (gate 8), `iap_copy.py` and `review_notes.py` sends (owner's go, at submission).
- 2026-11-27, **CI green on the hosted suite** (aac3cd0: 439 passed, 0 failed, 20 skipped — the known
  StoreKit ones). The first CI run of V2–V4's hosted tests had failed 6:
  - BackgroundSyncTests: an after-sync pass in `.active`/`.inactive` returned before the full plan
    had written (since 1.5.0 `apply` writes from the center's callback); it now awaits
    `scheduleAllHabitRemindersAndWait`, still without a prune. A real fix: an `.inactive` run (Mark
    Done over a frontmost Stride) can be suspended right after it returns.
  - NotificationActionHandlerTests: expected the bare id after a Mark Done; it now expects D4's
    overlay while the reminder time is ahead (test updated).
  - TodayRenderTests ×4: the cards are accessibility containers, which the test's lookup never
    matched (the cards were on screen). Lookup fixed; both D5 cards appear, act and dismiss.
  - The fixer ran the hosted suite on the already-booted iPhone 17 Pro under its lock (no boot);
    that device now holds an unsigned Debug 1.5.0 host instead of the kit's 1.4.1 ad-hoc build:
    `app.sh reset` and rebuild before the next upgrade gate on it.
- 2026-11-27, **gate 8 (back-translation, Claude lens)**: no meaning errors in ja, ko, zh. Fixed
  (1ecc892): es "Faltan 1" (verb agreement) → "N más" / "vence hoy"; ja and ko "Due today" lost the
  urgency (今日中に, 오늘 해야 함); zh "At risk this week" as a list header (…的习惯); ja What's New
  line 2 names "that habit's" reminders; minor wording (ko, zh spacing, ja/ko perfect days).
- 2026-11-27, **X4 Mac paywall** (dee9348): no NavigationStack on the Mac (it drew a blank ~48 pt
  title band), the close button in the top-right corner instead of a 63-pt bottom bar, ideal height
  570 → 634. At 600×700 the Yearly card ends ~430 pt and the bar starts ~497 in every state.
  Captures (en, ja; min and full; six fixtures) in `~/Library/Caches/Stride-build/plan-1.5.0/
  mac-paywall/`; the variant's container restored and hash-checked. iOS unchanged.
- **Still open for 1.5.0:** V5 and gates 3, 4, 5 need simulators (iPhone 17 Pro Max, iPad Pro 13",
  the kit's iPhone 17 Pro for `upgrade.sh --reminders`), blocked while the disk is under 30 GB free
  (16–17 GB on 11-27); the whole-branch review; gate 9 (owner, Mac); gate 10 and submission.
- 2026-11-27, **whole-branch review, first pass** (Gemini 4 Argon High, "a sentence a user can
  disprove", throwaway copy of `ab7b191`): 8 findings; 6 real and fixed in 80908f7 — times-per-week
  at risk only while reachable (`owed == daysLeft`; the demo's Yoga data moved so a weekend capture
  still has an at-risk row); no times-per-week habit in the missed-yesterday count; a past day's row
  counts through that day; Today keys `now` once (an exact UTC midnight read as tomorrow, proven by
  a hosted test that fails on the old keying in Los Angeles); the strip's rest days and its "of N".
  Not real: the row's check state already agrees for a target-0 count habit (`isCompletedOn` requires
  a target > 0), now pinned by a parity test. Rejected: "100 % beside At risk" (the header says "so
  far"). StrideTests 900 / 2 skipped / 0 in both zones; TodayRenderTests and WeeklyReviewRenderTests
  33 / 0 on the iPhone 17 Pro.
- 2026-11-27, **hosted suite 460 / 0 on the iPhone 17 Pro** (514e3f0). CI after V6 had failed 3:
  the paywall subtitle pins still read "See how your week went" (V6 missed two hosted tests); the
  review's at-risk tap test kept a fixture the 80908f7 rule made unreachable (Swim now owes exactly
  the days left); `HabitHistoryTests`' over-cap note test was a timing race, not a regression: after
  "Discard Changes" UIKit refocuses the note field and the page scrolls, so the lazy month grid
  drops yesterday's cell from the tree (failed 1 in 25 under load; 40/40 after waiting for the
  page to settle). Noted, not fixed: that refocus makes the keyboard flash after Discard Changes
  (cosmetic, no data lost).
