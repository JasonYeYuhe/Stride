# Stride v1.2.1 — release record (IN PROGRESS)

**Blocked at codesign, 2026-09-08.** App ID `6761262334`, bundle `yyh.stride.habittracker`.

Why this release exists: 1.2.0 shipped Sentry linked but inert (`dda470e` explains the
mechanism — Xcode silently drops `INFOPLIST_KEY_SentryDSN`, which is not on its 95-name
allowlist). So there is **no crash or app-hang data from any shipped build since
2026-06-07**. 1.2.1 carries that fix and nothing else.

| Item | Build | State |
|---|---|---|
| iOS 1.2.1 | 15 | `PREPARE_FOR_SUBMISSION` — version + What's New created, **no build attached** |
| macOS 1.2.1 | 15 | `PREPARE_FOR_SUBMISSION` — version + What's New created, **no build attached** |

## Done

- `main` fast-forwarded from `f23fc0f` to the full v2 line + the Sentry fix, and pushed.
  Everything shipped as 1.2.0 was still sitting on a branch until now.
- Version bumped 1.2.0 → 1.2.1, build 14 → **15** (higher than every existing build on
  both platforms; iOS was at 12, macOS at 14).
- Swift test suite: **71/71 passed**, and `-scheme Stride test` now actually runs them —
  the scheme had no test action, so that command exited 0 having run nothing. Server
  suite is **278/278** green on CI at this commit.
- Deleted the iCloud conflict copies that would have broken the next build:
  `Shared/SentryBootstrap 2.swift` (a pre-fix duplicate of `enum SentryBootstrap`, which
  `xcodegen` would have globbed into all five targets → invalid redeclaration), plus
  `project 2.yml` and ten `Stride N.xcodeproj` directories. All in `~/.Trash`, not erased.
- ASC 1.2.1 version records created for **both** platforms with What's New in all six
  locales, via `scripts/release.py prepare 1.2.1`.

## Blocked

`xcodebuild archive` fails at `Sentry.framework: errSecInternalComponent` because the
login keychain is locked — the console has been locked and nothing an agent has access to
can unlock it (login password only; `op` is Touch-ID-gated). `scripts/build-appstore.sh`
now preflights this in one second instead of failing 20 minutes in.

## To finish (after unlocking the screen)

```bash
./scripts/build-appstore.sh ios --upload
./scripts/build-appstore.sh macos --upload
python3 scripts/release.py finish 1.2.1 15   # waits for processing, attaches, submits
python3 scripts/release.py show 1.2.1        # confirm WAITING_FOR_REVIEW on both
```

`release.py` replaces the hand-finished path 1.2.0 needed: `asc_api.py` is platform-blind
(takes `versions[0]`) and posts to the retired `appStoreVersionSubmissions`, which is why
1.2.0's final submit was done in Chrome. `release.py` is per-platform, uses
`reviewSubmissions`, and every step is re-runnable.

## Not part of this release

- App Review demo account unchanged (`demo@stride-review.com`, `DEMO_TOKEN` in the
  server `.env`) — no server change, so no re-verification needed.
- The IAP is already approved and live; a first Lifetime purchase came in 2026-09-06.
