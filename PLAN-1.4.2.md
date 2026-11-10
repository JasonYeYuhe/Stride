# Stride 1.4.2+ — Pro worth paying for

App ID `6761262334`, bundle `yyh.stride.habittracker`. **Plan dated 2026-10-27, revised the same day
after three reviews (Review log, at the end); no code yet.** Every code citation is at `7fbb3ec`, the
`m4/1.4.1` tip.

- **Branch:** `m5/1.4.2`, cut from the `m4/1.4.1` tip on the day 1.4.1 (23) is submitted for iOS.
- **Version:** **1.4.2 (24)** (RELEASE-1.4.1.md:297). project.yml:19-20 still says 1.4.1 (23).
  DEV-PLAN-1.3.md:54 still says "build 22"; W12 corrects it.
- **Scope of 1.4.2:**
  - **Wave A** (must ship): a trial-ready paywall, purchase and trial states, Pro that is right in a
    trial's first week, and Pro that a free user and the agent's sweep can see.
  - **Wave B** (out by default): the rest of DEV-PLAN-1.3.md M5 (`:1253-1276`): any week, at risk,
    notes, groups, and Today's free "N more". It comes in only if W0–W9 are merged and green on
    **2026-11-10** (D1).
  - Also in scope: the items of RELEASE-1.4.1.md's "1.4.2 backlog" (`:923-942`) that serve this goal,
    and two acquisition items that need no code: localized store screenshots and a keyword pass
    (D19).
- **Then 1.5.0 (25):** the free daily loop first, then Groups worth paying for, then the opt-in review
  notification. The order is fixed now (see 1.5.0); readout 1 (2027-01-11) can only reorder it for
  breakage.
- **M6 (skip days)** keeps its gate and ships in a release of its own (D18).
- This file is committed as `RELEASE-1.4.2.md` when `m5/1.4.2` is cut. W0 opens the draft PR into
  `main`.
- **Process (unchanged):**
  - no TestFlight and no owner device checks; the agent tests (hosted, `scripts/sim_e2e`, the a11y
    sweep, `scripts/mac_variant`);
  - releases are MANUAL;
  - every ASC write and production deploy needs the owner's go;
  - six locales for every string;
  - worktree implementers, then review lenses, then an adversarial verify.

## Why this plan

- **The premise, corrected.** Stride has never sold a Monthly or Yearly subscription. Its only Pro
  sale ever is one Lifetime, on 2026-09-06 (RELEASE-1.4.1.md:1122-1125).
  - The cancellations the owner saw belonged to ColorArchive and RoastMate, because ASC reports
    cover the whole account (NEXT_SESSION_PROMPT.md:11).
  - So the problem is not that payers leave. Almost nobody buys at all.
- **Volume** (measured 2026-10-22):
  - about 12 new iOS downloads and 27 updates in 30 days;
  - about 19 production installs of 1.4.0, with 0 crashes;
  - about 2 of 17 recent installs came back;
  - 2 ratings and 1 written review ever (RELEASE-1.4.1.md:1126-1128).
- **What volume allows.** The RevenueCat 2025 figures from the market mapper set the scale:
  - the freemium median download-to-paid rate is 2.18 %, so 12 downloads give about 0.26 payers a
    month;
  - even the Health & Fitness top decile (12.1 %) gives about 1.5 a month.
  - This plan can make Pro worth buying, and it puts more people in front of the store page (D19).
    It cannot produce a revenue curve, and "What success looks like" says so.
- **What a buyer meets today** (table below):
  - Pro is invisible until the user taps on it.
  - The paywall sells Lifetime and has no trial.
  - The Pro cards are at their thinnest in the first week, and that week is exactly the trial.
- **What the rules allow.** Rule 4 forbids anything modal that the user did not ask for
  (DEV-PLAN-1.3.md:34-38). The three gates stay the only Pro gates, and nothing free moves behind Pro
  (the non-negotiable constraints, :40-43). App Review adds one more: a home-made review prompt is
  out (Guideline 5.6.1, D13). That leaves five levers:
  - Pro that is true;
  - Pro that is seen inline;
  - a trial;
  - a weekly reason to come back;
  - a store page that more people can read in their own language.

  A 7-day trial always contains a Monday, so it always contains one Weekly Review moment (D12).
- **Calendar.**
  - January is the category's peak month. The source is HabitKit's developer, which is weak.
  - App Review is slow in late December.
  - The approved 7-day Yearly trial can be created only after a paywall that shows its terms is live
    (RELEASE-1.4.1.md:926-929).

  So the paywall ships first, and it waits for nothing else.

### What each gate gains

| Gate | 1.4.2 Wave A | 1.4.2 Wave B (if it comes in) | 1.5.0 |
|---|---|---|---|
| Advanced Analytics | True in week one: no pre-start bars, one tile for a young habit, Insights never hides and its empty text fits the habit's age, a level week reads "Level", weekday minimums, a record line. Seen: a preview on the locked card and a Pro chip | — | An Overview of all habits (ranking, combined trend); "often together" if the readout shows use |
| Weekly Review | Opens on last week until this week has 4 days to show; the change in points; highlights by change, only for a week with 4 counted days; one presenter; Today's Monday card leads to it | Any week, at risk, 7-day strips, strength chips, sections by group, notes, share | Opt-in Monday notification; perfect days, with one rule shared by every surface |
| Habit Groups | Buying from New Group continues into New Group | Sections in the review | Group Overview; progress on Today's header (free); colour, reorder and a delete confirmation; New Group in Settings; group widget (O17) |
| Paywall | Trial-ready, Yearly first, one button, terms and links beside it on the first screen, honest states, continues what the user wanted | — | Offer codes only if O12 changes |

## Scoring

Three independent drafts (value depth, conversion, retention) were scored from 1 to 5 on four
criteria:
- willingness to pay, with the most weight (40 %);
- feasibility for one developer with agents (25 %);
- risk to users' data and to App Review, where 5 is safest (20 %);
- measurability (15 %).

Every file:line claim in the drafts was checked at 7fbb3ec.

| Draft | WTP | Feasibility | Risk | Measurability | Weighted |
|---|---|---|---|---|---|
| Conversion | 3.5 | 4.5 | 4.5 | 4 | **4.0** |
| Value depth | 4.5 | 2.5 | 4.5 | 3 | **3.8** |
| Retention | 2.5 | 2 | 2 | 4.5 | **2.6** |

- **Conversion is the skeleton.**
  - Taken:
    - the funnel audit;
    - a pure `PaywallModel` with DEBUG paywall fixtures, so the presentation is pinned on macOS CI
      while StoreKit tests run only on iOS 18.5;
    - select a plan, then buy with one button;
    - the billed price as the largest price, with the per-month figure rounded up;
    - a success state with Continue;
    - owner sittings batched;
    - dated success measures.
  - Not taken:
    - moving all of M5 to 1.5.0. A trial user meets the Weekly Review on their first Monday, so M5
      stays as Wave B: out by default, in only if Wave A is green on 11-10;
    - web-UI IAP edits in 1.5.0. They are not needed, because the IAP copy names only the three
      gates (NEXT_SESSION_PROMPT.md:17).
- **Value depth supplies the Pro content.**
  - Taken:
    - the value line;
    - the gate names are kept, so the ASC IAP copy never changes;
    - highlights by change, with minimums;
    - the Insights and StrengthCard corrections;
    - the opening-week rule;
    - `-demoPro` with a Pro sweep and a `verify_archive` guard;
    - the lockstep commit for the Pro claims.
  - Moved to 1.5.0: the Overview and group management. StatsView.swift is the hot file, and 1.4.2
    is already full.
  - Not taken:
    - swapping StrengthCard's headline. It churns the screenshots, and the tiles and chart already
      set the card apart;
    - "Your current run is #N". Top 5 already marks Current (StatsProCards.swift:220-227);
    - the demo-account group deploy, so that 1.4.2 needs no server deploy;
    - re-ranking the group levels. There are no subscribers to affect.
- **Retention has the best diagnosis of the free daily loop and the most honest readout.**
  - Taken:
    - the baseline is recorded before any code;
    - at-risk rules whose copy names no weekday;
    - the Monday card on Today;
    - one inline card at a time;
    - the daily loop first in 1.5.0, whatever the readouts show (about 2 of 17 installs come back).
  - Moved to 1.5.0, as the free daily-loop work (D17), except one line that ships now:
    - reminders fire after the habit is done (NotificationService.swift:405-412, :642-643);
    - the Daily Reminder asks for `.timeSensitive` (:274) without the entitlement
      (Stride/Stride.entitlements:4-13). **Dropping it ships in 1.4.2** (W9, O24);
    - rest days count as "remaining" (TodayView.swift:109-111; NotificationService.swift:648).
  - Not taken:
    - five changed surfaces at once, the widget included;
    - state-aware reminders, a class of regression that fails silently, with an unresolved widget
      spike (the spike itself runs during 1.4.2's review wait);
    - anonymous counts behind a server route and a privacy-page rewrite. About 20 devices cannot
      carry funnel statistics, and the page promises "no analytics service" (docs/privacy.html:35,
      :52);
    - a `requestReview` button. Apple advises against calling it from a button, because it may show
      nothing.
- **Corrections to the drafts:**
  - The Weekly Review button does have a VoiceOver label (StatsView.swift:185). What it lacks is a
    visible label, a crown and `.help`.
  - The evidence that groups stay usable after a lapse is that only New Group checks Pro
    (AddHabitView.swift:496-502), and Settings' group rows check nothing (SettingsView.swift:389-420).
    PurchaseOutcome.swift:225-241, which a draft cited, is Settings' Pro rows.
  - The paywall has four Release presenters (StatsView.swift:192-194, AddHabitView.swift:310-312,
    SettingsView.swift:624-626, ContentView.swift:251-257), plus DEBUG `-paywall`
    (ContentView.swift:16-18, :45-46). Stats' presenter serves both the toolbar button and the
    locked card (StatsView.swift:153-156); Settings' serves both Upgrade and the lapsed row
    (SettingsView.swift:1019, :1098).
  - There is no `scripts/tests/`. Script tests sit beside their script (scripts/test_release.py).
  - RELEASE-1.4.1.md:912-913 lists the schedule-aware "remaining" under M5. This plan moves it on
    purpose (D17).

## Where things stand on 2026-10-27

- **1.4.1 (23):** the code is done; the owner steps and App Review are pending
  (NEXT_SESSION_PROMPT.md:13-30). **1.4.0 (22)** is live on both platforms.
- **Toolchain and simulators (read 2026-10-27 with `xcodebuild -version`, `xcrun simctl list` and
  `xcrun simctl runtime list`):**
  - Xcode is **27.1** (SDK 27.1). Its bundle is dated 2026-10-17, so 1.4.1's 10-22 suites may already have run on it.
  - Runtimes installed: **iOS 27.0, iOS 27.1 and iOS 18.5**. The iOS 26.5 runtime is gone, and with
    it the E2E kit's two devices (iPhone 17 Pro F5510EA3…, Pro Max F54C8C41…, both "unavailable,
    runtime profile not found"); `scripts/sim_e2e/lib.sh:32-33` still names them.
  - The Xcode update made a new default set on **iOS 27.0**: iPhone 17 Pro `C53F6992…`, iPhone 17 Pro
    Max `8C431EC3…`, iPhone 17 `2D529F09…`, iPhone 17e, iPad Pro 13-inch (M5) `7B83B9D7…`. The two
    Pros were booted and the Claude app's simulator panel was attached to the Pro; the iOS
    Simulator MCP answered a screenshot on it (corrected 2026-10-27 after the workflow's read, which
    had seen only 18.5).
  - So the simulator gates are **not** blocked by a missing runtime. They need the kit moved to the
    new devices and new baselines on iOS 27.0 (Phase 0, item 1; O20). 1.4.1's remaining simulator
    gates (NEXT_SESSION_PROMPT.md:19-24) run there too.
  - The disk has about 27 GB free (read 2026-10-27, after the plan workflow).
- **Suites** (last green on 2026-10-22, while the iOS 26.5 runtime was still installed):
  - StrideTests: 732 (+2 known skips), in Tokyo and under `TEST_RUNNER_TZ=America/Los_Angeles`;
  - hosted: 326 (+12 StoreKit skips on iOS 26.5) (RELEASE-1.4.1.md:1139-1144).
  - W0 records both counts again on Xcode 27.1 before any change.
- **StoreKit tests** run only on iOS 18.5, because `SKTestSession` writes fail on iOS 26.3 and later
  (StoreKitStatusTests.swift:17-31).
  - The only iOS 18.5 simulator is Soundpost-iOS18 (DAF29479…), which another project made.
  - Stride-StoreKit-iOS18 no longer exists.
- **Greps at 7fbb3ec:**
  - `introductoryOffer` appears only as `null` in Configuration.storekit:41, :62.
    `isEligibleForIntroOffer` appears nowhere.
  - There is no `requestReview` and no `SKStoreReviewController`.
  - There is no `WeeklyReviewMath` and no `atRisk`.
  - The store descriptions already use the catalogs' feature names: the old names of
    RELEASE-1.4.1.md:1234-1237 appear nowhere in metadata/, scripts/ or docs/, and the scan pins
    each bullet's head to the catalog word (LocalizationSourceScanTests.swift:269).

### The way to Pro today

| Step | What a user meets | Evidence | Fixed by |
|---|---|---|---|
| Store page | 2 ratings, and the app never asks. The screenshots are free-tier captures; the sweep cannot draw a Pro card. Screenshot uploads default to en-US only | a11y_sweep.sh:122-124; RELEASE-1.4.1.md:1179-1185; store_screenshots.py:14-15, :269 | W7, W8, D19 |
| First launch | Four onboarding pages; none mentions Pro | OnboardingView.swift:8-29 | W7 |
| First week | Pro appears only where a user taps: a text-only locked card; an icon-only Weekly Review button with no crown or `.help`; New Group's crown; Settings' Upgrade row; the Mac menu. Nothing on Today | StatsView.swift:153-156, :178-187; AddHabitView.swift:496-512; SettingsView.swift:1010-1042; MenuCommands.swift:90-95 | W4, W7 |
| Locked feature | A crown, a title, a caption and a button. Nothing of the user's own data | StatsView.swift:678-721 | W4 |
| Paywall | "Unlock the full experience". Products sorted by price, so Monthly comes first, and in the local StoreKit file Lifetime and Yearly tie at 19.99. Lifetime is highlighted as "BEST VALUE". A tap on a card buys at once. No trial. A failed load shows raw English in every locale | StoreService.swift:515, :141, :576-578, :579-581, :134; Configuration.storekit:6, :58 | W2, W3 |
| Purchase | Ask to Buy ends in silence. Success only dismisses, so the user must tap New Group or Weekly Review again. Restore is a `try?` that says nothing | StoreService.swift:188-190, :238-239, :665-673, :247-250 | W2, W3, W7 |
| Pro's first week | Strength draws the weeks before the start as grey "0" bars, and VoiceOver reads them as 0. The 30- and 90-day tiles are equal for a young habit. Insights hides itself. A level week reads "Up". The weekday line uses all-time tallies with no minimum gap | StatsProCards.swift:38-45, :119, :135-140, :151-152; HabitScore.swift:61-66; StatsView.swift:911; StatsInsights.swift:41-60, :68-69; HabitStats.swift:702-720 | W5 |
| Weekly Review | Shows this week only. On a Monday before any check-in, every row and the ring are dashes. Best and Needs work are picked by raw percentage, so a 90 % habit can be "Needs work". The change is in points but labelled "%". A partial week is compared with a full one. It reads `StatsCache.shared`. There are two presenters | WeeklyReviewView.swift:35, :112, :144-164, :244-248; StatsInsights.swift:112-119; HabitStats.swift:640-642, :691; StatsView.swift:189-191; ContentView.swift:251-257 | W6, W10 |
| Groups | Only creating a group is gated, so one month of Pro buys groups for good. Groups show on Today (a count, no progress), in Settings' Groups section and in New Habit's picker. A group's colour is the habit colour picked at the moment of creation. No reorder; delete is an unconfirmed swipe | AddHabitView.swift:490, :496-502, :323; SettingsView.swift:389-420, :1373-1387; TodayView.swift:55-66, :248-281 | W10; 1.5.0 |
| Trial | Settings has no trial state | PurchaseOutcome.swift:226-243 | W2, W7 |
| Paperwork | The local StoreKit file still has Lifetime at 19.99, Yearly's "save 44%" and no offer. The subscriptions' App Review note, if they were created by setup_iap.py, claims unlimited habits, widgets, smart reminders and iCloud sync. The terms list no Lifetime. The description's purchase section has no trial sentence | Configuration.storekit:6, :41, :62, :65; setup_iap.py:194-211; docs/terms.html:38-45; metadata/en-US/description.txt:51-57 | W2, W9, W12 |

For comparison, the free detail card already shows the current streak, the best streak, the 30-day
rate and Strength (StatsView.swift:474-523).

## The value line

Every Pro surface in this plan passes four tests. Each workstream's acceptance names the test each
change serves.

1. **Distinct.** It shows at least one number or sentence that no free surface shows. Free answers
   "how is this habit doing now". Pro answers "what changed, across which habits, and what needs me
   this week". A free surface never shows a Pro surface's headline number (so Today's free week
   line has no number, D12).
