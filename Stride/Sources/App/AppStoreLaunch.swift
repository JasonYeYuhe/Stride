import SwiftUI
import SwiftData
#if canImport(Sentry)
import Sentry
#endif

/// The app's store, as the launch found it: opened (`ready`), or not openable, in which case the
/// app shows `StoreUnavailableView` and nothing else (upgrade race, E2E U123).
///
/// Until 1.3.1 a failed open fell back to a NEW EMPTY default.store. The user saw "Start Your
/// Journey" with every habit hidden, the one-time delivery migration spent its done flag on the
/// empty store, and the next launch pushed the whole real store. Now a failure opens nothing
/// else and runs nothing that touches data — no `prepare` (the day-key and delivery migrations),
/// no sync, no badge, no widget reload: all of that hangs off `ready`. The error (codes only) is
/// reported once per failed open, and Try Again opens the same real store again.
@MainActor
@Observable
final class AppStoreLaunch {
    enum Phase {
        case ready(ModelContainer)
        case unavailable(StoreOpenFailure)
    }

    private(set) var phase: Phase
    private(set) var isRetrying = false

    typealias Open = @Sendable () -> Result<ModelContainer, StoreOpenFailure>

    @ObservationIgnored private let open: Open
    @ObservationIgnored private let prepare: @MainActor (ModelContainer) -> Void
    @ObservationIgnored private let report: (StoreOpenFailure) -> Void

    /// Opens at once, synchronously: the first frame already knows which screen it draws.
    /// - `open`: the real store or a failure, never another store (`SharedModelContainer.openForApp`).
    /// - `prepare`: the launch's data work, run once, on the opened store, before `ready` — so
    ///   before any view's task can sync.
    /// - `report`: a failed open, codes only.
    init(open: @escaping Open,
         prepare: @escaping @MainActor (ModelContainer) -> Void,
         report: @escaping (StoreOpenFailure) -> Void) {
        self.open = open
        self.prepare = prepare
        self.report = report
        self.phase = Self.settle(open(), prepare: prepare, report: report)
    }

    var container: ModelContainer? {
        if case .ready(let container) = phase { return container }
        return nil
    }

    var failure: StoreOpenFailure? {
        if case .unavailable(let failure) = phase { return failure }
        return nil
    }

    /// The error screen's Try Again. The open blocks for up to `StoreOpenRetry.budget`, so it
    /// runs off the main thread while the screen shows progress.
    func retry() async {
        guard container == nil, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let open = self.open
        let result = await Task.detached(priority: .userInitiated) { open() }.value
        phase = Self.settle(result, prepare: prepare, report: report)
    }

    private static func settle(_ result: Result<ModelContainer, StoreOpenFailure>,
                               prepare: @MainActor (ModelContainer) -> Void,
                               report: (StoreOpenFailure) -> Void) -> Phase {
        switch result {
        case .success(let container):
            prepare(container)
            return .ready(container)
        case .failure(let failure):
            report(failure)
            return .unavailable(failure)
        }
    }

    /// To Sentry: a fresh NSError carrying only the domain and code — Core Data's own error holds
    /// the store's path and metadata in `userInfo`, and none of it may leave the device
    /// (docs/privacy.html lists this report). The underlying error's codes and the attempt count
    /// go as tags. A no-op under XCTest and wherever Sentry is not linked.
    nonisolated static func reportToSentry(_ failure: StoreOpenFailure) {
        #if canImport(Sentry)
        let error = NSError(domain: failure.domain, code: failure.code)
        _ = SentrySDK.capture(error: error) { scope in
            scope.setTag(value: "open", key: "store.step")
            scope.setTag(value: String(failure.attempts), key: "store.attempts")
            if let domain = failure.underlyingDomain {
                scope.setTag(value: domain, key: "store.underlying_domain")
            }
            if let code = failure.underlyingCode {
                scope.setTag(value: String(code), key: "store.underlying_code")
            }
        }
        #endif
    }
}

/// The app's window content: the app over its store, or, when the store could not be opened, the
/// error screen and nothing else. `content` is built only once there is a container, so nothing
/// in it — the launch sync, the badge, the widget reloads, onboarding — can run without one.
struct StoreGateView<Content: View>: View {
    let launch: AppStoreLaunch
    @ViewBuilder let content: (ModelContainer) -> Content

    var body: some View {
        if let container = launch.container {
            content(container)
        } else {
            StoreUnavailableView(isRetrying: launch.isRetrying) {
                Task { await launch.retry() }
            }
        }
    }
}

/// "Stride couldn't open your data", full screen, with Try Again. Shown instead of the app when
/// the store would not open even after the retries (`StoreOpenRetry`): never an empty app that
/// looks like the habits are gone.
struct StoreUnavailableView: View {
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Stride couldn't open your data", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Nothing was changed or deleted. Try again in a moment. If it keeps happening, restart your device and open Stride again.")
        } actions: {
            if isRetrying {
                ProgressView()
            } else {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
