# Stride Server Deployment

Runs alongside ColorArchive on an **Azure VM** — `172.207.80.109`, Ubuntu 24.04 LTS,
SSH as `azureuser` (sudo, no password). Migrated off the DigitalOcean droplet
`143.198.85.72` on **2026-08-29**; DNS now points only at Azure. The droplet was
kept as a rollback target rather than destroyed, so if you touch it, remember it
still holds a stale copy of `stride.db`.

```bash
ssh -o IdentityAgent=none -i ~/.ssh/id_ed25519 azureuser@172.207.80.109
```

> `IdentityAgent=none` is not optional for unattended sessions — the 1Password SSH
> agent will otherwise hang the connection forever with no prompt.

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
- `SENTRY_DSN` — optional; when set, server errors are reported to Sentry.
- `SENTRY_TRACES_SAMPLE_RATE` — optional, default `0.1`.
- Datadog APM (`dd-trace`) auto-initializes when `NODE_ENV !== test`; configure
  via the standard `DD_*` env vars (no-op without a local agent).

## Database Backups

`stride.db` is the single source of truth for **all** user data. It is gitignored
(never commit it). Three tiers are live and verified:

1. **On-host, daily 03:30**, root crontab → `/root/stride-server/backup.sh`
   → `/root/backups/stride-<date>-<hhmm>.db`, 14-day retention.
2. **Offsite pull to the Mac, every 6 h**, LaunchAgent
   `com.jason.doharvest.offsite-backup` → `~/Library/do-harvest-offsite/stride/`
   (gzipped, integrity-checked). Shared with ColorArchive; script is
   `~/Library/do-harvest-offsite/pull-offsite.sh`, status in `last-run-status.txt`.
3. **Cloud + Google Drive** uploads from the same script.

SQLite runs in WAL mode, so backups must use the online `.backup` command — do **not**
`cp` the file while the server is running, and do not judge freshness by `stride.db`'s
mtime, because writes land in `stride.db-wal` and the main file can look untouched for
weeks while the database is busy.

```bash
# /root/stride-server/backup.sh
set -euo pipefail
DB=/root/stride-server/stride.db
DEST=/root/backups
mkdir -p "$DEST"
STAMP=$(date +%F-%H%M)
sqlite3 "$DB" ".backup '$DEST/stride-$STAMP.db'"
# Retain 14 days
find "$DEST" -name 'stride-*.db' -mtime +14 -delete
```

Verify a restore rather than trusting the file list:

```bash
gunzip -c ~/Library/do-harvest-offsite/stride/stride-<date>-0330.db.gz > /tmp/check.db
sqlite3 /tmp/check.db "pragma integrity_check; select count(*) from users;"
```

Graceful shutdown (`SIGTERM`/`SIGINT`) checkpoints the WAL before exit, so a
PM2 `reload`/`restart` leaves the DB in a clean state.

## Maintenance / GC

The server self-maintains on a 6-hour timer (and once at boot): it deletes
deletion tombstones older than 90 days and expired sessions / magic-link tokens
(`db.sweepStaleData()` in `db.js`). No external cron needed for this.
