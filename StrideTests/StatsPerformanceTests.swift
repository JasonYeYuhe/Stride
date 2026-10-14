import XCTest
import SwiftData
import Foundation

/// Statistics timings at scale (RELEASE-1.4.1.md Data safety 4), host-less, in the
/// SyncPerformanceTests pattern: each measurement bounded at 5× its first value and printed
/// with `PERF`. **Owner: W1.** Scaffolded by W0: no tests yet.
///
/// TODO(W1): 10 habits × 730 days — the full `HabitStats` build, 100 cached reads, a widget
/// read over 2 day-keys, and the uncached wrapper path (84 `isCompletedOn` plus
/// `currentStreak` per habit), which must run no strength walk; 50 × 1,095 (54,750 entries) —
/// a full build.
@MainActor
final class StatsPerformanceTests: XCTestCase {}
