# Stride v1.2.1 — release record

**Submitted to App Review 2026-09-08.** App ID `6761262334`, bundle `yyh.stride.habittracker`.

Why this release exists: 1.2.0 shipped Sentry linked but inert (`dda470e` explains the
mechanism — Xcode silently drops `INFOPLIST_KEY_SentryDSN`, which is not on its 95-name
allowlist). So there is **no crash or app-hang data from any shipped build since
2026-06-07**. 1.2.1 carries that fix and nothing else.

| Item | Build | State at submit |
|---|---|---|
| iOS 1.2.1 | 15 | `WAITING_FOR_REVIEW` |
| macOS 1.2.1 | 15 | `WAITING_FOR_REVIEW` |

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

## How it was signed, with the screen locked the whole time

A locked console does not block signing; a locked **login keychain** does, and that
is what `errSecInternalComponent` means during `codesign`. SSH can unlock it —
`security unlock-keychain`, password typed at the prompt — so no physical access was
needed. Two things that are easy to get wrong, both hit here:

- **The unlock does not cross security sessions.** Unlocking from the phone's ssh
  session did not let the agent session (parented to the GUI login) sign; the build
  has to run in the same session that unlocked.
- **A pre-existing tmux server is in the OLD session.** `tmux new-session -A` attaches
  to it and the build inherits its locked keychain, failing seconds after a successful
  unlock. `scripts/ship.sh` uses `-L stride-ship` to force a private server.

`scripts/build-appstore.sh` now preflights signing in one second rather than failing
20 minutes into the archive.

## Two bugs in release.py, found by it silently doing nothing

Both were mine, both shipped in the first version of the script, and both are fixed:

- `find_build` passed `fields[builds]` without `preReleaseVersion`. `fields` is a
  whitelist over **relationships** too, so ASC returned each build with an empty
  relationships object while still listing the preReleaseVersions under `included` —
  the platform match could never succeed, and `finish` waited out its full 60-minute
  timeout on builds that were sitting there VALID.
- `asc_api.patch` called `.json()` unconditionally. Relationship endpoints answer
  **204 with no body**, so attaching a build raised a JSONDecodeError *after* the
  attach had already succeeded — iOS ended up attached, macOS never ran.

The pairing is worth remembering: the first bug made a real object look absent, the
second made a successful write look like a crash. Neither reports itself as a failure
of the thing it broke.

## Next release, from anywhere

```bash
ssh mac-ts
cd ~/Documents/Stride && ./scripts/ship.sh <version> <build>
```

Unlocks the keychain if needed, builds and uploads both platforms, attaches the build,
submits both for review. `scripts/release.py show <version>` reports state at any point
and changes nothing.

## After review

- Release type is `AFTER_APPROVAL` on both platforms, so approval ships it — nothing
  further to click.
- **Confirm Sentry is actually receiving events once the build is live.** The entire
  point of 1.2.1 is unverifiable from the project file; 1.2.0 looked correct in source
  and was dead. Silence in the dashboard after a week of downloads means this failed
  again, not that the app is flawless.

## Not part of this release

- App Review demo account unchanged (`demo@stride-review.com`, `DEMO_TOKEN` in the
  server `.env`) — no server change, so no re-verification needed.
- The IAP is already approved and live; a first Lifetime purchase came in 2026-09-06.
