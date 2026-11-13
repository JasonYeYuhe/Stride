import XCTest
import Foundation

/// The one system review prompt (RELEASE-1.4.2.md N3, `ReviewPromptRule`): one test per
/// condition — the milestone (a 7-day streak, a met week), once per version, 3 days after install,
/// never during onboarding, never with a sheet showing, never in an automated run — and the source
/// check that none of it is DEBUG-only.
final class ReviewPromptRuleTests: XCTestCase {

    typealias Rule = ReviewPromptRule

    private let install = Date(timeIntervalSince1970: 1_790_000_000)
    private var tenDaysLater: Date { install.addingTimeInterval(10 * 86_400) }

    /// Every condition but the one under test holds.
    private func context(version: String = "1.4.2", lastPrompted: String? = nil, installDate: Date?? = nil,
                         now: Date? = nil, onboarded: Bool = true, sheet: Bool = false,
                         automated: Bool = false) -> Rule.Context {
        Rule.Context(appVersion: version, lastPromptedVersion: lastPrompted,
                     installDate: installDate ?? install, now: now ?? tenDaysLater,
                     onboardingCompleted: onboarded, sheetShowing: sheet, automatedRun: automated)
    }

    /// A daily habit's check-in today taking the streak from 6 to 7.
    private let sevenDays = Rule.CheckIn(unit: .day, completesDay: true, isToday: true, streakBefore: 6, streakAfter: 7)

    func testTheBaselineAsks() {
        XCTAssertEqual(Rule.decide(sevenDays, in: context()), .ask)
    }

    // MARK: - Condition 1: the milestone

    func testADailyStreakIsAMilestoneAtEachMultipleOfSeven() {
        for (before, after, milestone) in [(6, 7, true), (13, 14, true), (20, 21, true), (5, 6, false),
                                           (7, 8, false), (0, 1, false), (7, 7, false)] {
            let c = Rule.CheckIn(unit: .day, completesDay: true, isToday: true, streakBefore: before, streakAfter: after)
            XCTAssertEqual(Rule.isMilestone(c), milestone, "\(before) → \(after)")
        }
        // A rest day between: specific days count scheduled days, as the row's streak does.
        XCTAssertTrue(Rule.isMilestone(.init(unit: .day, completesDay: true, isToday: true, streakBefore: 6, streakAfter: 7)))
        XCTAssertEqual(Rule.decide(.init(unit: .day, completesDay: true, isToday: true, streakBefore: 4, streakAfter: 5),
                                   in: context()), .skip(.notAMilestone))
    }

    func testMeetingTheWeekIsAMilestoneForTimesPerWeek() {
        func checkIn(_ before: Int, _ after: Int, goal: Int = 3) -> Rule.CheckIn {
            .init(unit: .week, completesDay: true, isToday: true, streakBefore: 0, streakAfter: 0,
                  weekDoneBefore: before, weekDoneAfter: after, weeklyGoal: goal)
        }
        XCTAssertTrue(Rule.isMilestone(checkIn(2, 3)))
        XCTAssertFalse(Rule.isMilestone(checkIn(1, 2)), "not met yet")
        XCTAssertFalse(Rule.isMilestone(checkIn(3, 4)), "met before this check-in")
        XCTAssertTrue(Rule.isMilestone(checkIn(0, 1, goal: 1)))
        XCTAssertTrue(Rule.isMilestone(checkIn(0, 1, goal: 0)), "a goal below 1 counts as 1")
        // A weekly habit's "7" streak in weeks is not a 7-day streak; only the met week counts.
        XCTAssertFalse(Rule.isMilestone(.init(unit: .week, completesDay: true, isToday: true, streakBefore: 6,
                                              streakAfter: 7, weekDoneBefore: 3, weekDoneAfter: 4, weeklyGoal: 3)))
    }

    /// Only a write that completes today: an un-check, a note, a count below its target, a backfill.
    func testOnlyACompletingCheckInTodayCounts() {
        XCTAssertFalse(Rule.isMilestone(.init(unit: .day, completesDay: false, isToday: true, streakBefore: 6, streakAfter: 7)))
        XCTAssertFalse(Rule.isMilestone(.init(unit: .day, completesDay: true, isToday: false, streakBefore: 6, streakAfter: 7)))
        XCTAssertEqual(Rule.decide(.init(unit: .day, completesDay: true, isToday: false, streakBefore: 6, streakAfter: 7),
                                   in: context()), .skip(.notAMilestone))
    }

