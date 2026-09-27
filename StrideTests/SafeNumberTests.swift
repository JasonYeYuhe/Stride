import XCTest

/// `SafeNumber` is what stands between a synced amount and `Int(Double)`, which traps. Each
/// case here is a number another device (or a hand-edited backup) can put in the store; before
/// 1.3.0, `1e19` or `1e999` pushed by any client made Today trap on every launch.
final class SafeNumberTests: XCTestCase {

    func testAmountShowsOrdinaryNumbersAsBefore() {
        XCTAssertEqual(SafeNumber.amount(8), "8")
        XCTAssertEqual(SafeNumber.amount(0), "0")
        XCTAssertEqual(SafeNumber.amount(-0.0), "0")
        XCTAssertEqual(SafeNumber.amount(0.5), "0.5")
        XCTAssertEqual(SafeNumber.amount(2.5), "2.5")
        XCTAssertEqual(SafeNumber.amount(1e6), "1000000")
        XCTAssertEqual(SafeNumber.amount(1000), "1000", "the target stepper's top")
        XCTAssertEqual(SafeNumber.amount(-3), "-3")
    }

    func testAmountNeverTrapsOnNonFiniteValues() {
        XCTAssertEqual(SafeNumber.amount(.infinity), SafeNumber.placeholder)
        XCTAssertEqual(SafeNumber.amount(-.infinity), SafeNumber.placeholder)
        XCTAssertEqual(SafeNumber.amount(.nan), SafeNumber.placeholder)
        XCTAssertEqual(SafeNumber.amount(.signalingNaN), SafeNumber.placeholder)
    }

    func testAmountShowsHugeValuesCompactly() {
        XCTAssertEqual(SafeNumber.amount(1e19), "1e+19")
        XCTAssertEqual(SafeNumber.amount(-1e19), "-1e+19")
        XCTAssertEqual(SafeNumber.amount(Double(Int.max)), "9.22e+18")
        XCTAssertEqual(SafeNumber.amount(.greatestFiniteMagnitude), "1.8e+308")
        XCTAssertEqual(SafeNumber.amount(1e15), "1e+15", "the first compact value")
        XCTAssertEqual(SafeNumber.amount(999_999_999_999_999), "999999999999999", "the last plain one")
        XCTAssertEqual(SafeNumber.amount(1e9), "1000000000", "DataBackup.maxAmount reads in full")
    }

    func testWholeNumberTruncatesLikeIntInsideTheRange() {
        XCTAssertEqual(SafeNumber.wholeNumber(8, in: 1...1000), 8)
        XCTAssertEqual(SafeNumber.wholeNumber(2.9, in: 1...1000), 2, "toward zero, as Int(_:) did")
        XCTAssertEqual(SafeNumber.wholeNumber(1e6, in: 1...Int.max), 1_000_000)
    }

    func testWholeNumberClampsAndNeverTraps() {
        let range = 1...1_000_000_000
        XCTAssertEqual(SafeNumber.wholeNumber(.infinity, in: range), 1_000_000_000)
        XCTAssertEqual(SafeNumber.wholeNumber(-.infinity, in: range), 1)
        XCTAssertEqual(SafeNumber.wholeNumber(.nan, in: range), 1)
        XCTAssertEqual(SafeNumber.wholeNumber(1e19, in: range), 1_000_000_000)
        XCTAssertEqual(SafeNumber.wholeNumber(-1e19, in: range), 1)
        XCTAssertEqual(SafeNumber.wholeNumber(0.5, in: range), 1, "max(1, …) as before")
        XCTAssertEqual(SafeNumber.wholeNumber(0, in: range), 1)
    }

    /// The full Int range is where a naive clamp still traps: Double(Int.max) is 2^63, one past it.
    func testWholeNumberAtTheEdgesOfInt() {
        let all = Int.min...Int.max
        XCTAssertEqual(SafeNumber.wholeNumber(1e19, in: all), Int.max)
        XCTAssertEqual(SafeNumber.wholeNumber(-1e19, in: all), Int.min)
        XCTAssertEqual(SafeNumber.wholeNumber(9.2233720368547758e18, in: all), Int.max)
        XCTAssertEqual(SafeNumber.wholeNumber(.infinity, in: all), Int.max)
        XCTAssertEqual(SafeNumber.wholeNumber(.nan, in: all), Int.min)
        let justBelow = Double(Int.max).nextDown
        XCTAssertEqual(SafeNumber.wholeNumber(justBelow, in: all), Int(justBelow))
    }

    func testUnitIntervalClampsProgress() {
        XCTAssertEqual(SafeNumber.unitInterval(0.5), 0.5)
        XCTAssertEqual(SafeNumber.unitInterval(1), 1)
        XCTAssertEqual(SafeNumber.unitInterval(8), 1)
        XCTAssertEqual(SafeNumber.unitInterval(-1e19), 0)
        XCTAssertEqual(SafeNumber.unitInterval(-.infinity), 0)
        XCTAssertEqual(SafeNumber.unitInterval(.infinity), 1)
        XCTAssertEqual(SafeNumber.unitInterval(.nan), 0)
    }

    /// End to end on the model: a count habit whose synced check-in is absurd still yields a
    /// label and a ring. Before, `Int(-1.25e18 * 100)` or `String(Int(1e19))` trapped here.
    func testAbsurdSyncedCheckInFormatsWithoutTrapping() {
        let habit = Habit(name: "Water")
        habit.habitKind = .count
        habit.targetValue = 8
        let today = Date()
        for value in [Double.infinity, -.infinity, .nan, 1e19, -1e19] {
            habit.records = [HabitRecord(date: today, value: value)]
            let logged = SafeNumber.amount(habit.loggedValue(on: today))
            XCTAssertFalse(logged.isEmpty)
            let ring = SafeNumber.unitInterval(habit.progress(on: today))
            XCTAssertTrue((0...1).contains(ring), "\(value) -> \(ring)")
        }
        habit.targetValue = 1e19
        XCTAssertEqual(SafeNumber.amount(habit.targetValue), "1e+19")
        XCTAssertEqual(SafeNumber.wholeNumber(habit.targetValue, in: 1...Int(DataBackup.maxAmount)), 1_000_000_000)
    }
}
