import XCTest
import SwiftData
@testable import Stride

/// History and Today's past days (RELEASE-1.4.1.md D6, D7, D8), hosted. **Owner: W4.**
/// Scaffolded by W0: no tests yet.
///
/// TODO(W4): a pulled note survives an open editor; a 600-character stored note survives a
/// value edit; the habit deleted while History is open; Today's filter (a habit created today
/// is absent on yesterday, and present after a History backfill of yesterday); after a
/// second-context delete, a tap on that row creates and deletes nothing.
@MainActor
final class HabitHistoryTests: XCTestCase {}