    // MARK: - Condition 2: once per version

    func testAtMostOncePerVersion() {
        XCTAssertEqual(Rule.decide(sevenDays, in: context(lastPrompted: "1.4.2")), .skip(.alreadyAskedThisVersion))
        XCTAssertEqual(Rule.decide(sevenDays, in: context(lastPrompted: "1.4.1")), .ask, "a new version may ask again")
        XCTAssertEqual(Rule.decide(sevenDays, in: context(version: "")), .skip(.alreadyAskedThisVersion),
                       "an unknown version never asks")
    }

    // MARK: - Condition 3: 3 days after install

    func testNeverInTheFirstThreeDaysAfterInstall() {
        let almost = install.addingTimeInterval(3 * 86_400 - 1)
        XCTAssertEqual(Rule.decide(sevenDays, in: context(now: almost)), .skip(.tooSoonAfterInstall))
        XCTAssertEqual(Rule.decide(sevenDays, in: context(now: install.addingTimeInterval(3 * 86_400))), .ask)
        XCTAssertEqual(Rule.decide(sevenDays, in: context(installDate: .some(nil))), .skip(.tooSoonAfterInstall),
                       "no install date recorded yet")
        XCTAssertEqual(Rule.decide(sevenDays, in: context(now: install.addingTimeInterval(-86_400))),
                       .skip(.tooSoonAfterInstall), "a clock set back before the install")
    }

    // MARK: - Condition 4: onboarding

    func testNeverDuringOnboarding() {
        XCTAssertEqual(Rule.decide(sevenDays, in: context(onboarded: false)), .skip(.onboarding))
    }

    // MARK: - Condition 5: a sheet

    func testNeverWithASheetShowing() {
        XCTAssertEqual(Rule.decide(sevenDays, in: context(sheet: true)), .skip(.sheetShowing))
    }

    // MARK: - Condition 6: automated runs (-demo, UI tests, hosted tests)

    func testNeverInAnAutomatedRun() {
        XCTAssertEqual(Rule.decide(sevenDays, in: context(automated: true)), .skip(.automatedRun))
        let app = "/private/var/containers/Bundle/Application/X/Stride.app/Stride"
        for arguments in [[app, "-demo"], [app, "-demoPro"], [app, "-paywall"], [app, "-tab", "0"],
                          [app, "-stride_onboarding_completed", "YES"], [app, "-inlineCard", "week"],
                          [app, "-NSDocumentRevisionsDebugMode", "YES"], [app, "-UITesting"]] {
            XCTAssertTrue(Rule.isAutomatedRun(arguments: arguments, environment: [:]), "\(arguments)")
        }
        for key in Rule.xcTestEnvironmentKeys {
            XCTAssertTrue(Rule.isAutomatedRun(arguments: [app], environment: [key: "x"]), key)
        }
        XCTAssertFalse(Rule.isAutomatedRun(arguments: [app], environment: ["HOME": "/"]), "a store launch")
        XCTAssertFalse(Rule.isAutomatedRun(arguments: [], environment: [:]))
        // This very process is an XCTest run.
        XCTAssertTrue(Rule.isAutomatedRun(arguments: ProcessInfo.processInfo.arguments,
                                          environment: ProcessInfo.processInfo.environment))
    }

    /// The automated-run check wins over everything, a milestone included.
    func testAnAutomatedRunIsCheckedFirst() {
        let notAMilestone = Rule.CheckIn(unit: .day, completesDay: false, isToday: false, streakBefore: 0, streakAfter: 0)
        XCTAssertEqual(Rule.decide(notAMilestone, in: context(lastPrompted: "1.4.2", onboarded: false, sheet: true,
                                                               automated: true)), .skip(.automatedRun))
    }

    /// The rule is the same in Release: nothing in ReviewPromptRule.swift is conditional, so a
    /// Release build skips an automated run exactly as these tests see it.
    func testTheRuleHasNoConditionalCompilation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Shared/ReviewPromptRule.swift"), encoding: .utf8)
        let directives = source.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if") }
        XCTAssertEqual(directives, [])
    }

    // MARK: - D13

    func testTheRateRowOpensTheWriteAReviewPage() {
        XCTAssertEqual(Rule.writeReviewURL.absoluteString, "https://apps.apple.com/app/id6761262334?action=write-review")
    }
}
