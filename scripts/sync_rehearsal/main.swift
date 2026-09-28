import Foundation
import SwiftData

// scripts/sync_rehearsal.sh's tool: Shared/ (the SHIPPING sync engine, planner, resolver and
// reconciler) plus this directory, compiled into one macOS binary and run against the local
// test server the script started. Prints one line per check as it goes, then the PASS / FAIL /
// SKIPPED table, and exits 1 on any FAIL.

@MainActor
func main() async -> Int32 {
    // Line-buffered even into a pipe, so the check lines and the server's / CoreData's stderr
    // interleave in the order they happened.
    setvbuf(stdout, nil, _IOLBF, 0)
    let report = Report()
    let scenarios = Scenarios(report: report)
    let started = Date()
    print("sync rehearsal against \(Rehearsal.base.absoluteString) (1.3.1 devices send \(Rehearsal.client131))")

    var plan: [(String, () async throws -> Void)] = [
        ("S1 delivery state", scenarios.deliveryState),
        ("S3 2,500-entry first upload", scenarios.firstUpload2500),
        ("S4 2 KB notes", scenarios.notes2KB),
        ("S5 failure at chunk 2", scenarios.failureAtChunk2),
        ("S6 row_error hold", scenarios.rowError),
        ("S7 mixed fleet", scenarios.mixedFleet),
        ("S8 300 ms apart", scenarios.editsThreeHundredMsApart),
        ("S9 skewed clock", scenarios.skewedClock),
        ("S10 truncated full pull", scenarios.truncatedFullPull),
        ("S11 run binding", scenarios.runBinding),
        ("S13 untap + re-tap", scenarios.untapAndReTap),
        ("S14 migrated marks proof", scenarios.migratedMarksProof),
    ]
    if Rehearsal.env["STRIDE_REHEARSAL_LARGE"] == "1" {
        plan.append(("S12 20,000 entries (timed)", scenarios.largeAccount))
    }
    for (name, run) in plan {
        report.current = name
        print("\n\(name)")
        let t = Date()
        do {
            try await run()
        } catch {
            // A scenario that could not finish is a failure, never a silent skip.
            report.check("scenario ran to the end", false, "threw \(error)")
        }
        print(String(format: "  (%.1f s)", Date().timeIntervalSince(t)))
    }
    scenarios.skipped()

    report.current = "whole run"
    let all = HTTPTransport.all.flatMap(\.exchanges)
    let limited = all.filter { $0.status == 429 }
    report.check("no request in the whole rehearsal was answered 429", limited.isEmpty,
                 "\(all.count) requests, \(limited.count) × 429")

    printTable(report.checks)
    let counts = Dictionary(grouping: report.checks, by: \.verdict).mapValues(\.count)
    print(String(format: "\n%d PASS, %d FAIL, %d SKIPPED in %.0f s",
                 counts[.pass] ?? 0, counts[.fail] ?? 0, counts[.skipped] ?? 0, Date().timeIntervalSince(started)))
    return report.failed ? 1 : 0
}

func printTable(_ checks: [Check]) {
    print("\n" + String(repeating: "=", count: 100))
    print("RESULT   SCENARIO                      CHECK")
    print(String(repeating: "-", count: 100))
    for c in checks {
        let verdict = c.verdict.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let scenario = c.scenario.padding(toLength: 29, withPad: " ", startingAt: 0)
        print("\(verdict) \(scenario) \(c.name)")
        if c.verdict != .pass { print("         \(String(repeating: " ", count: 29)) ↳ \(c.detail)") }
    }
    print(String(repeating: "=", count: 100))
}

exit(await main())
