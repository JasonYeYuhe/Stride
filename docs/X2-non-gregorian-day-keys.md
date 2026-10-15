# X2: non-Gregorian day keys — investigation (2026-10-15, read-only, HEAD 0d61b1c)
- `main.swift`, `mig/main.swift`, `streak/main.swift`, `utc0/main.swift`, `bench/`, `mapbench/` are compiled against the repo's real `Shared/DateHelpers.swift`.
- `exp/exp.js` runs against a copy of `server/` in `srv/` with its own `stride.db`. That server process is stopped.

## Bottom line
- **Every shipped build since 1.2.0 writes wrong day keys** on a device whose system calendar is not Gregorian. Locally the keys are consistent, so on-device streaks mostly work for Japanese, Buddhist and ROC. But weekday math is wrong for every calendar. Calendars with different months also merge some days, skip others and go backwards, so daily streaks cannot last.
- **Some regions get this by default.** Foundation's region defaults, verified on this Mac: th_TH → buddhist, fa_IR and ps_AF → persian, ar_SA → islamic-umalqura. ja_JP, zh_TW and he_IL default to Gregorian, so those users only get it by opting in.
- **The server stores whatever date string arrives.** There is no validation, so "2026-02-30" is accepted too.
- **There is a short window to act.** No real account had synced before #8 was deployed on 2026-10-15 (RELEASE-1.4.1.md:23), so the server holds about zero wrong rows today. From now on, every non-Gregorian user who signs in pushes them.
- **No data has been lost yet.** Measured: every key written so far can be traced back to its real day.

## 1. Code paths
**Where a key is built from the device calendar (these are the only four):**
- `Shared/DateHelpers.swift:32-37` `dayKey(for:localCalendar:)` and `:50-54` `dayKey(forInstant:calendar:)`.
- `Shared/WidgetTimelinePlan.swift:129-133` `dayKey(of:in:)`.
- `Shared/HabitCheckIn.swift:675-695` `HistoryLink.target`. It was deliberately made to round-trip through the device calendar, and `StrideTests/HabitCheckInTests.swift:1101-1124` and `StrideAppTests/HabitEntryCommitTests.swift:505+` pin the keys "0008" and "2569". Both tests flip with the fix.
- The feeders all pass `Calendar.current` or `appCalendar`, and `appCalendar` keeps the identifier (`LanguageManager.swift:144-151`):
  - `HabitRecord.init` (`Habit.swift:311`); `record(on:)`, `isCompletedOn` and `isScheduled(on:)` (`Habit.swift:141`, `:172`, `:189-197`)
  - `HabitStats.dayNumber(of:in:)` (`HabitStats.swift:342-346`), which feeds StatsCache (`StatsCache.swift:136`) and the widget's row inputs (`WidgetTimelinePlan.swift:173-207`)
  - `ReminderDay.resolve` (`ReminderPlan.swift:228-243`) and `CheckInEffects.swift:70-71`
  - `StrideApp.swift:371-376`, `StrideShortcuts.swift:135`, DemoData

**Weekday and week math run on the keys, so they break whenever a key's weekday differs from the real one:**
- `HabitStats.weekday`, `monday` and `isScheduled` (`HabitStats.swift:350-368`), `completionsPerWeekday` (`:634-638`), times-per-week weeks, and HabitScore's inputs.
- `Habit.isScheduled` (`Habit.swift:194`).
- TrendCard (`StatsView.swift:449-473`) and the Insights momentum (`:562-567`). The weekday labels at `:548` and `:626-640` are correct names attached to wrong counts.

**Parsers with a year bound:**
- `DataBackup.dayKey` accepts 1970–2100 only (`DataBackup.swift:443-449`). Restore validation goes through it and refuses the whole file (`:377-379`), and so does a snooze's carried day (`NotificationRouter.swift:100-102`).
- The X2 note's "SyncDelivery 1970–2069" bound is for edit stamps only (`SyncDelivery.swift:249-289`). It falls back losslessly to `SyncTimestamp`, so it does not touch keys.
- One stamp side effect: a record never edited since before 1.2.0 stamps as `updatedAt ?? date` (`SyncDelivery.swift:73`). Its `client_updated_at` is then year 8 (it loses every last-write-wins comparison) or 2569/5787 (it wins every comparison forever).
- `HistoryLink.dateParts` accepts years 1–9999 (`HabitCheckIn.swift:703-726`).