2. **True.** It never says something the user can disprove from the free cards beside it. When there
   is too little data, it says so in words that fit the habit's age. It never hides and never
   guesses. It never compares a partial week with a full one unlabelled.
3. **Seen.** A free user can tell that it exists without being interrupted, and the agent can sweep it
   and screenshot it.
4. **Tryable.** The paywall states exactly what is being bought. When StoreKit offers a trial, its
   terms sit beside the button.

**Market check** (market mapper):
- A cap on habits is the category's most common paywall, and also its most common complaint.
  Stride's rules forbid one.
- People in this category pay for insight, automation and identity. This plan deepens insight inside
  the three gates. New Pro categories are O15; the cheapest identity perk (alternate app icons) is
  put to the owner there for 1.5.0.

## Milestones

| Release | Build | Theme | Target | Size (DEV-PLAN units) |
|---|---|---|---|---|
| **1.4.2** | 24 | Wave A: Pro you can see, trust and try. Wave B (if it comes in): a Weekly Review worth opening | iOS and Mac submitted by 2026-11-25 (latest 2026-12-04); trial offer live by 2026-12-11 | Wave A ≈ 2.5 w, Wave B ≈ 1.5 w, plus ~2 d of release mechanics |
| **1.5.0** | 25 | The daily loop; Groups worth paying for; the opt-in review notification | Order fixed now; submitted by 2027-02-12 | ≈ 4 w + 2 d |
| M6 | — | Skip days, gated (DEV-PLAN-1.3.md:1278-1287) | Gate checked on 1.5.0's cut day | 4 w |

- **For scale:** M3 was specced at 3.5 w and took about 2 agent-days of code (RELEASE-1.4.1.md:701-703).
  M4's code ran from 10-14 to 10-22, and its owner steps were still open on 10-27. DEV-PLAN rule 3
  records that estimates ran 35–50 % low (DEV-PLAN-1.3.md:29-33). So Wave B is planned as out.
- **What sets the calendar:** owner sittings, App Review, the simulator runtime (Phase 0) and the
  window for deploying while no review is open. Code does not.

| Date | Step | Bound by |
|---|---|---|
| By 2026-11-02 | Kit moved to the iOS 27.0 devices (O20); 1.4.1's remaining simulator gates | agent |
| Week of 2026-11-02 | 1.4.1 iOS submitted; branch cut; W0; Phase 0 sitting (O1–O25); Gemini 4 Argon High rerun (its quota resets about 11-02) | owner, agent |
| 11-03 to 11-10 | Wave A (W1–W9). **Day 1:** the StoreKit simulator, W2's SKTestSession cases and the paywall fixtures, which are the 3.1.2 critical path | agents |
| **11-10** | **Wave B checkpoint.** W10 and W11 start only if W0–W9 are merged and green | — |
| 11-10 to 11-16 | Wave B, if in; whole-branch review | agents |
| **11-18** | **Code freeze.** Anything not green follows the cut order (D1) | — |
| 11-18 to 11-24 | Gates, Mac gate 10 included; owner sittings 2 (submission) and 3 (Mac) | simulator, owner |
| **11-25** | iOS and Mac `finish`, the day before US Thanksgiving. The Mac goes only if gate 10 passed (O19) | owner |
| ~12-01 to 12-04 | Approval; MANUAL release of both; the offer, gate 14, then the promotional text (sitting 4) | App Review, owner |
| 12-04 | Latest submission that still leaves one rejection round before the holiday slowdown | — |
| From release day | `metrics_snapshot.py` every Monday | agent |
| 2027-01-11 / 02-01 | Readouts 1 and 2: breakage and existence checks, not funnel statistics | owner |

## Phase 0 — before and alongside the branch cut

1. **Move the simulator kit to the iOS 27.0 devices (O20).** The iOS 26.5 runtime is gone, and Xcode
   27.1's default set on iOS 27.0 has an iPhone 17 Pro and Pro Max (Where things stand). Default:
   point `scripts/sim_e2e/lib.sh:32-33` (and any script naming `F5510EA3`/`F54C8C41`, the a11y
   sweep's default device name and run_hosted_tests.sh's "iPhone 17") at the iOS 27.0 devices,
   run `selftest.sh`, and record new baselines (hosted, a11y sweep, upgrade gate) in W0. Also try
   SKTestSession on iOS 27.0 once (`STRIDE_HOSTED_NO_SKIPS=StoreKitStatusTests`): if FB22774836 is
   fixed there, StoreKit tests no longer need iOS 18.5 (O21). Update the global CLAUDE.md's
   simulator table only through the owner. No download is needed; restoring iOS 26.5
   (`xcodebuild -downloadPlatform iOS -buildVersion 26.5`) is the fallback only if a gate needs
   26.5 evidence. This also unblocks 1.4.1's remaining gates, so it comes first.
2. **[owner]** Finish 1.4.1 (NEXT_SESSION_PROMPT.md:15-30).
   - The branch is cut at the iOS submission.
   - If 1.4.1 is rejected, the fix goes on m4 and is merged forward.
3. **[owner]** Rotate the App Review demo token once 1.4.1 is live, while no review is open
   (RELEASE-1.4.1.md:939-940).
4. **[owner, ASC write]** Request ASC Analytics Reports now (O13): one ONGOING request plus one
   ONE_TIME_SNAPSHOT. The reports take days to start (RELEASE-1.4.1.md:931). They count only users
   who share analytics with developers, under privacy thresholds, so at this volume they decide
   nothing; they are kept for later.
5. **Agent, GET only: the three IAPs' App Review notes.** setup_iap.py:204 is the creation payload
   (POST, :194-211), so editing it changes nothing live. W9 adds `reviewNote` to `iap_copy.py`
   (dry run first). If a live note names anything but D11's three things, the owner decides O22: a
   `--yes` PATCH, or a web-UI edit if the API answers 409 (as for approved localizations,
   NEXT_SESSION_PROMPT.md:15).
6. **Agent, GET only:** `store_screenshots.py list` for each of the 6 locales, to see which locales
   have their own sets (D19).
7. **Agent, read-only:** write W9's `scripts/metrics_snapshot.py` first. Record the 1.4.0/1.4.1
   baseline in the progress log:
   - weekly active production devices, by release;
   - Stride-only downloads and Pro sales;
   - the ratings count, read by the owner from ASC's Ratings and Reviews page (the API has no
     ratings count; D15).
8. **The StoreKit simulator (O21).** The global rule is to reuse an existing device. Check that
   Soundpost-iOS18 is not in use (`pgrep -f DAF29479-97FB-4BA7-A60E-0271DAA5AD78`, no `/tmp/lock-*`
   naming it), then ask the owner or the Soundpost session before borrowing it. Create
   `Stride-StoreKit-iOS18` (iOS 18.5, 2–5 GB) only if it cannot be borrowed, tell the owner, and
   give the `xcrun simctl delete` command when 1.4.2 is submitted. Never delete Soundpost-iOS18.
9. **Plan review rerun:** Gemini 4 Argon High via agy (`gemini-4-argon-high`, passed by its full id)
   did not run on 10-27 (429 quota, Review log). Rerun it on a throwaway `git archive` copy of the
   cut tip plus this file, never on the repo and never in Chrome, when its quota resets (about
   11-02), before W0's merge. Its findings go into "Plan review (rerun)" with the same format.
10. The owner takes O1–O25 or their defaults.
11. **Optional, independent of the release:** **[owner]** set `SENTRY_DSN` on the server, and raise
    pm2-logrotate's retention from 7 to 30 (RELEASE-1.4.1.md:932-933).

## Spec corrections

| Spec | Reality at 7fbb3ec | Decision |
|---|---|---|
| M5 = build 22 (DEV-PLAN-1.3.md:54) | 1.4.1 is 23 | 1.4.2 (24) |
| "2 more by Sun" (DEV-PLAN-1.3.md:1264) | Week math is Monday-based (HabitStats.swift:355-357), while heatmap rows follow the region (HeatmapLayout.swift:38-42). Agreed rule: copy names no weekday (RELEASE-1.4.1.md:881-883) | "N more this week" (D10) |
| Perfect-day count (DEV-PLAN-1.3.md:1259) | Today's "All done! Perfect day!" divides by every shown habit, rest days included (TodayView.swift:109-111, :423). A review count would contradict it | Comes in 1.5.0, with one rule for every surface (D17) |
| Schedule-aware "remaining" in M5 (RELEASE-1.4.1.md:912-913) | It changes five surfaces, including the widget and the badge (NotificationService.swift:648; RELEASE-1.4.0.md:230-232) | 1.5.0 (D17) |
| `atRisk` "after the user's evening reminder time" (DEV-PLAN-1.3.md:1257-1259) | A habit has its own reminder (Habit.swift:14-15), and there is a Daily Reminder too (NotificationService.swift:116-131) | The habit's time, then the Daily Reminder's, then 18:00 (D10) |
| "requestReview after a streak milestone" (RELEASE-1.4.1.md:934) | Rule 4 forbids a system prompt without a user action (DEV-PLAN-1.3.md:34-38); a home-made card instead is a custom review prompt (Guideline 5.6.1) | A Settings row only (D13, O10) |
| M6 = 1.5.0 (DEV-PLAN-1.3.md:55) | The gate is unmet; the 426 floor at 1.3.1 or later is not live (RELEASE-1.4.1.md:901) | A release of its own (D18) |
| "verify_archive.sh via ship.sh" (DEV-PLAN-1.3.md:1345-1346) | ship.sh refuses to run (RELEASE-1.4.1.md:1223) | `build-appstore.sh` plus `verify_archive --exported` |

## Design decisions

Placement rules are 1.4.1's. `Shared/` holds pure values only:
- no `appLocalized` and no user-facing literals;
- a `Calendar` is passed in;
- no UIKit and no StoreKit (PurchaseOutcome.swift:6-12).

**D1 — Version, waves, cut order.**
- 1.4.2 (24) is one release in one branch. Wave A is W0–W9.
- **Wave B (W10, W11) is out by default.** It starts only if W0–W9 are merged and green on 11-10,
  and only once its own Wave A dependencies have merged. If 1.4.1 slips past 11-09, it stays out.
- **Cut order** at the 11-18 freeze, if Wave B came in. Cut from the top:
  1. W10's share image;
  2. W10's notes;
  3. the rest of W10. D11's Weekly Review sentence then stays as it is today;
  4. W11.
- **Never cut:** W2 and W3 (the paywall), W5 (the truth fixes), W6 (the opening week), W4's single
  presenter, W8's `-demoPro` with its Pro sweep, and W12's description trial clause.

**D2 — Stay inside the three gates, and keep their names.**
- Every addition sits under Habit Groups, Advanced Analytics or Weekly Review. The non-negotiable
  constraints (DEV-PLAN-1.3.md:40-43) then hold with no amendment.
