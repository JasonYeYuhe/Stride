# Stride Server Deployment

Runs alongside ColorArchive on an **Azure VM** — `172.207.80.109`, Ubuntu 24.04 LTS,
SSH as `azureuser` (sudo, no password). Migrated off the DigitalOcean droplet
`143.198.85.72` on **2026-08-29**; DNS now points only at Azure. The droplet was
**destroyed on 2026-08-30**, and its copy of `stride.db` with it.

> This file said until 2026-09-26 that the droplet had been kept as a rollback target
> still holding a stale `stride.db`. The owner's ledger (`~/Documents/credits.md`,
> DigitalOcean row) records it destroyed on 08-30 after the last files were archived,
> with the account left holding no droplets, snapshots, volumes or reserved IPs; the
> DigitalOcean credit expired on 08-31, so a surviving droplet would have started billing
> the card on file in September. On 2026-09-26 the address answered ping but timed out on
> 22, 80 and 443 — the droplet had sshd and nginx open to the world, so that is not it,
> most likely another customer on a recycled IP. The one check no agent can make (the Mac
> has no `doctl` token): the DigitalOcean console's Droplets page should be empty, and the
> September invoice (due 1 October) should be $0.00. Also run
> `ssh-keygen -R 143.198.85.72` — `~/.ssh/known_hosts` still trusts three keys for an
> address someone else may now own.

```bash
ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519 azureuser@172.207.80.109
```

> `IdentityAgent=none` is not optional for unattended sessions — the 1Password SSH
> agent will otherwise hang the connection forever with no prompt.

## Deploying — five steps, in this order

1. tests on the Mac, 2. diff the host, 3. rehearse on a copy of production, 4. back up,
5. rsync, restart, verify. Steps 2 and 3 are the ones that have each saved a deploy; skip
neither.

### 1. Tests

```bash
cd server && npm test && npm run typecheck     # CI runs the same two on every server change
```

### 2. ⚠️ Diff the host against the repo BEFORE you rsync

The host has held changes that were never committed. On 2026-09-09 a deploy was
one command away from reverting a live security fix: production's `index.js` was
1160 bytes larger than the repo's because someone had bound the listener to
`127.0.0.1` on 2026-07-27 and not pushed it. Overwriting it would have re-exposed
port 3002 to the internet, and with `trust proxy` set, a direct caller can forge
`X-Forwarded-For` and defeat every per-IP rate limit — including the one on the
unauthenticated magic-link endpoint, whose Resend key is shared with ColorArchive.

Always dry-run first and read the itemised output. `s` means the content differs;
`t` alone is just an mtime.

```bash
rsync -avzn --itemize-changes \
  --exclude node_modules --exclude '*.db' --exclude '*.db-shm' --exclude '*.db-wal' \
  --exclude .env --exclude test --exclude SYNC_PAUSED --exclude .DS_Store \
  -e "ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519" --rsync-path="sudo rsync" \
  server/ azureuser@172.207.80.109:/root/stride-server/
```

