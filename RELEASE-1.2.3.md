# Stride v1.2.3 — release record

App ID `6761262334`, bundle `yyh.stride.habittracker`. Build 17 on both platforms.

1.2.2 (build 16) reached `READY_FOR_SALE` on both platforms on 2026-09-15, and this
release fixes what the audit run against it found.

## Why this release exists

`AUDIT-2026-09-09.md` (31 confirmed defects, adversarially verified) was run against
1.2.2 the day it went to review. Everything in the must-fix list is here, plus the
should-fix items that touch data. Three things ran ahead of the build because they are
server-side and reach every installed client without an update.

## Server (deployed 2026-09-15, no client update needed)

### Ids were stored in two different cases — `0b21cb6`

Swift's `UUID.uuidString` is upper case; `crypto.randomUUID()` is lower case; the id
columns are `TEXT` with BINARY collation, so `"abc"` and `"ABC"` are different rows.
Every id the server generated itself — `seed-demo.js`, the REST create routes — was
lower case, and the whole App Review demo account was seeded that way.

That broke the demo account in both directions: shipped clients compared ids as raw
strings, so its 133 check-ins matched no habit and a full pull deleted the device's
own history; and once 1.2.3 normalises ids, its next push would send them upper case,
find no `ON CONFLICT(id)` match, and insert every habit and entry a second time.

