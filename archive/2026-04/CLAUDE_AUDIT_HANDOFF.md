# Claude Handoff: Stride Audit and Fix Scope

Last updated: 2026-04-11

## Goal

Please take over implementation work for the highest-priority issues found in this repository audit.

The project is an iOS/macOS/watchOS/widget app with a Node.js backend in `server/`.

## Highest-Priority Problems

### 1. Cross-device sync is incomplete and can lose or resurrect data

Evidence:

- Client sync models already include reminder and note-related fields:
  - `Stride/Sources/Services/APIClient.swift`
  - `Stride/Sources/Services/SyncService.swift`
- Server sync endpoints do not persist or return those fields:
  - `server/routes/sync.js`
  - `server/db.js`
- Client pull logic only upserts local data and does not apply remote deletions:
  - `Stride/Sources/Services/SyncService.swift`

Observed risks:

- Deleting a habit or entry on device A may never delete it on device B.
- Reminder settings and notes can silently disappear across devices.
- Feature implementation is currently inconsistent between app and server.

Required direction:

- Introduce a proper sync contract that supports:
  - habit deletion propagation
  - entry deletion propagation
  - reminder field round-trip
  - note field round-trip
- Update backend schema and routes as needed.
- Update client pull/push logic so remote deletions are actually applied locally.
- Add tests for these cases.

### 2. Widget toggle flow does not fully participate in sync deletion tracking

Evidence:

- Widget direct toggle:
  - `StrideWidget/Sources/StrideWidget.swift`
- Deletion tracking only exists in app-side sync service calls:
  - `Stride/Sources/Services/SyncService.swift`
  - `Stride/Sources/Views/TodayView.swift`

Observed risk:

- Completing from widget may be recoverable via full push.
- Un-completing from widget can fail to sync correctly because the delete tombstone is not tracked.

Required direction:

- Make widget-originated deletions participate in the same deletion tracking strategy as the main app.
- Verify both complete and un-complete flows sync correctly.

### 3. Static legal/support pages are broken in server runtime/deployment shape

Evidence:

- Server serves static files from `server/docs`:
  - `server/index.js`
- Actual pages exist in repository root:
  - `docs/index.html`
  - `docs/privacy.html`
  - `docs/terms.html`
  - `docs/support.html`
- Deployment doc says only `server/` is copied:
  - `server/DEPLOY.md`

Direct verification already performed locally:

- `GET /health` returned `200`
- `GET /privacy` returned `404`
- `GET /terms` returned `404`

Required direction:

- Fix static asset pathing and/or deployment assumptions.
- Ensure the deployed server can actually serve these pages.
- Update deployment docs to match reality.

### 4. App cold start session restore and auto-sync timing is unreliable

Evidence:

- Session restore is asynchronous:
  - `Stride/Sources/Services/AuthService.swift`
- Startup sync gate depends on `AuthService.shared.isLoggedIn`, which depends on `currentUser`:
  - `Stride/Sources/App/StrideApp.swift`

Observed risk:

- If a token exists in Keychain on cold launch, the app can skip initial sync before session restoration finishes.

Required direction:

- Make startup auth/session restoration deterministic.
- Ensure auto-sync happens after session validation, not before.

## Important Secondary Problems

### 5. CI does not cover enough surface area

Evidence:

- Current CI:
  - `server` tests
  - iOS build
  - macOS build
- Missing:
  - `StrideTests`
  - widget target validation
  - watch target validation
  - sync regression tests around cross-device state

File:

- `.github/workflows/ci.yml`

### 6. Config/domain/docs drift

Evidence:

- API base URL in app:
  - `Stride/Sources/Services/APIClient.swift`
- Frontend origin used in auth mail flow:
  - `server/routes/auth.js`
- Deployment doc hostnames:
  - `server/DEPLOY.md`

Required direction:

- Normalize the domains and operational docs.
- Avoid future breakage in magic links, CORS, or deployment cutovers.

## Repo State Notes

There are unrelated untracked files in the worktree. Do not revert or delete them unless explicitly necessary:

- `.mcp.json`
- `ExportOptions.plist`
- `Stride/PrivacyInfo.xcprivacy`
- `gemini-review-todo.md`
- `todo.md`
- `upload.sh`

## Validation Already Performed

Local checks already run successfully:

- `cd server && npm test`
- `xcodebuild build -scheme Stride -project Stride.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild build -scheme StrideMac -project Stride.xcodeproj -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -scheme StrideTests -project Stride.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO`

This means the current issues are mostly logic/integration/deployment gaps rather than basic compile failures.

## Recommended Execution Order

1. Fix sync contract and persistence gaps.
2. Fix widget sync deletion behavior.
3. Fix server static page serving and deployment doc mismatch.
4. Fix startup auth/session restore and auto-sync timing.
5. Expand CI and regression coverage.

## Expected Deliverables

- Code changes implementing the fixes above.
- Tests covering the new sync behavior and key regressions.
- Updated docs where runtime/deployment assumptions changed.
- A concise summary of:
  - what was changed
  - what was verified
  - any residual risks or follow-up items
