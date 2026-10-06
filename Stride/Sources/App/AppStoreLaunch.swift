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
    /// What the error screen advises beyond Try Again, for the current failure: the race's
    /// advice alone only the first time its signature shows (`StoreUnavailableAdvice`).
    private(set) var advice: StoreUnavailableAdvice?

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
        let phase = Self.settle(open(), prepare: prepare, report: report)
        self.phase = phase
        self.advice = Self.advice(for: phase, previous: nil)
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
        let previous = failure
        phase = Self.settle(result, prepare: prepare, report: report)
        advice = Self.advice(for: phase, previous: previous)
    }

    private static func advice(for phase: Phase, previous: StoreOpenFailure?) -> StoreUnavailableAdvice? {
        guard case .unavailable(let failure) = phase else { return nil }
        return StoreUnavailableAdvice(failure, previous: previous)
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
            StoreUnavailableView(isRetrying: launch.isRetrying, failure: launch.failure, advice: launch.advice ?? .tryAgain) {
                Task { await launch.retry() }
            }
        }
    }
}

/// "Stride couldn't open your data", full screen, with Try Again. Shown instead of the app when
/// the store would not open even after the retries (`StoreOpenRetry`): never an empty app that
/// looks like the habits are gone.
///
/// The race (`StoreUnavailableAdvice.tryAgain`) gets the calm line alone. Any other failure, or
/// the race's codes again after a Try Again, adds a line with the error's code and the remedy
/// that can work — free storage, or reinstall and sign in when the habits are synced — and
/// Contact Support (review round): restarting cannot mend a damaged file or a full disk, and the
/// screen used to offer nothing else. It never opens another store either way.
struct StoreUnavailableView: View {
    let isRetrying: Bool
    var failure: StoreOpenFailure?
    var advice: StoreUnavailableAdvice = .tryAgain
    let retry: () -> Void

    /// The support page (docs/support.html, the App Store listing's Support URL), which has the
    /// contact address.
    static let supportURL = URL(string: "https://jasonyeyuhe.github.io/stride-site/support")!

    var body: some View {
        ContentUnavailableView {
            Label("Stride couldn't open your data", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text("Nothing was changed or deleted. Try again in a moment. If it keeps happening, restart your device and open Stride again.")
                if let failure, advice != .tryAgain {
                    remedy(failure)
                }
            }
        } actions: {
            if isRetrying {
                ProgressView()
            } else {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
            if failure != nil, advice != .tryAgain {
                Link("Contact Support", destination: Self.supportURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each remedy is a whole key; the code goes in as numbers and an untranslated domain.
    @ViewBuilder
    private func remedy(_ failure: StoreOpenFailure) -> some View {
        switch advice {
        case .tryAgain:
            EmptyView()
        case .freeStorage:
            Text("Your device may be out of storage. Free up some space, then tap Try Again. (Error \(failure.domain) \(failure.code))")
        case .reinstallIfSynced:
            Text("If it still fails and you sync with a Stride account, delete Stride, install it again and sign in: your synced habits come back. Without an account, contact support first — deleting Stride also deletes the habits on this device. (Error \(failure.domain) \(failure.code))")
        }
    }
}
