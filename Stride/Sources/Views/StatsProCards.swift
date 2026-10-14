import SwiftUI

// The Pro cards M4 adds to Statistics (RELEASE-1.4.1.md D10), shown inside StatsView's
// `store.isPro` branch beside InsightsCard and TrendCard; ProLockedCard sells them for everyone
// else, in D11's words ("your top 5 streaks"). **Owner: W3.** Scaffolded by W0: both bodies are
// empty and nothing shows them yet.
//
// TODO(W3):
// - Both read the cached `HabitStats` (StatsCache, D3) that StatsView passes in, never
//   `Habit`'s wrappers.
// - New `-statsScrollTo strength|beststreaks` anchors (StatsView.statsLaunchAnchor).
// - The free tier keeps its Best Streak tile on the detail card, where "Total" becomes
//   "Strength" (D10, O7), so no copy sells "your best streaks" as Pro (D11).
// - Strings: the new keys are in the W0 key list (scratchpad w0/keys.json, for the catalogs).

/// Strength, 0–100, with Δ30, Δ90 and weekly bars in TrendCard's hand-rolled style (no Swift
/// Charts), plus D9's one-sentence explanation. From `HabitStats.strength`,
/// `strengthDelta30`/`strengthDelta90` and `weeklyStrength`.
struct StrengthCard: View {
    let habit: Habit
    let stats: HabitStats

    var body: some View {
        // TODO(W3)
        EmptyView()
    }
}

/// The habit's top 5 runs, dated, longest first (`HabitStats.bestStreakRanges`), in the habit's
/// streak unit (days, or Monday-anchored weeks for times-per-week).
struct BestStreaksCard: View {
    let habit: Habit
    let stats: HabitStats

    var body: some View {
        // TODO(W3)
        EmptyView()
    }
}
