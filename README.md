# Stride

A habit tracker for iPhone and Mac: SwiftUI + SwiftData on the device (iOS 17 / macOS 14),
an optional account that syncs habits between devices through a small Node/Express +
SQLite server, a home-screen widget, and a Pro tier sold with StoreKit 2. Six languages
(en, es, ja, ko, zh-Hans, zh-Hant). On the App Store as app `6761262334`, bundle
`yyh.stride.habittracker`.

Where things stand and what comes next: the newest `RELEASE-<version>.md` at the root, and
[`DEV-PLAN-1.3.md`](DEV-PLAN-1.3.md) for the 1.3.x–1.4.x plan.

## Layout

| Path | What |
|---|---|
| `Stride/` | the iOS app (and the sources StrideMac shares with it) |
| `StrideMac/` | macOS-only files (entitlements) |
| `StrideWidget/` | the iOS widget extension |
| `Shared/` | code compiled into every target — see [the rule](#the-shared-rule) |
| `StrideTests/`, `StrideAppTests/` | the two test suites — see [Tests](#tests-and-gates) |
| `server/` | the sync / auth server — see [Server](#server) |
| `scripts/` | build, release, CI and ops scripts — see [Scripts](#scripts) |
| `metadata/` | App Store listing text per locale, pushed by `scripts/push_metadata.py` |
| `docs/` | the public legal and support pages, **published by GitHub Pages** — nothing private goes here |
| `archive/` | old notes kept for the record; see its README |

## Targets

Defined in [`project.yml`](project.yml):

| Target | Platform | Notes |
|---|---|---|
| `Stride` | iOS | the app; embeds the widget |
| `StrideMac` | macOS | the Mac app, same sources |
| `StrideWidgetExtension` | iOS | widget; its own privacy manifest (`StrideWidget/PrivacyInfo.xcprivacy`) |
| `StrideTests` | iOS + macOS | host-less unit tests over `StrideTests/` + `Shared/` |
| `StrideAppTests` | iOS | hosted tests (`TEST_HOST` = Stride.app) for the services |

There is no watch app any more: the `StrideWatch` target was removed in 1.3.0 — it was never
embedded or sold. Why, and where its sources are in history: [RELEASE-1.3.0.md](RELEASE-1.3.0.md).

### The `Shared/` rule

Pure logic that tests or scripts need to exercise — models, date keys, check-in, the sync
wire models and the reconciler — lives in `Shared/`, with no dependency on app singletons or
UI. That is what lets `StrideTests` run host-less (and on macOS, where CI can run it), and
lets `scripts/check_demo_account.sh` compile the **shipping** sync code into a small tool and
run it against production. Code that stays under `Stride/Sources/` can only be tested hosted.
Until 1.2.3 the reconciler was tested through a hand-copied replica that had drifted from
the shipping code, so its tests were green while the real one was wrong: move code into
`Shared/`, never copy it into a test.

### XcodeGen

`project.yml` is the source of truth; `Stride.xcodeproj` is generated from it and committed
(Xcode, CI and the release scripts open it directly). After editing `project.yml`, or adding
or removing source files:

```bash
xcodegen generate        # XcodeGen 2.45.3 exactly — output differs between versions
```

and commit both. Never add targets or files in Xcode's UI: the next `xcodegen generate`
(`build-appstore.sh` runs one) deletes them. The pinned version lives in
`.github/workflows/ci.yml` (`XCODEGEN_VERSION`, with the release checksum) and
`scripts/ci/check_xcodegen_drift.sh`; CI and the pre-push hook fail when the committed
project is not exactly what `project.yml` generates.

## Tests and gates

| Suite / gate | Command | Runs where |
|---|---|---|
| `StrideTests` (macOS) | `xcodebuild test -scheme StrideTests -destination platform=macOS CODE_SIGNING_ALLOWED=NO` | CI, locally |
| `StrideTests` (iOS) | same with `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | locally |
| `StrideAppTests` (hosted) | `scripts/ci/run_hosted_tests.sh ["iPhone 17"]` | locally, a release gate; CI on the preview runner |
| iOS product check | `scripts/ci/build_ios_generic.sh <derived-data>` | CI, pre-push hook |
| Server | `cd server && npm test && npm run typecheck` | CI, locally |
| Archive / export | `scripts/verify_archive.sh` (two modes) | `build-appstore.sh`, before any upload |

- **`run_hosted_tests.sh`** uses an existing simulator ("iPhone 17", else the first
  iPhone) and never creates or erases one; it fails unless more than zero tests ran and none
  failed, counted from the xcresult (`xcodebuild` can exit 0 having run nothing).
  Its derived data is one per simulator (README "Building locally");
  `STRIDE_HOSTED_DERIVED_DATA` moves it. Hosted tests launch the real app, so
  anything the app does at launch happens in them too — which is why they stay off the E2E
  kit's iPhone 17 Pro (the launch removes that device's pending reminders). Outside CI it holds
  `/tmp/lock-iphone-17` for the run: someone else's lock is waited on for up to 40 min, then it
  exits 2 with BLOCKED; your own hold is reused when its holder file says
  `label=$STRIDE_SIM_LOCK_LABEL` (`scripts/ci/sim_lock.sh`).
- **CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on pushes and PRs to
  `main` and `release/**`. A cheap `Changed areas` job (`scripts/ci/changed_areas.sh`)
  decides what else runs: `project.yml`, `Stride*/`, `Shared/` → the Apple job; `server/` →
  the server job; workflow or `scripts/ci/` changes → both. The Apple job runs on the
  `xcode-27` preview image and refuses any other Xcode major: drift check, generic iOS build +
  product check (widget embedded, both privacy manifests, Info.plist, Sentry), `StrideTests` on
  macOS, macOS build + product check, hosted tests on a simulator.
- **Pre-push hook** — install once per clone with `scripts/install-git-hooks.sh`. On a push
  that changes Apple paths it runs the drift check and the generic iOS build + product check
  (incremental, a few seconds warm). It refuses when the working tree differs from the pushed
  commit under the Apple paths. Skip once with `SKIP_STRIDE_HOOKS=1 git push`. It is the gate
  that does not depend on the preview runner existing.
- **`verify_archive.sh <archive> <ios|macos>`** checks the archive's contents (appex and its
  manifest, the app's manifest, bundle id, versions, display name, Sentry);
  **`--exported <dir> <ios|macos>`** checks what is actually uploaded: signed by Apple
  Distribution, no `get-task-allow`, associated domains matching the entitlements file. Both
  modes check the required-reason APIs each privacy manifest declares, exactly (the app's
  UserDefaults CA92.1 and 1C8F.1, FileTimestamp C617.1 and SystemBootTime 35F9.1; the widget's
  UserDefaults 1C8F.1 and SystemBootTime 35F9.1).

## Building locally: where build output goes

Trashing a build root frees nothing (the Trash is on the same volume) and makes the next build
cold. So the scripts build into persistent roots and rebuild them incrementally, never under
`~/Documents` (iCloud) and never under `$TMPDIR` (macOS purges it on low disk, which forced cold
rebuilds on 2026-10-11 and 10-14).

| Root | Written by | Notes |
|---|---|---|
| `~/Library/Caches/Stride-build/SourcePackages-<hash>` | every script below | Swift packages (sentry-cocoa, ~1.9 GB), shared; keyed by `Package.resolved` |
| `~/Library/Developer/Xcode/DerivedData/Stride-hosted-tests`, `…-<device>` | `run_hosted_tests.sh` | one per simulator; the plain name is "iPhone 17" |
| `~/Library/Developer/Xcode/DerivedData/Stride-prepush` | pre-push hook | `build_ios_generic.sh` |
| `~/Library/Caches/Stride-build/sim-e2e` | `scripts/sim_e2e` (`$STRIDE_E2E_ROOT`) | `builds/current` stays; per-tag gate builds go when the release ships |
| `~/Library/Caches/Stride-build/mac-variant` | `mac_variant/build.sh` | an upgrade gate's old version gets its own root |
| `~/Library/Caches/Stride-build/mac-variant-release` | `mac_variant/build.sh --release` | the Release variant (gate 12) |
| `~/Library/Caches/Stride-build/a11y-dd` | `a11y_sweep.sh` | shared by every checkout |

These are not session leftovers: leave them at a session's wrap-up.

- **Packages.** `scripts/ci/build_cache.sh` (`spm_cache_args`) resolves once per package set
  (`Package.resolved` plus the project's package references) into the shared checkout, under a
  lock, with `-onlyUsePackageVersionsFromResolvedFile` as CI does. Builds then pass
  `-clonedSourcePackagesDirPath <it> -disableAutomaticPackageResolution`. They still rewrite its
  `workspace-state.json`, under SwiftPM's own lock files in `$TMPDIR`, which is what lets several
  build from it at once. CI passes its own flags; `STRIDE_SPM_DIR=off` turns it off. If the
  resolve fails (no network, or a `Package.resolved` that no longer satisfies the project), the
  build resolves into its own derived data as before.
- **One derived data per checkout that builds at the same moment**, not one per agent, step or
  round. Agents that run one after another reuse the same one. Only worktree-isolated agents that
  build in parallel get their own, and they still take packages from the shared checkout.
- **A workflow that calls `xcodebuild` itself** resolves once before fanning out (any script
  above does it, or `bash -c 'source scripts/ci/build_cache.sh && spm_cache_args "$PWD"'`). Each
  agent then runs `source scripts/ci/build_cache.sh && spm_cache_args "$PWD"` in the shell that
  builds (warm, that is one sha256) and passes `"${SPM_ARGS[@]+"${SPM_ARGS[@]}"}"`: a bare
  `"${SPM_ARGS[@]}"` of an empty array is an error under bash 3.2's `set -u`.
- **Locks.** Each script above takes its derived data's lock (`build_lock_path`) around its
  build, so two runs never share a `build.db` at once; on a signal it stops its own xcodebuild
  before letting go. Hosted runs also hold the device's `/tmp/lock-<device>`. `a11y_sweep.sh`
  copies the app out of its shared derived data before it lets go, and installs the copy.
- Release archives (`build-appstore.sh`) stay cold by design and are not covered here.

## Server

`server/` — Express + better-sqlite3, one SQLite file, PM2 on an Azure VM behind nginx at
`stride-api.colorarchive.me`. Everything operational — the deploy procedure, backups, the
restore drill, the demo-account top-up, monitoring, the sync contract as clients see it, the
pause switch — is in **[server/DEPLOY.md](server/DEPLOY.md)**. The short version of a deploy:
tests, diff the host, `scripts/rehearse_server.sh` on a copy of production (must pass), back
up, rsync. Environment variables: [`server/.env.example`](server/.env.example).

```bash
cd server && npm ci && npm run dev      # http://localhost:3002 — debug app builds point here
```

## Scripts

Release and App Store:

- `ship.sh` — retired in 1.4.1: it refuses to run and prints the steps that replace it. It
  defaulted to shipping 1.2.1 build 15 and submitted both platforms in one `release.py finish`,
  while each platform now goes on its own go.
- `build-appstore.sh [ios|macos|all] [--upload]` — archive, verify, upload dSYMs, export,
  verify the signed export; uploads only after every requested platform passed.
- `verify_archive.sh` — the archive and export assertions above.
- `upload_dsyms.sh <archive>…` — keep an archive's dSYMs and upload them to Sentry.
- `release.py prepare|finish|release|cancel|show <version> [build] [--platform IOS|MAC_OS]` —
  ASC version records, What's New in six locales, attach the build, submit, release, pull out of
  review; idempotent per platform. `--platform` limits every command but `show` to one platform.
  `python3 -I scripts/test_release.py` tests its parsing and the platform filter offline.
- `push_metadata.py` — push `metadata/` to ASC; run it in the same submission as any
  description change.
- `check_demo_account.sh` — the App Review demo account as a reviewer's device sees it
  (compiles `Shared/`'s sync code, pulls from production); exit 0 before every submission.
- `sync_rehearsal.sh` — the M2 sync rehearsal: compiles all of `Shared/` with the real sync
  engine into a tool and runs 1.3.1 devices plus 1.2.3- and 1.3.0-shaped snapshot devices
  against a local `NODE_ENV=test` copy of `server/` on a throwaway database (never
  `server/stride.db`, never production); prints a PASS / FAIL / SKIPPED table, exit 0 before
  every 1.3.x submission.
- `asc_api.py` — the shared ASC API helper. `setup_iap.py`, `upload_iap_screenshot.py`,
  `appstore_metadata.py`, `update_asc_metadata.py`, `update_screenshots.py`,
  `submit_build.py` — one-off ASC jobs from earlier releases, kept for reference; read one
  before running it. Never run `update_screenshots.py` or `appstore_metadata.py` for
  screenshots: the first wipes every locale's sets and picks a version without a platform, the
  second rewrites the 1.0 metadata.
- `store_screenshots.py list|upload --platform IOS|MAC_OS --version <v>` — store screenshots
  for one version on one platform: `list` is read-only; `upload --set <display type> <files…>`
  replaces only the named display types, en-US unless `--locale` says otherwise, from an
  explicit file list, and is a dry run without `--yes` (an owner-approved ASC write).
- `screenshots.sh`, `generate_screenshots.swift` — the pre-1.4.0 App Store screenshots (AppKit
  mock images). From 1.4.0 they are captured from real builds (RELEASE-1.4.0.md D8).
- `mac_variant/build.sh [--release]` — the macOS test variant, `yyh.stride.habittracker.mactest`:
  a StrideMac Debug (or Release) build that cannot reach the real store on this Mac. The Release
  variant talks to production. Build, preflight, launch rules:
  [scripts/mac_variant/README.md](scripts/mac_variant/README.md).
- `a11y_sweep.sh [--size <content size>|default] [--app <Stride.app>]` — the Dynamic Type
  review artefact: every tab, Stats scrolled to each chart, and the paywall, as PNGs in
  `build/a11y/<size>/`. The size defaults to `accessibility-extra-extra-extra-large`;
  `--size default` (`large`) is the layout check against a previous set before store
  screenshots — they must match up to sub-pixel text. It runs on iPhone 17 Pro Max (the
  screenshot device; `--device` for another) under the per-device mutex `/tmp/lock-<device>`
  every project uses (40-minute wait, then BLOCKED), never creates a simulator, and puts content
  size, appearance, status bar and boot state back even when it fails. `--help` has the rest.

Launch arguments the sweep and screenshot runs use — all but `-tab` exist only in DEBUG
builds, so a store build cannot open a sheet or change its data without a tap:

| Argument | Effect |
|---|---|
| `-demo` | **replaces** the store with the demo set (habits, check-ins and groups) |
| `-demoScenario plurals\|weekly` | with `-demo`: one habit with one check-in today, or one 3-a-week habit with 4- and 5-week streaks — the plural acceptance data |
| `-tab <0…n>` | opens on that tab (0 Today, 1 Stats, 2 Settings) |
| `-statsScrollTo detail\|insights\|trend\|weekday\|heatmap` | Stats scrolls to that card once, after launch |
| `-paywall` | opens the Pro paywall |

ASC scripts read `ASC_API_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` from `scripts/.env`
(gitignored); the key itself never lives in the repo.

CI and hooks: `ci/` — `changed_areas.sh`, `check_xcodegen_drift.sh`, `build_ios_generic.sh`,
`check_ios_product.sh`, `check_macos_product.sh` (+ the shared `product_checks.sh`),
`run_hosted_tests.sh` (+ `sim_lock.sh`, the simulator mutex it shares with `a11y_sweep.sh`);
`git-hooks/pre-push` and `install-git-hooks.sh`.

Server and ops: `rehearse_server.sh` (deploy rehearsal on a copy of production, on the host);
`ops/check_email_auth.sh` (SPF/DKIM/DMARC for the magic-link sender). The on-host jobs
(backup, restore drill, demo top-up, snapshot requests, usage report) are in `server/` and
`server/ops/`, documented in DEPLOY.md.

## Releasing

1. Follow the "Standing rules for every milestone" at the end of
   [DEV-PLAN-1.3.md](DEV-PLAN-1.3.md): demo-account check, hosted tests, verified archive,
   What's New in every locale, metadata pushed with any description change, server changes
   rehearsed on a copy of production before they deploy.
2. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` and regenerate;
   `scripts/release.py prepare <version>` creates the ASC version records and What's New.
3. `scripts/build-appstore.sh all --upload`, then `release.py finish <version> <build>
   --platform IOS` and, after the Mac gate, `--platform MAC_OS`, each on its own go (the
   release's "Submission checklist").
4. Write `RELEASE-<version>.md` in the style of [RELEASE-1.2.3.md](RELEASE-1.2.3.md): what
   shipped, why, what only rehearsal found, what was deliberately not done.

Signing needs an unlocked login keychain: probe it first (`security show-keychain-info` plus a
one-second `codesign` of a copy of `/bin/echo`; `ship.sh` prints both) rather than failing twenty
minutes into an archive.

**One-tap sign-in needs the release signing to carry associated domains.** From 1.3.0 both
apps' entitlements claim `applinks:stride-api.colorarchive.me`, so the emailed login link opens
the app signed in (the server serves the AASA file). The App ID needs the Associated Domains
capability and the App Store profiles regenerated after it is enabled — otherwise the export
cannot be signed with the entitlement — and `verify_archive.sh --exported` checks the
entitlement on the signed export. Test it only with a Release or TestFlight build (Debug talks
to `localhost:3002`), in Apple Mail; Gmail and in-app browsers never open universal links,
which is why `/login` keeps its copy-paste page. Apple's CDN can take hours to fetch the AASA
after an install.
