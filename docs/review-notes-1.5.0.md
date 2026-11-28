# App Review notes, 1.5.0 (draft, V6)

`scripts/review_notes.py 1.5.0` reads the two fenced blocks below (dry run first; `--yes` is an
**[owner]** ASC write, one per platform, after `release.py prepare 1.5.0` has made the records).
App Store Connect carries 1.4.2's notes over to the new records, so both are replaced.

- **Sign-In Information stays as it is.** The demo account's Password field holds its login token
  (rotated 2026-11-11, pasted at the 1.4.2 submission). The notes only point at it ("Paste the
  Password shown above"). Never write the token, or any password, into the notes or into this file.
  Gate 10's demo account check (`check_demo_account.sh`, read-only) runs before submission; the
  demo-topup cron keeps this week's check-ins current.
- **The Pro list is D11's set** with D8's Weekly Review sentence (RELEASE-1.5.0.md D8): Habit
  Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5
  streaks), both word for word as in 1.4.2; Weekly Review, "any week at a glance: what improved and
  what is at risk". No notes and no share image (1.5.1).
- **Where Weekly Review is** (Submission checklist): Statistics' calendar button, or Today's card
  on Monday and Tuesday; on Mac also View > Weekly Review. Today shows one card at a time, and the
  missed-yesterday card comes first (D5), so the notes say how to pass it ("Not now").
- **Reminders stay quiet once a habit is done** (D4, D5): local notifications only, planned on the
  device; nothing is sent from a server.
- **The trial** (1.4.2's sentence, updated): the Yearly 7-day free trial has been live since
  1.4.2's release (O3, gate 14), so the sentence no longer says "no introductory offer". It still
  says what the code does: the paywall states a trial only when StoreKit returns the offer and the
  account is eligible.
- **The review prompt** (N3): the system API only, unchanged from 1.4.2.

## iOS (iPhone and iPad)

```
Stride uses magic link authentication (no passwords). To log in with the demo account:
1. Open Stride and go to Settings (the Settings tab on iPhone, the sidebar on iPad)
2. Under Account, tap Sign In
3. Tap I have a login token
4. Paste the Password shown above as the login token
5. Tap Log In

The demo account has eight habits with more than three months of check-ins. It does not own Stride Pro; any plan can be bought with a Sandbox account.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review (any week at a glance: what improved and what is at risk). Everything else is free.

Where to find them:
- The paywall: Settings > Upgrade to Pro; Unlock with Pro on the Advanced Analytics card in Statistics (the Stats tab on iPhone); the calendar button at the top of Statistics; or New Group when adding a habit (the + on Today). A free user's buttons show a crown.
- Advanced Analytics: in Statistics, pick a habit; the Pro cards (marked PRO) follow its free card.
- Weekly Review: the calendar button at the top of Statistics, or, on Monday and Tuesday, the card under the progress card on Today. Today shows one card at a time: if a card about habits not checked yesterday is showing, tap Not now to see the Weekly Review card. In the review, the arrows at the top go to earlier weeks and back; under At risk this week, tapping a habit shows it on Today.
- Habit Groups: New Group in the Group section of New Habit or Edit Habit.

New in 1.5.0 (free): Today's count leaves out rest days and habits whose weekly goal is already met; a card on Today offers to show yesterday when a habit was not checked; and once a habit is checked in (in the app, from the widget, or with Mark Done on a notification), its reminders stay quiet for the rest of that day. Reminders are local notifications scheduled on the device; nothing is sent from a server.

Free trial: Yearly has a 7-day free trial. The paywall states it only when the App Store returns the introductory offer for Yearly and the account is eligible for it; otherwise it shows the plan's price alone.

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

The demo account has eight habits with more than three months of check-ins. It does not own Stride Pro; any plan can be bought with a Sandbox account.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review (any week at a glance: what improved and what is at risk). Everything else is free.

Where to find them:
- The paywall: Stride > Settings… under Upgrade to Pro; Unlock with Pro on the Advanced Analytics card in Statistics; View > Weekly Review (Shift-Command-R); or New Group when adding a habit (File > New Habit). A free user's buttons show a crown.
- Advanced Analytics: choose Statistics in the sidebar and pick a habit; the Pro cards (marked PRO) follow its free card.
- Weekly Review: View > Weekly Review (Shift-Command-R), the calendar button at the top of Statistics, or, on Monday and Tuesday, the card under the progress card on Today. Today shows one card at a time: if a card about habits not checked yesterday is showing, click Not now to see the Weekly Review card. In the review, the arrows at the top (or Command-Left Arrow and Command-Right Arrow) go to earlier weeks and back; under At risk this week, clicking a habit shows it on Today.
- Habit Groups: New Group in the Group section of New Habit or Edit Habit.

New in 1.5.0 (free): Today's count leaves out rest days and habits whose weekly goal is already met; a card on Today offers to show yesterday when a habit was not checked; and once a habit is checked in (in the app or with Mark Done on a notification), its reminders stay quiet for the rest of that day. Reminders are local notifications scheduled on the Mac; nothing is sent from a server.

Free trial: Yearly has a 7-day free trial. The paywall states it only when the App Store returns the introductory offer for Yearly and the account is eligible for it; otherwise it shows the plan's price alone.

Ratings: Settings > About has a Rate Stride row that opens the App Store review page. Stride also calls the system rating request (StoreKit requestReview) at most once per app version, only right after a check-in that brings a streak to 7 days (or a multiple of 7) or meets a weekly goal, and never in the first 3 days, during onboarding or while a sheet is showing. There is no custom rating prompt.
```

## Checked against the code (aac3cd0 + V6)

- Sign-in, paywall entries, the Mac menu and Rate Stride: unchanged since 1.4.2's notes
  (docs/review-notes-1.4.2.md); View → "Weekly Review", ⇧⌘R (MenuCommands.swift:94-97); the
  Statistics toolbar button `calendar.badge.clock` (StatsView.swift:195-210).
- The review's week arrows: "Previous week" / "Next week", ⌘← / ⌘→, bounded by the earliest
  habit's start and this week (WeeklyReviewView.swift:255-283). "At risk this week" is shown on
  this week only (:136); a row's tap is "Show on Today" (:442-443), which writes nothing (D6).
- Today's cards, one at a time in this order: missed yesterday ("Show yesterday" / "Not now"),
  the week card (Monday and Tuesday, unchanged), the reminder offer (TodayCards.swift; D5).
- Quiet when done: the full plan with each habit's quiet days (D4), run from the app, from
  `ToggleHabitIntent.perform` in the widget and after Mark Done (`CheckInEffects.live`, 5e4eac4).
  All local `UNUserNotificationCenter` requests; none of the three targets has the push
  entitlement (`aps-environment`).
- The trial: the paywall's terms appear only when the model's trial flag is set (Yearly's intro
  offer is a free trial, `isEligibleForIntroOffer` is true, the user is not Pro; PaywallModel).
  The Yearly 1-week offer is live (RELEASE-1.4.2.md, O3 and gate 14, 2026-11-26).