**Serializers (always Gregorian; they faithfully write the wrong key):**
- `dayStringFormatter` uses en_US_POSIX and stays Gregorian, verified under `-AppleLocale ja_JP@calendar=japanese`, `th_TH`, `fa_IR`, `ar_SA` and `he_IL@calendar=hebrew`.
- Push: `SyncPushPlanner.swift:168`, `:492`. Pull: `SyncReconciler.swift:694` parses any 4-digit year and `:415-424` stores it verbatim.
- Backup export: `DataBackup.swift:813-817`. The CSV puts the wrong year in its date column (`:734`) beside a correct-year `created_at` (`:771-777`).

**Server:**
- `server/routes/sync.js:889` checks only `!e.date`.
- The upsert is `ON CONFLICT(habit_id, date)` (`:607-621`); the table has `date TEXT` and `UNIQUE(habit_id, date)` (`server/db.js:64-74`).
- The legacy REST route validates dates (`routes/habits.js:197-203`), but "0008-10-15" passes it.
- The demo seed and top-up write Gregorian UTC dates.

**Calendar-safe, no change needed:**
- `startOfDay`, `isDate(inSameDayAs:)` and day addition: TodaySelection, ShellState, `WeeklyReviewView.swift:10-18`, `HeatmapLayout.swift:32-41`, `nextLocalMidnight`.
- Notification triggers (hour, minute, weekday).
- Weekday numbering is identical in all 15 calendars (measured).
- Display-only uses are fine: `TodayView.swift:282` day numbers, symbols, formatted dates.

**An extra case in UTC+0 zones** (London, Dublin and Lisbon in winter; Reykjavik; Accra):
- `isDayKey` (`DateHelpers.swift:33`) passes a local midnight through as a Gregorian key.
- Strip-picked days (`TodayView.swift:304`, `:315`), the heatmap and Weekly Review therefore key 2026-12-15.
- Today's default `now` (`ShellState.swift:82`) keys 0008-12-15. So one device mixes two kinds of key (measured).

## 2. Experiments
Today, 2026-10-15 12:00 in Tokyo (a Thursday):

| calendar | key | key's weekday | backup/snooze parser |
|---|---|---|---|
| japanese | 0008-10-15 | Mon | refuses |
| buddhist | 2569-10-15 | Sun | refuses |
| roc | 0115-10-15 | Mon | refuses |
| islamicCivil | 1448-05-03 | | refuses |
| islamicUmmAlQura | 1448-05-04 | | refuses |
| islamic | 1448-05-05 | | refuses |
| hebrew | 5787-02-04 | | refuses |
| persian | 1405-07-23 | | refuses |
| indian | 1948-07-23 | | refuses |
| coptic | 1743-02-05 | | refuses |
| ethiopicAmeteMihret | 2019-02-05 | | accepts |
| ethiopicAmeteAlem | 7519-02-05 | | refuses |
| chinese | 0043-09-06 | | refuses |

**2025–2028, 1,461 real days:**

| calendar | days sharing a key | backward steps | real days with no key |
|---|---|---|---|
| japanese / buddhist / roc | 2 (only 2028-02-29 + 03-01) | – | – |
| islamic family | 6–10 | – | 48–50 |
| persian, indian | 38 each | 12 | 19 |
| coptic, ethiopic | 56 | – | 28 |
| chinese | 126 (leap months) | – | 50 |
| hebrew | 242 (Elul collides with Tishri every year) | 8 | 134 |

The key's weekday is wrong on every day for Japanese (shift of 3–4), Buddhist (2–3) and ROC (4–5).

**Streaks**, checking in every real day from 2026-03-30 to 10-15 (200 days):

| calendar | daily | Mon/Wed/Fri |
|---|---|---|
| gregorian | 200 | 86 |
| japanese | 200 | 1 |
| buddhist | 200 | 0 |
| roc | 200 | 1 |
| islamicUmmAlQura | 34 | – |
| hebrew | 4 | – |
| chinese | 6 | – |
| ethiopicAM | 5 | – |

