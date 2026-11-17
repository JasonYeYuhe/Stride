# App Review notes, 1.4.2 (draft, W12)

`scripts/review_notes.py 1.4.2` reads the two fenced blocks below (dry run first; `--yes` is an
**[owner]** ASC write, one per platform, after `release.py prepare 1.4.2` has made the records).
App Store Connect carries 1.4.1's notes over to the new records, so both are replaced.

- **Sign-In Information stays as it is.** The demo account's Password field holds its login token,
  rotated on 2026-11-11 (RELEASE-1.4.2.md, Submission checklist): the owner pastes the new one
  into the Password field of both records at submission. The notes only point at it ("Paste the
  Password shown above"). Never write the token, or any password, into the notes or into this file.
- **The Pro list is D11's set exactly** (RELEASE-1.4.2.md D11; Wave B is out, N1, so D11 is
  unchanged): Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength
  chart and your top 5 streaks); Weekly Review. The free detail card keeps its Best Streak tile,
  so the notes never call "best streaks" Pro.
- **The trial** (D5, the 11-09 decision): one sentence. Under N2 the 7-day Yearly offer is created
  in the release sitting, after approval, so during review StoreKit returns no introductory offer
  and the paywall shows none. The sentence says what the code does either way.
- **The review prompt** (N3): the system API only, under rule 4 as amended (DEV-PLAN-1.3.md).
- The Submission checklist's three points are all here: where Weekly Review is (Statistics'
  calendar button, or Today on Monday); a trial only when StoreKit offers one and the account is
  eligible; a Yearly trial may be added after approval.

## iOS (iPhone and iPad)

```
Stride uses magic link authentication (no passwords). To log in with the demo account:
1. Open Stride and go to Settings (the Settings tab on iPhone, the sidebar on iPad)
2. Under Account, tap Sign In
3. Tap I have a login token
4. Paste the Password shown above as the login token
5. Tap Log In

The demo account has eight habits with about three months of check-ins. It does not own Stride Pro; any plan can be bought with a Sandbox account.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review. Everything else is free.

Where to find them:
- The paywall: Settings > Upgrade to Pro; Unlock with Pro on the Advanced Analytics card in Statistics (the Stats tab on iPhone); the calendar button at the top of Statistics; or New Group when adding a habit (the + on Today). A free user's buttons show a crown.
- Advanced Analytics: in Statistics, pick a habit; the Pro cards (marked PRO) follow its free card.
- Weekly Review: the calendar button at the top of Statistics, or, on Monday and Tuesday, the card under the progress card on Today.
- Habit Groups: New Group in the Group section of New Habit or Edit Habit.

New in 1.4.2: the paywall puts the selected plan's price and terms, the purchase button and the Terms of Use and Privacy Policy links in one bar at the bottom. Yearly is selected first; Monthly and Lifetime are one tap away.

Free trial: the paywall states a free trial only when the App Store returns an introductory offer on Yearly and the account is eligible for it. At the time of this submission Yearly has no introductory offer, so the paywall shows none. We plan to add a 7-day free trial on Yearly after approval.

Ratings: Settings > About has a Rate Stride row that opens the App Store review page. Stride also calls the system rating request (StoreKit requestReview) at most once per app version, only right after a check-in that brings a streak to 7 days (or a multiple of 7) or meets a weekly goal, and never in the first 3 days, during onboarding or while a sheet is showing. There is no custom rating prompt.
```

## macOS

```
Stride uses magic link authentication (no passwords). To log in with the demo account on the Mac:
1. Open Stride and choose Stride > Settings… (Command-comma)
2. Under Account, click Sign In
3. Click I have a login token
4. Paste the Password shown above as the login token
5. Click Log In

The demo account has eight habits with about three months of check-ins. It does not own Stride Pro; any plan can be bought with a Sandbox account.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review. Everything else is free.

Where to find them:
- The paywall: Stride > Settings… under Upgrade to Pro; Unlock with Pro on the Advanced Analytics card in Statistics; View > Weekly Review (Shift-Command-R); or New Group when adding a habit (File > New Habit). A free user's buttons show a crown.
- Advanced Analytics: choose Statistics in the sidebar and pick a habit; the Pro cards (marked PRO) follow its free card.
- Weekly Review: View > Weekly Review (Shift-Command-R), the calendar button at the top of Statistics, or, on Monday and Tuesday, the card under the progress card on Today.
- Habit Groups: New Group in the Group section of New Habit or Edit Habit.

New in 1.4.2: the paywall puts the selected plan's price and terms, the purchase button and the Terms of Use and Privacy Policy links in one bar at the bottom. Yearly is selected first; Monthly and Lifetime are one click away.

Free trial: the paywall states a free trial only when the App Store returns an introductory offer on Yearly and the account is eligible for it. At the time of this submission Yearly has no introductory offer, so the paywall shows none. We plan to add a 7-day free trial on Yearly after approval.

Ratings: Settings > About has a Rate Stride row that opens the App Store review page. Stride also calls the system rating request (StoreKit requestReview) at most once per app version, only right after a check-in that brings a streak to 7 days (or a multiple of 7) or meets a weekly goal, and never in the first 3 days, during onboarding or while a sheet is showing. There is no custom rating prompt.
```

## Checked against the code (62485f0)

- Sign-in: Settings' Account section has "Sign In" (SettingsView.swift:193); LoginView has
  "I have a login token" and "Log In" (LoginView.swift:171, :248).
- Paywall entries: "Upgrade to Pro" (SettingsView.swift:1761); "Unlock with Pro" on the locked
  card (StatsView.swift:759); the Weekly Review toolbar button, `calendar.badge.clock` with a
  crown for free users (StatsView.swift:195-210); "New Group" with a crown (AddHabitView.swift:509-535).
  Every press goes through D8's latched request (MenuCommandRules), so a free user meets the
  paywall and a Pro user the review.
- Mac menu: View (`CommandGroup(before: .toolbar)`) → "Weekly Review", ⇧⌘R (MenuCommands.swift:85-98);
  File → New Habit (`.newItem`, :70).
- Today's card: Monday 00:00 to Tuesday 23:59 local time, under the progress card, once last week
  has a counted rate; a free user sees it in at most 3 weeks (W7, InlinePrompts).
- Paywall bar and order: W3 (D4); the trial terms appear only when the model's trial flag is set,
  i.e. Yearly's intro offer is a free trial, `isEligibleForIntroOffer` returned true and the user
  is not Pro (PaywallModel, W2).
- Rate Stride: Settings → About (SettingsView.swift:608, :621).
- Review prompt: `ReviewPromptRule` and `ReviewPrompter` (W7): once per `CFBundleShortVersionString`,
  after a check-in on today that lifts the streak to a multiple of 7 or takes a times-per-week
  count across its goal; never in the first 3 days after the install date, during onboarding,
  with a sheet, alert or cover up, or in an automated run.
- Demo account: reseeded 2026-11-11 with the rotated token (8 habits, 521 entries).
