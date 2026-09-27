#!/usr/bin/env bash
# Nightly on-host backup of stride.db — tier 1 of the four in DEPLOY.md.
# Root crontab (ops/crontab.stride):
#   30 3 * * * /root/stride-server/backup.sh >> /root/backups/stride-backup.log 2>&1
#
# Lived only on the host until 2026-09-26 (DEPLOY.md excluded it from rsync), so the one
# script that protects every user's data had no history and no review. Changes from that
# host copy, found by reading it for the first time and by the review that followed:
#
# - It checks what it wrote. `.backup` succeeding says the pages were copied, not that the
#   copy opens; an unverified backup is a hope. PRAGMA integrity_check on the new file, one
#   log line either way (the log had been 0 bytes since the move to Azure, so "no news"
#   and "cron never ran" looked the same).
# - It checks it copied the right thing: the live DB must exist and be non-empty before the
#   copy, and the copy must hold at least one user after it (see below).
# - Retention matches only the nightly files. The old `find -name 'stride-*.db'` also
#   matched stride-predeploy-* and stride-preseed-*, the snapshots DEPLOY.md tells you to
#   take before a deploy or a re-seed — so a rollback point quietly expired two weeks
#   later, whether or not anyone had finished with it. Those are deleted by hand.
#
# And it prunes only after a verified backup: if tonight's copy is bad, the last good
# fourteen stay put.
#
# WAL mode: never `cp` stride.db while the server runs — `.backup` is the online copy.
set -euo pipefail

# Overridable only so the script can be exercised on a copy; cron sets neither.
DB="${STRIDE_DB:-/root/stride-server/stride.db}"
DEST="${STRIDE_BACKUP_DIR:-/root/backups}"
RETAIN_DAYS=14

mkdir -p "$DEST"

# sqlite3 on a path that does not exist CREATES an empty database there, backs that up, and
# integrity_check calls it "ok" — so a lost stride.db would have been logged as fourteen good
# nights while retention aged out every real backup, and the stray empty file at the live
# path would have been opened by db.js as a fresh, empty service (review of 2026-09-26).
if [[ ! -s "$DB" ]]; then
  echo "[backup] $(date -u +%FT%TZ) ERROR: $DB is missing or empty; nothing backed up, nothing pruned" >&2
  exit 1
fi

STAMP=$(date +%F-%H%M)            # host is Etc/UTC; restore-drill.js reads this stamp as UTC
OUT="$DEST/stride-$STAMP.db"
sqlite3 "$DB" ".backup '$OUT'"

# First line only: a damaged file can list hundreds of problems. `|| true` so that a file
# sqlite3 refuses to open at all is reported below instead of ending the script silently.
# immutable=1 opens it read-only without the WAL machinery: a plain open of a WAL-mode file
# that then errors leaves -wal/-shm files behind, which the retention glob never removes.
INTEGRITY=$(sqlite3 "file:${OUT}?immutable=1" "PRAGMA integrity_check;" 2>&1 | head -1 || true)
# A healthy file of the wrong database is still healthy: a stride.db the server re-created
# empty has the schema and no rows. Every real one has at least the demo account.
USERS=$(sqlite3 "file:${OUT}?immutable=1" "SELECT count(*) FROM users;" 2>&1 | head -1 || true)
BYTES=$(wc -c < "$OUT" | tr -d ' ')
echo "[backup] $(date -u +%FT%TZ) $(basename "$OUT") ${BYTES} bytes integrity_check: ${INTEGRITY} users: ${USERS}"
if [[ "$INTEGRITY" != "ok" ]]; then
  echo "[backup] ERROR: the new backup failed integrity_check; not pruning older backups" >&2
  exit 1
fi
if ! [[ "$USERS" =~ ^[0-9]+$ ]] || (( USERS == 0 )); then
  echo "[backup] ERROR: the new backup has no users; not pruning older backups" >&2
  exit 1
fi

# Nightly files only: stride-YYYY-MM-DD-HHMM.db. Never stride-predeploy-* / stride-preseed-*.
find "$DEST" -maxdepth 1 -type f \
  -name 'stride-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9].db' \
  -mtime +"$RETAIN_DAYS" -delete
