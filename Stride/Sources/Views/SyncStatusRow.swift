import SwiftUI
import SwiftData

// Today's sync rows (DEV-PLAN-1.3.md M2, "Sign-in that stays" + "Sync status where the user
// works"; acceptance 9 and 10). What to show is decided in Shared/SyncStatusLine.swift, where
// StrideTests cover it; this file only draws it and runs the reauth row's tap.
//
// Everything here is inline: a row in Today's scroll view, drawn when the state says so and gone
// when it does not. Nothing is presented because a sync answered something — the only sheet is
// the sign-in the user opens by tapping "Sign in again" (acceptance 10).

extension SyncStatusLine {
    /// The line for Today from the live services, or the DEBUG launch scenario.
    ///
    /// Read inside a view's `body`: AuthService and SyncService are `@Observable`, so the view is
    /// redrawn when a sync ends, the backoff changes or the session goes. The counts are the
    /// view's (`SyncStatusCounts`, refreshed on saves and when a sync ends), because reading the
    /// store on every render is not free.
    ///
    /// `now` is when the line is drawn; tests pass a later one to see the window lapse.
    @MainActor
    static func today(auth: AuthService, sync: SyncService, counts: SyncStatusCounts.Counts,
                      now: Date = Date()) -> SyncStatusLine? {
        #if DEBUG
        if let scenario = launchScenario { return scenario }
        #endif
        return make(SyncStatusInput(
            signedIn: auth.isLoggedIn,
            // A 401 this launch (in memory), or a session the launch check found gone and deleted
            // (persisted: a cold launch after a revocation has no 401 to see — acceptance (9)).
            needsReauth: sync.needsReauth || auth.sessionExpired,
            ownerConflict: sync.ownerConflict != nil,
            backoff: sync.backoff?.reason,
            // The gate's own test (`SyncBackoffStore.decision`), so "Offline" lasts exactly as
            // long as automatic syncs are held back by that failure (review critic-2).
            retryAt: sync.backoff.flatMap { $0.isWaiting(at: now) ? $0.retryAt : nil },
            lastSync: SyncTimestamp.parse(sync.lastSyncTime),
            pending: counts.pending,
            held: counts.held))
    }

    #if DEBUG
    /// `-syncStatus signInAgain|paused|offline|waiting|held|synced|justSynced` draws that state on
    /// Today whatever the services say, so scripts/a11y_sweep.sh and the screenshot runs can
    /// capture each one on a simulator with no server — none of them can be produced there on
    /// demand (a revoked session, the pause switch). DEBUG-only like ContentView's `-paywall`:
    /// a release build has no way to show a state that is not true.
    static let launchScenario: SyncStatusLine? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-syncStatus"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "signInAgain", "reauth": return .signInAgain
        case "paused": return .paused
        case "offline": return .offline(waiting: 3, until: .distantFuture)
        case "waiting": return .waiting(3)
        case "held": return .held(2)
        case "synced": return .synced(Date().addingTimeInterval(-120))
        case "justSynced": return .synced(Date())
        default: return nil
        }
    }()
    #endif
}

/// The reauth row or the status line, for one `SyncStatusLine`.
struct SyncStatusRow: View {
    let line: SyncStatusLine

    var body: some View {
        switch line {
        case .signInAgain:
            SignInAgainRow()
        case .paused:
            SyncStatusLabel(systemImage: "pause.circle") { Text("Sync paused") }
        case .offline(let count, let until):
            // Once the window lapses, worded as `make` would word it from then on, a count
            // (review critic-2): Today may not be redrawn before the next foreground, and
            // "Offline" would stay up on a device that is online again. Checked once a minute,
            // not at `until`: an explicit schedule starts from its FIRST date even when that is
            // in the future, and never fired its last one (both measured, macOS 27) — so
            // `.explicit([until])` drew the count at once, and a past date plus `until` never
            // flipped. `.everyMinute` behaves as documented; the flip lags by under a minute.
            TimelineView(.everyMinute) { context in
                if max(context.date, Date()) < until {
                    SyncStatusLabel(systemImage: "icloud.slash") { Text("Offline — \(count) changes waiting") }
                } else {
                    Self.waiting(count)
                }
            }
        case .waiting(let count):
            Self.waiting(count)
        case .held(let count):
            SyncStatusLabel(systemImage: "exclamationmark.circle", tint: .orange) {
                Text("\(count) changes can't sync — see Settings")
            }
        case .synced(let date):
            // Once a minute, so "2 min ago" does not stay on screen for an hour. `context.date`
            // is the START of the current minute, not now: a stamp 120 s old read "1 minute ago",
            // and a sync after the boundary a negative interval — so the later of the two.
            TimelineView(.everyMinute) { context in
                SyncStatusLabel(systemImage: "checkmark.icloud") {
                    SyncedText(date: date, now: max(context.date, Date()))
                }
            }
        }
    }

