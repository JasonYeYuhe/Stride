import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Crash + app-hang reporting ONLY — no APM/RUM (Datadog / New Relic own that),
/// no screenshots / view-hierarchy / PII, and request data is stripped so no
/// user content can leave the device. No-ops while the `SentryDSN` Info.plist
/// key is empty, so this is safe to ship before the DSN is provisioned. In
/// targets that don't link sentry-cocoa, `canImport(Sentry)` is false and
/// `start()` compiles to an empty no-op.
///
/// Privacy note: enabling this (setting a real SentryDSN) means the app now
/// collects "Crash Data" / "Other Diagnostic Data" sent to a third party —
/// declare it in PrivacyInfo.xcprivacy + the App Store privacy nutrition label
/// (not linked to identity, not used for tracking) before shipping with a DSN.
enum SentryBootstrap {
    static func start() {
        #if canImport(Sentry)
        guard
            let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
            !dsn.isEmpty
        else { return }
        SentrySDK.start { options in
            options.dsn = dsn
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
