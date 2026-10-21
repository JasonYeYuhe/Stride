# App Review notes, 1.4.1 (draft, W9)

The repository has no other home for review notes: they live only in App Store Connect, on each
version record (App Review Information → Notes). `release.py prepare` creates the 1.4.1 records,
and App Store Connect carries the previous version's review information over to them (1.4.0's Mac
record arrived with notes that pointed at a Settings row 1.4.0 had removed, RELEASE-1.4.0.md:946-948).
After `prepare`, read both records back; each then needs the text below in place of what was
carried over. That is an **[owner]** ASC write, one per platform.

What 1.4.0 holds (read back 2026-10-21, GET `/v1/appStoreVersions/{id}/appStoreReviewDetail`;
redacted copy in the W9 gate evidence, `asc-readback.md`):
- **iOS:** still the 1.2 text: "v1.2 adds habit groups + advanced analytics behind Stride Pro";
  it leaves out Weekly Review, and its sign-in steps ("tap Log In in Settings") are older than the
  Account section.
- **macOS:** corrected for 1.4.0 (RELEASE-1.4.0.md:946-948). Pro = Habit Groups, Advanced
  Analytics, Weekly Review.
- Both records: demo account required, user name and password set. **Keep the Sign-In Information
  fields as they are.** The Password field holds the demo account's login token, and the notes
  only point at it ("Paste the Password shown above"). Never write the token, or any password,
  into the notes or into this file.

The Pro list is D11's set exactly (RELEASE-1.4.1.md D11): Habit Groups; Advanced Analytics
(Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); Weekly Review. The
free detail card keeps its Best Streak tile, so the notes never call "best streaks" Pro.

## iOS (iPhone and iPad)

```
Stride uses magic link authentication (no passwords). To log in with the demo account:
1. Open Stride and go to Settings (the Settings tab on iPhone, the sidebar on iPad)
2. Under Account, tap Sign In
3. Tap I have a login token
4. Paste the Password shown above as the login token
5. Tap Log In

The demo account has eight habits with about three months of check-ins.

New in 1.4.1:
- Strength: open Statistics (the Stats tab on iPhone), pick a habit, and see the Strength tile on its card.
- History: on the same card, tap Edit history, or tap a day on the habit's heatmap. Pick a past day to check it in or out or change a count; once a day has a check-in, you can add a note to it.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review. Everything else is free, including the Strength score and History. The paywall is under Settings > Upgrade to Pro, or Unlock with Pro on the Advanced Analytics card in Statistics.
```

## macOS

```
Stride uses magic link authentication (no passwords). To log in with the demo account on the Mac:
1. Open Stride and choose Stride > Settings… (Command-comma)
2. Under Account, click Sign In
3. Click I have a login token
4. Paste the Password shown above as the login token
5. Click Log In

The demo account has eight habits with about three months of check-ins.

New in 1.4.1:
- Strength: choose Statistics in the sidebar, pick a habit, and see the Strength tile on its card.
- History: on the same card, click Edit history, or click a day on the habit's heatmap. Pick a past day to check it in or out or change a count; once a day has a check-in, you can add a note to it.

Stride Pro (monthly, yearly, or a one-time Lifetime purchase) adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend chart, the Strength chart and your top 5 streaks); and Weekly Review. Everything else is free, including the Strength score and History. The paywall is in Stride > Settings… under Upgrade to Pro, or Unlock with Pro on the Advanced Analytics card in Statistics.
```

## Checked against the code (eccdd49)

- Sign-in: SettingsView's Account section has the Sign In row (SettingsView.swift:169-193);
  LoginView has "I have a login token" and "Log In" (LoginView.swift:171, :248). On the Mac,
  Settings is its own window (ContentView.swift:174). iPhone's tab is "Settings"; Statistics' tab
  is labelled "Stats" and titled "Statistics" (ContentView.swift:205-233).
- Strength: the detail card's fourth tile (StatsView.swift:514-519), free (D10).
- History: the card's "Edit history" button (StatsView.swift:399-414) and a heatmap tap
  (StatsView.swift:1168) open HabitHistoryView; its note field needs a check-in on that day
  (HabitHistoryView.swift:498-516).
- Pro: Statistics' locked card is "Advanced Analytics" with "Unlock with Pro" (StatsView.swift:155,
  :705); Settings' row is "Upgrade to Pro" (SettingsView.swift:1025). The paywall rows are
  `testProClaimsNameExactlyD11sSet`'s three.
- Demo account: seed-demo.js and ops/demo-add-habits.js, eight habits, about 90 days (gate 2).
