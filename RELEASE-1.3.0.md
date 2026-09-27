# Stride v1.3.0 — release record

App ID `6761262334`, bundle `yyh.stride.habittracker`. **In progress**: M0 (server, CI, ops)
is done and the server half is live; the 1.3.0 client (DEV-PLAN-1.3.md M1) has not been built.

1.2.3 (build 17) has been `READY_FOR_SALE` on iOS and macOS since 2026-09-17. This release
follows [DEV-PLAN-1.3.md](DEV-PLAN-1.3.md): M0 lands everything the incremental-push client
(1.3.1) will depend on, while every shipped app keeps working unchanged; M1 is 1.3.0 itself.

## M0 — shipped ahead of the build (server, CI, ops)

Branch `m0/server-ci-ops`. The server half is three commits — `b384fe6` (contract),
`2911f87` (ops), `44f863f` (rehearsal script) — rehearsed on a copy of production and
**deployed 2026-09-27 10:25 UTC**. It reaches every installed app without an update, and is
additive for all of them: shipped apps decode only `ok` from a push.

### The sync contract the 1.3.1 client will build on — `b384fe6`

Today every app pushes its whole history on every sync, so a row the server silently dropped
came back next time and nobody noticed. Once apps send only what changed (M2), a silent drop
is a row that never syncs. So:

- **A push says what it did not apply, and why.** `{ok, applied, skipped:{habits,entries,
  groups}, skippedReasons}`. The reason decides the client's action — `tombstoned` means drop
  it, `unknown_habit` / `skipped_habit` mean retry once the habit lands, `not_owned*` means
  rows from the previous account after an account switch (re-id them), `missing_field` /
  `row_error` mean quarantine. One bad row never fails the request: SQLite errors are caught
  per row and reported as `row_error`, because the 1.3.1 client backs off on 5xx, and a row
  that 500'd its chunk would have stopped that account for good.
- **A pull says how much there is.** `totals:{habits,entries,groups}`, read in the same
  transaction as the arrays, so a client deletes local rows missing from a full pull only when
  the pull is provably complete.
- **Tombstones are no longer swept.** An app ≤ 1.2.3 that pulls past a swept window cannot be
  told (it has no `cursor_expired` handler) and pushes the deleted rows back on its next
  snapshot. They stay until a 426 minimum-version floor retires that cohort.
- **A pause switch, not a snapshot switch.** A flag file on the host answers every sync request
  `503 sync_paused` with `Retry-After`; support can ask *one* account for a full re-upload
  (`409 snapshot_required`, one-shot, recorded). There is no global re-upload switch — it would
  have every app push its whole history in the same minute.
- **Rate limits by account.** Sync is limited per account (60/min) and exempt from the global
  per-IP limiter, which a household behind one address could exhaust; requests without a
  session keep a per-IP limit.
- **Sliding sessions.** A Bearer session with less than 15 days left extends to 30 days (at
  most one write per ~15 days per session). This removes the silent day-30 logout that
  surfaced only as a red Settings footer.
- **The AASA file** for one-tap sign-in from the email link (M1), served now because Apple's
  CDN caches it for hours.
- **Counters that decide when the old paths can go**: hits on the snake_case shim, habits
  arriving without `kind`, the legacy `/sync` `/auth` `/habits` mounts, and accounts per
  client build (`ops/usage-report.js`). These numbers, not a date, decide when the shim, the
  legacy mounts, the 426 floor and tombstone sweeping can return.

Server suite 302 → 375, `npm run typecheck` now covers `lib/` and `ops/`. The operator's view
of all of it — every status code a client can get and who can get it, the pause switch,
snapshot requests, the usage report — is in [server/DEPLOY.md](server/DEPLOY.md).

### Ops — `2911f87`, `44f863f`

- **`backup.sh` is in the repo** (it lived only on the host). It refuses a missing or empty
  database — `sqlite3` on a missing path creates an empty one and backs it up with
  `integrity_check: ok`, so fourteen such nights would have aged out every real backup — counts
  users in what it wrote, and prunes only nightly files: the old glob also expired the
  predeploy/preseed rollback points after 14 days.
- **Nightly restore drill** (04:10 UTC): restores the newest backup into a private temp
  directory, integrity and foreign-key checks, fails on a missed night, an empty database or
  users halving overnight. Sentry message plus cron check-in once `SENTRY_DSN` exists.
- **Daily demo-account top-up** (03:50 UTC), see the decisions below.
- **`scripts/rehearse_server.sh`**: the prod-copy rehearsal, scripted. It is now step 3 of the
  deploy procedure and must pass before the real rsync.
- `scripts/ops/check_email_auth.sh`: SPF / DKIM / DMARC for the magic-link sender.

### Deploy verification (production, 2026-09-27)

- Rehearsal on a copy of production: **20/20** checks passed.
- `GET /.well-known/apple-app-site-association` → 200 `application/json`.
- Demo account full pull: `totals` 6 / 133 / 0, equal to the array lengths.
- Push with one entry whose habit does not exist → 200, the id in `skipped.entries`, reason
  `unknown_habit`.
