import Foundation

/// The Weekly Review's and the Pro insights' week math (RELEASE-1.4.2.md D8, D10). **A W0 stub:
/// W1 fills it.**
///
/// What W1 builds here, pure, with the `Calendar` passed in and weeks Monday-anchored on UTC
/// day-keys (Data safety 5):
/// - `weekRange(containing:)` for any week, and the opening week (this week once 4 of its days
///   have passed, else last week);
/// - each habit's counted rate for any week and its strength change;
/// - the highlights ("Most improved", "Slipped") under the 4-counted-day rule;
/// - `atRisk`, remaining and daysLeft (D10), and the group section rates.
enum WeeklyReviewMath {}