- The ASC IAP and subscription copy names only the gates ("Habit groups, advanced analytics & weekly
  review"; "Full access billed …", NEXT_SESSION_PROMPT.md:17-18). The in-app copy can therefore grow
  without an owner web-UI edit, which approved localizations would need
  (RELEASE-1.4.1.md:1097-1099).

**D3 — Free or Pro, for each new surface.**

| Surface | Tier | Why |
|---|---|---|
| Today's "Your week" card: for Pro, "Last week: 82%" and a button to the review; for free users, "Your Weekly Review is ready" with no number and a crowned button to the paywall (`.today`) | Free line; Pro destination | Rule 4 allows inline rows. The card shows that Pro exists, at a moment the user earned, without giving away the review's headline (value-line test 1) |
| Today's "N more this week" badge; at-risk rows first in their section (Wave B) | Free | M5's own spec (DEV-PLAN-1.3.md:1264-1265) |
| Locked-card preview: the blurred shape of the user's own strength bars, no numbers | Seen by free users; the content is Pro | It shows without giving anything away |
| Pro chip on Pro card headers and the review's title | Everyone | Guideline 2.3.2 for the screenshots; it also tells a subscriber what they pay for |
| Insights, Strength and Top 5 corrections | Pro (existing cards) | Value-line test 2 |
| Weekly Review: opening week, change in points, highlights by change (Wave A); any week, at risk, strips, chips, groups, notes, share (Wave B) | Pro | M5 |
| "Rate Stride" row in Settings → About | Free | D13 |
| Onboarding's "What's in Stride Pro" | Free; a tap opens the paywall (`.onboarding`) | Seen, never automatic |

**D4 — A paywall that sells the right plan and states its terms.**
- **Signature.**
  - `ProPaywallView(trigger: PaywallTrigger = .settings, onUnlock: () -> Void = {})` moves to
    `Views/ProPaywallView.swift` (W0).
  - The triggers are `.analytics`, `.weeklyReview`, `.today`, `.groups`, `.settings`, `.onboarding`
    and `.lapsed`.
  - Settings has two paywall buttons on one `showingPaywall` (SettingsView.swift:62, :624-626, :1019,
    :1098). W0 replaces it with `@State paywallTrigger: PaywallTrigger?` and `.sheet(item:)`, so
    Upgrade passes `.settings` and the lapsed row `.lapsed`.
- **Content follows the trigger.**
  - The header subtitle depends on the trigger.
  - The trigger's row comes first; the other two follow in D11 order.
  - The three `ProFeatureRow` calls stay literals, each written once **in D11's order in the source**.
    The runtime order is an index permutation over them (for example a `ForEach` over the order,
    with one `switch` whose cases keep D11's order). `testProClaimsNameExactlyD11sSet` captures the
    literals in source order and compares them with D11's list (LocalizationSourceScanTests.swift:196-204,
    :308-315), so it stays green unchanged.
- **`Shared/PaywallModel.swift` (pure)** is built from product mirrors and one flag:
  - each mirror: id, plan kind, price, display price, period, **currency code and the currency's
    fraction digits** (from `priceFormatStyle`), the intro offer's payment mode and period, and
    `eligible: Bool?`;
  - `isPro`. When it is true the model returns no trial at all. Lifetime is outside the subscription
    group (Configuration.storekit:4-19), so StoreKit calls a Lifetime owner eligible for Yearly's
    trial. Every presenter already shows the paywall only to non-Pro users, and it dismisses on
    `isPro` (StoreService.swift:632-634); this is the second guard.

  It returns values, not words: the plan order, the selection, the CTA kind, the terms kind, the
  per-month and savings figures. The view owns the keys.
- **Plans.**
  - Yearly comes first and is selected by default, then Monthly, then Lifetime. The order is by plan
    kind, **never by price**: StoreService sorts by price (StoreService.swift:141), and the local
    StoreKit file ties Lifetime and Yearly at 19.99 (Configuration.storekit:6, :58).
  - Tapping a card selects it. One CTA under the cards buys. Today a tap on any card buys at once
    (StoreService.swift:579-581).
  - Lifetime keeps its title and subtitle (:574, :577) but loses "BEST VALUE" and the highlight (:576,
    :578).
  - The billed price is the largest price text on each card.
  - Yearly adds a small per-month figure, `price / 12`, rounded **up** to the currency's minor unit
    (whole yen and won), formatted with `priceFormatStyle`.
  - The savings badge stays computed and rounded down (StoreService.swift:160-184).
- **Trial copy** appears only when all are true:
  - Yearly's `introductoryOffer` is a free trial;
  - `isEligibleForIntroOffer` returned `true` (eligibility is per subscription group, so a former
    Monthly subscriber is ineligible);
  - `isPro` is false.

  "Unknown" counts as no. The day count comes from the offer's period, so P1W and P7D both read
  "7 days", through the stringsdict.
- **Words come from the catalogs; only the price comes from StoreKit.** Period words ("year", "7
  days") are catalog keys, because the in-app language picker (`appLocalized`) can differ from the
  system language that StoreKit's localized period text follows.
- **CTA and terms.**
  - CTA: "Start 7-day free trial", "Subscribe" or "Buy Lifetime".
  - Directly above or under the CTA, the selected plan's terms:
    - for the trial: "Free for 7 days, then $19.99/year. Renews automatically unless cancelled at
      least 24 hours before the trial ends.";
    - for a subscription: the price per period, plus the renewal clause;
    - for Lifetime: "One payment of $39.99. No subscription."
  - The legal line (StoreService.swift:596) gains a trial clause. The Terms and Privacy links stay
    (:602-603).
- **Layout: the CTA, the selected plan's terms and the Terms and Privacy links sit in a bottom bar**
  (`safeAreaInset(edge: .bottom)`) on iOS and the Mac, so they are on the first screen at the
  default size. The features and plan cards scroll above it. At accessibility sizes, where the bar
  would cover the cards, it becomes the end of the scroll content instead (`ViewThatFits`), and the
  sweep reaches it with `-paywallScrollTo cta` (D14). Gate 10 checks the Mac sheet at its minimum
  size (StoreService.swift:654) and raises `minHeight` if the bar crowds the cards.
- **States, each with a fixture:**
  - loading;
  - load failed: "Stride Pro options couldn't load. Check your connection and try again." with Try
    Again. The raw detail goes only to the existing Sentry report (docs/privacy.html:59);
  - purchasing;
  - pending: "Waiting for approval. Stride Pro unlocks when it's approved.";
  - restored / no purchases found / couldn't reach the App Store, shown inline;
  - failed, through the existing alert;
  - unlocked: "Stride Pro is unlocked" with **Continue**, which calls `onUnlock`.
- **Dismissal.**
  - The `isPro` auto-dismiss (StoreService.swift:632-634) now fires only for an entitlement that
    arrives from elsewhere while no purchase is running.
  - The Mac frame stays (:654), subject to the check above.
- **`onUnlock` continues what the user wanted:**
  - `.groups` opens the New Group alert (AddHabitView keeps its own sheet), from the paywall sheet's
    `onDismiss`, not from `onUnlock` while the sheet is still dismissing: SwiftUI on iOS drops an
    alert raised during a sheet's dismissal (G2-2);
  - in the shell, Continue issues the request the paywall was opened to resume (D8): the review on
    the requested week for `.weeklyReview`, last week for `.today`;
  - the others dismiss.
- **Not `SubscriptionStoreView`.** Lifetime is a NonConsumable outside the subscription group
  (Configuration.storekit:4-19), and D11's rows are pinned.

**D5 — The trial: code in 1.4.2, the offer after both platforms are live.**
- While ASC has no offer, StoreKit returns none and the paywall shows no trial. That is the safe
  default in either order.
- **[owner]** creates the 7-day free trial on Yearly, in all territories, **once iOS and Mac 1.4.2 are
  both released** (O3, O19), and then gate 14 runs against the real offer before anything promotes
  it. The agent reads the offer back by GET.
- What's New never mentions the trial: it is not live at release, and not every user is eligible.
- The description gets a trial clause that is true with or without an offer (D16, O23), because the
  description changes only with a version, while the offer and the promotional text come later.
- Accepted: once the offer exists, 1.4.0 and 1.4.1 paywalls still show "$19.99/yr" while Apple's
  sheet shows the trial. The sheet states the terms.

**D6 — Purchase and trial states** (extends 1.4.1's D12).
- **Purchase and restore results.**
  - `purchase` returns an outcome that includes `.pending`, instead of a `Bool` (StoreService.swift:195,
    :238).
  - `restorePurchases() -> RestoreOutcome` returns `.restored`, `.nothingFound`, `.cancelled` or
    `.failed`. `AppStore.sync()` throws `StoreKitError.userCancelled` when the user cancels the
    Apple Account sheet; that is `.cancelled`, which shows nothing (G2-10).
  - `loadError` becomes a kind that the view words.
- **The trial on the status mirror** (`SubscriptionStatusMirror`, PurchaseOutcome.swift:55-73).
  - The mirror gains the offer: from `transaction.offer`, behind
    `if #available(iOS 17.2, macOS 14.2, *)`. The targets are 17.0 and 14.0 (project.yml:4-6).
  - Below 17.2 only `offerType` exists, and `.introductory` does not say which kind. There it maps to
    a trial only when the product's `subscription?.introductoryOffer?.paymentMode` is `.freeTrial`;
    otherwise the row is an ordinary active one. Stride creates no other kind (D16).
  - The mirror stays pure: Shared/ is compiled into the widget without StoreKit. A new
    `OfferMirror` (`.freeTrial`, `.introductoryPrice`, `.none`) is filled by StoreService's adapter,
    which becomes `mirror(_:products:)` so the below-17.2 fallback can read the loaded product's
    `introductoryOffer` (G2-3).
  - `ProStatus` gains `.trial(productID:firstChargeOn:willAutoRenew:)`.
- **Settings rows for the trial.**
  - "Free trial · first charge of $19.99 on <date>", with Manage.
  - "Trial ends on <date>" when auto-renew is off.
  - With unverified renewal info, no date is shown, as `dateLine` already does
    (PurchaseOutcome.swift:246-249).
  - The price comes from the loaded Products, which load at launch (StrideApp.swift:205) and can be
    missing offline. Without them the row keeps the date and drops the price.
- **`isPro` stays derived from `Transaction.currentEntitlements` alone** (StoreService.swift:49-58).
  Every new row is display only.

**D7 — Pro is right in its first week (Advanced Analytics).**
- **StrengthCard:**
  - weeks that end before the start draw no bar, and VoiceOver reads them as "Not started", as
    TrendCard already does (`endsBeforeStart`, HabitStats.swift:659-661; StatsView.swift:778, :855);
  - a habit younger than 30 days shows one "Since start" tile;
  - a habit between 30 and 90 days old shows "30-Day Change" plus "Since start";
  - the score heading stays;
  - the change values use `Color.readableText` instead of system green and orange
    (StatsProCards.swift:105; ColorExtension.swift:150).
- **Insights, never hidden, and never wrong about why.** Today it hides (StatsView.swift:911). With
  nothing to say:
  - "Insights appear after your first full week", only while the habit has had no full
    Monday-anchored week since its `startDay`;
  - "Not enough recent check-ins to compare" for an older habit. Momentum is nil when both weeks are
    0 % (StatsInsights.swift:76-80), and the weekday minimums may leave nothing else.
- **Level week.** A week level with the last one reads "Level with last week". This changes
  StatsInsights.swift:68-69 and StatsInsightsTests.swift:203-212 on purpose.
- **Weekday line.** It uses the last 12 weeks only, needs at least 4 due occurrences of every
  scheduled weekday in that window, and needs a gap of at least 15 points.
  - The tally is a new windowed one in HabitStats, beside the all-time one (HabitStats.swift:702-720).
  - By Weekday's bars are untouched.
- **A new line:** "3 days from your record of 20" (weeks for times-per-week), only while the current
  run is open, is not itself the record, and is within 7 of it.
- **At most 3 lines,** in this order: record, momentum, weekday.
- **A Pro chip** on InsightsCard, TrendCard, StrengthCard and BestStreaksCard.
  - It is decorative and hidden from VoiceOver.
  - It meets 4.5:1 contrast (ColorExtension.swift:101-103).

**D8 — Weekly Review, step 1 (Wave A).**
- **Opening week.** The review opens on the week it was asked for. Otherwise:
  - this week, once at least 4 of its days have passed (Thursday on, Monday-anchored), titled "This
    week so far";
  - else last week, titled "Last week" with its dates.

  So on Monday to Wednesday it opens on a finished week, and a partial week is never shown as if it
  were whole.
- **The change in points:** "+12 points vs previous week" (plural, through the stringsdict), or
  "Level with the previous week". Today it is labelled "%" (WeeklyReviewView.swift:112).
- **Highlights from change** (`WeeklyReviewMath`). They replace Best and Needs work
  (StatsInsights.swift:112-119).
  - "Most improved": the largest rise, only if it is at least 10 points.
  - "Slipped": the largest drop of at least 10 points, never for a habit at 80 % or more this week.
  - Only for a finished week, or a week with at least 4 counted days (counted as the Pro cards count,
    through the last counted day, HabitStats.swift:640-642), labelled "so far". The change line
    follows the same rule. Today a Tuesday with 1 of 1 done (100 %) against last week's 60 % would
    read "+40".
  - When nothing qualifies, there is no row.
- **Colour.** Rises and drops use `Color.readableText`; the existing system green and orange go
  (WeeklyReviewView.swift:115).
- **Data.** It reads the environment `StatsCache`, not `StatsCache.shared` (WeeklyReviewView.swift:35;
  StatsView.swift:26).
- **One presenter, decided when the request is issued.**
  - `ShellRequest` (ShellState.swift:132-146) gains `.weeklyReview(week: Date?)` and
    `.paywall(trigger: PaywallTrigger, resume: ShellRequest?)` (an `indirect` case; resume is the
    review request to open after Continue, or nil).
  - Whoever issues a request picks the case from `store.isPro` at that moment
    (`MenuCommandRules.weeklyReviewDestination`, MenuCommandRules.swift:106): the review for Pro, the
    paywall with its trigger and its resume for everyone else.
  - Today ContentView picks inside the sheet's content, from the live `isPro`
    (ContentView.swift:251-256). After a purchase that would swap the paywall for the review before
    its success state shows, or fire the paywall's own dismiss (StoreService.swift:632-634), so
    Continue and `onUnlock` would never run. Latching the destination at issue fixes both.
  - Continue sets `shell.request` to the resume request, which replaces the sheet.
  - **Issuers:** Stats' locked card issues `.paywall(.analytics, resume: nil)`; Stats' toolbar button
    and the Mac menu (MenuCommands.swift:92-95, which reads `StoreService.shared.isPro` when clicked)
    issue the review or `.paywall(.weeklyReview, resume: the review)`; Today's card issues the review
    on last week or `.paywall(.today, resume: last week)`.
  - Stats' own two sheets go, the locked card's included (StatsView.swift:153-156, :189-194;
    RELEASE-1.4.1.md:912-914). AddHabitView and Settings keep their own sheets.
- **Mac:** the ideal size becomes 560×680; the minimum stays 420×520 (WeeklyReviewView.swift:68).

**D9 — Weekly Review, step 2 (Wave B, if it comes in).**
- **Navigation.** ‹ and › run from the first week of the earliest habit to this week.
- **At risk this week** (this week only), by D10. A tap dismisses the review and focuses the habit on
  Today. `TodaySelection` cannot do that: it re-anchors a date (Shared/TodaySelection.swift:3-26). W4
  adds `shell.todayFocusHabitID`; W11 adds a `ScrollViewReader` target in TodayView that scrolls to
  the row and moves VoiceOver focus to it; W10 only sets the value. It writes nothing.
- **Each habit row:**
  - a 7-cell strip: done, missed, rest, before the start, future, and today not yet done. For a
    times-per-week habit, a day without a check-in is neutral, never missed, and once the week's goal
    is met nothing is missed: every day of such a habit counts as scheduled
    (HabitStats.swift:360-362; StatsInsights.swift:38-39), so a met 3×/week week would otherwise draw
    4 misses;
  - the strip is **one accessibility element** with a summary value ("5 of 7 done, 1 rest day"), not
    7 stops per habit;
  - the week's rate;
  - a strength-change chip: the end-of-week score against the previous week's (`strengthSeries`,
    HabitStats.swift:746-752; `score(on:)`, HabitScore.swift:52-54), in `Color.readableText`.
- **Sections by group,** Ungrouped last. Each section header shows the members' mean counted rate.
  This is Habit Groups' Pro value in 1.4.2.
- **Notes of the week:** the day, the habit and the first two lines. A tap opens History on that day
  (`ShellRequest.history`, ShellState.swift:145).
  - HabitStats keeps only which days have a note (HabitStats.swift:76-78), so W10 adds one live-notes
    read beside StatsCache. It excludes ghosts by what the store holds (HabitStats.swift:14-17) and
    shows the note of the day's kept record, the one every device keeps (`HabitRecord.outranks`,
    HabitCheckIn.swift:29-36).
- **Share as an image,** rendered once. Notes are left out unless the user turns them on. Nothing is
  uploaded. This is cut first.
- **⇧⌘R on iPad** goes on the Stats toolbar button (W4), so it works while Statistics is the active
  tab only (StatsView.swift:178). The Mac menu works from any tab (MenuCommands.swift:92-94; the file
  is macOS-only, :1). The limit is documented, not worked around.

**D10 — At risk, and Today's badge (free; Wave B).**
- **When a habit is at risk:**
  - **times-per-week:** remaining = goal − done this Monday-anchored week; daysLeft = today (if it is
    not done yet) through Sunday; at risk when remaining > 0 and remaining ≥ daysLeft;
  - **daily and specific days:** scheduled today, not done, and past the evening time. The evening
    time is the habit's reminder time if its reminder is on (Habit.swift:14-15), else the Daily
    Reminder's time if that is on (NotificationService.swift:116-131), else 18:00.
- **Today rows:**
  - a times-per-week row with a goal not yet met reads "1/3 this week · 2 more". Today it reads "1/3
    this week" (TodayView.swift:706-710);
  - when at risk, it reads "2 more · 2 days left" in `Color.readableText(hex: "#FF9500", …)`, as the
    streak words already are (TodayView.swift:720-724). System orange is 1.97:1 on the light card;
  - a daily habit at risk shows "Due today";
  - the row's VoiceOver label gets the same words (TodayView.swift:652-660);
  - no copy names a weekday.
- **Strings with two numbers** use positional specifiers, as the catalogs already do
  (ja Localizable.stringsdict:82-95, `%1$lld/%2$#@habits@`): "%1$#@more@ · %2$#@days@", one plural
  variable per number.
- **Order.** At-risk rows sort first within their section. The order is computed when Today appears,
  the day changes or the app comes to the foreground, and never again inside that pass, so a row
  never jumps under the user's tap.
- **Pro off:** Today is identical.

**D11 — Pro claims in lockstep (1.4.1's D11, amended: D11′).**
- The names stay (D2).
- **If Wave B ships,** only the Weekly Review sentence changes: "Weekly Review — any week at a glance:
  what improved, what is at risk, and your notes."
- Habit Groups and Advanced Analytics stay word for word until 1.5.0.
- **One commit (W12) changes all of these:**
  - the paywall row and the trigger subtitles (ProPaywallView.swift; StoreService.swift:531 today);
  - the 6 STRIDE PRO blocks (metadata/en-US/description.txt:37-41 and its 5 peers);
  - the review notes;
  - the expected values in LocalizationSourceScanTests.swift:196 and :232.
- **What the tests pin today:** `testStoreDescriptionsSellD11sProSet` checks only each bullet's head
  outside en-US (LocalizationSourceScanTests.swift:255-284), and the full lines in en-US only
  (:286-293). So if D11′ ships, W12 also pins the Weekly Review body in all 6 locales.
- **Unchanged:**
  - the Settings upsell, which names only the gates (SettingsView.swift:1031);
  - ProLockedCard, which is Advanced Analytics only. Exactly one `ProLockedCard(` call stays
    (LocalizationSourceScanTests.swift:206-208).
- **If Wave B is out,** D11 stays as it is, and the Wave B keys leave the catalogs.

**D12 — Seen, without interrupting.**
- **Locked card.** ProLockedCard keeps its literals and adds a preview:
  - the user's own 8-week strength shape (`stats.weeklyStrength`), blurred so that no value can be
    read, with no numbers or dates;
  - VoiceOver skips it;
  - plus "Stride Pro has 2 insights about this habit". The count comes from the same function
    InsightsCard uses, and the line is shown only when the count is at least 1.
- **Weekly Review toolbar button:** a crown for free users, `.help("Weekly Review")` on the Mac, and
  ⇧⌘R on iPad (D9's limit).
- **Onboarding.** The last page gets a "What's in Stride Pro" text button (`.onboarding`). The
  primary button is unchanged, and nothing opens on its own. No full-page Pro screen (O8).
- **Today's "Your week" card** (`Shared/InlinePrompts.swift`, pure; `Views/TodayCards.swift`):
  - **When:** it shows from Monday 00:00 to Tuesday 23:59 local time, once last week has an overall
    counted rate.
  - **Copy, Pro:** "Last week: 82%" and "See your Weekly Review".
  - **Copy, free:** "Your Weekly Review is ready" (no number) and "See your Weekly Review", with a
    crown.
  - **Pro:** every week; × hides it for that week.
  - **Free:** in at most 3 weeks ever; × ends it for good.
  - **Placement:** under the progress card.
- **At most one inline card on Today** at any time. The week card is the only one in 1.4.2.
- **Dismissal state** lives in `UserDefaults.standard`. It is never synced, never in the backup, and
  never read by the widget. It is a per-device preference on purpose: a card dismissed on the iPhone
  can still show on the iPad or the Mac, and a reinstall resets it.

**D13 — Ratings: a persistent row, nothing else.**
- A "Rate Stride" row in Settings → About (SettingsView.swift:580). It opens
  `https://apps.apple.com/app/id6761262334?action=write-review`.
- **No Today rating card.** Guideline 5.6.1 says to use the system API and disallows custom review
  prompts; an "Enjoying Stride?" card after a streak is one, and its wording reads as sentiment
  gating. A persistent link in settings is the placement Apple documents.
- **No `requestReview`.** Rule 4 stands, and the backlog's "requestReview after a streak milestone"
  (RELEASE-1.4.1.md:934) is declined by default. O10 puts the alternative to the owner: amend rule 4
  to allow one `requestReview(in:)` after a streak milestone, which the system limits to 3 a year.

**D14 — DEBUG switches and the Pro sweep.**
- **The switches**, all inside `#if DEBUG`, following `-paywall` (ContentView.swift:16-18) and `-demo`
  (StrideApp.swift:102-112):
  - `-demoPro` makes `isPro` true (StoreService.swift:49-51). With `-demo`, it seeds
    `DemoData.Scenario.pro`. The free `.standard` set is unchanged, so the free baselines hold
    (DemoData.swift:52-62);
  - `-paywallFixture <state>` drives every state of the paywall from a `PaywallModel` fixture. This
    is needed on the Mac variant, which has no products (RELEASE-1.4.1.md:1053-1054);
  - `-paywallScrollTo cta|terms|plans` scrolls the paywall on launch, as `-statsScrollTo` does,
    because `simctl` cannot scroll (a11y_sweep.sh:114-121);
  - `-inlineCard none|week` fixes Today's card. The sweeps pass `none`, then capture the card
    explicitly.
- **`DemoData.Scenario.pro`:**
  - two groups;
  - noted days last week;
  - a 3×/week habit that is at risk;
  - a habit that started 10 days ago.
- **The guards:**
  - a source-scan test checks that each flag appears only inside `#if DEBUG`;
  - the flags' parser prints one DEBUG-only sentinel, `[StrideDebugLaunchFlags]` (24 bytes), and
    `verify_archive.sh` fails if the sentinel is in a Release binary. The flag strings themselves
    cannot be the probe: Swift keeps literals of up to 15 bytes inside the instructions, where no
    text search finds them (mac_variant/build.sh:102-105), and `-demoPro` (8), `-inlineCard` (11)
    and `-paywallFixture` (15) are all that short.

**D15 — Measurement, with what already exists.**
- `scripts/metrics_snapshot.py` makes GET calls only. It reads:
  - Sentry sessions (environment=production), by release and by week: unique devices, sessions,
    crash-free rate;
  - ASC SALES, SUBSCRIPTION and SUBSCRIPTION_EVENT reports for vendor 94126306, filtered in code to
    SKU `stride-habit-tracker` (appstore_metadata.py:158) and app 6761262334 (iap_pricing.py:26),
    through `scripts/asc_api.py`;
  - the count of written reviews (`customerReviews`).
- **The ratings count is read by the owner** from ASC's Ratings and Reviews page at each sitting and
  written into the progress log. The API has no ratings count, and the public lookup hides small
  counts.
- It prints one dated table, and never prints a secret.
- **Nothing new in the app.** 1.4.2 adds no in-app counter and no Sentry capture, so
  docs/privacy.html (:35, :52, :54-62) does not change.
- **What the numbers can decide:** breakage (S1, S4) and existence (any trial, any sale). Never a rate,
  a price or an order of work. The ASC Analytics Reports (O13) are weighed in no decision.

**D16 — Paperwork, and what stays unchanged.**
- **Configuration.storekit:**
  - Lifetime 39.99;
  - Yearly's description becomes "Full access billed yearly";
  - Yearly gets an intro offer: P1W, paymentMode free (:6, :62, :65).
- **The IAP App Review notes** (O22): `iap_copy.py` gains `reviewNote` for the three products (dry
  run, then `--yes` with the owner's go, or the web UI on a 409). The note says D11's three things.
  setup_iap.py:204 is changed too, but only so that future products are created right.
- **The 6 descriptions** (O23): a trial clause in PURCHASE & SUBSCRIPTION INFORMATION
  (metadata/en-US/description.txt:51-57 and its peers) that is true with or without an offer: "If a
  free trial is offered, you are charged when it ends unless you cancel at least 24 hours before it
  ends. Any unused part of a trial ends when you subscribe." en-US is at 3,992 and es-ES at 3,984 of
  4,000 UTF-16 units (measured 2026-10-27), so W12 trims elsewhere first;
  `testStoreDescriptionsSellD11sProSet` keeps the limit.
- **docs/terms.html:38-45:** adds Lifetime as a one-time purchase, and a sentence on how a trial
  converts.
- **Unchanged:**
  - prices (Monthly 2.99, Yearly 19.99, Lifetime 39.99);
  - group levels (setup_iap.py:29, :47; Configuration.storekit:39, :60);
  - no Family Sharing, which cannot be undone for a product;
  - no offer codes (`offerCodesShip = false`, PurchaseOutcome.swift:261);
  - no win-back or promotional offers, and no intro offer other than the free trial.

**D17 — Left out of 1.4.2 on purpose: the daily loop, but one line.**
- These are real bugs, but free ones, and some fail silently:
  - "remaining" counts rest days on five surfaces (TodayView.swift:109-111; NotificationService.swift:648;
    RELEASE-1.4.0.md:230-232);
  - reminders still fire after the habit is done (NotificationService.swift:405-412, :642-643);
  - the evening Daily Reminder fires on a perfect day (:267-288).
- They ship together in 1.5.0, under one pure `DailyProgress` rule (X2), first in 1.5.0. The review's
  perfect-day count joins then.
- **In 1.4.2:** the Daily Reminder stops asking for `.timeSensitive` (NotificationService.swift:274),
  which the app has no entitlement for (Stride/Stride.entitlements:4-13). One line, no string, and no
  test pins it (O24). A trial user meets the evening reminder in exactly the week Pro must feel
  right.
- **During 1.4.2's review wait:** X2's spike (can the widget remove the app's pending requests?)
  runs, so 1.5.0 starts with its answer.

**D18 — M6 on its own.**
- Skip days keep their gate: the ≤1.3.0 cohort at zero for 8 weeks, and a live 426 floor at 1.3.1 or
  later (DEV-PLAN-1.3.md:1278-1287).
- When the gate is met on 1.5.0's cut day, M6 becomes its own minor release (1.6.0). A schema and wire
  change on entries never ships in the same release as Pro work.

**D19 — Exposure, inside 1.4.2 and without code.**
- **Localized store screenshots** for es, ja, ko, zh-Hans and zh-Hant. Uploads go to en-US unless a
  locale is given (store_screenshots.py:14-15, :269); Phase 0 item 6 reads which locales have sets.
  W8 captures each locale with `a11y_sweep.sh --lang` (:24-28). The sets ride 1.4.2's version
  record; each `--yes` needs the owner's go (O9).
- **A keyword pass** in the 6 locales that leads with "unlimited habits" and "free" (O25), pushed with
  the 1.4.2 metadata.
- With these, Wave B's share image and notes are the first things to drop (D1).

## Data safety (invariants; each has a test)

1. **No `@Model` change.** `upgrade.sh` finds the same model checksum before and after (gate 7).
2. **No wire change and no server change.** 1.4.2 needs no deploy and no production-copy rehearsal.
   `sync_rehearsal.sh` stays unchanged and green.
3. **Read-only surfaces.**
   - The review, the Today card, the preview and the Rate row only read and navigate.
   - Hosted test: tapping each new control leaves the store's row counts, and every `updatedAt`,
     unchanged.
4. **Derived on read.** Every new number comes from StatsCache, read once per render
   (StatsView.swift:24-26). The one exception is Wave B's notes, which come from one live-notes read
   beside it that excludes ghosts (HabitStats.swift:14-17) and shows the kept record's note
   (HabitCheckIn.swift:29-36). StatsPerformanceTests bound any-week review reads, notes included, at
   50 habits × 1,095 entries.
5. **Week math is Monday-anchored, with day keys at UTC midnight.** It is tested:
   - in Asia/Tokyo and under `TEST_RUNNER_TZ=America/Los_Angeles`; `TZ=` alone does not reach the
     test process;
   - over the DST changes of 2026-11-01 and 2027-03-14;
   - in `ja_JP@calendar=japanese`.
6. **Entitlement.** `isPro` comes from `Transaction.currentEntitlements` only (StoreService.swift:49-58).
   The trial rows are display only, and unverified renewal info claims nothing
   (PurchaseOutcome.swift:88-92).
7. **Nothing free moves behind Pro.** With Pro off, these work exactly as before (hosted tests plus a
   source scan):
   - Today;
   - the detail card;
   - the heatmap;
   - History;
   - existing groups: assign, view, rename and delete.
8. **No DEBUG switch in Release** (D14's sentinel and source scan).
9. **New per-device state** lives in `UserDefaults.standard` only. It is never synced and never in the
   JSON backup. Devices show the card independently (D12).
10. **Privacy.** The `SentrySDK.capture` call sites are the same as 1.4.1's (a grep diff), and
    docs/privacy.html is unchanged. `RestoreOutcome.failed` and the new paywall states add no capture.

## Workstreams (in order; parallel workstreams never share a file)

- `Shared/*.lproj` belongs to W0. A key added later is added by the integrator after its workstream
  merges, never inside a parallel workstream.
- Sizes are relative (S < M < L).

| W | Scope | Files (exclusive while it runs) | Tests | Size |
|---|---|---|---|---|
| **W0** scaffold | 1.4.2 (24). Baseline suite counts on Xcode 27.1 first. **Pure moves, no behaviour change:** ProPaywallView, PricingCard and ProFeatureRow go from StoreService.swift (:486-785) to `Views/ProPaywallView.swift`; InsightsCard and TrendCard go from StatsView.swift (:757-934) to StatsProCards.swift. `ProPaywallView(trigger:onUnlock:)` with defaults, and every presenter passes its trigger; Settings' `paywallTrigger` with `.sheet(item:)` (SettingsView.swift:62, :624-626, :1019, :1098). `ShellRequest.weeklyReview(week:)` and `.paywall(trigger:resume:)` with their call sites (ShellState.swift:137; ContentView.swift:251; MenuCommands.swift:94). Stubs: Shared/PaywallModel.swift, Shared/PaywallTrigger.swift, Shared/WeeklyReviewMath.swift, Shared/InlinePrompts.swift, Views/TodayCards.swift, Views/WeeklyReviewShare.swift. Inert DEBUG flags and the sentinel (D14). The whole copy deck: the 5 Localizable.strings, plus plurals in the 6 stringsdict, with positional specifiers for every two-number key. Draft PR | project.yml, pbxproj, StoreService.swift (move and flag), Views/ProPaywallView.swift, StatsView.swift and StatsProCards.swift (move only), AddHabitView.swift, ContentView.swift and MenuCommands.swift (call sites only), SettingsView.swift (the trigger state), ShellState.swift (enum), StrideApp.swift (flags), Shared/*.lproj, the stubs | Builds on iOS and macOS; LocalizationSourceScanTests and LocalizationCatalogTests unchanged and green; the DEBUG-flag source scan; a hosted test that Upgrade opens `.settings` and the lapsed row `.lapsed`; xcodegen drift clean | **M** |
| **W1** review and insight math | `WeeklyReviewMath` (pure): `weekRange(containing:)` for any Monday week; the opening week (D8: 4 days passed); each habit's counted rate for any week (`countedRate(ofWeekStarting:)`, HabitStats.swift:650) and its strength change; highlights with the 4-counted-day rule (D8); `atRisk`, remaining and daysLeft (D10); group section rates. HabitStats: the 12-week weekday tally beside the all-time one (:702-720), and strength on a given day (:746). demo_check gains a "last week" block | Shared/WeeklyReviewMath.swift, Shared/HabitStats.swift, Shared/HabitScore.swift, scripts/demo_check/main.swift, StrideTests/WeeklyReviewMathTests.swift (new), StrideTests/StatsPerformanceTests.swift | Sunday 23:59 and Monday 00:00; Wednesday 23:59 and Thursday 00:00 for the opening week; the DST weeks; both zones; the Japanese calendar; times-per-week at risk on Fri, Sat, Sun and Mon; daily at risk before and after 18:00, after its own reminder time and after the Daily Reminder's; a habit created mid-week; archived habits; a 90 % habit never "Slipped"; a Tuesday 1-of-1 week against 60 % gives no highlight. HabitStatsParityTests unchanged; the performance bound | M |
| **W2** purchase core | D4's `PaywallModel` (kind order, `isPro`, currency digits, eligibility); D6 (outcomes, restore, load-error kind, the offer with its 17.2 guard and fallback, `.trial`, the trial row without products); D16's Configuration.storekit. **Day 1 of Wave A** | StoreService.swift, Shared/PurchaseOutcome.swift, Shared/PaywallModel.swift, Stride/Configuration.storekit, StrideTests/PaywallModelTests.swift (new), StrideTests/PurchaseOutcomeTests.swift, StrideAppTests/StoreKitStatusTests.swift, StrideAppTests/StoreServiceTests.swift | **PaywallModelTests** (macOS CI): eligible, ineligible and unknown, with trial words only when eligible; `isPro` true gives no trial; P1W and P7D; USD, EUR, JPY and KRW per-month figures rounded up to the minor unit; savings rounded down; Yearly first and selected with tied Lifetime and Yearly prices. **PurchaseOutcomeTests:** the trial rows; the row without products keeps the date and drops the price; unverified info claims nothing; `.introductory` on 17.0 maps to a trial only for a free-trial offer. **SKTestSession on the iOS 18.5 device (O21)** with `STRIDE_HOSTED_NO_SKIPS=StoreKitStatusTests,StoreKitConfigurationLoadTests`: eligible on a clean session; buy the trial, then the trial row shows its first charge; `timeRate` past 7 days, then it renews; auto-renew off, then "Trial ends", then lapsed; ineligible after an earlier Monthly; Ask to Buy pending, then approved; restore with nothing and with Lifetime. StoreServiceTests pin 39.99 and the offer | M, from W0 |
| **W3** paywall UI | D4's view: selection, one CTA, the bottom bar with the terms and links and its accessibility-size fallback, every state, the trigger subtitles and row order, Continue; the `-paywallScrollTo` anchors | Views/ProPaywallView.swift, StrideAppTests/PaywallRenderTests.swift (new), StrideTests/LocalizationSourceScanTests.swift (the subtitles join the D11 pin) | Hosted render test per fixture: CTA and terms text; the CTA, terms and links inside the bar at the default size on iPhone and iPad, and at the end of the scroll at AX5; the billed price is the largest price text; the selected plan has the selected trait; no trial word when ineligible, unknown, Pro or without an offer; the Terms and Privacy links. The scan test | M, after W2's API |
| **W4** Statistics and shell | D8's single presenter, decided at issue, and Stats' two sheets removed (the locked card's included). `shell.todayFocusHabitID` for Wave B. D12's toolbar button and the locked-card preview; the insight count after W5's API. Carried from 1.4.1: the Spanish iPad sidebar at AX5 | StatsView.swift, ContentView.swift, ShellState.swift, MenuCommands.swift, Shared/MenuCommandRules.swift | ShellTests: buying inside the shell paywall shows "Stride Pro is unlocked", and Continue then opens the requested week; the locked card opens `.analytics`; Today's card opens `.today`; a request while another sheet is showing. MenuCommandRules tests. Hosted StatsRenderTests: the preview's count equals InsightsCard's lines, and its label holds no number. AccessibilityActionScanTests | M, from W0 |
| **W5** Analytics that tell the truth | D7, the readable change colours included. Removes `StatsInsights.weeklyReview` once W6 has merged | Views/StatsProCards.swift, Shared/StatsInsights.swift, StrideTests/StatsInsightsTests.swift, StrideAppTests/StatsRenderTests.swift | StatsInsightsTests in both zones: :203-212 updated on purpose; the thresholds; the 12-week window; the first week; an old habit with two 0 % weeks reads "Not enough recent check-ins to compare"; the record line; at most 3 lines. StatsRenderTests: no bars before the start, read as "Not started"; the young-habit tiles; the empty states. HabitStatsParityTests green | M, after W0's move and W1's tally |
| **W6** Weekly Review, step 1 | D8 (the opening week or a requested week, points, highlights with "so far", the readable colours, the environment cache, the Mac size) | WeeklyReviewView.swift, StrideAppTests/WeeklyReviewRenderTests.swift (new) | Hosted, with an injected cache: on a Monday before any check-in, and on a Wednesday, "Last week" with its dates and no dash rows; on a Thursday, "This week so far"; `.weeklyReview(week: lastMonday)` opens that week; the change in points; the highlight thresholds | S, after W1 |
| **W7** Today card, onboarding, Settings, New Group | `InlinePrompts` and the week card (D12). Onboarding's link. Settings: Rate Stride (D13); restore results inline; the trial rows (after W2). Carried from 1.4.1: the #FF9500 "4d" at 2.1:1. AddHabitView: `onUnlock` opens New Group | Shared/InlinePrompts.swift, Views/TodayCards.swift, TodayView.swift (card only), OnboardingView.swift, SettingsView.swift, AddHabitView.swift (group section only), StrideTests/InlinePromptsTests.swift (new) | InlinePromptsTests in both zones: Monday 00:00, Tuesday 23:59 and Wednesday 00:00; a DST weekend; the first-week edge; the free cap of 3; × hides or ends; the free line has no number. Hosted Settings rows for every ProStatus, the trial with and without products included. AccessibilityActionScanTests | M, from W0 |
| **W8** verification surfaces | D14's scenario. `a11y_sweep.sh --pro`: every Pro card, the preview, the review (this week, last week, Wave B's navigation if in), the paywall fixtures with `-paywallScrollTo` and the Today card, at default size and AX5, on iPhone 17 Pro Max and iPad Pro 13". `screenshots.sh` adds the O9 frames, and `--lang` sets for the 5 other locales (D19). `verify_archive.sh` probes for the sentinel. `mac_variant/capture.sh`: every fixture in 6 locales and the review, at full and minimum width. Tries a run of the variant under the StrideMac scheme's StoreKit configuration (project.yml:240); if a by-path launch does not pick it up, the fixtures stay the evidence | Shared/DemoData.swift, scripts/a11y_sweep.sh, scripts/screenshots.sh, scripts/verify_archive.sh, scripts/mac_variant/capture.sh | Free baselines unchanged; Pro baselines new; `verify_archive` fails a Debug archive (sentinel found) and passes a Release one; a blank-frame check on every PNG | M, captures after W3–W7 (and W10 if in) |
| **W9** measurement, paperwork, one reminder line | D15's script (Phase 0, first), with no ratings call. D16: `reviewNote` in iap_copy.py (dry run now; `--yes` with O22), setup_iap.py:204 for future products, docs/terms.html. D17: `.timeSensitive` dropped (O24). Carried from 1.4.1: History's Done button at the bottom edge of a 700-pt Mac window | scripts/metrics_snapshot.py, scripts/test_metrics_snapshot.py, scripts/iap_copy.py, scripts/setup_iap.py, docs/terms.html, NotificationService.swift (that line only), HabitHistoryView.swift | test_metrics_snapshot.py on a fixture with ColorArchive and RoastMate rows, none of them counted, and no secret printed; a dry run; iap_copy's dry run prints the three live notes; ReminderPlanTests and `upgrade.sh --reminders` unchanged (gate 7); a Mac variant capture at 700 pt | S, any time |
| **W10** Weekly Review, step 2 (Wave B) | D9, with the live-notes read | WeeklyReviewView.swift, Views/WeeklyReviewShare.swift, Shared/WeeklyReviewMath.swift (`notesOfWeek`), Stride/Sources/Services/StatsCache.swift (the notes read) | Hosted: ‹ and › stop at their bounds; each habit's numbers equal WeeklyReviewMath's; a met 3×/week strip draws no miss; the strip reads as one element; group sections; an at-risk tap sets `todayFocusHabitID` and writes nothing; a note tap opens History on its day; ghosts excluded and the kept record's note shown; share renders once. E2E WR2 | L, after W6 and W4 |
| **W11** Today badge and at-risk (Wave B) | D10, and the focus target for D9 | TodayView.swift (rows; the focus target) | Hosted TodayRenderTests: the badge copy in readable orange; at-risk rows first in their section; the order holds across a check-in in the same pass; the focus target scrolls and moves VoiceOver focus; the VoiceOver label matches; Pro off identical | S, after W7 and W1 |
| **W12** release | The D11 lockstep commit, after W3, W4 and W10 (or with Wave B out), with D11′'s 6-locale pins if it ships. The description trial clause ×6 (O23), trimmed to fit. The keyword pass ×6 (O25). Localization passes, with a translation lens that back-translates the trial and renewal terms in ja and ko; zh reviewed with the owner. What's New ×6, metadata ×6, review notes. DEV-PLAN edits: M5 = 1.4.2 (24), M6 on its own, "N more this week", perfect days in 1.5.0, the ship.sh rule, the 1.5.0 order. The progress log. Gates. Screenshots | metadata/, scripts/release.py, docs/review-notes-1.4.2.md, DEV-PLAN-1.3.md, this file, the D11 sites, StrideTests/LocalizationSourceScanTests.swift | Gates below | M |

**Critical path:**
- W0 → W2 → W3 → W8's paywall captures → gate 2 → W12. This is now the long pole (3.1.2).
- W0 → W1 → W6 → W8's review captures.
- W4, W5 and W7 start from W0's stubs. W9 starts in Phase 0.
- If Wave B comes in: W6 and W4 → W10; W7 and W1 → W11.

**Reviews:** a whole-branch review after Wave A merges, and again before the freeze.
- Gemini 4 Argon High via agy (`gemini-4-argon-high`, passed by its full id) and Gemini 3.8 Flash
  High, run on a throwaway `git archive` copy, never on the repo.
- Claude adversarial lenses:
  - "a sentence a user can disprove" (Insights, highlights, partial weeks, the strips and the Today
    card, checked against the free cards);
  - week boundaries in both zones;
  - StoreKit and Guideline 3.1.2, reading the paywall PNGs of both platforms;
  - rule 4 and Guideline 5.6.1;
  - D11 drift;
  - l10n, with the back-translation of the terms.

**Builds and simulators:**
- one derived-data root per session; the persistent roots in `~/Library/Caches/Stride-build/` stay;
- the iOS 18.5 device (O21) is used for W2's StoreKit tests and gate 3 only;
- nothing is trashed to make room; if the disk fills, the owner empties the Trash.

## Release gates and acceptance (1.4.2)

1. **Tests:**
   - StrideTests: W0's Xcode 27.1 baseline + new, in Tokyo and under
     `TEST_RUNNER_TZ=America/Los_Angeles`, with the known skips;
   - hosted: W0's baseline + new;
   - StoreKit: 12 + new on the iOS 18.5 device, with 0 skips;
   - `sync_rehearsal.sh` and the server tests, unchanged and green;
   - kit selftest; CI green; xcodegen drift clean; the performance bounds hold.
2. **Trial honesty (3.1.2).** Capture every paywall fixture in all 6 locales at default size, and
   with `-paywallScrollTo cta` at AX5 (the sweep is otherwise top-only for the price cards,
   a11y_sweep.sh:119-121). Each capture must show:
   - the trial length, the price afterwards, auto-renewal and the cancel clause, beside the CTA and
     on the first screen at the default size;
   - the billed price as the largest price text;
   - the Terms and Privacy links;
   - no trial word in the ineligible, unknown, Pro and no-offer states.

   A review lens reads the PNGs.
3. **StoreKit end to end** (iOS 18.5, Configuration.storekit with the offer): W2's cases, plus 1.4.1's
   gate 4 (RELEASE-1.4.1.md:746-752), plus one purchase from the shell's paywall (`.weeklyReview`)
   that ends on "Stride Pro is unlocked", after which Continue opens the review on the requested week.
4. **Weekly Review** (sim kit, `-demoPro`):
   - **WR1:** on a Monday before any check-in, the review opens on "Last week" with no dash rows. The
     Today card's button opens the same week. Without `-demoPro`, the card's line has no number.
   - **WR2 (Wave B):** tap ‹ once from this week. Each habit's rate and the highlights equal
     demo_check's "last week" block. The at-risk list names the 3×/week habit as "N more · M days
     left", and a tap focuses it on Today. The notes appear.
   - **WR3:** without `-demoPro`, the Today badge (Wave B) still shows, the review opens the paywall
     (`.weeklyReview`) with that trigger's subtitle and first row, and nothing else changes. (The
     purchase that resumes the review is gate 3's, under SKTestSession.)
   - **Demo account:** `check_demo_account.sh` prints the "last week" block in both zones. It is
     read-only; the demo account has the 3×/week habit (server/ops/demo-add-habits.js:92).
5. **Pro claims and the value line:**
   - D11 (or D11′) appears in the 6 blocks, the paywall, the upsell, ProLockedCard and the review
     notes;
   - tests :196 and :232 pass, with the 6-locale body pins if D11′ ships;
   - the ASC IAP read-back is unchanged (GET), and the three IAP review notes read back with D11's
     three things;
   - every Pro PNG from W8 shows something no free capture shows, and contradicts none.
6. **No new interruptive UI:**
   - every new surface is inline or sits behind a tap;
   - no `.sheet` or `.alert` is driven from `onAppear` or `.task`;
   - onboarding opens nothing on its own;
   - a grep finds no `requestReview`, and no home-made review prompt exists (5.6.1);
   - InlinePromptsTests pin the caps.
7. **Upgrades:**
   - iOS: `upgrade.sh` with a widget placed and `--reminders`, from 1.4.1 (23), 1.4.0 (22) and 1.3.1
     (21);
   - Mac: the variant installed in place over the m4 tip, with row counts and the checksum equal (as
     1.4.1's gate 7).
8. **Accessibility:**
   - the sweep, free and `--pro`, on iPhone 17 Pro Max and iPad Pro 13", at default size and AX5;
   - VoiceOver reads no locked number; the plan cards announce their selection; each strip is one
     element with its summary (Wave B);
   - contrast of 4.5:1 for text and 3:1 for marks (ColorExtension.swift:101-103): every new change,
     at-risk and highlight text uses `Color.readableText`, and the old system green and orange are
     gone from StatsProCards.swift:105 and WeeklyReviewView.swift:115;
   - AccessibilityActionScanTests.
9. **Release builds:** `verify_archive.sh` passes both exports and finds no DEBUG sentinel.
10. **macOS, on the final tree, before 11-25:**
    - a Release archive, then `verify_archive.sh`;
    - the variant with `-demoPro` and `-paywallFixture`: the review sheet at minimum and full width;
      every paywall fixture in all 6 locales at minimum and full width, read by the 3.1.2 lens;
      ⇧⌘R and the toolbar tooltip; keyboard focus reaches the CTA;
    - **[owner]** one sitting (sitting 3).

    Never run the real-id app on this Mac.
11. **Release-build smoke**, as 1.4.1's gate 12. The paywall loads products from the sandbox and shows
    no trial, because no offer exists yet. No crash.
12. **Privacy:** the capture sites are the same as 1.4.1's, and docs/privacy.html is unchanged.
13. **Baseline:** the last 4 weeks of `metrics_snapshot.py`, and the owner's ratings counts, are in
    the progress log.
14. **The real offer (after approval, before O14).** Once the offer exists and its GET read-back
    matches: a Release-build sandbox smoke on iOS, and on the Mac if its 1.4.2 is live. In en, ja and
    zh-Hans, the trial copy appears only when eligible, and the day count, price and renewal clause
    are right. **[owner]** compares Apple's sheet with a sandbox tester. If anything fails, the owner
    ends the offer before the promotional text goes up.

**Acceptance:**
1. A free user on a simulator meets Pro through these surfaces, and nothing appears without a tap or
   outside its window:
   - the locked preview;
   - the crowned review button;
   - the Monday card;
   - onboarding's link;
   - Settings.
2. From each trigger, the subtitle and the first row match the trigger. After a purchase, Continue
   resumes the user's action.
3. With `-demoPro`, on a habit started 10 days ago:
   - Strength draws no bars before the start;
   - one "Since start" tile shows;
   - Insights shows a true line or the first-week line;
   - on a Monday before any check-in, the review opens on last week.

## Submission checklist (1.4.2)

- [ ] 1.4.1 is released, and m5 has merged m4's tip and `main`.
- [ ] **[owner]** The demo token is rotated, and the review notes' password matches.
- [ ] Gates 1–13 are green on the final tree, gate 10 included. Signing preflight:
      `security show-keychain-info`, plus a 1-second codesign probe.
- [ ] **[owner]** docs/terms.html (with Lifetime and the trial sentence) is published to stride-site
      and verified live. The privacy page does not change (gate 12).
- [ ] **[owner]** The three IAP review notes are fixed and read back (O22).
- [ ] `WHATS_NEW_BY_VERSION["1.4.2"]` ×6, **before** **[owner]** `release.py prepare 1.4.2`.
- [ ] **[owner]** `push_metadata.py 1.4.2`, which writes both records: the descriptions with the trial
      clause (O23) and the keywords (O25).
- [ ] **[owner]** Screenshots (O9), the localized sets included: a dry run after `prepare`, a go for
      each `--yes`, then a read-back with `list`.
- [ ] **[owner]** `review_notes.py 1.4.2 --yes`. The notes say:
  - where Weekly Review is: Statistics → calendar button, or Today on Monday;
  - that the paywall shows a trial only when StoreKit offers one and the account is eligible;
  - that a Yearly trial may be added after approval.
- [ ] **[owner]** `build-appstore.sh all --upload` with `verify_archive --exported`. **Never `ship.sh`.**
- [ ] **[owner]** `release.py finish 1.4.2 24 --platform IOS`, and `--platform MAC_OS` the same day if
      gate 10 passed (O19), each with its own go.

**After approval** (owner sitting 4, in order):
1. `release.py release 1.4.2` for each approved platform; once both are released, merge the PR with a
   merge commit and tag `v1.4.2`.
2. **[owner]** Once both platforms' 1.4.2 is live (O3), create the Yearly introductory offer in ASC:
   free trial, 1 week, all territories (`subscriptionIntroductoryOffers`).
   - If the permission classifier blocks the agent, the step is written as
     `scripts/asc_writes_1_4_2.sh` for the owner to run.
   - Read it back by GET.
3. Gate 14 against the real offer. On a failure, **[owner]** ends the offer and nothing below runs.
4. **[owner]** Promotional text ×6: "Unlimited habits, free. Try Stride Pro free for 7 days." (O14)
5. The weekly snapshot starts. If a simulator was created for W2, the owner deletes it with the
   command the agent gives.

**Draft copy (en-US; W12 makes all 6 locales):**
- **What's New:** "Stride Pro, clearer: pick a plan and see exactly what it costs before you pay.
  Insights and the Strength chart now make sense from your first week. Weekly Review opens on last
  week until this week has something to show. Rate Stride from Settings."
  - If Wave B ships, add: "Look back at any week: what improved, what is at risk, and your notes.
    Today shows how many more check-ins a weekly habit needs."
- **Paywall subtitle, by trigger:**
  - `.analytics`: "See what's changing, not just where you are";
  - `.weeklyReview` and `.today`: "See how your week went", or "Look back at any week" (Wave B);
  - `.groups`: "Organize your habits into groups";
  - `.settings` and `.onboarding`: "Almost everything is free. Pro adds three things."
    (description.txt:35);
  - `.lapsed`: "Welcome back".
- **Description clause** (D16): "If a free trial is offered, you are charged when it ends unless you
  cancel at least 24 hours before it ends. Any unused part of a trial ends when you subscribe."
- **Other new copy:**
  - "Last week: %lld%%" / "Your Weekly Review is ready" / "See your Weekly Review";
  - "Rate Stride";
  - "What's in Stride Pro";
  - "Insights appear after your first full week" / "Not enough recent check-ins to compare" / "Level
    with last week" / "%1$lld days from your record of %2$lld";
  - "This week so far" / "+%lld points vs previous week" / "Level with the previous week" / "Most
    improved" / "Slipped";
  - Wave B: "At risk this week" / "Notes" / "%1$#@more@ · %2$#@days@" / "Due today";
  - "Purchases restored" / "No purchases found for this Apple ID" / "Couldn't reach the App Store" /
    "Waiting for approval. Stride Pro unlocks when it's approved." / "Stride Pro is unlocked" /
    "Continue".

## Risks

1. **Volume caps the result.** At about 12 downloads a month, even a perfect Pro yields 0–2 payers a
   month.
   - Mitigations: the Settings rating row, the Pro frames and localized sets on the store page, the
     keyword pass, the promotional text.
   - The success measures say this up front.
2. **A 3.1.2 rejection in December.**
   - Gate 2, the bottom bar and the review lens guard against it.
   - The reviewer will not see a trial, because the offer is created after approval; the notes say
     so, and gate 14 checks the real offer before anything promotes it.
   - A submission on 11-25 leaves room for resubmissions before 12-04.
3. **A 5.6.1 rejection.** Removed by design: no home-made review prompt, only a Settings row (D13).
4. **Trial wording shown to someone who cannot get it.** By default there is no trial copy. It needs
   `eligible == true` and `isPro == false` (D4), and gates 2, 3 and 14 test the other states.
5. **A trial that shows an empty Pro.** The first week is the trial. D7 and D8 cover it, and "Last
   week" is ready on day 7.
6. **A surprise charge,** then a refund and a one-star review. The terms sit beside the CTA, Settings
   shows the first-charge date, the description states the trial terms, and Apple's sheet repeats
   them.
7. **Fewer one-off buyers once Lifetime loses its highlight.** It cannot be measured: there is 1
   Lifetime sale ever. Accepted on reasoning: Yearly first is the category's norm, and Lifetime stays
   one tap away.
8. **Insights says wrong things again** (1.4.1 had to fix it, RELEASE-1.4.1.md:1131-1135). Guards: the
   minimums, the 12-week window, the empty text by age, the 4-counted-day rule, both zones, and the
   "disprove" lens.
9. **Week-boundary bugs that Tokyo hides.** Guards: `TEST_RUNNER_TZ`, the DST weeks, the Japanese
   calendar.
10. **Inline cards becoming nags.** One card on Today, a free cap of 3 weeks, the caps pinned in tests,
    and a rule-4 lens.
11. **Rows jumping under a tap** (Wave B). D10 keeps the order stable, and W11 tests it.
12. **A DEBUG switch leaking into Release.** Guards: `#if DEBUG`, the source scan, the sentinel probe
    in `verify_archive`, and the variant preflight (mac_variant/build.sh:62-69).
13. **Hot files** (StatsView, TodayView, WeeklyReviewView). W0 moves code first, and each file has one
    owner at a time (see the table).
14. **Pro copy drift.** One D11 commit, tests :196 and :232 (with the 6-locale pins if D11′ ships),
    and the ASC read-back.
15. **The Mac paywall with real products is never seen by the agent,** because the variant has no
    products. Covered by the fixtures in all 6 locales at both widths, `PaywallModel`, the shared
    StoreKit code, W8's StoreKit-configuration attempt, and the offer waiting for the Mac's 1.4.2
    (O3). The residual risk is accepted.
16. **The StoreKit simulator.** It needs the iOS 18.5 runtime. Soundpost-iOS18 is borrowed only with
    the owner's or the Soundpost session's yes, and never deleted; otherwise a Stride device is made
    and later deleted by the owner.
17. **The simulator runtime changed.** Xcode is 27.1, iOS 26.5 is gone, and the house devices are
    now iOS 27.0's. Baselines may move (new runtime), so W0 records them before any change, and
    SKTestSession's behaviour on 27.0 is checked once (O20, O21).
18. **Calendar.** 1.4.1 may slip (its own simulator gates need the runtime too); Thanksgiving week;
    Apple's late-December slowdown. Wave B out by default and the cut order (D1) protect 12-04.
19. **Readouts read as signal.** At this volume "no trial start by 01-11" has roughly a 15–60 % chance
    whatever the cause. D15 limits the readouts to breakage and existence.
20. **Disk.** About 27 GB free (2026-10-27). One derived-data root per session. Nothing is trashed to make room; if the
    disk fills, ask the owner to empty the Trash.

## Owner decisions

The defaults are proposals. O3, O9, O13, O14, O20, O22, O23 and O25, and every ASC write and
download, still need a go for each action.

| # | Question | Default |
|---|---|---|
| O1 | 1.4.2 = Wave A; Wave B only if W0–W9 are merged and green on 11-10, cut from the top at 11-18; 1.5.0 = the daily loop first, then Groups, then the notification; M6 on its own. Option (G2-8): move the Weekly Review share image into Wave A | Yes (D1, D18); share image stays Wave B |
| O2 | Paywall: Yearly first and selected, then Monthly, then Lifetime without "BEST VALUE"; one CTA; the CTA, terms and links in a bottom bar | Yes (D4) |
| O3 | When to create the 7-day Yearly trial (all territories). (a) Once iOS and Mac 1.4.2 are both live, then gate 14; (b) on iOS release day even if the Mac lags; (c) at submission, so App Review sees it, while live 1.4.1 meets a trial its paywall never states; (d) in the release sitting while both are PENDING_DEVELOPER_RELEASE, released at once, then gate 14 (G2-5) | (a); if the Mac lags iOS by more than 7 days, ask again |
| O4 | Subtitles by trigger; a success screen with Continue | Yes |
| O5 | Today's "Your week" card: Monday–Tuesday; Pro every week with "Last week: 82%"; free users at most 3 weeks, × final, a line with no number | Yes (D12) |
| O6 | A locked-card preview of the user's own strength shape, blurred with no numbers, plus the insight count | Yes |
| O7 | A Pro chip on Pro card headers, for every user | Yes |
| O8 | Onboarding: a "What's in Stride Pro" text button on the last page, not a full Pro page with a trial button | Yes (a full page would be the onboarding paywall that Out of scope rules out) |
| O9 | Store screenshots: the free frames first, then Weekly Review and Advanced Analytics with the chip (`-demoPro`), for iPhone and iPad, in all 6 locales; Mac in 1.5.0. This amends 1.4.1's O8 | Yes |
| O10 | Ratings: a Settings → About row only. Alternative: amend rule 4 to allow one `requestReview(in:)` after a streak milestone (the system limits it to 3 a year). Never a home-made card (5.6.1). Gemini 3.8 Flash (G2-6) recommends the alternative: 2 ratings in 7 months | Settings row only; rule 4 kept (the owner's rule) |
| O11 | Measurement: no in-app counters and no new Sentry capture; a weekly read-only snapshot; the owner reads the ratings count at each sitting | Yes |
| O12 | Prices, group levels, Family Sharing, offer codes, win-back offers | All unchanged (D16) |
| O13 | The ASC Analytics Reports request (ONGOING plus a ONE_TIME_SNAPSHOT), weighed in no decision | Yes, now (Phase 0) |
| O14 | Promotional text ×6 once the offer exists and gate 14 passed | Yes |
| O15 | New Pro categories. This amends DEV-PLAN-1.3.md:40-43. Alternate app icons are the cheapest identity perk; a Today group focus filter (show one group) turns Groups into a daily tool. Gemini 3.8 Flash (G2-7) recommends pulling one into 1.4.2. Their cost is that amendment, icon art for icons, plus a web-UI edit of Lifetime's en-US description (NEXT_SESSION_PROMPT.md:17-18) | Not in 1.4.2 by default; one of the two into 1.4.2 Wave A only if the owner amends the constraint and W0–W9 are on time, else 1.5.0 |
| O16 | 1.5.0's review notification: opt-in, Pro only, Mondays 09:00 local, generic text | Yes |
| O17 | A group widget in 1.5.0 (reopens DEV-PLAN-1.3.md:1322) | Not in 1.5.0 by default |
| O18 | Demo account: add one group (add-only, while no review is open) | Not in 1.4.2 (no deploy); with Groups in 1.5.0 |
| O19 | Submit Mac 1.4.2 with iOS on 11-25, which moves gate 10 and sitting 3 before it | Yes; if gate 10 is not green, iOS goes alone and O3 waits |
| O20 | Simulators: move the kit to Xcode 27.1's iOS 27.0 devices with new baselines, or download iOS 26.5 to keep 1.4.1's | Move to iOS 27.0 |
| O21 | StoreKit tests: borrow Soundpost-iOS18 (if free, with the Soundpost session's yes), or create Stride-StoreKit-iOS18 (2–5 GB) | Borrow |
| O22 | Fix the three IAP review notes to D11's three things (`iap_copy.py --yes`, or the web UI on a 409) | Yes, in Phase 0 after the GET |
| O23 | The conditional trial clause in all 6 descriptions in 1.4.2 | Yes |
| O24 | Drop `.timeSensitive` from the Daily Reminder in 1.4.2 | Yes |
| O25 | A keyword pass ×6 that leads with "unlimited habits" and "free" | Yes |

## 1.5.0 (25): the daily loop, then Groups worth paying for

- The branch is cut from m5's tip at 1.4.2's iOS submission.
- **The order is fixed now, on reasoning, not on readouts:** about 2 of 17 recent installs come back,
  so X2 (the daily loop) goes first whatever the readouts show. Then X1, then X3. Readout 1 can only
  put a fix first if S1 or S4 show breakage, and trim X1's size.
- No `@Model` change and no wire change.

| X | Scope | Files | Tests | Size |
|---|---|---|---|---|
| **X2** the daily loop (free), first | One pure `DailyProgress` (done, due, rest, met for the week, not started) for Today's card, the badge, the Dock, the widget and group headers. Perfect days join the review. Reminders stay quiet for a habit that is done or not due today, on the answer of the spike run during 1.4.2's review wait (can the widget remove the app's pending requests?). The Daily Reminder skips a perfect day (`.timeSensitive` already gone in 1.4.2). A reminder offer whose permission prompt appears on the tap. A "missed yesterday?" row that opens History | Shared/DailyProgress.swift, TodayView.swift, NotificationService.swift, Shared/ReminderPlan.swift, StrideWidget/Sources/StrideWidget.swift, Shared/WidgetTimelinePlan.swift | Parity across the five surfaces; a reminder never under-fires; over budget, the plan is unchanged; `notifications.py` checks against the pending store; `upgrade.sh --reminders` | L |
| **X1** Groups worth paying for | Statistics chips: All, then groups, then habits (StatsView.swift:108-129). An Overview card: the 30-day rate and mean strength, each with its 30-day change; members ranked by strength; an 8-week combined trend. "All habits" sits under Advanced Analytics, a group's Overview under Habit Groups. One cache read per render. Today's group header shows "2/3", free (TodayView.swift:268-281). New Group becomes a small sheet with a name and a colour; New Group in Settings (Pro); recolour, reorder (`sortOrder` and `touch()`), a confirmation before delete, and a Mac context menu with accessibility actions. Editing existing groups stays free. The D11 lockstep for the Groups and Analytics sentences. O18 | StatsView.swift, Views/OverviewCard.swift, TodayView.swift, Views/GroupsSection.swift, SettingsView.swift, AddHabitView.swift | The Overview equals its members' cached stats; StatsPerformanceTests; a rehearsal in which a recolour and a reorder on A arrive on B (SyncModels.swift:60-67; sync.js:779-791); a lapsed user keeps every group | M–L |
| **X3** review notification (O16) | A switch in Settings; the permission prompt only when it is turned on; Mondays 09:00; a tap opens last week; removed on lapse; re-titled on a language change (NotificationService.swift:356-360); budget 64 − 3 − 4 (ReminderPlan.swift:35) | Shared/ReminderPlan.swift, NotificationService.swift, SettingsView.swift | ReminderPlanTests; hosted tests that it is scheduled only for Pro users who opted in | S |
| **X4** carried | Whatever 1.4.2 cut or left out (D1), Wave B first | — | — | — |
| **X5** by owner decision | "Often together" (8 weeks of overlap, a lift of at least 1.5× and at least 20 points, worded as never a cause); two-column Pro cards at regular width; O15's alternate icons; O17; offer codes only if O12 changes | — | — | — |

**Never draw** price conclusions, A/B conclusions or conversion rates at this volume.

## Out of scope (this phase)

- Moving anything free behind Pro, or capping the number of habits.
- A launch or onboarding paywall, an automatic `requestReview`, a home-made review prompt, StoreKit
  Messages (rule 4, Guideline 5.6.1).
- An analytics SDK, in-app counters, A/B tests.
- App Store Server Notifications V2, until trials exist and SUBSCRIPTION_EVENT proves too slow.
- Win-back and promotional offers, Family Sharing, price changes, promoted in-app purchases.
- New Pro categories (O15).
- CloudKit and iCloud sync (DEV-PLAN-1.3.md:1324). Before any iCloud entitlement, pass
  `cloudKitDatabase: .none` (SharedModelContainer.swift:133-137).
- HealthKit, the Watch, macOS widgets, Swift Charts, a deployment-target bump.
- Import from other apps: a separate, free acquisition track.

## What success looks like (and what it cannot show)

| Signal | Source | Read | Can tell | Cannot tell |
|---|---|---|---|---|
| S1: no product-load, purchase or verification error from 1.4.2 | Sentry's existing reports (docs/privacy.html:56, :59-60) | weekly | the paywall can sell | demand |
| S2: any trial start within 45 days of the offer | SUBSCRIPTION_EVENT | weekly | that one happened | a rate, or why none did |
| S3: more than 2 ratings by 2027-02-01 | ASC Ratings and Reviews, read by the owner | each sitting | whether anyone uses the row | why |
| S4: no 3.1.2 or 5.6.1 rejection and no rule-4 regression | App Review, gate 6 | per submission | — | — |
| S5: the first subscription ever, by 2027-02-28 | SALES / SUBSCRIPTION | readout 2 | Pro sells at all | revenue |
| Weekly active devices on 1.4.2 | Sentry sessions against the Phase 0 baseline | weekly | up or flat | cohorts, feature use |
| Value-line tests 2 and 3 | W8, the lenses | each gate run | Pro is true and seen | buyers |

**Honest expectation:** by 2027-02-28, success means a few trials and Stride's first subscription, not
a revenue curve. A zero by readout 1 is not evidence of anything at this volume, and changes no plan.

## Review log (Gemini 4 Argon High, Gemini 3.8 Flash High, Claude skeptic, 2026-10-27)

**Reviewers:**
- **Gemini 4 Argon High** (`gemini-4-argon-high`) via the agy bridge: **did not run.** Both calls
  (the first and one retry, same settings, workspace a throwaway copy) returned 429
  RESOURCE_EXHAUSTED, "Individual quota reached", resetting in about 153 hours (around 2026-11-02).
  It produced no findings. The rerun is Phase 0 item 9, on this revised file.
- **Gemini 3.8 Flash High** (`gemini-3.8-flash-high`) via agy, once, on a throwaway `git archive` copy
  of 7fbb3ec plus the draft plan, with an adversarial lens (code assumptions, StoreKit trial
  eligibility, 3.1.2, privacy, l10n, Mac parity, sync and schema gating, scope, willingness to pay):
  19 findings.
- **Claude skeptic** (`claude-opus-5-5`), plan against the code at 7fbb3ec: 17 findings.
- Every finding about the code was checked at 7fbb3ec before it was accepted or rejected.

**Accepted (30):**

| # | Reviewer | Finding | What changed |
|---|---|---|---|
| G1 | Gemini 3.8 Flash | Removing Stats' two sheets leaves the locked Advanced Analytics card with no presenter. Confirmed: the toolbar and ProLockedCard share `showingPaywall` (StatsView.swift:153-156, :178-194), and ShellRequest has no paywall case (ShellState.swift:132-146) | D8: `.paywall(trigger:resume:)`; the locked card issues `.analytics`; W0 adds the case, W4 moves the card; a ShellTests case (with C2) |
| G2 | Gemini 3.8 Flash | Settings' Upgrade and lapsed rows share one sheet, so `.lapsed` cannot be passed. Confirmed (SettingsView.swift:62, :624-626, :1019, :1098) | D4 and W0: `paywallTrigger` with `.sheet(item:)`; a hosted test for each row's trigger |
| G3 | Gemini 3.8 Flash | Reordered or duplicated rows break the scan, which captures literals in source order. The draft's "written once" holds only if the source order stays D11's (LocalizationSourceScanTests.swift:196-204, :308-315) | D4: the three literals stay in D11's order in the source; the runtime order is an index permutation |
| G4 | Gemini 3.8 Flash | D6 cites PurchaseOutcome.swift:88-92 for "no date with unverified renewal info". Confirmed: that rule is `dateLine` (:246-249); :88-92 is `stillRenews`, which is right for Data safety 6 | D6's citation corrected; Data safety 6 kept |
| G5 | Gemini 3.8 Flash | :232 pins only the bullet heads outside en-US. Confirmed (:255-284; full lines en-US only, :286-293) | D11 and W12: if D11′ ships, the Weekly Review body is pinned in all 6 locales |
| G6 | Gemini 3.8 Flash | Price order is unstable while Lifetime and Yearly tie at 19.99 in the local file. Confirmed (Configuration.storekit:6, :58; StoreService.swift:141) | D4: order by plan kind, never by price; a PaywallModelTests case with tied prices |
| G8 | Gemini 3.8 Flash | StoreKit calls a Lifetime owner eligible for Yearly's trial. Confirmed: Lifetime is outside the group (Configuration.storekit:4-19). Low in practice, since every presenter gates on `!isPro` and the paywall dismisses on `isPro` (StoreService.swift:632-634) | D4: `PaywallModel` takes `isPro` and returns no trial when it is true; a test |
| G10 | Gemini 3.8 Flash | Terms and links can fall below the fold, worst on the Mac sheet (StoreService.swift:654) | D4: the CTA, terms and links in a bottom bar, the end of the scroll at accessibility sizes; gate 2 and gate 10 capture both; W3 tests |
| G11 | Gemini 3.8 Flash | Below iOS 17.2 only `offerType` exists, and `.introductory` does not say free trial. The draft named both APIs but not how to tell the kind | D6: an `@available` guard, and below 17.2 a trial only when the product's intro offer is a free trial; a PurchaseOutcomeTests case |
| G12 | Gemini 3.8 Flash | `price / 12` rounded up gives fractional yen and won | D4 (with C15): the mirror carries the currency's fraction digits; round up to the minor unit; tests in USD, EUR, JPY and KRW |
| G13 | Gemini 3.8 Flash | Two-number strings need positional specifiers; split "%lld more · %lld days left" | Accepted in part: positional specifiers, as the catalogs already use (ja Localizable.stringsdict:82-95). Not taken: the split. A stringsdict format key takes one plural variable per number (`%1$#@more@ · %2$#@days@`), so one key pluralizes both |
| G14 | Gemini 3.8 Flash | Card dismissal in `UserDefaults.standard` is per device | D12 and Data safety 9: accepted as a per-device preference and written down (another device can still show the card; a reinstall resets it) |
| G15 | Gemini 3.8 Flash | About 12 working days for W0–W11 before the freeze | D1 (with C14): Wave B is out by default, in only if W0–W9 are green on 11-10 |
| C1 | Claude skeptic | The Today rating card is a custom review prompt, which Guideline 5.6.1 disallows; only a persistent settings link is the documented placement. About is SettingsView.swift:580 | D13: the Settings row only; the card, its fixture and its cut-order slot are gone; O10 offers the rule-4 amendment for `requestReview(in:)`; risk 3; gate 6 |
| C2 | Claude skeptic | The single presenter breaks Continue and loses `.analytics` and `.today`. Confirmed: ContentView picks the destination from the live `isPro` when the sheet is built (ContentView.swift:251-256), which swaps the content or fires StoreService.swift:632-634 | D8: the destination is latched when the request is issued, with `resume`; ShellTests for buy → "unlocked" → Continue → the requested week, the locked card's `.analytics` and Today's `.today`; gate 3 |
| C3 | Claude skeptic | The strings probe cannot see literals of 15 bytes or fewer. Confirmed (mac_variant/build.sh:102-105); every proposed flag is that short | D14: a 24-byte DEBUG-only sentinel that `verify_archive` probes; the source scan stays; gate 9 |
| C4 | Claude skeptic | The versioned description would never explain the trial that the promotional text advertises. Confirmed (description.txt:51-57); en-US 3,992 and es-ES 3,984 of 4,000 (measured) | D5, D16 and W12: a conditional trial clause in all 6 descriptions, trimmed to fit; O23 |
| C5 | Claude skeptic | setup_iap.py:204 is the POST creation payload, so the live review note is not fixed. Confirmed (:194-211) | Phase 0 item 5: GET the three notes; `reviewNote` in iap_copy.py; O22; gate 5 read-back; setup_iap.py changed for future products only |
| C6 | Claude skeptic | Nobody checks the shipped trial UI against the real offer before it is promoted | Gate 14 between the offer's read-back and O14; the owner ends the offer on a failure |
| C7 | Claude skeptic | Mac parity: the offer would go live while the Mac still runs 1.4.1, and the Mac review would be the first look at live trial copy. Confirmed: the variant has no products (RELEASE-1.4.1.md:1053-1054) and StrideAppTests is iOS-only (project.yml:141-143) | O19: the Mac is submitted with iOS; O3: the offer waits for both; gate 10 captures every fixture in 6 locales at both widths; W8 tries the scheme's StoreKit configuration (project.yml:240) |
| C8 | Claude skeptic | Three lines a user can disprove. Confirmed: momentum is nil when both weeks are 0 % (StatsInsights.swift:76-80); this week counts only through the last counted day (HabitStats.swift:640-642, :691); every day of a times-per-week habit is scheduled (HabitStats.swift:360-362) | D7: the empty text by age; D8: the opening week after 4 days, highlights only from 4 counted days, "so far"; D9: neutral times-per-week days; W1, W5, W6 and W10 cases; the "disprove" lens |
| C9 | Claude skeptic | At this volume the readouts cannot decide 1.5.0; Analytics Reports are opt-in and thresholded; the API has no ratings count; a Lifetime decline cannot be seen | 1.5.0's order fixed now (X2 first); D15: breakage and existence only; the owner reads ratings; O13 weighed in nothing; risks 7 and 19; the success table |
| C10 | Claude skeptic | Exposure binds, yet acquisition waited until after January. Confirmed: uploads default to en-US (store_screenshots.py:14-15, :269) and `--lang` exists (a11y_sweep.sh:24-28). Which locales have sets today is unread | D19: localized sets and a keyword pass in 1.4.2 (O9, O25); Phase 0 item 6 reads the live sets; Wave B's share image and notes drop first; O15 puts alternate icons to the owner |
| C11 | Claude skeptic | `TodaySelection` selects a date, not a habit; the notes need text that the cache does not keep. Confirmed (Shared/TodaySelection.swift:3-26; HabitStats.swift:76-78, :14-17) | D9: W4's `shell.todayFocusHabitID`, W11's focus target, W10's live-notes read with the kept record (HabitCheckIn.swift:29-36); Data safety 4 |
| C12 | Claude skeptic | The localization work is underestimated, and StoreKit's period words would follow the system language, not the in-app picker | Accepted in part: W0 is M; period words come from the catalogs (D4); a translation lens back-translates the terms in ja and ko, zh with the owner (W12). Not taken: the store and catalog feature-name mismatch is already fixed. The old names of RELEASE-1.4.1.md:1234-1237 appear nowhere in metadata/, scripts/ or docs/, and the scan pins each bullet's head to the catalog word (LocalizationSourceScanTests.swift:269) |
| C13 | Claude skeptic | Accessibility left to the gates. Confirmed: readable orange on Today (TodayView.swift:720-724), system green and orange in StatsProCards.swift:105 and WeeklyReviewView.swift:115, the sweep cannot scroll the paywall (a11y_sweep.sh:114-121) | `Color.readableText` in D7–D10, with W5 and W6 fixing the old text; the strip is one element (D9); `-paywallScrollTo` (D14, W3); gate 8 |
| C14 | Claude skeptic | The calendar is tight against the plan's own evidence (DEV-PLAN-1.3.md:29-33) | D1: Wave B out by default with the 11-10 checkpoint; day 1 of Wave A is the StoreKit simulator, W2's SKTestSession cases and the fixtures |
| C15 | Claude skeptic | The pure model has no currency; the trial row's price needs a source that can be missing offline (StrideApp.swift:205) | D4: currency code and fraction digits on the mirror; D6: the row keeps the date and drops the price without products; a PurchaseOutcomeTests case |
| C16 | Claude skeptic | Minor inaccuracies: "Groups appear only on Today"; the simulator rule; :575 for :574; :579 for :580; iPad ⇧⌘R only on Stats (StatsView.swift:178); the free "Last week: 82%" breaks test 1 | All corrected: the Groups row cites SettingsView.swift:389-420 and AddHabitView.swift:490; O21 borrows Soundpost-iOS18 after asking; :574 and :580; D9 documents the iPad limit (MenuCommands.swift is macOS-only, :1); D12's free line has no number |
| C17 | Claude skeptic | Deferring the daily loop hurts the trial's first week. Confirmed: `.timeSensitive` (NotificationService.swift:274) with no such entitlement (Stride/Stride.entitlements:4-13); no test pins it | D17 and W9: the line is dropped in 1.4.2 (O24); X2's widget spike runs during the review wait; X2 leads 1.5.0 |

**Rejected (6):**
- **G7** Gemini 3.8 Flash, "eligibility is per group, so check it before showing a trial": already in
  the draft. Trial copy needs `isEligibleForIntroOffer == true`, unknown counts as no (D4), and W2
  tests "ineligible after an earlier Monthly". The per-group note is now written into D4.
- **G9** Gemini 3.8 Flash, "create the offer before submitting so App Review sees the trial": rejected
  as the default. It breaks the approved order (RELEASE-1.4.1.md:926-929, the offer waits for a
  paywall that shows its terms), and every live 1.4.1 user would meet a trial in Apple's sheet that
  their paywall never states, for the whole review. The gap it names is closed by gate 14 and the
  description clause (C4, C6). It stays as O3's option (c).
- **G16** Gemini 3.8 Flash, "cover purchase logic headlessly so the gate leans less on SKTestSession":
  already the design. PaywallModelTests and PurchaseOutcomeTests run host-less on macOS CI (D4, W2);
  SKTestSession covers only the StoreKit adapter, which nothing else can.
- **G17** Gemini 3.8 Flash, "a full-page Pro introduction in onboarding with a trial button": that is
  the onboarding paywall this plan rules out (Out of scope), against rule 4's spirit
  (DEV-PLAN-1.3.md:34-38), and the "40–60 % of trial starts" figure has no source. O8 keeps the text
  button; the owner can choose otherwise.
- **G18** Gemini 3.8 Flash, "defer the analytics polish a buyer never sees": the trial is the first
  week, so a trial user sees every one of these within 7 days. "Points" fixes a label that is wrong
  today (WeeklyReviewView.swift:112 prints a points difference as "%"), and the weekday window stops
  a claim the free By Weekday bars can disprove (value-line test 2). Both are small (W5 M, W6 S).
- **G19** Gemini 3.8 Flash, "a trial row with the end date, the renewal price and Manage": already D6
  ("Free trial · first charge of $19.99 on <date>", with Manage, and "Trial ends on <date>" when
  auto-renew is off).

**Also corrected while revising (not reviewer findings):**
- The iOS 26.5 simulator runtime is gone and Xcode is 27.1 (read 2026-10-27). The workflow first
  read this as "only iOS 18.5 installed, every simulator gate blocked"; checked again the same day,
  iOS 27.0 and 27.1 are installed with a new iPhone 17 Pro / Pro Max set, so the fix is moving the
  kit, not a download: Where things stand, Phase 0 item 1, O20, risk 17.
- D2 called DEV-PLAN-1.3.md:40-43 "Rule 1". Those lines are the non-negotiable constraints; rule 1 is
  "Nothing a paying user can lose" (:20-24).
- The disk has about 27 GB free (2026-10-27), which weighs on O21.

### Plan review (second Gemini pass, 2026-10-27): Gemini 3.8 Flash High, product lens

Gemini 4 Argon High (`gemini-4-argon-high`) did not run: agy answered "Individual quota reached …
Resets in 152h50m" (429 RESOURCE_EXHAUSTED) on the workflow's two calls and on a third the same
evening. As the house method says when the Pro model is unavailable, Gemini 3.8 Flash High was run
a second time, with the product-and-engineering lens meant for Gemini 4, on this revised file in a
throwaway `git archive` copy. Gemini 4 Argon stays Phase 0 item 9.

| # | Finding (severity) | Decision |
|---|---|---|
| G2-1 | `Product.priceFormatStyle` cannot format a computed `Decimal` or give fraction digits (high) | Rejected: `priceFormatStyle` is a `Decimal.FormatStyle.Currency`, so `(price / 12).formatted(product.priceFormatStyle)` works. W2 reads the currency's minor-unit digits from `Locale.Currency` / the style's own rounding, and PaywallModelTests pin USD, EUR, JPY and KRW |
| G2-2 | After a purchase the shell's sheet swaps on live `isPro`, pre-empting the success state; the New Group alert is dropped when raised during dismissal (high) | First half already D8/C2 (latched destination). Second half accepted: D6, the alert opens from the sheet's `onDismiss` |
| G2-3 | `SubscriptionStatusMirror` cannot hold StoreKit types in Shared/, and `mirror(_:)` has no products for the below-17.2 fallback (medium) | Accepted: D6, `OfferMirror` and `mirror(_:products:)` |
| G2-4 | `scrollBounceBehavior` does not pin a bottom bar (medium) | Rejected: the plan uses `safeAreaInset(edge: .bottom)` and `ViewThatFits` (D4); it never relies on `scrollBounceBehavior` |
| G2-5 | Create the trial offer while 1.4.2 is PENDING_DEVELOPER_RELEASE, not after release (high) | Put to the owner as O3 (d): create the offer in the same sitting as the MANUAL release, release at once, gate 14 on the live build. The default stays (a): the description clause is true with or without an offer (D16), and no 1.4.2 paywall is live without its terms in either order |
| G2-6 | Without `requestReview` the ratings stay at 2 (high) | Owner decision O10, with this recommendation recorded: Gemini advises amending rule 4 for one `requestReview(in:)` after a streak milestone (Apple caps it at 3 a year). The default stays the owner's rule 4 |
| G2-7 | Effort goes to analytics wording a buyer never notices; pull a tangible Pro reward (a Today group focus filter, or alternate app icons) into 1.4.2 (high) | Partly accepted: O15 now names both as 1.4.2 candidates (Wave A only if W0–W9 are on time; icons need art). W5's wording fixes stay: they stop Pro claims the free cards can disprove (value line test 2), and the trial is the first week |
| G2-8 | Weekly Review share image belongs in Wave A (medium) | Owner option on O1; default unchanged (Wave B) |
| G2-9 | Cut Wave B formally now (medium) | Rejected: Wave B is already out by default and enters only at the 11-10 checkpoint (D1); the checkpoint costs nothing |
| G2-10 | `AppStore.sync()` throws `userCancelled` on a cancelled Apple Account sheet (low) | Accepted: D6, `RestoreOutcome.cancelled` |
