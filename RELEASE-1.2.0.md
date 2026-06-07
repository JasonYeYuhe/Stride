# Stride v1.2.0 — release record

**Submitted to App Review 2026-06-07.** App ID `6761262334`, bundle `yyh.stride.habittracker`.

| Item | Build | State at submit |
|---|---|---|
| iOS App 1.2.0 | 12 | Waiting for Review |
| macOS App 1.2.0 | 14 | Waiting for Review (first macOS release) |
| Lifetime IAP `…pro.lifetime` | — | Waiting for Review (covers both platforms) |

Branch `feat/v2-phase0-phase1-foundation` (not yet merged to `main`). Tag `v1.2.0` → commit `9b4cc7d` (iOS build 12). macOS build 14 → `f25583c`.

## What shipped (v2)
- **Stride Pro** tier: Monthly / Yearly subscriptions + a new one-time **Lifetime** non-consumable ($19.99). Pro gates **Habit Groups** + **Advanced Analytics / Weekly Review**; everything else (habits, reminders, widgets, sync, quantitative & flexible habits) is free.
- **Flexible / forgiving frequency** (X times per week, specific days), **quantitative habits** (target value + unit), **habit grouping**, deeper analytics, and Phase-0 data-integrity hardening.

## Pre-ship fixes (this release)
- `StrideApp`: refresh StoreKit entitlements on cold launch (paying users were locked out of Pro until opening Settings). `a00a31d`
- Paywall/Settings copy: accurate Pro feature list, Restore in Settings, removed donation-style row, Lifetime renewal wording. `a00a31d` / `9240b85`
- Verified v1.1→v2 **SwiftData lightweight migration** preserves data (install-over test on simulator).
- Version bump 1.1.0→1.2.0; added shared `Stride` / `StrideMac` schemes for non-interactive archiving.

## Operational (backend)
- v2 server deployed to droplet (`/root/stride-server`, PM2 `stride-server`): `NODE_ENV=production` confirmed, `trust proxy` live, daily `stride.db` backup cron (03:30). `9695b65`
- Fixed a v2 `db.js` migration crash (index-before-migration + non-constant `ADD COLUMN` default) — tested against a copy of prod data.
- **Demo review token rotated** (old revoked); now env-driven in `seed-demo.js`, value in droplet `.env`, mirrored into ASC App Review sign-in for both platforms. Old hardcoded token removed from source.

## How it was submitted
ASC API (`scripts/asc_api.py`, `scripts/upload_iap_screenshot.py`, build via `scripts/build-appstore.sh`) + Chrome for the final "Submit for Review". IAP submitted via `inAppPurchaseSubmissions` (new IAPs can't be `reviewSubmissionItem`s). iOS What's New localized to all 6 locales; macOS first release needs none.

## Demo account (App Review)
`demo@stride-review.com` — token in droplet `/root/stride-server/.env` (`DEMO_TOKEN`). Login: Settings → Log In → "I have a login token" → paste.

## After review
- On approval: choose release (iOS 1.2.0 is set to manual/auto per the version's release setting — verify before approval lands).
- Consider merging `feat/v2-phase0-phase1-foundation` → `main` once approved.
- Deferred, non-blocking: harden the `ModelContainer` fallback so a migration failure surfaces loudly instead of opening an empty store; mixed-version sync quirks (last-push-wins, local-vs-UTC entry dates) self-resolve as users upgrade.