**1.2.0/1.2.1 only:** `dayKey` had no idempotency check, so re-keying an existing key drifted: 0008 → 0637, 2569 → 3112, Hebrew 5787 → 9547.

**Server copy:**
1. Pushing six same-day entries in six calendars: all applied, stored as six rows, all served by pull.
2. Same id pushed with the corrected day, where another id holds that day: merged into the other row with an alias, and **the wrong-day row stays**.
3. Same id with a corrected day nobody holds: **`row_error`**, so 1.3.1+ quarantines the row.
4. New id plus a tombstone of the old one: works; only the wrong-day row is deleted.

## 3. What a non-Gregorian user gets, by version
- **1.2.0/1.2.1:** wrong keys, plus the re-key drift in the read paths (rates read 0%, schedules random). Their pushes are now refused with 426 (#9).
- **1.2.2:** wrong keys, consistent on the device. Pushes are refused with 426.
- **1.2.3 and 1.3.0** (full-snapshot pushes): the server stores the wrong-year rows verbatim.
  - 1.3.0 adds backups; restore refuses the user's own backups (invalidDate) for 13 of 14 calendars.
- **1.3.1 and 1.4.0:** same server effect.
  - 1.4.0 adds reminders: a snooze's carried day is refused, so it falls back to the delivered day.
  - The Mac 1.4.0 build in review has the same code.
- **HEAD:** a Gregorian device holding year-8 rows starts its strength walk in year 8. That is about 737,000 days, roughly 18 MB of arrays per habit (`HabitScore.swift:147-164`), once W3 reads strength.
- **Any version, second Gregorian device:**
  - The other device's rows are invisible: years in the past, or Buddhist/Hebrew/Amete Alem years in the future, which HabitStats ignores.
  - The same real day is two server rows, and neither device sees the other's check-ins.
  - Once that device has pulled one wrong row, its own backups are unrestorable too.

## 4. Weekday and month grids
- Weekday math (specific days, Monday weeks, weekday charts, Insights, times-per-week, TrendCard buckets) breaks for every non-Gregorian calendar.
- There is no month grid. The heatmap's rows and the Today strip use local instants and are correct. Only the calendars that share keys light two cells from one record.

## 5. Fix design
**(a) Day-key calendar.**
- `HabitCalendar.dayCalendar(c)` returns `c` when it is Gregorian, otherwise a Gregorian calendar with `c.timeZone`.
- Use it at the four build sites. Measured cost is 0.47 µs a call against 0.62 µs today, so no cache is needed. Gregorian keys come out byte-identical.
- The user's calendar stays only for display (symbols, day numbers, titles, labels) and for its time zone.
- HabitStats should also ignore days outside the window below when computing `startDay` (`HabitStats.swift:434-437`).
- **Never ship this change without the migration:** it would orphan every existing key of affected users.

**(b) One-time local migration.**
- Store a v3 flag in the App Group defaults, following `SharedModelContainer.swift:229`, and run it in `prepareStore` before `SyncService.prepareLaunch` (`StrideApp.swift:86-95`).
- **Detection:** any key before 2026-01-01 or after today+2 (the first commit is 2026-03-27).
  - The suggested "year < 1900 or > 2200" misses Indian (1946–1950) and Ethiopic Amete Mihret (2017–2021).
  - The window catches 203 of 203 lifetime keys for all 14 calendars.
- **Decoding:** build an inverse map by walking real days forward with the old formula.
  - Try `Calendar.current`'s identifier first, then the other 13. Building all 14 maps over 1,100 days takes 32 ms.
  - Where several real days share a key, pick the one on the local day of `updatedAt`, else the latest one on or before it.
  - Measured recovery over the app's lifetime: 100% with same-day stamps, 97.5–100% with stamps 3 days later.
  - Japanese, Buddhist and ROC keys stay unique until 2028-02-29.
  - The four Islamic variants produce the same keys 1 day apart, so the device's own variant goes first and the stamp breaks ties.
- **Applying:**
  - A record never delivered is re-keyed in place.
  - A delivered record gets a new id at the correct day, plus a tombstone for the old id queued after the save. This deletes only the wrong-day row, so it does not conflict with decision 7, which is about same-day duplicates.
  - A record held as `invalid_value` is re-keyed and its hold cleared.
  - Days that end up with duplicates follow decision 7.
  - Re-scan on every launch for rows pulled from devices still on old builds.
- **Widget:** `ExtensionStoreOpen` waits for the v3 flag, but only on non-Gregorian devices. The app writes the schema marker (`SharedModelContainer.swift:383-386`) before `prepareStore` runs, so without this the widget can read or write in between.
- **Restore:** decode out-of-window days (with new ids) instead of refusing the file.

**(c) Server.**
- Add a date guard after `sync.js:889`: canonical YYYY-MM-DD, a real date, 1970–2100.
  - Clients ≥ 1.3.1 get `invalid_value` per row, which holds it on the device (`SyncAnswers.swift:110-111`; Settings shows "A value the server doesn't accept", `SyncSectionView.swift:278`).
  - Clients ≤ 1.3.0 get the whole push refused with 426. A row-level skip would be deleted locally by their full-pull rule (`v1.3.0:Shared/SyncReconciler.swift:164-171`). A 426 is safe because their push and pull share one do/catch (`v1.2.3:Stride/Sources/Services/SyncService.swift:55-57`, `v1.3.0:Stride/Sources/Services/SyncService.swift:79-81`), and 1.4.0 is an available update.
- **No server-side data migration.** The server cannot know which calendar (Islamic variants, collisions), and devices match pulled entries by day (`SyncReconciler.swift:385`), so a rewrite alone gives every device duplicates with the same id.
- **Prod check (owner, read-only):** `SELECT substr(e.date,1,4) y, count(*), count(DISTINCT h.user_id) FROM habit_entries e JOIN habits h ON h.id=e.habit_id WHERE e.date<'2026-01-01' OR e.date>date('now','+2 days') GROUP BY y;`

**(d) Devices still on buggy builds after the fix:**
- With the guard, nothing new reaches the server. 1.3.1/1.4.0 keep their rows intact as held until they update; ≤ 1.3.0 stop syncing with their data intact.
- Without the guard, every fixed device deletes and recreates their rows, and their users see check-ins vanish after each sync.
- Ethiopic Amete Mihret passes the server's 1970–2100 rule; only the client's window catches it.

## 6. Risk, size and tests
**Risk:** a no-op for Gregorian users. Medium for affected users, from id churn in sync and the widget race.

**Size:** about 350–450 lines in the client plus about 600 lines of tests; about 40 lines in the server plus about 100 lines of tests; 3–4 rehearsal scenarios.

**Tests:**
- All 14 calendars across these zones: Tokyo, Los Angeles, UTC, London in winter, +14 and −11.
- Gregorian keys byte-identical; W1 goldens unchanged.
- Migration recovery checked against the experiment numbers; running it twice changes nothing; mixed stores; delivered vs undelivered vs held rows.
- The widget gate; restoring an old backup; the server guard by client version.
- Rehearsal and hosted runs launched with `-AppleLocale ja_JP@calendar=japanese`, `th_TH` and `he_IL@calendar=hebrew`.
- An in-place upgrade from 1.4.0 on a dedicated `Stride-NonGregorian` simulator. The widget only sees the global setting, so this needs its own device.

## 7. Recommendation
1. **Deploy the server guard now**, independent of any app release, before non-Gregorian users start syncing now that sign-in works.
2. **Ship the client fix in 1.4.1**, after X1 and before W3 (StrengthCard reads `startDay`).
3. **Not as a 1.4.0.x hotfix:**
   - Waiting loses no data, because the keys are exactly recoverable.
   - The guard stops the spread to the server and other devices.
   - The migration relies on 1.4.1's same-day merge from W2 and on X1.
   - Mac 1.4.0 is still in review.
   - A hotfix would duplicate every release gate for a small population.

   Reconsider only if the prod query finds real affected accounts.

**Owner decisions:**
- Guard semantics for ≥ 1.3.1: a per-row hold or a 426.
- New ids plus tombstones for delivered rows.
- The window's lower bound of 2026-01-01.

## 8. W10: the client half as built (2026-10-16, not merged; Q2)
- **Day calendar (5(a)).** `HabitCalendar.dayCalendar(c)` (`Shared/DateHelpers.swift`): `c` when
  Gregorian, else a Gregorian calendar in `c.timeZone` (nothing else is copied: weekday numbering
  is the same everywhere). Used by both `dayKey`s, `WidgetTimelinePlan.dayKey(of:in:)`,
  `HistoryLink.target`, and one site this report did not list: `HabitHistoryView.noon(ofDay:in:)`,
  which built a key's instant in the device's calendar (2026-10-15 as Reiwa 2026). Month grids and
  labels stay in the device's calendar.
- **Window.** [2025-01-01, today + 2], not this report's 2026-01-01: 1.4.1's History allows
  backfills into 2025, and History's floor is now capped at 2025-01-01
  (`HabitHistoryView.window`). `HabitStats.startDay` ignores record days before it, and
  `HabitScore.series` never starts before it.
- **Repair (5(b)).** `Shared/DayKeyRepair.swift`: `DayKeyDecoder` (inverse maps over the real days,
  the device's calendar first, then the 14 in a fixed order; ties by the local day of `updatedAt`,
  else the latest on or before it, else the earliest) and `DayKeyRepair.run`/`launchPass`, called
  every launch by `SharedModelContainer.repairDayKeysIfNeeded` in `prepareStore`, after the v2
  migration and before `SyncService.prepareLaunch`; flag `stride_daykey_migration_v3_done` in the
  App Group defaults. Choices beyond this report:
  - "May be on the server" is `syncedAt != nil` **or `restoredAt != nil`** (a restore that kept its
    ids may hold an id the server has at the wrong day).
  - When it has something to repair, the pass runs `SyncDeliveryMigration` first: a 1.3.0 store's
    rows are all "never delivered" until that rule marks what 1.3.0 pushed, and a row re-keyed in
    place and marked afterwards would be "delivered" at a day the server lacks.
  - A delivered row held for a reason other than `invalid_value` (row_error, not_owned, tombstoned)
    is left as it is for the user to resolve in Settings; the next launch takes it once it is no
    longer held. A never-delivered held row is re-keyed in place and re-held at its new stamp.
  - Merges use `HabitCheckIn.setChecked(nil, …)` on each repaired day with two records (decision 7
    as amended: no tombstone for the duplicate). Two different notes are left for the next write to
    ask about.
  - The new record keeps the old one's `updatedAt` (nil stays nil: its stamp becomes its real day).
- **Widget.** `ExtensionStoreOpen` refuses with `waitForApp(dayKeyRepair)` while the flag is unset
  on a device whose calendar is neither Gregorian nor ISO 8601; the app reloads widgets when the pass
  sets the flag or changes the store.
- **Restore.** `DataBackup.restoredDay`: a real day as it is; an out-of-window key any calendar
  wrote, read back with a new id (and no `restoredAt`; its old id's queued deletion is not
  withdrawn); any other canonical 1970–2100 day as before; anything else is still `invalidDate`.
- **Snoozes.** `NotificationRouter.day(from:)` is unchanged: corrected keys parse; an old key is
  refused or (Ethiopic) is neither today nor yesterday, so it never credits the stray day.
- **Residual.** A never-delivered row whose first push reached the server but whose answer was lost
  (pending until its next push) is re-keyed in place, and that next push is answered `row_error`
  (the server holds the id at the wrong day): the row is held. The window closes at the next
  successful push, so only an upgrade landing inside it is exposed.
- **Tests.** StrideTests `DayKeyCalendarTests` (14 calendars × 6 zones, Gregorian byte-identical,
  weekday and week math) and `DayKeyRepairTests` (decoder recovery, every record kind, merges,
  idempotence, tombstone after save, 1.3.0 order, the widget gate, restore, the strength floor);
  the two "0008"/"2569" tests flipped; hosted History window and noon; rehearsal K1 and K2.