# Stride Server Deployment

Runs alongside ColorArchive on the same DigitalOcean Droplet.

## Setup on Droplet

```bash
# Clone or copy server/ to the Droplet
cd /root/stride-server
npm install --production

# Create .env
cp .env.example .env
# Edit .env with real values

# Start with PM2
pm2 start index.js --name stride-server
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

## Nginx Config

Add to `/etc/nginx/sites-available/stride-api`:

```nginx
server {
    listen 80;
    server_name api.stride.yyh.app;

    location / {
        proxy_pass http://localhost:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
ln -s /etc/nginx/sites-available/stride-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL
certbot --nginx -d api.stride.yyh.app
```

## DNS

Add A record: `api.stride.yyh.app` → Droplet IP

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
- `SENTRY_DSN` — optional; when set, server errors are reported to Sentry.
- `SENTRY_TRACES_SAMPLE_RATE` — optional, default `0.1`.
- Datadog APM (`dd-trace`) auto-initializes when `NODE_ENV !== test`; configure
  via the standard `DD_*` env vars (no-op without a local agent).

Start in production:

```bash
NODE_ENV=production pm2 start index.js --name stride-server --update-env
```

## Database Backups

`stride.db` is the single source of truth for **all** user data. It is gitignored
(never commit it). Back it up off the droplet on a schedule.

SQLite in WAL mode is safely backed up with the online `.backup` command (do **not**
just `cp` the file while the server is running — the WAL may be uncommitted):

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
# (optional) push offsite, e.g. rclone copy "$DEST/stride-$STAMP.db" remote:stride-backups/
```

```bash
chmod +x /root/stride-server/backup.sh
# Daily at 03:30
( crontab -l 2>/dev/null; echo "30 3 * * * /root/stride-server/backup.sh" ) | crontab -
```

Graceful shutdown (`SIGTERM`/`SIGINT`) checkpoints the WAL before exit, so a
PM2 `reload`/`restart` leaves the DB in a clean state.

## Maintenance / GC

The server self-maintains on a 6-hour timer (and once at boot): it deletes
deletion tombstones older than 90 days and expired sessions / magic-link tokens
(`db.sweepStaleData()` in `db.js`). No external cron needed for this.