    /// "3 changes waiting to sync": `.waiting`, and `.offline` once its window has lapsed.
    private static func waiting(_ count: Int) -> some View {
        SyncStatusLabel(systemImage: "arrow.triangle.2.circlepath") { Text("\(count) changes waiting to sync") }
    }
}

/// One quiet line: a small symbol and a footnote, secondary, never red — none of these states is
/// something the user did wrong or must act on now (the reauth row is the one that asks).
private struct SyncStatusLabel<Content: View>: View {
    let systemImage: String
    var tint: Color = .secondary
    @ViewBuilder let text: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            text
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        // One element, read as its sentence: the symbol only repeats it.
        .accessibilityElement(children: .combine)
    }
}

/// "Synced just now" / "Synced 2 minutes ago", in the in-app language.
///
/// `RelativeDateTimeFormatter` in `LanguageManager.stringLocale` and `appCalendar`, not its
/// defaults: those follow the SYSTEM language, and a Japanese-picked app would read "Synced
/// 2分前" — English words inside a Japanese sentence, the WeekStripView bug. Not `appLocale`
/// either: under "System" on a device language Stride does not ship (French, German…), the
/// sentence key falls back to English while `appLocale` is fr_FR, and Today read "Synced il y a
/// 2 minutes". `stringLocale` is the language the sentence actually resolved in, in the device's
/// region (en_FR), and equals `appLocale` whenever a language is picked. Under a minute, and for
/// a stamp in the future (the clock moved back since), it says "just now" rather than "in 0
/// seconds".
private struct SyncedText: View {
    let date: Date
    let now: Date

    var body: some View {
        if now.timeIntervalSince(date) < 60 {
            Text("Synced just now")
        } else {
            let dateLabel = Self.relative(date, now: now)
            Text("Synced \(dateLabel)")
        }
    }

    @MainActor
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageManager.shared.stringLocale
        formatter.calendar = appCalendar
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Sign in again

/// "Sign in again to keep syncing" (M2, "Sign-in that stays"): the last sync was answered 401.
///
/// Until 1.3.1 the only signal was "Please log in again" in red at the foot of Settings, which
/// nobody sees from Today; the device went on looking signed in and synced nothing. Nothing was
/// reset by the 401 — rows keep `syncedAt` and holds, the cursor and the deletion queue stay —
/// so signing back into the same account resumes and uploads nothing twice.
///
/// The tap first asks the server about the stored session (`AuthService.checkSession`):
/// - `{user: null}` — the session is gone: the dead token is deleted and the device is signed
///   out, so the login sheet behaves as a normal sign-in. Without this, a login link tapped in
///   Mail would be ignored as "already signed in" (`handleLoginLink` refuses to replace a stored
///   session), and the sheet would never close (it closes when `isLoggedIn` turns true, and it
///   never turned false);
/// - a user — the session is fine (a 401 on a run's captured token that has since been
///   replaced): a sync runs instead, and the row goes away if it succeeds;
/// - no answer (offline) — the sheet opens anyway; its own errors say why nothing can be sent.
///
/// After the sheet closes signed in, a sync runs at once (user-initiated, so no backoff), as
/// Settings does; a different account signed in there meets the account screen, not a merge.
private struct SignInAgainRow: View {
    @Environment(\.modelContext) private var modelContext
    private var auth = AuthService.shared
    private var sync = SyncService.shared

    @State private var showingLogin = false
    @State private var isChecking = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button {
            Task { await signInAgain() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                    // Decoration: at the largest sizes it took a third of the row from the text.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text("Sign in again to keep syncing")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if !typeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appSecondaryBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isChecking)
        .accessibilityHint("Opens sign-in")
        .sheet(isPresented: $showingLogin, onDismiss: syncIfSignedIn) {
            LoginView()
        }
    }

    private func signInAgain() async {
        isChecking = true
        defer { isChecking = false }
        if auth.hasStoredSession {
            await auth.checkSession()
            if auth.isLoggedIn {
                await sync.sync(context: modelContext)
                if !sync.needsReauth { return }
            }
        }
        showingLogin = true
    }

    private func syncIfSignedIn() {
        guard auth.isLoggedIn else { return }
        Task { await sync.sync(context: modelContext) }
    }
}
