# Stride v1.2.2 — release record

**Submitted to App Review 2026-09-09.** App ID `6761262334`, bundle `yyh.stride.habittracker`.

| Item | Build | State at submit |
|---|---|---|
| iOS 1.2.2 | 16 | `WAITING_FOR_REVIEW` |
| macOS 1.2.2 | 16 | `WAITING_FOR_REVIEW` |

1.2.1 (build 15) reached `READY_FOR_SALE` on both platforms before this went out.

## Why this release exists

1.2.1 restored crash reporting, and the first thing worth reporting was that four
serious defects had been shipping for months. None were visible from this machine —
see "Why nothing caught these" below.

### 1. Sync push never worked, and signing in destroyed local data — `0177d93`

`APIClient` encoded with `keyEncodingStrategy = .convertToSnakeCase` while the
backend reads *and* emits camelCase. Pull worked by accident (`.convertFromSnakeCase`
passes underscore-free keys through untouched); push did not:

- every entry hit `if (!e.id || !e.habitId || !e.date) continue` — **no check-in
  ever reached the server**;
- habits stored only `id`/`name`; colour, reminders, target value, schedule and
  group membership all fell back to server defaults;
- deletions never propagated;
- and the full pull then returned `entries: []`, so `SyncService`'s reconciliation
  deleted **every local `HabitRecord`** whose id was missing from that empty set.
  The unconditional habit upsert then overwrote local customisations with the
  server's defaults.

Signing in wiped the user's entire check-in history from the device. Second bug in
the same file: `pullChanges(since:)` appended `?since=…` to the path and handed it
to `appendingPathComponent`, which percent-encodes `?` — every incremental pull
requested `/v1/sync/pull%3Fsince=…` and 404'd, so the destructive full-pull path ran
exactly once, at first sign-in.

Both date from `3829085`, the commit that introduced sync. **Server-side half is
already deployed** (it accepts both casings), so shipped ≤ 1.2.1 clients are safe
without updating. That shim is temporary — remove it once ≤ 1.2.1 is gone.

### 2. Streaks read zero everywhere west of UTC — `a958d90`

`HabitCalendar.dayKey(for:)` was not idempotent. Streak/schedule math re-keys
values that are already day-keys (`isScheduled`, `weekStart`, `completionRate`),
and re-keying re-reads the instant in the *local* calendar, so at any negative UTC
offset it moved back a day — and the weekday with it:

    UTC / Asia/Tokyo      2026-09-04 Fri -> 2026-09-04 Fri
    America/New_York      2026-09-04 Fri -> 2026-09-03 Thu

For a Mon/Wed/Fri habit in New York every scheduled day reported `false` and every
rest day `true`; `currentStreak()` skipped the real days and broke on Saturday, so
the streak read 0 no matter how perfect the record. Fixed at the root — `dayKey` now
returns an existing key unchanged — which repairs all six call sites at once.

Also folded in: `SharedModelContainer.modelContainer` was a computed `var`, handing
each caller a fresh `ModelContainer` over the same store (`StrideShortcuts` built one
per Siri invocation). Now a lazily-initialised `let`.

### 3. The widget was never in the app — `6c3c0c2`, `266e9eb`

`Stride.app` had no `PlugIns/` directory and the project had no
`PBXCopyFilesBuildPhase` at all. The dependency pointed the wrong way
(`StrideWidgetExtension -> Stride, embed: false`), which builds cleanly and embeds
nothing. Meanwhile the listing sells widgets in four places, including
"All widget styles unlocked" as a paid **Pro** benefit.

Building it for the first time exposed two more latent defects:

- `Shared/SentryBootstrap.swift`'s `#if canImport(Sentry)` found the app's
  `Sentry.framework` in the shared products directory, tried to rebuild the module
  from its `.private.swiftinterface`, and failed (binary built with Swift 5.9.2,
  toolchain 6.3.3). Excluded from the widget and watch targets, neither of which
  references it.
- the App Store refused the upload with error 90360: the extension's `Info.plist`
  had no `CFBundleDisplayName`.

`StrideWatch` is deliberately **not** embedded: no metadata anywhere claims an Apple
Watch app, so shipping one would add icon/provisioning/screenshot requirements for a
promise never made. The reversed dependency is fixed for it too, so it is one line
away if ever wanted.

### 4. Magic-link tokens were written to the server log — `a9079c1`

The request logger printed `originalUrl`, and the magic-link email points at
`/login?token=…`. Hitting that page does **not** consume the token — it only renders
it for the user to paste — so every logged token stayed valid until used or expired.
`redactUrl` now masks token/session/key/password values.

## Why nothing caught these

- **278 server tests pushed camelCase** — the server's own assumption on both sides
  of the seam. Nothing asserted the bytes Swift actually serialises. There is now a
  wire-format contract test that pushes a real client payload.
- **The date suite only exercised non-negative UTC offsets** (Asia/Tokyo, plus one
  Los Angeles *local instant*, never a key), and CI runs UTC. Regression tests now
  walk both offset signs.
- **A target that is never built cannot fail to build.** Verify the product, not the
  project file: `ls Stride.app/PlugIns`.
- **A pipe swallows a failing script's exit code.** The failed 90360 upload *looked* like
  it exited 0, and this record originally blamed the `|| true` on the export step for it.
  **That diagnosis was wrong** (corrected 2026-09-15). The script did stop: `set -euo
  pipefail` halted it at the failed upload — no "Upload complete", no "Build Complete",
  and macOS never started. The 0 came from the command it was run with,
  `build-appstore.sh all --upload | tail -60`, which reports `tail`'s status; the
  `pipefail` inside the script does not reach the shell that launched it. `ship.sh` calls
  the script unpiped under its own `pipefail`, so unattended releases were never exposed.
  (The `|| true` is real but minor: it can hide a failed *export* step, after which the
  upload step re-exports from the archive and fails loudly on its own.) Lesson: never read
  a release script's outcome through a pipe — check `$?` unpiped, or the artifact itself.

## Also in this release

- Production's loopback-bind security fix (2026-07-27) existed **only on the host**
  and was one rsync from being reverted; it is now in the repo (`22f134b`). Overwriting
  it would have re-exposed port 3002, and with `trust proxy` set a direct caller can
  forge `X-Forwarded-For` and defeat every per-IP limit — including the one guarding
  an unauthenticated mail send on a Resend key shared with ColorArchive.
- `server/DEPLOY.md` now documents the dry-run/diff/backup procedure that caught it.
- `release.py`'s What's New is keyed by version, so re-running `prepare` for an older
  release can no longer overwrite that release's copy.

## Known-inaccurate metadata (unresolved)

`description.txt` claims widgets are "Available in small, medium, and large sizes",
but only five families are declared and `.systemLarge` is not among them — no large
layout exists. "5 different widget styles" is accurate. Either implement a large
widget or amend the copy; this predates the release and has passed review repeatedly,
but now that widgets actually exist a reviewer could check.

## Verification

Swift 73/73 · server 282/282 · both builds `VALID` on ASC · widget confirmed in the
archive (`NSExtensionPointIdentifier = com.apple.widgetkit-extension`,
`CFBundleDisplayName = Stride`) · server fix verified end-to-end through the public
TLS endpoint against production, with the test user removed afterwards.