- `GET /v1/sync/pull?since=<400 days ago>` → 409 with `X-Stride-Client: ios/1.3.1(19)`, 200
  without it.
- A 20-day-old session's `expires_at` moved from now + 10 d to now + 30 d.
- Root crontab gained the 03:50 top-up and 04:10 drill; ColorArchive's lines untouched, the
  old crontab saved in `/root/backups`. First runs: `backup.sh` integrity ok, users 4; the
  top-up added 43 check-ins, a re-run added 0; the restore drill ok.
- `scripts/check_demo_account.sh` green again. It had been **stale (exit 3)**: the last demo
  check-in was 2026-09-16, and streaks count back from today with one day of grace.

### CI and project — `4d59f4f`

- **One Apple job on the `xcode-27` image**, pinned to the Xcode major that ships (it fails
  rather than test another compiler): XcodeGen drift check, a generic-iOS build with product
  checks (widget embedded, both privacy manifests, Info.plist, Sentry), `StrideTests` on
  macOS, a macOS build with product checks, and the hosted tests on a simulator. A cheap
  `Changed areas` job decides which halves run; `release/**` is covered.
- **Pre-push hook** (`scripts/install-git-hooks.sh`): the drift check and the generic iOS
  build + product check before Apple-side commits leave the Mac — the gate that does not
  depend on a preview runner.
- **`StrideAppTests`**, a hosted suite (`APIClient`, `SyncService.sync` ordering,
  `AuthService`, `NotificationService`, `StoreService`) through injected seams — never the
  host app's Keychain, defaults or notification store. A `ship.sh` gate.
- **`verify_archive.sh`**, two modes: the archive's contents, and the Distribution-signed
  export — signer, no `get-task-allow`, associated domains. The 1.2.3 archive is signed
  *Apple Development* with `get-task-allow`; only the export carries the Distribution
  signature, so that is where entitlements can be asserted.
- **`build-appstore.sh`**: a failed export is now fatal (it was `|| true` since the script's
  first commit), and uploads are queued until every platform has passed both gates, so
  `all --upload` sends nothing to App Store Connect unless iOS *and* macOS pass. `ship.sh` is
  one call to it.
- `generateEmptyDirectories: false`: a local-only empty folder put a group into the committed
  project that a clean checkout could not reproduce, and the drift check failed on it.
- `CFBundleDisplayName` added to both apps (the 1.2.3 archives had none); `1C8F.1` (app-group
  defaults) added to the app's privacy manifest.
- `Configuration.storekit` wired into the Stride and StrideMac run actions.
- Root hygiene: the April 2026 notes and the v1.0 upload script moved to `archive/2026-04/`
  (not `docs/`, which GitHub Pages publishes); `README.md` added.

### StrideWatch removed

The watchOS target is gone from `project.yml`, and `StrideWatch/` from the tree. It was never
embedded — no "Embed Watch Content" phase, absent from the 1.2.3 archive — so no user ever
had it; it had no path to the server; and it was never sold. It still cost a build and a
place in every accessibility and localization pass. The sources are in git history, last
present at `ab9e854`. Comments and three dead `#elseif os(watchOS)` branches remain in
`Shared/` (harmless; clean up when those files are next touched).

### Decisions and deviations from DEV-PLAN-1.3.md