`migrations/canonicalizeIds.js` upper-cases every stored id inside `migrateIfNeeded`'s
transaction, with foreign keys deferred to COMMIT. It refuses to run outside a
transaction, and if any lower-case id already has an upper-case twin it logs and
changes nothing — a startup migration must never throw (v2's did) or guess a merge.
Production: 139 values re-keyed, 6 habits / 133 entries unchanged, `foreign_key_check`
empty.

### One timestamp column doing two jobs — `5a5b712`, `03972ba`

Each table got it wrong in a different direction:

- **habits and groups** stored the device's edit time, and `?since` filtered on it. A
  rename made offline on Monday and pushed on Wednesday sorted *before* the cursor of
  every device that synced on Tuesday, so those devices never received it — not on the
  next sync, not ever.
- **entries** stored only server time, so nothing could tell a newer check-in from an
  older one and the last device to push won. An iPad coming back online with "Water
  2/8" from the morning overwrote the 8/8 logged on the phone that afternoon, then the
  next pull propagated the 2 back.

`client_updated_at` (edit time) now decides conflicts; `updated_at` (server time) drives
the feed, and only moves when a push actually changes the row — every client pushes a
full snapshot every sync, so bumping unchanged rows would refill every other device's
incremental pull. Pushes with no entry `updatedAt` (every client ≤ 1.2.2) are stamped
`now` and keep last-push-wins.

Two more on the pull side: timestamps go out at whole seconds, because every shipped
app parses with a default `ISO8601DateFormatter`, which returns nil on fractional
seconds — the entire demo account is server-stamped, so a fresh sign-in believed every
demo habit was created *today* and its 30-day rate, Weekly Review and trend chart all
started from today. And `?since` is normalised before the string comparison, since
`"…:18Z"` sorts after `"…:18.500Z"`.

**Found by rehearsing on a copy of production**, not by the test suite: all 133 demo
entries had `updated_at` NULL (`seed-demo.js` never wrote it, and the column is
nullable on a database upgraded from before it existed). Those rows were already
invisible to every `?since` pull, and under the new guard `excluded >= COALESCE(NULL,
NULL)` is NULL, so no push could ever have changed them again. Backfilled from
`created_at`; the guards treat a missing edit time as oldest.

### Magic-link emails defaulted to a host with no DNS record — `78ba3ca`

`FRONTEND_ORIGIN` defaulted to `https://stride.colorarchive.me` in two places. The
domain has one A record, for `stride-api`. `/login` — which shows the token for
copy-paste and does not consume it — is served by this process, so a user following a
dead link had no way to finish signing in: the app asks for a token they can never see.
Production sets the variable correctly, so this was one lost `.env` line away from
breaking every login email. `origins.js` now owns the value, both jobs it does (CORS
allowlist, emailed link), and warns at startup when it is unset in production.

## Client

| Fix | Commit |
|---|---|
| Reconciler tested for real (it was tested through a hand-copied replica that had drifted); ids compared case-insensitively; `Dictionary(uniquingKeysWith:)` instead of the trapping initialiser; deletion tombstones cleared only after the push succeeds | `72ccb74` |
| One check-in routine for the list, widget, watch and Siri — tapping a count habit from the widget deleted the whole logged day | `7c601c0` |
| A purchase that fails verification raises an error instead of vanishing; entitlements read before anything network-bound | `8d4c8ad` |
| Deleting or archiving a habit cancels its reminder; launch prunes orphaned ones | `0ecfd84` |
| Stats hold the selected habit's id, not the model object | `773522e` |
| Best streak, 30-day rate, the 8-week trend and Weekly Review follow each habit's schedule | `44d97e7` |
| Entry edit times on the wire; cursor from the server's clock minus 60 s; timestamps with milliseconds parse | `777b64c` |
| Today re-anchors to the new day; the widget reloads on every `ModelContext.didSave` | `5bb8b73` |
| 175 UI strings translated into es/ja/ko/zh-Hans/zh-Hant, plus the code that could never have been translated | `6ede75c` |
| VoiceOver pass across every view, and the in-app language picker reaching String(localized:) | `3093199` |

### Accessibility, and the bug the reviewers found under it

Twelve agents audited one view each, edited it, and had the diff reviewed by an independent
skeptic. That pass is in `3093199`; the finding that mattered most was not an accessibility
defect at all:

**The in-app language picker never reached `String(localized:)`.** It only sets
`.environment(\.locale)`, which SwiftUI applies to `LocalizedStringKey` — `String(localized:)`
reads the system language, and nothing writes `AppleLanguages`, so the "Restart the app for the
change to fully take effect" note did not help either. Running the app in Japanese on an English
device drew a Japanese screen under an English "Today" title. `LanguageManager.bundle` +
`appLocalized` / `appCalendar` now resolve strings and weekday names through the picked
language; Siri replies and the widget deliberately stay on the system language.

The VoiceOver work itself: a count habit's row announced "not completed, double tap to toggle
completion" while its increment button was swallowed by `.combine`; the day picker read
hardcoded English weekday names over duplicate single letters; Settings, Weekly Review, Login,
Templates, Onboarding, the widget and the watch had no annotations at all; and the Stats
Insights rows were `String`, so `Text` rendered them verbatim English in every language.

Triaged OUT of the agents' diffs, as behaviour changes wearing accessibility clothes:
`.textContentType(.oneTimeCode)` on a token that never arrives by SMS, a hint restating the
footer under it, and a stepper value repeating its own label. Two streak badges that drew "12d"
while speaking "12 week streak" now draw "12w".

### Localization, and why the export tool could not be trusted

`xcodebuild -exportLocalizations` (Xcode 27) reported `Text("\(n) check-ins")` as
`"%@ check-ins"` and listed strings that are plainly used ("Cancel", "Delete") as
unused. The runtime keys were checked directly instead — `Mirror` on
`LocalizedStringKey` gives Int → `%lld`, String → `%@`, Double → `%lf` — and the
missing-key list was built by scanning the source against that.

Three shapes of code could never have been translated, and adding catalog entries
would not have fixed them:

- a ternary nested **inside** an interpolation (`"…, \(done ? "completed" : "not
  completed")"`) is a plain `String` argument, so the phrase is `%@` and the words are
  never looked up;
- `"\(streak) \(habit.streakUnit) streak"` spliced the English unit into every
  language — now `%lld day streak` / `%lld week streak`, in the app and in Siri;
- `OnboardingPage` and `PricingCard`'s badge/subtitle were `String`, which `Text`
  renders verbatim.

Templates now show and save a localized name, so a Japanese user adding "Drink Water"
gets a habit called 水を飲む.

## Tooling and CI

- **`release.py finish` could exit 0 without submitting** — `9d51615`. `submit()` took
  the first open review submission and, if it was `WAITING_FOR_REVIEW` or `IN_REVIEW`,
  printed "nothing more to do" without checking which version it held; with an older
  version in review the new one was attached and never submitted. Its "already in this
  submission?" check also read item relationships from a request without
  `include=appStoreVersion`, which returns them empty — always false. It now returns
  whether the target version is actually submitted, and `finish` exits 1 naming every
  platform that did not get there.
- **The Swift tests had never run in CI** — `1fe964f`. Only the server suite and a
  macOS compile ran; `TimezoneTests`, written for exactly the day-key bug that shipped
  in 1.2.1, ran nowhere but this Mac. `StrideTests` is host-less, so it now also builds
  for macOS and CI runs it — GitHub's runners have no iOS simulator runtime matching
  the SDK. The job fails unless a non-zero number of tests report 0 failures, because
  `xcodebuild` can exit 0 having run nothing.
- **ASC credentials out of the scripts** — `cc4449b`. Three scripts hardcoded the key
  id and issuer id and pointed at a `.p8` inside iCloud Drive's Downloads folder.

## Metadata

The description rewritten in `ad9abed` is now **pushed to ASC** for both platforms in
all six locales. What the store sold before this release, in every language: unlimited
habits against a 5-habit free cap, Pro-only widget styles, smart context-aware
reminders, and Pro-only cross-device sync — four features that do not exist. Only
Habit Groups, Advanced Analytics and Weekly Review are gated, and none of the three was
mentioned. `PrivacyInfo.xcprivacy` (`aff73c2`) declares the email address and habit
content the app uploads; the ASC App Privacy questionnaire was updated on 2026-09-10.

## Verification

- Server suite 302/302; Swift tests 119 + the accessibility pass, on macOS and on an
  iOS simulator; iOS / macOS / watchOS all build.
- Server changes rehearsed against a copy of production on the host before deploying —
  that is what caught the NULL `updated_at`. After deploying, the live demo account
  pulls 6 habits and 133 entries, all ids upper case, all 133 matched to a habit.
- Japanese launched on a simulator to confirm onboarding and Today actually render
  translated.

## The demo account

Re-seeded 2026-09-16 (its check-ins are generated relative to seed time, and they had run
2026-05-09 … 06-07 — a reviewer would have seen zero streaks and 0% rates). The login token is
unchanged. Verified end-to-end by compiling the SHIPPING reconciler against the live account
and printing what a reviewer's device computes:

```
pulled: 6 habits, 133 entries → after reconcile: 6 habits
  Drink 8 Glasses  records=24 streak= 4 best= 5 rate=80%  created=2026-08-02
  Journal          records=25 streak=11 best=11 rate=83%  created=2026-08-02
  Meditate         records=19 streak= 2 best= 3 rate=63%  created=2026-08-02
  Morning Run      records=23 streak= 5 best= 5 rate=76%  created=2026-08-02
  Practice Guitar  records=15 streak= 2 best= 2 rate=50%  created=2026-08-02
  Read 30 Minutes  records=27 streak= 3 best=11 rate=90%  created=2026-08-02
habits with no history: 0 | zero current streak: 0 | zero 30-day rate: 0
```

`created=2026-08-02` rather than today is the millisecond-timestamp fix showing end to end: on
1.2.2 every one of these habits would have been dated today, with a 30-day rate computed from a
single day. Re-seed again if review slips by more than a few weeks.
