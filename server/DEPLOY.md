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

## ⚠️ Diff the host against the repo BEFORE you rsync

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
  --exclude .env --exclude test \
  -e "ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519" --rsync-path="sudo rsync" \
  server/ azureuser@172.207.80.109:/root/stride-server/
```

For every file marked `s` that you did not change yourself, diff it and port the
host's version into the repo first:

```bash
ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519 azureuser@172.207.80.109 \
  'sudo cat /root/stride-server/index.js' > /tmp/prod_index.js
diff /tmp/prod_index.js server/index.js
```

Then take a backup before touching anything:

```bash
sudo sqlite3 /root/stride-server/stride.db \
  ".backup /root/backups/stride-predeploy-$(date +%Y%m%d-%H%M%S).db"
```

Deploy, restart, verify:

```bash
# (same rsync without -n)
sudo pm2 restart stride-server --update-env
curl -s -o /dev/null -w '%{http_code}\n' https://stride-api.colorarchive.me/health   # 200
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://172.207.80.109:3002/health      # 000 = loopback bind intact
```

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
- `FRONTEND_ORIGIN` — allowed CORS origin (default `https://stride.colorarchive.me`).
- `RESEND_API_KEY` — magic-link email delivery.
- `DEMO_TOKEN` — App Review demo account login token, consumed by `seed-demo.js`.
  Mirrored into the ASC App Review sign-in fields; rotate in both places at once.
- `SENTRY_DSN` — optional for the server, which reports errors to Sentry when it is set;
  `ops/restore-drill.js` reads it too and cannot alert without it. Not set on production
  as of 2026-09-26 (no Sentry project for the server yet).
- `SENTRY_TRACES_SAMPLE_RATE` — optional, default `0.1`.
- Datadog APM (`dd-trace`) auto-initializes when `NODE_ENV !== test`; configure
  via the standard `DD_*` env vars (no-op without a local agent).

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
replace them. Install the two new lines (the 03:30 one is already there) after an rsync
has put `backup.sh` and `ops/` on the host:

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

The server self-maintains on a 6-hour timer (and once at boot): it deletes
deletion tombstones older than 90 days and expired sessions / magic-link tokens
(`db.sweepStaleData()` in `db.js`). No external cron needed for this.