`SYNC_PAUSED` is the [pause switch](#pausing-sync)'s flag file. Carried to the host it would
pause every user; and since this rsync has no `--delete`, excluding it also means a deploy
never removes a pause someone set on the host during an incident. Both excludes must be in
the dry run *and* the real run below, or the dry run is not showing you what will happen.

For every file marked `s` that you did not change yourself, diff it and port the
host's version into the repo first:

```bash
ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519 azureuser@172.207.80.109 \
  'sudo cat /root/stride-server/index.js' > /tmp/prod_index.js
diff /tmp/prod_index.js server/index.js
```

### 3. Rehearse on a copy of production — must pass before the real rsync

```bash
scripts/rehearse_server.sh      # ends "✓ rehearsal passed — safe to deploy", exit 0
```

It copies the working tree's `server/` and an online `.backup` of the live `stride.db` into
`/root/rehearsal-<stamp>` on the host, boots that copy on `127.0.0.1:3199` with no `.env`
(no Sentry, no email, no APM), runs [`ops/rehearsal-checks.js`](ops/rehearsal-checks.js)
against it as the App Review demo account, prints the server log and deletes the directory.
The live process and database are never touched. The checks: `integrity_check` on the
migrated copy and the new tables present; `/health`; the AASA file; the demo token signs in;
a full pull whose `totals` equal its arrays, every entry matched to a habit, every id upper
case; a 1.2.3-shaped snapshot of the real account applying with nothing skipped and bumping
no `updated_at`; an unknown-habit entry landing in `skipped.entries`; `cursor_expired` only
with a ≥ 1.3.1 header; a 20-day-old session sliding to 30 days; and the pause flag answering
503 then 200.

Why it is a step and not an option: the test suite's database never has the shapes an
upgraded production database has — columns added by `ALTER TABLE`, rows written by seed
scripts rather than pushes. 1.2.3's rehearsal found all 133 demo entries with a NULL
`updated_at`, which no test could have. Any `FAIL` line, or a non-zero exit: do not deploy.
Rehearse again after porting anything from step 2, because the rehearsal runs the working
tree.

### 4. Back up

```bash
sudo sqlite3 /root/stride-server/stride.db \
  ".backup /root/backups/stride-predeploy-$(date +%Y%m%d-%H%M%S).db"
```

(Kept until deleted by hand — `backup.sh`'s retention matches only the nightly files.)

### 5. Deploy, restart, verify

```bash
rsync -avz --itemize-changes \
  --exclude node_modules --exclude '*.db' --exclude '*.db-shm' --exclude '*.db-wal' \
  --exclude .env --exclude test --exclude SYNC_PAUSED --exclude .DS_Store \
  -e "ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519" --rsync-path="sudo rsync" \
  server/ azureuser@172.207.80.109:/root/stride-server/
```

then restart, and check from the Mac (the loopback check only means something from outside):

```bash
ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519 azureuser@172.207.80.109 \
  'sudo pm2 restart stride-server --update-env'
curl -s -o /dev/null -w '%{http_code}\n' https://stride-api.colorarchive.me/health   # 200
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://172.207.80.109:3002/health      # 000 = loopback bind intact
curl -sI https://stride-api.colorarchive.me/.well-known/apple-app-site-association \
  | grep -iE '^HTTP|^content-type'                                                    # 200, exactly application/json
```

The AASA file (the server half of one-tap sign-in from the email link) must come back `200`
with `Content-Type: application/json` and nothing after it — no `; charset=…`, no redirect,
no auth. The app sets that header itself; what can break it is nginx, if a `location` rewrites
or redirects `/.well-known/` or adds a charset. Apple's CDN caches the file for hours, so a
bad answer outlives the fix. The rehearsal checks the app on `127.0.0.1`; only this `curl`
checks the path through nginx.

Then from the Mac, `scripts/check_demo_account.sh` should exit 0.

## Setup on the host

```bash
# Clone or copy server/ to /root/stride-server (the service runs as root)
cd /root/stride-server
npm install --production

# Create .env
cp .env.example .env
# Edit .env with real values

# Start with PM2
NODE_ENV=production pm2 start index.js --name stride-server --update-env
pm2 save
```

## Static Pages

Legal/support pages (privacy, terms, support) live in `server/docs/`.
The source of truth is `docs/` at the repo root — copy them into
`server/docs/` when they change:

```bash
cp docs/*.html server/docs/
```

The server serves these via `express.static` with `extensions: ["html"]`,
so `/privacy` resolves to `docs/privacy.html`.

## Nginx / TLS

Live vhost is `/etc/nginx/sites-enabled/stride-api`, serving
**`stride-api.colorarchive.me`** (port 80 → 301 → 443, TLS from Let's Encrypt):

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name stride-api.colorarchive.me;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name stride-api.colorarchive.me;
    ssl_certificate     /etc/letsencrypt/live/stride-api.colorarchive.me/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/stride-api.colorarchive.me/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
nginx -t && systemctl reload nginx
certbot --nginx -d stride-api.colorarchive.me   # renewal: certbot.timer (systemd), active
```

⚠️ **Migration trap, cost a day in August:** if a second reverse proxy sits in front
(the DO droplet forwarding to Azure during cutover), setting `proxy_set_header Host`
at *both* hops sends **two** `Host` headers and Azure's nginx answers `400`. Set it
at one hop only.

## DNS

`stride-api.colorarchive.me` → A record → `172.207.80.109`.
The app's base URL is compiled in at `Stride/Sources/Services/APIClient.swift`
(release) with `http://localhost:3002` for debug builds — changing the hostname
means shipping a new build, so keep the DNS name stable and move the A record instead.

### Email authentication (magic links)

Sign-in is an email or nothing, so the sending domain's DNS is part of the login path.
Resend sends as `hello@stride.colorarchive.me` (`FROM_EMAIL`), DKIM selector `resend`,
envelope sender `send.stride.colorarchive.me` (Amazon SES). Records live at Namecheap
(`colorarchive.me`). Check them with `scripts/ops/check_email_auth.sh` after any DNS change.
State on 2026-09-26:

| Mechanism | Record | Result |
|---|---|---|
| SPF | `send.stride.colorarchive.me TXT "v=spf1 include:amazonses.com ~all"` | present; relaxed-aligned with the From domain |
| Bounce MX | `send.stride.colorarchive.me MX 10 feedback-smtp.us-east-1.amazonses.com` | present |
| DKIM | `resend._domainkey.stride.colorarchive.me TXT "p=MIGf…"` | key published (aligned `d=stride.colorarchive.me`) |
| DMARC | none at `_dmarc.stride.colorarchive.me`; inherits `_dmarc.colorarchive.me "v=DMARC1; p=none;"` | present but not enforcing; no `rua`, so nobody sees reports |
| Root SPF | none on `colorarchive.me` (the root sends no mail and has no MX) | advisory |

Enough for Gmail and Yahoo to accept today (they require a DMARC record, not an enforcing
one). The recommended change touches only the Stride subdomain, where Resend is the only
sender and DKIM always aligns:
`_dmarc.stride.colorarchive.me TXT "v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:<owner address>"`
(start at `p=none` with `rua` for two weeks if you want to read the reports first). The
root's `p=none` and missing SPF belong to whatever else uses `colorarchive.me`; leave them
unless you know nothing else sends as it.

## Ports

- ColorArchive: 3001
- Stride: 3002

## Environment

`index.js` reads these (see `.env.example`):

- `NODE_ENV=production` — **required in production.** Disables dev CORS origins and
  hardens error responses. The global error handler never leaks stack traces
  regardless, but production mode is still expected.
- `PORT` — defaults to 3002.
- `FRONTEND_ORIGIN` — the origin this process answers on: CORS allowlist and the host in
  magic-link emails (default `https://stride-api.colorarchive.me`, see `origins.js`; the old
  default had no DNS record).
- `RESEND_API_KEY` — magic-link email delivery.
- `DEMO_TOKEN` — App Review demo account login token, consumed by `seed-demo.js`.
  Mirrored into the ASC App Review sign-in fields; rotate in both places at once.
- `SENTRY_DSN` — optional for the server, which reports errors to Sentry when it is set;
  `ops/restore-drill.js` reads it too and cannot alert without it. Not set on production
  as of 2026-09-26 (no Sentry project for the server yet).
- `SENTRY_TRACES_SAMPLE_RATE` — optional, default `0.1`.
- Datadog APM (`dd-trace`) auto-initializes when `NODE_ENV !== test`; configure
  via the standard `DD_*` env vars (no-op without a local agent).
- Sync switches and limits, all optional and commented out in `.env.example` with their
  defaults: `SYNC_PAUSED`, `SYNC_PAUSE_FILE`, `SYNC_PAUSE_RETRY_AFTER_SECONDS` (900) — see
  [Pausing sync](#pausing-sync); `SYNC_RATE_LIMIT_PER_MIN` (60, per account),
  `SYNC_AUTH_FAILURE_LIMIT_PER_15MIN` (100, per IP, sync requests without a valid session),
  `GLOBAL_RATE_LIMIT_PER_15MIN` (100, per IP, everything except sync). None is set on
  production; the defaults are the intended values.

## Sync contract — what a client can be told

The full contract is the comment at the top of `routes/sync.js`; this is the operator's view:
which answers exist, and which apps can receive them. `/v1/sync/*` and the legacy `/sync/*`
behave identically.

An app identifies itself with `X-Stride-Client: ios|macos/<version>(<build>)`, e.g.
`ios/1.3.1(19)`, sent from 1.3.0 on. **No header, or one that does not parse, means a shipped
app ≤ 1.2.3**, and those are never sent anything they cannot handle: they push their whole
history on every sync, cannot split a request, and have no handler for a cursor error — for
them a 400 is as fatal as a 413 and a 409 would be an endless loop.

| Status | `code` | Who can get it | Meaning / what the app does |
|---|---|---|---|
| 200 | — | everyone | Push: `{ok, applied, skipped, skippedReasons}`. Pull: arrays + `totals` + `serverTime`. |
| 401 | — | everyone | `{error:"Unauthorized"}` — no or expired session; sign in again. |
| 400 | `invalid_payload` | everyone | A present field is not an array, or `since` is repeated. A client bug. |
| 400 | `too_many_rows` | header ≥ 1.3.1 | Over 500 habits / 5,000 entries / 200 groups in one push; `limits` says which. Deletion lists are not capped. |
| 409 | `snapshot_required` | header ≥ 1.3.1 | Support asked this account to re-upload everything ([below](#per-account-re-upload)). One-shot. |
| 409 | `cursor_expired` | header ≥ 1.3.1 | Pull `since` older than 355 days (365 − 10 grace). The app does a full pull. |
| 413 | — | everyone | Body over 5 MB. |
| 429 | `rate_limited` | everyone | Over 60 sync requests/min for the account, or over 100 per 15 min from one IP without a session; `Retry-After`. |
| 503 | `sync_paused` | everyone | The [pause switch](#pausing-sync) is on; `Retry-After`. |

Error bodies added in 1.3 carry a machine `code` always. With a valid header the body is
`{error:<code>, code, message:<sentence>}`; without one it is `{error:<sentence>, code}`,
because 1.2.3 prints `error` verbatim in the Settings footer — a user should read "Too many
sync requests, please try again later", not `rate_limited`. The older errors (401, the
global 429, 413) are unchanged.

Skipped rows are reported, never silently dropped: `skippedReasons` names why (`tombstoned`,
`tombstoned_habit`, `missing_field`, `row_error`, `not_owned`, `not_owned_habit`,
`skipped_habit`, `unknown_habit`). A shipped app ignores all of it — it decodes only `ok` and
re-sends everything next time — so the field is additive. It matters from 1.3.1, when apps
send only what changed and a silently dropped row would be a row that never syncs.

The request log line carries what an operator needs to answer "what did that device send":
`client=<header or ->`, and for sync `user=… in=… applied=… skipped=… reasons=…` or
`pull=full|since out=…`.

## Database Backups

`stride.db` is the single source of truth for **all** user data. It is gitignored
(never commit it). Four tiers are live, on two machines and two providers:

1. **On-host, daily 03:30**, root crontab → [`backup.sh`](backup.sh)
   → `/root/backups/stride-<YYYY-MM-DD>-<HHMM>.db`, integrity-checked as written,
   14-day retention on those nightly files only. Log: `/root/backups/stride-backup.log`.
   Restored and checked every night at 04:10 by the [restore drill](#restore-drill).
2. **VM → Azure Blob, every 6 h at :10** — ColorArchive's
   `/root/ColorArchive/server/scripts/sync-azure.sh` also uploads `/root/backups/stride-*.db`
   to `colorarchivestu/sqlite-backups`. The VM's managed identity can write there but not
   delete, so a compromised host cannot erase its own backups.
3. **Offsite pull to the Mac, every 6 h**, LaunchAgent
   `com.jason.doharvest.offsite-backup` → `~/Library/do-harvest-offsite/stride/`
   (gzipped, integrity-checked), plus a Google Drive copy. Shared with ColorArchive;
   script is `~/Library/do-harvest-offsite/pull-offsite.sh`, status in
   `last-run-status.txt`. The VM watches the Mac back: ColorArchive's `backup-health.cjs`
   (08:30 daily) emails if the Mac's heartbeat blob goes stale.
4. **Weekly incremental snapshot of the VM's OS disk**, made by the same Mac script — see
   [VM snapshots](#vm-snapshots). It buys rebuild speed, not data safety.

SQLite runs in WAL mode, so backups must use the online `.backup` command — do **not**
`cp` the file while the server is running, and do not judge freshness by `stride.db`'s
mtime, because writes land in `stride.db-wal` and the main file can look untouched for
weeks while the database is busy.

`backup.sh` lived only on the host until 2026-09-26 and was excluded from rsync. It is
in the repo now and deploys with everything else. The repo version differs from the host's
in three ways:

- It runs `PRAGMA integrity_check` on the file it just wrote and logs one line (the log had
  been 0 bytes since the move to Azure, so a cron that had stopped looked like success).
- It refuses to back up a missing or empty `stride.db`, and refuses a copy with no users.
  `sqlite3` on a missing path *creates* an empty database there and backs that up with
  `integrity_check: ok` — fourteen such nights would have aged out every real backup while
  the log said ok, and left an empty `stride.db` at the live path for the server to open.
- Its retention glob matches only the nightly `stride-YYYY-MM-DD-HHMM.db` files — the old
  `stride-*.db` also expired the `stride-predeploy-*` / `stride-preseed-*` rollback points
  after 14 days. Those are now kept until someone deletes them by hand; prune them once the
  release they guarded is settled.

Older backups are pruned only after tonight's passed both checks. A failed night exits 1
into the log and leaves no alert of its own: the 04:10 drill fails the next morning because
tonight's file is missing or bad, and that is what reaches Sentry.

Graceful shutdown (`SIGTERM`/`SIGINT`) checkpoints the WAL before exit, so a
PM2 `reload`/`restart` leaves the DB in a clean state.

### Scheduled jobs (root crontab)

[`ops/crontab.stride`](ops/crontab.stride) lists Stride's lines: the 03:30 backup, the
03:50 demo top-up and the 04:10 restore drill, each logging to `/root/backups/`. It is a
**fragment** — root's crontab also holds ColorArchive's jobs, and `crontab <file>` would
replace them. The block below installs the two new lines (the 03:30 one was already there)
once an rsync has put `backup.sh` and `ops/` on the host. **Done on production 2026-09-27**
(the previous crontab is saved in `/root/backups`; first runs: backup `integrity_check: ok
users: 4`, top-up 43 check-ins added and then 0, drill ok). On a rebuilt host, add the 03:30
line from the fragment too — the block only appends the 03:50 and 04:10 lines:

```bash
sudo chmod 755 /root/stride-server/backup.sh   # cron runs it directly; the .js files run via node
sudo crontab -l > ~/root-crontab.bak-$(date +%Y%m%d)
# Appends the 03:50 and 04:10 lines once; a second run changes nothing.
sudo bash -c 'crontab -l | grep -q ops/restore-drill.js ||
  (crontab -l; grep -E "^(50 3|10 4) " /root/stride-server/ops/crontab.stride) | crontab -'
sudo crontab -l | grep -c stride-server        # 3
diff <(sudo crontab -l | grep -v stride-server) <(grep -v stride-server ~/root-crontab.bak-$(date +%Y%m%d))  # no output: ColorArchive's jobs untouched
```

Then run each once by hand, in this order, and read the output:

```bash
sudo /root/stride-server/backup.sh
#   [backup] …Z stride-<today>-<HHMM>.db 311296 bytes integrity_check: ok users: 4
sudo /usr/bin/node /root/stride-server/ops/demo-topup.js --dry-run
#   [demo-topup] …Z DRY RUN <n> check-ins added — Morning Run +k (<from>..<today>), … Journal +k (…)
#   (n is about 4 per day since the last check-in; nothing is written)
sudo /usr/bin/node /root/stride-server/ops/demo-topup.js
#   the same line without DRY RUN; run it again and it says 0 check-ins added
sudo /usr/bin/node /root/stride-server/ops/restore-drill.js --dry-run-sentry
#   [restore-drill] …Z stride-<today>-<HHMM>.db age=0.0h integrity_check: ok foreign_key_check: ok users=4 … users_before=4
#   [restore-drill] …Z dry-run: would send check-in stride-restore-drill status=ok
```

and from the Mac, `scripts/check_demo_account.sh` should now exit 0. Anything else — a
`FAIL:` line, `ERROR:`, a non-zero exit — stop and read it before leaving the cron to it.
The next morning, each log in `/root/backups/` (`stride-backup.log`,
`stride-demo-topup.log`, `stride-restore-drill.log`) should have gained one run.

### Restore drill

[`ops/restore-drill.js`](ops/restore-drill.js), daily 04:10. Copies the newest nightly
backup into a private (0700, `mkdtemp`) temp directory and requires:

- `integrity_check: ok` and an empty `foreign_key_check`;
- `users` > 0, and at least half the users of the night before — a database the server
  re-created empty is a perfectly healthy SQLite file, so without this a lost `stride.db`
  would pass. Habit and entry counts are logged, not judged (a demo re-seed legitimately
  drops hundreds of entries at once);
- a file from the most recent scheduled 03:30 UTC backup, once 20 minutes have passed. So a
  single failed backup night fails that morning's drill; a plain "younger than 26 h" rule
  let yesterday's file (24.7 h old at 04:10) pass. The rule holds at any hour, so a hand run
  needs no flag. The backup time is `BACKUP_AT` in the script — change it with the crontab.

The temp directory is deleted in every case: the copy holds every user's email. A healthy
log line:

```
[restore-drill] 2026-09-27T04:10:01.123Z stride-2026-09-27-0330.db age=0.7h integrity_check: ok foreign_key_check: ok users=4 habits=6 habit_entries=133 habit_groups=0 deletion_tombstones=0 sessions=2 users_before=4
```

On failure it sends a Sentry message and exits 1. On every run it also sends a Sentry cron
check-in (monitor `stride-restore-drill`, schedule `10 4 * * *` UTC), so a drill that stops
running at all raises an alert too. **Both need `SENTRY_DSN` in `/root/stride-server/.env`,
which production did not have on 2026-09-26** (and there was no Sentry project for the
server) — until it is set, the script logs that the failure was not sent anywhere, and only
`/root/backups/stride-restore-drill.log` knows. `--dry-run-sentry` prints what would be sent.

To drill a restore by hand from the offsite tier instead:

```bash
gunzip -c ~/Library/do-harvest-offsite/stride/stride-<date>-0330.db.gz > "$TMPDIR/check.db"
sqlite3 "$TMPDIR/check.db" "pragma integrity_check; select count(*) from users;"
rm "$TMPDIR/check.db"                          # it holds every user's email
```

### App Review demo account top-up

[`ops/demo-topup.js`](ops/demo-topup.js), daily 03:50. **Never put `seed-demo.js` on a
timer**: it deletes the demo account's sessions and magic-link tokens and re-creates its
habits under new ids, so a scheduled run during a review signs the reviewer out and
replaces everything on their device. The top-up only adds check-ins — for each seeded
habit, from the day after its last entry through today (UTC, at most 30 days back),
following that habit's seed pattern by a hash of habit id + date. It is idempotent (a second
run the same day adds nothing), never deletes, and refuses to run if the account or its
seeded habits are missing ("run seed-demo.js first"). Two rules keep it from changing what a
reviewer did:

- **Un-checked stays un-checked.** It never writes on or before the UTC day of the account's
  newest entry tombstone. A tombstone names only the entry id, so the first version, which
  skipped just its own hashed ids, re-checked a day the reviewer had cleared whenever that
  check-in had come from `seed-demo.js` or the app. Costs at most one day of streak, which the
  one day of grace absorbs; a re-seed clears the tombstones and the floor with them.
- **Only habits `seed-demo.js` made**: a seeded name *and* `created_at` before the 30-day
  window (the seed back-dates it 45 days), and never a day before the habit's own creation.
  A reviewer who deletes "Journal" and adds it back gets no invented history.

Daily, not weekly: streaks count back from today with one day of grace, so two days after
the last check-in every streak is 0 — `scripts/check_demo_account.sh` exit 3. Before a
submission, run it once by hand and then the check. Still re-seed with `seed-demo.js` if the
account itself is broken (habits deleted, token rotated) — and only when no review is open.

### VM snapshots

The VM (`apps-prod-vm`, `apps-prod-rg`, japaneast zone 1, `Standard_B2ats_v2`) has one
64 GB Premium SSD (P6) OS disk and no data disks; about 10 GB is used. Since 2026-08-30
`pull-offsite.sh` on the Mac makes an **incremental** snapshot when the newest is over
144 h old and keeps the newest 4 (tag `created-by=pull-offsite.sh`). On 2026-09-26 there were
four: 09-05, 09-11, 09-17, 09-24. There is no Recovery Services vault.

Cost: incremental snapshots are stored as Standard HDD LRS at $0.05/GB-month of *used and
changed* data, not the 64 GB provisioned — the first holds ~10 GB (≈ $0.50/month), each
later one only the week's changes, so four stay well under $1/month, inside the student
credit.

By hand (for example before an OS upgrade):

```bash
az snapshot create -g apps-prod-rg -n "apps-prod-vm-os-$(date -u +%Y%m%d-%H%M)" \
  --source /subscriptions/fef8a4db-affc-4e72-85b4-4380b0b8d829/resourceGroups/apps-prod-rg/providers/Microsoft.Compute/disks/apps-prod-vm_OsDisk_1_97d70ac261724b69a117131d53962684 \
  --incremental true --tags created-by=manual -o table
az snapshot list -g apps-prod-rg --query "[].{name:name,created:timeCreated,incremental:incremental}" -o table
```

The weakness is the trigger, not the snapshot: they stop when the Mac sleeps. That is
already detected (`backup-health.cjs` alarms on a stale Mac heartbeat within a day), and
the data tiers above do not depend on it, so this is left as it is. Azure Backup for the VM
was considered and rejected: a $5–10/month protected-instance fee (by VM size band) plus
vault storage, for a machine whose data already sits in four independent copies. If the Mac
trigger ever becomes a problem, the cheap move is a root cron on the VM itself calling the
ARM snapshot API with the VM's managed identity (IMDS token, no `az` install) — that needs
the owner to grant the identity `Microsoft.Compute/disks/read` + `snapshots/write|read|delete`
on `apps-prod-rg` (it currently holds only Blob Backup Writer on the backups container).

### Uptime monitoring

What exists: a Datadog Synthetics API test on `/health` (`cys-6yb-3pg`, Tokyo, every
15 min, email) — too slow to see a two-minute outage — and Azure metric alert
`prod-vm-down` (VM availability, 1-min evaluation, email via action group
`apps-prod-alerts`), which sees the VM, not the app: a crashed or stopped pm2 process
leaves it green.

The fast check is a **Sentry uptime monitor** (org `jason-yeyuhe` already runs one on
colorarchive.org at a 60 s interval): URL `https://stride-api.colorarchive.me/health`,
GET, interval 1 minute, timeout 10 s, downtime threshold 2, recovery threshold 1, in the
`stride-server` project, alerting the owner by email. Stopping pm2 makes nginx answer 502
at once, so a two-minute stop fails two consecutive checks and raises exactly one alert.
Every plan includes one uptime monitor, which colorarchive.org uses, so this one is
$1/month pay-as-you-go (the plan needs a PAYG budget ≥ $1). Acceptance:

```bash
sudo pm2 stop stride-server; sleep 150; sudo pm2 start stride-server   # expect one alert, then a resolve
```

Rejected: Datadog at 1-minute frequency (≈ 43,000 runs/month, outside what the student
account is known to cover, and editing the test needs the application key that lives only
in 1Password); Azure Application Insights standard tests (5-minute minimum frequency per
location, and the recommended 3-of-5-locations rule can miss a two-minute outage);
GitHub Actions cron (5-minute floor, often delayed much longer).

## Maintenance / GC

A 6-hour timer (and one run at boot) sweeps expired sessions and magic links,
`usage_counters` and `user_clients` rows older than 400 days, and snapshot requests
answered more than 90 days ago (`db.sweepStaleData()` in `db.js`). No external cron needed.

**Deletion tombstones are kept indefinitely.** Sweeping them would let a ≤ 1.2.3 app
resurrect deleted rows: it cannot be told its cursor is too old (it has no
`cursor_expired` handler), pulls past the swept window, and pushes the deleted rows back
with its next full snapshot. Tombstones are about 100 bytes each. Sweeping returns — at 365
days, `sweepStaleData({ tombstoneRetentionDays: 365 })` — only after a 426 minimum-version
floor retires ≤ 1.2.3, and the [usage report](#usage-report) is what says when that is.
(Until 2026-09-27 this section said tombstones were swept at 90 days; they were, until M0.)

The three tables M0 added — `sync_snapshot_requests`, `usage_counters`, `user_clients` —
are created on boot with `CREATE TABLE IF NOT EXISTS`; nothing to run by hand.

### Pausing sync

For a day the server cannot take the sync load, or a bad deploy that needs the fleet held
still while it is rolled back. Every `/v1/sync/*` and `/sync/*` request then answers
`503 sync_paused` with `Retry-After`, before any session lookup or body parsing. Shipped
apps show the error in Settings and retry on their next sync, as they do for any failed
sync; from 1.3.1 (DEV-PLAN-1.3.md M2) apps back off with jitter and show "sync paused". Sign-in and everything else keep
working.

```bash
sudo touch /root/stride-server/SYNC_PAUSED                     # pause, Retry-After 900 s
echo 1800 | sudo tee /root/stride-server/SYNC_PAUSED            # pause, Retry-After 1800 s
sudo rm /root/stride-server/SYNC_PAUSED                         # resume
```

Read on every request: no restart either way. `SYNC_PAUSED=1` in `.env` does the same but
needs `pm2 restart --update-env`, so prefer the file. The file is gitignored and excluded
from the deploy rsync (see step 2).

There is deliberately no global "everyone re-upload" switch: every installed app would push
its whole history in the same minute.

### Per-account re-upload

For support: an account whose server copy is missing rows the user still has on a device.
The next push or pull from that account by an app ≥ 1.3.1 gets `409 snapshot_required`, and
that device marks every local row dirty and uploads them all (the client half is M2; until a
1.3.1 build ships, a request just stays pending). Apps before 1.3.1 already push
everything on every sync and leave the request pending for a newer device.

```bash
cd /root/stride-server
sudo node ops/request-snapshot.js <email> [note]   # set it, or re-arm an answered one
sudo node ops/request-snapshot.js --list           # pending, or "answered <time> to <client>"
sudo node ops/request-snapshot.js --clear <email>  # withdraw it
```

Answered is not repaired: the 409 can be lost on the way (a timeout, the app suspended).
Check the account's rows; if the re-upload never came, run it again for the email.

### Usage report

```bash
cd /root/stride-server && sudo node ops/usage-report.js [--days N] [--db path]
```

Active accounts by client version over 7 / 28 / 56 days, the legacy (no header) and < 1.3.1
cohorts, and counter totals by UTC day: `snake_fallback.*` (the snake_case shim),
`habit_without_kind`, `mount.*` (hits on the legacy `/sync`, `/auth`, `/habits` mounts),
`client.*`. It opens the database read-only and runs no migrations, so it is safe on the live
host or on a copy. The process flushes its counters hourly and on SIGTERM, so the report
trails live traffic by up to an hour. **These numbers, not a date, decide when the
snake_case shim, the legacy mounts, the 426 floor and tombstone sweeping can go.**
