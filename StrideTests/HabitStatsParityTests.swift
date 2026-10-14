import XCTest
import SwiftData
import Foundation

/// `HabitStats` against today's `Habit` methods (RELEASE-1.4.1.md D2, Data safety 3).
/// **Owner: W1.** Scaffolded by W0: no tests yet.
///
/// TODO(W1), in W1's FIRST commit, before `Habit`'s aggregates switch over: golden values from
/// the current methods on the fixtures (daily, specificDays, 3×/week, count partials,
/// backdated, ghost, DST, UTC−9; same-day duplicates — a count habit below and above target,
/// a yes/no habit with two records; a record after today; a record before `createdAt` across a
/// DST change; a deletion saved by a second `ModelContext` on the same container), run in the
/// default zone and under `TZ=America/Los_Angeles`. Only D2's named fixes may differ;
/// `Habit.isCompletedOn` equals the per-day answer on every fixture day (except the
/// second-context fixture, where only the store-id answer is right); and
/// `bestStreakRanges.first?.length == bestStreak()` everywhere.
@MainActor
final class HabitStatsParityTests: XCTestCase {}
