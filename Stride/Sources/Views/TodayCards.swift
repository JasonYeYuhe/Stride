import SwiftUI

/// Today's inline cards (RELEASE-1.4.2.md D12). **A W0 stub: W7 fills it.**
///
/// W7 adds the "Your week" card here, under the progress card: for Pro "Last week: 82%" and "See
/// your Weekly Review"; for a free user "Your Weekly Review is ready" with no number and a crowned
/// "See your Weekly Review", which issues `.paywall(trigger: .today, resume: last week's review)`.
/// When it shows is `InlinePrompts`' (Shared/), and it only reads and navigates (Data safety 3).
enum TodayCards {}
