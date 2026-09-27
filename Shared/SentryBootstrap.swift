import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Crash + app-hang reporting ONLY — no APM/RUM (Datadog / New Relic own that),
/// no screenshots / view-hierarchy / PII, and request data is stripped so no
/// user content can leave the device. In targets that don't link sentry-cocoa
/// (StrideWidgetExtension), `canImport(Sentry)` is false and
/// `start()` compiles to an empty no-op.
///
/// The DSN is a compiled-in constant rather than a build setting, and that is
/// deliberate. It used to be delivered as `INFOPLIST_KEY_SentryDSN` in
/// project.yml, which never worked: with `GENERATE_INFOPLIST_FILE = YES` Xcode
/// copies only a fixed 95-name allowlist of `INFOPLIST_KEY_*` settings into the
/// generated Info.plist and drops every other name SILENTLY — no warning, no
/// error, the build stays green. `SentryDSN` is not on that allowlist, so the
/// key was set on both app targets, never reached the built Info.plist, this
/// lookup returned nil, and `start()` bailed at the guard below on every launch
/// of every shipped build. The defect is invisible from the project file and
/// from this source; it shows up only in the Info.plist *inside the built app*,
/// which is where it was finally caught (uploaded 1.2.0(14) archive).
///
/// The Info.plist lookup is kept as an override so a fork or a rebuild that
/// supplies an explicit `INFOPLIST_FILE` can point at its own Sentry project
/// without touching code. Hard-coding the DSN is safe: a Sentry DSN is a
/// publishable, write-only ingest key, designed to ship inside every
/// distributed binary. It is not a secret and grants no read access.
///
/// Privacy note: this collects "Crash Data" / "Other Diagnostic Data" sent to a
/// third party — already declared in PrivacyInfo.xcprivacy and the App Store
/// privacy nutrition label (not linked to identity, not used for tracking).
enum SentryBootstrap {
    /// Compiled into the binary so Info.plist generation cannot drop it again.
    private static let defaultDSN =
        "https://461897892c305803cfd5d06c2b62a502@o4511263220891648.ingest.us.sentry.io/4511513693585408"

    static func start() {
        #if canImport(Sentry)
        // Not under XCTest. StrideAppTests (hosted) launches the real app as its test host, so
        // without this every test run — the ship.sh gate, and CI booting a fresh simulator
        // each time — started production Sentry with the live DSN: the first runs on
        // 2026-09-27 filed a dozen abnormal sessions against the live 1.2.3+17 release,
        // polluting the only crash-free-rate denominator this app has.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        // Info.plist wins when a build supplies one; otherwise the constant.
        let override = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String
        let dsn = (override?.isEmpty == false) ? override! : defaultDSN
        guard !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            #if DEBUG
            // Simulator and Xcode runs would otherwise count as production sessions of
            // whatever version the tree is at; release health filters on environment.
            options.environment = "development"
            #endif
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.tracesSampleRate = 0.0          // crash/error only, no perf tracing
            #if os(iOS) || os(tvOS)
            // Screenshot / view-hierarchy capture is UIKit-only (absent on macOS);
            // explicitly disabled here for privacy regardless.
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif
            options.sendDefaultPii = false
            options.beforeSend = { event in
                event.request = nil                 // strip URLs / headers / bodies
                return event
            }
        }
        #endif
    }
}