| Plan said | Done | Why |
|---|---|---|
| Push returns `skipped` ids | Also `skippedReasons` per id | The same "skipped" needs opposite client actions (drop vs retry vs re-id). With ids alone, a keep-and-merge after an account switch would acknowledge the old account's rows and the next full pull would delete what the user chose to keep. |
| Array caps of 500 habits / 5,000 entries / 200 groups | Same caps; **deletion lists uncapped** | Deleting history queues one tombstone per record, and M2 sends every deletion in the first chunk. The 5 MB body limit still bounds them, as it always has. |
| Caps for every request | **Only for `X-Stride-Client` ≥ 1.3.1**, like `cursor_expired` | A shipped app cannot split a push; for it a 400 is as fatal as a 413, and it would never sync again. |
| Errors as `{error:code}` | A `code` always; apps with no header get the **human sentence in `error`** | 1.2.3 prints `error` verbatim in the Settings footer. With a valid header: `{error:code, code, message}` — so **1.3.0's `APIClient` must display `message ?? error`** (an M1 item), or 1.3.0 users read `rate_limited`. |
| Add `Stride/PrivacyInfo.xcprivacy` to the widget | The widget has **its own manifest** (`1C8F.1` only, no collection) | The app's manifest declares email and habit content the widget never collects; ASC combines both into one report anyway. |
| Weekly cron re-seeding the demo account | **Daily top-up** that only inserts | `seed-demo.js` deletes the account's sessions and re-creates its habits under new ids: on a timer it would sign a reviewer out mid-review and replace everything on their device. And weekly is too slow — two days without a check-in zero every streak (`check_demo_account.sh` exit 3). The top-up never writes on or before a day the reviewer un-checked something, and leaves habits the reviewer created alone. |
| A new Azure VM snapshot | **None; the existing weekly incremental snapshots** | `pull-offsite.sh` on the Mac already takes one weekly and keeps four (09-05, 09-11, 09-17, 09-24), under $1/month. DEPLOY.md documents a manual one before OS upgrades. |
| Owner action: wipe `stride.db` on the DO droplet | **Nothing to wipe** | The droplet was destroyed on 2026-08-30 with its database (the owner's ledger); DEPLOY.md had said until 2026-09-26 that it was kept. |
| ASC check on intro offers; M1 disclosure line if kept | **ASC has none**; `Configuration.storekit` and `setup_iap.py` aligned to that | Production Monthly ($2.99) and Yearly ($19.99) carry no introductory offer, so there is no Guideline 3.1.2 exposure and **no disclosure line is needed in M1**. The local config and the setup script still described $0.99 / $9.99 intro offers; they now match production. |
| `verify_archive.sh` called by `ship.sh` | Called by `build-appstore.sh` for each platform (which `ship.sh` calls), with the associated-domains check on the **export** | See "CI and project" — the archive is development-signed. DEV-PLAN-1.3.md amended. |
| Hosted tests only as a local `ship.sh` gate | Also a CI step on the preview image | Costs nothing when the runner exists; `ship.sh` remains the gate that does not depend on it. |
| Acceptance (3): delete `embed: true` → red | **Set `embed: false`** → red | In XcodeGen 2.45.3 an app's extension dependencies embed by default, so deleting the line changes nothing and the check correctly stays green. DEV-PLAN-1.3.md amended. |

## Owner actions still open

- [ ] **Sentry project for the server.** Create `stride-server` (Node/Express) in org
  `jason-yeyuhe`, add `SENTRY_DSN=` to `/root/stride-server/.env`,
  `sudo pm2 restart stride-server --update-env`, then run
  `ops/restore-drill.js` once without `--dry-run-sentry`. Until then a failed drill — and so a
  failed backup night — is visible only in `/root/backups/stride-restore-drill.log`.
- [ ] **Sentry uptime monitor** on `https://stride-api.colorarchive.me/health`: 1-minute
  interval, 10 s timeout, downtime threshold 2, recovery 1, email. It is the org's second
  monitor, $1/month pay-as-you-go (set a PAYG budget ≥ $1). Acceptance (5): stop pm2 for
  150 s → exactly one alert, then a resolve.
- [ ] **DMARC** at Namecheap: `_dmarc.stride.colorarchive.me TXT "v=DMARC1; p=quarantine;
  adkim=r; aspf=r; rua=mailto:<owner address>"` (or `p=none` with `rua` for two weeks first),
  then `scripts/ops/check_email_auth.sh`.
- [ ] **The ASC `.p8` keys**: move the two `AuthKey_*.p8` files out of iCloud Drive's
  Downloads into the out-of-repo secrets directory (mode 600), and `chmod 600
  ~/private_keys/AuthKey_*.p8` (currently 644) — or point `scripts/.env`'s `ASC_KEY_PATH` at
  the secrets directory and remove `~/private_keys`.
- [ ] **DigitalOcean console**: the Droplets page is empty and the September invoice (due
  1 October) is $0.00; then `ssh-keygen -R 143.198.85.72`.
- [ ] Once 1.2.3 is settled: delete the `stride-predeploy-20260915-*`, `-20260916-*` and
  `stride-preseed-20260916-*` files in `/root/backups` by hand; they no longer expire.

## TODO — CI evidence (M0 acceptance 3)

_Not yet run. Fill in with run links._

- [ ] First push of this branch: the `xcode-27` label gets a runner (note queue time);
  `Require Xcode 27` prints 27.x; XcodeGen install, drift check, package resolve, iOS build +
  check, `StrideTests` on macOS, macOS build + check and hosted tests all green.
- [ ] A server-only and a docs-only push skip the Apple job.
- [ ] A scratch branch with `embed: false` on the widget dependency turns the Apple job (and
  the pre-push hook) red with "PlugIns/StrideWidgetExtension.appex missing".
- [ ] If the jobs become required checks, `Changed areas` must be required too.
- [x] **Before any hosted run in CI or `ship.sh`**: the XCTest guard in
  `Shared/SentryBootstrap.swift` (landed in `4d59f4f`, with DEBUG builds reporting as
  `development`). Hosted tests launch the real app, which starts Sentry with
  the production DSN; the 2026-09-27 test runs filed abnormal sessions against live 1.2.3+17
  (ignore that release's sessions from 08:00–11:00 UTC that day; Sentry cannot delete them).

## TODO — the 1.3.0 client (M1)

_Not started. Per DEV-PLAN-1.3.md M1, plus what M0 added to it:_

- [ ] `APIClient` sends `X-Stride-Client` and decodes `{error, code?, message?}`: match on
  `code`, display `message ?? error`.
- [ ] The associated-domains entitlement for the AASA file now being served; the
  `verify_archive.sh --exported` check activates itself once the entitlement is declared.
- [x] Drop the planned intro-offer disclosure line (see decisions; DEV-PLAN-1.3.md amended).
- [ ] Release notes, verification, demo-account check and what was deliberately not done, in
  the style of RELEASE-1.2.3.md.
