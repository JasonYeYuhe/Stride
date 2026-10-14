import XCTest
import Foundation

/// `HabitScore` (RELEASE-1.4.1.md D9). **Owner: W1.** Scaffolded by W0: no tests yet.
///
/// TODO(W1): empty = 0; always 0…1; the recomputed reference values (30 perfect days 0.798,
/// 100 days 0.995, one miss after 60 days −4.98 points); recovery; rest days unchanged; a
/// 3×/week habit decays slower than a daily one under identical misses; Mon/Wed/Fri on a
/// 3×/week habit has a daily INPUT of 1.0 every day and a monotonic score (an EMA from 0 never
/// reaches 1.0); count 4/8 today equals yesterday's score and 8/8 raises it; a 3×/week habit
/// unchecked today equals yesterday's score and decays the next day; editing the target or
/// schedule re-scores the whole history (2026-10-15 decision 8).
final class HabitScoreTests: XCTestCase {}
