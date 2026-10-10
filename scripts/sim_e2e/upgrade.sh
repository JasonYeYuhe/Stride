#!/bin/bash
# upgrade.sh <udid> <old app> <new app> [--wait <s>] [--server <name>] [--label <name>] [--relaunch]
#            [--reminders <daily habit id>,<Mon/Wed/Fri habit id>]
#                                RELEASE GATE: one in-place upgrade on a simulator, checked.
# upgrade.sh check-log <device log>     the device-log check alone, on a saved log
# upgrade.sh check-gate <device log>    the store-gate order alone (no widget open before the app's)
# upgrade.sh check-dir <dir>            the default.store check alone, on a directory
# upgrade.sh counts <store dir | file>  row counts of a saved store (read from a scratch copy)
# upgrade.sh prefs <plist | plutil -p listing>
#                                       its stride_delivery_* entries
# upgrade.sh check-reminders <app.sh reminders listing | dir of the plists> <daily id>,<M/W/F id>
#                                       the after-upgrade reminder check alone (below)
#
# Why (E2E U123 and MIG, 2026-10-07): on the first 1.3.1 launch after an in-place upgrade from
# 1.2.3 or 1.3.0, chronod launched StrideWidgetExtension with the app; StrideWidget.init()
# touches SharedModelContainer.modelContainer, so both processes opened and migrated the same
# App Group Stride.store. The app's ModelContainer failed with CoreData 134110 (underlying 134100,
# "the store version hashes didn't migrate"), and SharedModelContainer fell back to a NEW EMPTY
# <AppGroup>/Library/Application Support/default.store: "Start Your Journey" with every habit
# hidden, the delivery migration spent on the empty store, and on the next launch the real store
# pushed whole (Recovered Edits filled with rows deleted elsewhere). 4 of 4 with the widget, 0 of
# 2 without. A one-process migration test passes on the very same stores, so only a real
# in-place upgrade with the stock build (widget included) shows it: this run.
#
# Starting point: <udid> runs <old app> (same version and build) over a store it has synced, with
# no default.store in its containers (`app.sh reset` to the old app gives that). Then:
#   1. terminate; copy Stride.store (+ -wal, -shm) out, with sha1, row counts and model checksum;
#      save the app's prefs;
#   2. `xcrun simctl install` <new app> IN PLACE (no uninstall: the containers stay), and check
#      the store files are byte-identical after the install;
#   3. cold launch, wait <s> (default 20), screenshot, check the app still runs, terminate;
#   4. check and print:
#        - the device log since just before the install (the widget may start before the app):
#          CoreData 134110/134100, "Failed to create ModelContainer … Falling back to default
#          location", "Could not open the store" (the no-fallback open's error screen), in any
#          Stride process;
#        - every default.store* in the app group and data containers, with its rows;
#        - Stride.store's rows before/after (ZHABIT, ZHABITRECORD, ZHABITGROUP; rows with
#          ZSYNCEDAT set; the model checksum, which changes when the store was migrated);
#        - the app's stride_delivery_* prefs;
#        - with --server <name>: that kit server's E2E request lines of the launch;
#        - the store gate (the upgrade-race fix, review round): in the device log, no widget
#          "Store opened in the extension" before the app's "Store opened by the app", and how
#          often the widget was turned away before it ("Store not opened in the extension: …");
#          then the marker the app wrote, stride_store_schema_version in the App Group prefs;
#        - the delivery marks: when the old store had rows 5+ min older than the old app's last
#          sync (SyncDeliveryMigration.margin), the migration must have marked them — marks still
#          waiting in the prefs, or a first full pull with ?deletionsSince= in the server log;
#        - recovered edits: lines in the data container's SyncRecoveryLog. The gate's scenario
#          makes no edit on the upgraded device, so any line is a row pushed back that was deleted
#          elsewhere — the U123 relaunch's 17.
#   5. with --relaunch: a second cold launch (the U123 relaunch pushed the whole store and filled
#      Recovered Edits), its requests, and the recovered edits again.
#   6. with --reminders <daily>,<mwf> (1.4.0, RELEASE-1.4.0.md D4/D7): the system's pending
#      notification store, read from scratch copies of <device data>/Library/UserNotifications/
#      <dir>/PendingNotifications.plist and Categories.plist (app.sh reminders, notifications.py).
#        - before the install, as part of the starting point: both habits' bare 1.3.x ids,
#          stride.habit.reminder.<id>, are pending (else exit 1: the recipe was not followed);
#        - after the first launch, retried (the daemon writes the file after the app's adds and
#          removes; STRIDE_E2E_REMINDER_TRIES × STRIDE_E2E_REMINDER_PAUSE s, default 10 × 3):
#          the Mon/Wed/Fri habit has exactly .2, .4 and .6 and no bare id; the daily habit keeps
#          exactly its bare id; both categories, stride.habit.binary and stride.habit.count, are
#          registered; and when the archive's records show categories at all, those four requests
#          carry one of the two.
#      Without the flag nothing about reminders is read, so runs on devices with no reminder
#      habits (every gate run before 1.4.0) work as they did. Why the system's store and not an
#      app log line: design review upgrade-gate-blind-to-reminders; README, "Reminder habits",
#      has the starting point (notification permission is granted on the OLD build, by hand).
# Everything lands in $ROOT/upgrades/<label>/ (default <UTC time>-<pro|promax>), report.txt
# included. Exit 0 PASS; 3 FAIL (a failed open in the log, any default.store, the app not running
# after the wait, a widget open before the app's, no marker, unmarked rows, recovered edits,
# reminders not converted); 1 the run could not be made. Never uninstalls, never opens the
# device's store with sqlite3 (it reads scratch copies), never removes anything on the device.
#
# The check-* commands need no simulator. Each prints what it found; check-log and check-dir exit
# 3 on a fallback, check-gate on a widget open before the app's, like the run.
source "$(dirname "$0")/lib.sh"

SQLITE=/usr/bin/sqlite3
[[ -x "$SQLITE" ]] || SQLITE="$(command -v sqlite3 || true)"
APP_SH="$KIT_DIR/app.sh"

# A failed open of the store, in any Stride process:
#   - CoreData 134110 "An error occurred during persistent store migration" and its underlying
#     134100 "incompatible model", as CoreData logs them ("…NSCocoaErrorDomain (134110)",
#     "Code=134100"); not a bare 1341x0, which a hex address can contain;
#   - SharedModelContainer's fallback line (up to 1.3.1 (20)): "Failed to create ModelContainer
#     … Falling back to default location";
#   - the no-fallback open's failure line, "Could not open the store: … the app shows the error
#     screen" (AppStoreOpen, the upgrade-race fix): no default.store then, but no habits either,
#     so it fails the gate the same way. Keep this in step with that message.
FALLBACK_RE='NSCocoaErrorDomain[^0-9]{0,12}1341(00|10)|Code=1341(00|10)|Failed to create ModelContainer|Falling back to default location|Could not open the store'
# The widget extension's own failed open: printed, not failed on — it shows no data, it does not
# hide the user's (the app's open decides).
NOTE_RE='Extension could not open the store'
# The store gate's lines (SharedModelContainer, the upgrade-race fix). Keep these in step with
# its messages: the app's open (after it wrote the marker), the widget's open, and the widget
# turned away ("waitForApp(noMarker)" while the app has not opened the store yet).
APP_OPEN_RE='Store opened by the app'
EXT_OPEN_RE='Store opened in the extension'
EXT_WAIT_RE='Store not opened in the extension: '
# What the run reads from the device log: both Stride processes (the app, StrideWidgetExtension)
# and anything logged under the app's subsystem.
LOG_PREDICATE='process BEGINSWITH "Stride" OR subsystem == "yyh.stride.habittracker"'

# ── Checks (also the offline commands) ──────────────────────────────────────────────────────

# The failed-open markers in a saved device log: prints them; returns 3 when there is any.
check_log() {
  local log="$1" hits notes procs
  [[ -f "$log" ]] || die "no device log at $log"
  notes="$(grep -E "$NOTE_RE" "$log" || true)"
  if [[ -n "$notes" ]]; then
    echo "device log, widget (not failed on): $(wc -l <<<"$notes" | tr -d ' ') line(s):"
    cut -c1-320 <<<"$notes" | sed 's/^/  /'
  fi
  hits="$(grep -E "$FALLBACK_RE" "$log" || true)"
  if [[ -z "$hits" ]]; then
    echo "device log: no CoreData 134110/134100, no fallback, no failed open ($(wc -l <"$log" | tr -d ' ') lines read)"
    return 0
  fi
  procs="$(grep -oE '(^| )Stride[A-Za-z]*\[[0-9]+' <<<"$hits" | sed 's/^ //; s/\[.*//' | sort | uniq -c | awk '{printf "%s%s ×%s", (NR > 1 ? ", " : ""), $2, $1}' || true)"
  echo "device log: STORE OPEN FAILED — $(wc -l <<<"$hits" | tr -d ' ') line(s)${procs:+, in $procs}:"
  cut -c1-320 <<<"$hits" | sed 's/^/  /'
  return 3
}

# The store gate in a saved device log: the widget must never open the store before the app's own
# open (which writes the marker first). Prints what the gate did; returns 3 when the widget opened
# first, or the widget asked but the app never logged its open. Sets GATE_BUILD=1 when the log
# has any gate line (a build with the gate, which must also have written the marker).
GATE_BUILD=0
check_gate() {
  local log="$1" lines app ext waits before after
  [[ -f "$log" ]] || die "no device log at $log"
  GATE_BUILD=0
  lines="$(grep -nE "$APP_OPEN_RE|$EXT_OPEN_RE|$EXT_WAIT_RE" "$log" || true)"
  if [[ -z "$lines" ]]; then
    echo "store gate: no gate line in the device log (a build before the schema gate)"
    return 0
  fi
  GATE_BUILD=1
  app="$(grep -nE "$APP_OPEN_RE" "$log" | sed -n '1s/:.*//p' || true)"
  ext="$(grep -nE "$EXT_OPEN_RE" "$log" | sed -n '1s/:.*//p' || true)"
  if [[ -z "$app" ]]; then
    echo "store gate: the widget asked, but the app never logged its open:"
    cut -c1-320 <<<"$lines" | sed 's/^/  /'
    return 3
  fi
  echo "store gate: the app opened the store and wrote the marker at log line $app:"
  sed -n "${app}p" "$log" | cut -c1-320 | sed 's/^/  /'
  if [[ -n "$ext" && "$ext" -lt "$app" ]]; then
    echo "store gate: THE WIDGET OPENED THE STORE FIRST, at line $ext — the U123 race window:"
    sed -n "${ext}p" "$log" | cut -c1-320 | sed 's/^/  /'
    return 3
  fi
  waits="$(awk -v app="$app" -v re="$EXT_WAIT_RE" 'NR < app && $0 ~ re { sub(/.*Store not opened in the extension: /, ""); print }' "$log" | sort | uniq -c | sed 's/^ *//' || true)"
  if [[ -n "$waits" ]]; then
    echo "store gate: the widget was turned away before the app's open: $(tr '\n' ',' <<<"$waits" | sed 's/,$//; s/,/, /g')"
  else
    echo "NOTE: the widget asked for nothing before the app's open, so the gate was not exercised — only the extension's launch was. Place a Stride widget on the home screen for that (README)."
  fi
  if [[ -n "$ext" ]]; then
    echo "store gate: the widget opened the store after the app's open, at line $ext"
  else
    echo "NOTE: no widget open after the app's open (no Stride widget on the home screen, or none reloaded within the wait)"
  fi
  return 0
}

# Rows of a pre-upgrade store the delivery migration must mark: never delivered (every row of a
# 1.3.0 store) with a stamp at least SyncDeliveryMigration.margin (300 s) before <last sync ISO>.
# Stamps as SyncDeliverable has them: updatedAt, else createdAt (records: date). Prints a number,
# or "?" when the store or the time cannot be read that way.
qualifying_rows() {
  local store="$1" iso="$2" secs cut tmp x n
  [[ -f "$store" && -n "$iso" && -n "$SQLITE" ]] || { echo "?"; return 0; }
  secs="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$(sed 's/[.Z].*$//' <<<"$iso")" +%s 2>/dev/null || true)"
  [[ -n "$secs" ]] || { echo "?"; return 0; }
  cut=$((secs - 978307200 - 300))   # Core Data's reference date is 2001-01-01
  tmp="$ROOT/scratch/qualify.$$"
  rm_under_root "$tmp"
  mkdir -p "$tmp"
  cp -p "$store" "$tmp/c.store"
  for x in -wal -shm; do
    if [[ -f "$store$x" ]]; then cp -p "$store$x" "$tmp/c.store$x"; fi
  done
  n="$("$SQLITE" "$tmp/c.store" "SELECT (SELECT COUNT(*) FROM ZHABIT WHERE COALESCE(ZUPDATEDAT, ZCREATEDAT) <= $cut)
      + (SELECT COUNT(*) FROM ZHABITRECORD WHERE COALESCE(ZUPDATEDAT, ZDATE) <= $cut)
      + (SELECT COUNT(*) FROM ZHABITGROUP WHERE COALESCE(ZUPDATEDAT, ZCREATEDAT) <= $cut)" 2>/dev/null || echo '?')"
  rm_under_root "$tmp"
  echo "$n"
}

# Recovered edits on the device: lines in <data container>/Library/Application Support/
# SyncRecoveryLog/*.jsonl (SyncRecoveryLog.defaultDirectory). 0 when there is no log.
recovered_edits() {
  local dir="$1/Library/Application Support/SyncRecoveryLog" n=0 f
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.jsonl; do
      if [[ -f "$f" ]]; then n=$((n + $(wc -l <"$f" | tr -d ' '))); fi
    done
  fi
  echo "$n"
}

# Row counts of a SwiftData store FILE, plus its model checksum, as one line. Read from a scratch
# copy (with its -wal and -shm): sqlite3 opening a WAL store checkpoints it, and neither the
# device's store nor an evidence copy may change.
store_counts() {
  local store="$1" tmp x t tbl label n nset has out="" synced="" ck
  [[ -f "$store" ]] || { echo "no store at $store"; return 0; }
  [[ -n "$SQLITE" ]] || die "sqlite3 is required"
  tmp="$ROOT/scratch/counts.$$"
  rm_under_root "$tmp"
  mkdir -p "$tmp"
  cp -p "$store" "$tmp/c.store"
  for x in -wal -shm; do
    if [[ -f "$store$x" ]]; then cp -p "$store$x" "$tmp/c.store$x"; fi
  done
  for t in ZHABIT:habits ZHABITRECORD:records ZHABITGROUP:groups; do
    tbl="${t%%:*}"; label="${t#*:}"
    if [[ "$("$SQLITE" "$tmp/c.store" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$tbl'" 2>/dev/null || echo 0)" != 1 ]]; then
      out="$out $label=-"
      continue
    fi
    n="$("$SQLITE" "$tmp/c.store" "SELECT COUNT(*) FROM $tbl" 2>/dev/null || echo '?')"
    out="$out $label=$n"
    has="$("$SQLITE" "$tmp/c.store" "SELECT COUNT(*) FROM pragma_table_info('$tbl') WHERE name='ZSYNCEDAT'" 2>/dev/null || echo 0)"
    if [[ "$has" == 1 ]]; then
      nset="$("$SQLITE" "$tmp/c.store" "SELECT COUNT(*) FROM $tbl WHERE ZSYNCEDAT IS NOT NULL" 2>/dev/null || echo '?')"
      synced="$synced $label=$nset"
    fi
  done
  ck="?"
  if "$SQLITE" "$tmp/c.store" "SELECT writefile('$tmp/meta.plist', Z_PLIST) FROM Z_METADATA LIMIT 1" >/dev/null 2>&1 \
     && [[ -f "$tmp/meta.plist" ]]; then
    ck="$(plutil -extract NSStoreModelVersionChecksumKey raw -o - "$tmp/meta.plist" 2>/dev/null || echo '?')"
  fi
  rm_under_root "$tmp"
  echo "rows:${out}  syncedAt set:${synced:- (no ZSYNCEDAT column: a pre-1.3.1 model)}  model=$ck"
}

# A directory, or a .store file: the store file in it.
store_file() {
  if [[ -d "$1" ]]; then echo "$1/Stride.store"; else echo "$1"; fi
}

# Every default.store* under <dir>, with the rows of each default.store; returns 3 when any.
check_dir() {
  local dir="$1" what="${2:-$1}" found f
  [[ -d "$dir" ]] || die "no directory $dir"
  found="$(fallback_stores "$dir")"
  if [[ -z "$found" ]]; then
    echo "$what: no default.store"
    return 0
  fi
  echo "$what: FALLBACK STORE (SharedModelContainer could not open Stride.store):"
  while IFS= read -r f; do
    echo "  $f ($(stat -f '%z bytes, modified %Sm' "$f"))"
    if [[ "$f" == */default.store ]]; then echo "    $(store_counts "$f")"; fi
  done <<<"$found"
  return 3
}

# The stride_delivery_* entries (nested values included) of a prefs plist or a saved
# `plutil -p` listing.
delivery_prefs() {
  local src="$1" listing found
  [[ -f "$src" ]] || die "no prefs at $src"
  if plutil -lint -s "$src" >/dev/null 2>&1; then listing="$(plutil -p "$src")"; else listing="$(cat "$src")"; fi
  found="$(awk '
    /^}/ { show = 0 }
    /^  "/ { show = ($0 ~ /^  "stride_delivery_/) }
    show { print }
  ' <<<"$listing")"
  if [[ -z "$found" ]]; then
    echo "stride_delivery_*: none (the 1.3.1 delivery migration has not run with these prefs)"
    return 0
  fi
  echo "stride_delivery_*:"
  echo "$found"
  # The U123 signature: the migration finished, but with no marks waiting for the proof — it
  # stamped 0 rows. Right for a store with nothing older than 5 min before the last sync
  # (SyncDeliveryMigration.margin), wrong when it ran on a fallback store.
  if grep -Eq '"stride_delivery_migration_v1_done" => (1|true)' <<<"$found" \
     && ! grep -q '"stride_delivery_marks_unproven"' <<<"$found"; then
    echo "  (done, and no marks wait for the proof: either the first sync already proved them, or the migration stamped no row — see \"delivery marks\" below)"
  fi
}

# ── Reminders (--reminders) ─────────────────────────────────────────────────────────────────
# Read from an `app.sh reminders` listing: "request<TAB><id><TAB><category>…" lines (the header of
# notifications.py). The ids are NotificationService's: stride.habit.reminder.<habit id> for a
# daily trigger (1.3.x and 1.4.0 alike), stride.habit.reminder.<habit id>.<w> (w = 1 Sun … 7 Sat)
# for 1.4.0's weekday triggers (D4).
REMINDER_PREFIX="stride.habit.reminder."
REMINDER_CATEGORIES="stride.habit.binary stride.habit.count"
UUID_RE='^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'

# "<daily>,<mwf>" → REM_DAILY, REM_MWF (upper-cased: Habit.id.uuidString is upper case).
parse_reminders_arg() {
  local daily mwf
  [[ "$1" == *,* ]] || die "--reminders <daily habit id>,<Mon/Wed/Fri habit id> (got '$1')"
  daily="$(tr '[:lower:]' '[:upper:]' <<<"${1%%,*}")"
  mwf="$(tr '[:lower:]' '[:upper:]' <<<"${1#*,}")"
  [[ "$daily" =~ $UUID_RE && "$mwf" =~ $UUID_RE ]] || die "--reminders: two habit UUIDs, comma-separated (got '$1')"
  [[ "$daily" != "$mwf" ]] || die "--reminders: the daily and the Mon/Wed/Fri habit must be two habits"
  REM_DAILY="$daily"
  REM_MWF="$mwf"
}

# The request ids of one habit in a listing, bare and .<w>, sorted, space-separated.
habit_requests() {
  awk -F'\t' -v p="$REMINDER_PREFIX$2" '$1 == "request" && ($2 == p || index($2, p ".") == 1) { print $2 }' "$1" \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# A listing for an `app.sh reminders` output file or a directory holding the plists themselves.
reminders_listing() {
  local src="$1" out="$2"
  if [[ -d "$src" ]]; then
    {
      printf 'source\t%s\n' "$src"
      if [[ -f "$src/PendingNotifications.plist" ]]; then notifications_py requests "$src/PendingNotifications.plist"; else printf 'decoded-requests\tnone\n'; fi
      if [[ -f "$src/Categories.plist" ]]; then notifications_py categories "$src/Categories.plist"; else printf 'decoded-categories\tnone\n'; fi
    } >"$out" || die "could not decode the stores in $src"
  else
    [[ -f "$src" ]] || die "no reminders listing at $src"
    cp "$src" "$out"
  fi
}

# Before the install: the old build's state the run starts from. Both bare ids, nothing else for
# the two habits (1.3.x knows no weekday id). Prints; returns 1 when the starting point is wrong.
check_reminders_before() {
  local listing="$1" id got rc=0
  for id in "$REM_DAILY" "$REM_MWF"; do
    got="$(habit_requests "$listing" "$id")"
    if [[ "$got" == "$REMINDER_PREFIX$id" ]]; then
      echo "reminders before: $REMINDER_PREFIX$id pending (the old build's daily trigger)"
    else
      echo "reminders before: habit $id has [${got:-nothing pending}], not exactly its bare id"
      rc=1
    fi
  done
  return $rc
}

# After the first launch: D4's conversion. Prints each finding; returns 3 on any failure.
check_reminders() {
  local listing="$1" got want rc=0 mode id cat cats_seen c cat_bad=0
  mode="$(awk -F'\t' '$1 == "decoded-requests" { print $2; exit }' "$listing")"
  [[ "$mode" != none && -n "$mode" ]] || { echo "reminders: NO PendingNotifications.plist after the launch (every request removed?)"; return 3; }
  got="$(habit_requests "$listing" "$REM_DAILY")"
  want="$REMINDER_PREFIX$REM_DAILY"
  if [[ "$got" == "$want" ]]; then
    echo "reminders: the daily habit keeps exactly its bare id ($want)"
  else
    echo "reminders: DAILY HABIT $REM_DAILY has [${got:-nothing pending}], want exactly [$want]"
    rc=3
  fi
  got="$(habit_requests "$listing" "$REM_MWF")"
  want="$REMINDER_PREFIX$REM_MWF.2 $REMINDER_PREFIX$REM_MWF.4 $REMINDER_PREFIX$REM_MWF.6"
  if [[ "$got" == "$want" ]]; then
    echo "reminders: the Mon/Wed/Fri habit has exactly .2 .4 .6 and no bare id"
  else
    echo "reminders: MON/WED/FRI HABIT $REM_MWF has [${got:-nothing pending}], want exactly [$want]"
    rc=3
  fi
  # The requests' categories. Asserted only when the archive's records show categories at all:
  # the record keys were read from the runtime's strings, not from a real store (notifications.py),
  # so "no category anywhere" may be a key the decoder does not know rather than a missing one.
  if [[ "$mode" == strings ]]; then
    echo "NOTE: the pending store's records were not decoded (strings fallback): request categories not checked"
  else
    cats_seen="$(awk -F'\t' '$1 == "request" && index($2, "stride.habit.") == 1 && $3 != "-" { print $3 }' "$listing" | sort -u | tr '\n' ' ')"
    if [[ -z "$cats_seen" ]]; then
      echo "NOTE: no Stride request in the store shows a category: either none was set (a D4 bug) or the record keeps it under a key notifications.py does not know — read reminders-after/PendingNotifications.plist with plutil -p"
    else
      for id in "$REM_DAILY" "$REM_MWF.2" "$REM_MWF.4" "$REM_MWF.6"; do
        cat="$(awk -F'\t' -v i="$REMINDER_PREFIX$id" '$1 == "request" && $2 == i { print $3; exit }' "$listing")"
        case " $REMINDER_CATEGORIES " in
          *" $cat "*) ;;
          *) [[ -z "$cat" ]] || { echo "reminders: $REMINDER_PREFIX$id carries category '$cat', not stride.habit.binary or stride.habit.count"; cat_bad=1; } ;;
        esac
      done
      if [[ $cat_bad -eq 0 ]]; then echo "reminders: the requests carry ${cats_seen% }"; else rc=3; fi
    fi
  fi
  if [[ "$(awk -F'\t' '$1 == "decoded-categories" { print $2; exit }' "$listing")" == none ]]; then
    echo "reminders: NO Categories.plist: the app registered no notification category"
    rc=3
  else
    for c in $REMINDER_CATEGORIES; do
      if awk -F'\t' -v c="$c" '$1 == "category" && $2 == c { f = 1 } END { exit !f }' "$listing"; then
        echo "reminders: category $c registered ($(awk -F'\t' -v c="$c" '$1 == "category" && $2 == c { print $3; exit }' "$listing"))"
      else
        echo "reminders: CATEGORY $c NOT REGISTERED"
        rc=3
      fi
    done
  fi
  return $rc
}

# ── Offline commands ────────────────────────────────────────────────────────────────────────
RC=0
case "${1:-}" in
  check-log)
    [[ -n "${2:-}" ]] || die "usage: upgrade.sh check-log <device log>"
    check_log "$2" || RC=$?
    exit $RC ;;
  check-gate)
    [[ -n "${2:-}" ]] || die "usage: upgrade.sh check-gate <device log>"
    check_gate "$2" || RC=$?
    exit $RC ;;
  check-dir)
    [[ -n "${2:-}" ]] || die "usage: upgrade.sh check-dir <dir>"
    check_dir "$2" || RC=$?
    exit $RC ;;
  counts)
    [[ -n "${2:-}" ]] || die "usage: upgrade.sh counts <store dir | .store file>"
    store_counts "$(store_file "$2")"
    exit 0 ;;
  prefs)
    [[ -n "${2:-}" ]] || die "usage: upgrade.sh prefs <plist | plutil -p listing>"
    delivery_prefs "$2"
    exit 0 ;;
  check-reminders)
    [[ -n "${2:-}" && -n "${3:-}" ]] || die "usage: upgrade.sh check-reminders <app.sh reminders listing | dir of the plists> <daily id>,<M/W/F id>"
    parse_reminders_arg "$3"
    mkdir -p "$ROOT/scratch"
    L="$ROOT/scratch/reminders-listing.$$"
    reminders_listing "$2" "$L"
    check_reminders "$L" || RC=$?
    rm -f "$L"
    exit $RC ;;
  ""|-h|--help)
    die "usage: upgrade.sh <udid> <old app> <new app> [--wait <s>] [--server <name>] [--label <name>] [--relaunch] [--reminders <daily id>,<M/W/F id>] | check-log <log> | check-gate <log> | check-dir <dir> | counts <store> | prefs <plist> | check-reminders <listing|dir> <daily id>,<M/W/F id>" ;;
esac

# ── The run ─────────────────────────────────────────────────────────────────────────────────
[[ $# -ge 3 ]] || die "usage: upgrade.sh <udid> <old app> <new app> [--wait <s>] [--server <name>] [--label <name>] [--relaunch] [--reminders <daily id>,<M/W/F id>]"
UDID="$(resolve_udid "$1")"
OLD="$2"
NEW="$3"
shift 3
WAIT=20
SERVER=""
LABEL=""
RELAUNCH=0
REM_DAILY=""
REM_MWF=""
REM_TRIES="${STRIDE_E2E_REMINDER_TRIES:-10}"
REM_PAUSE="${STRIDE_E2E_REMINDER_PAUSE:-3}"
[[ "$REM_TRIES" =~ ^[1-9][0-9]*$ && "$REM_PAUSE" =~ ^[0-9]+$ ]] || die "STRIDE_E2E_REMINDER_TRIES (≥ 1) and STRIDE_E2E_REMINDER_PAUSE must be whole numbers"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --relaunch) RELAUNCH=1 ;;
    --reminders) [[ -n "${2:-}" ]] || die "--reminders <daily id>,<M/W/F id>"; parse_reminders_arg "$2"; shift ;;
    --wait) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--wait <seconds>"; WAIT="$2"; shift ;;
    --server) [[ -n "${2:-}" ]] || die "--server <name>"; SERVER="$2"; check_name "$SERVER"; shift ;;
    --label) [[ "${2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--label <letters, digits, . _ ->"; LABEL="$2"; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
check_app "$OLD"
check_app "$NEW"
OLD_V="$(app_version "$OLD")"
NEW_V="$(app_version "$NEW")"
[[ "$OLD_V" != "$NEW_V" ]] || die "old and new are both $OLD_V: that is not an upgrade"
DEV="$(udid_alias "$UDID")"
OUT="$ROOT/upgrades/${LABEL:-$(date -u +%Y%m%dT%H%M%SZ)-$DEV}"
[[ ! -e "$OUT" ]] || die "$OUT exists: pick another --label"
mkdir -p "$OUT/before" "$OUT/after"

section() { echo; echo "── $* ──"; }

# Prints "<sha1>  <name>" for the store files in <dir>.
store_sha1() {
  local dir="$1" x
  for x in "" -wal -shm; do
    if [[ -f "$dir/Stride.store$x" ]]; then
      echo "$(shasum -a 1 "$dir/Stride.store$x" | cut -d' ' -f1)  Stride.store$x"
    fi
  done
}

copy_store() {
  local from="$1" to="$2" x
  for x in "" -wal -shm; do
    if [[ -f "$from/Stride.store$x" ]]; then cp -p "$from/Stride.store$x" "$to/"; fi
  done
}

run() {
  local installed grp grp2 data t0 mark="" log="" pid fail="" ck_before ck_after last_sync="" qualify edits_before edits marker mark2
  local try rem_ok
  echo "upgrade.sh: $OLD_V → $NEW_V on $DEV ($UDID), evidence in $OUT"

  section "starting point"
  installed="$("$APP_SH" version "$UDID")"
  [[ "$installed" == "$OLD_V" ]] || die "$DEV runs $installed, not the old app $OLD_V: reset to it, sign in and sync first (app.sh reset $DEV $OLD)"
  echo "installed: $installed"
  "$APP_SH" terminate "$UDID" >/dev/null
  grp="$("$APP_SH" group "$UDID")"
  data="$("$APP_SH" container "$UDID")"
  [[ -f "$grp/Stride.store" ]] || die "no Stride.store in $grp: launch the old app, sign in and sync first"
  if [[ -n "$(fallback_stores "$grp")$(fallback_stores "$data")" ]]; then
    check_dir "$grp" "app group container" || true
    check_dir "$data" "data container" || true
    die "a default.store is there BEFORE the upgrade (an earlier run's fallback?), so this run could not tell a new one apart: app.sh reset $DEV $OLD, sign in and sync, then run again"
  fi
  if "$APP_SH" prefs "$UDID" app >"$OUT/prefs-before.txt" 2>&1; then
    grep -q '"stride_last_sync_time"' "$OUT/prefs-before.txt" \
      || echo "NOTE: the old app has never synced (no stride_last_sync_time): the delivery migration will stamp nothing. The fallback check still holds; the gate's scenario is a synced store."
    grep -E '"stride_(last_sync_time|sync_cursor|delivery_migration_v1_done)"' "$OUT/prefs-before.txt" | sed 's/^ */prefs: /' || true
    last_sync="$(sed -n 's/^ *"stride_last_sync_time" => "\(.*\)"$/\1/p' "$OUT/prefs-before.txt")"
  else
    echo "NOTE: no prefs plist before the upgrade ($(tail -1 "$OUT/prefs-before.txt"))"
  fi
  store_sha1 "$grp" >"$OUT/sha1-before.txt"
  copy_store "$grp" "$OUT/before"
  echo "Stride.store (copied to before/):"
  sed 's/^/  sha1 /' "$OUT/sha1-before.txt"
  echo "  $(store_counts "$OUT/before/Stride.store")"
  qualify="$(qualifying_rows "$OUT/before/Stride.store" "$last_sync")"
  echo "  rows the delivery migration must mark (5+ min before the last sync${last_sync:+, $last_sync}): $qualify"
  edits_before="$(recovered_edits "$data")"
  if [[ -n "$REM_DAILY" ]]; then
    # Read while the old build's requests are all there is. The stores live outside the app's
    # containers, so the in-place install should leave them alone; the new build's first launch
    # is what changes them (its reschedule and prune, D4).
    "$APP_SH" reminders "$UDID" "$OUT/reminders-before" >"$OUT/reminders-before.txt" \
      || die "--reminders: could not read the device's notification store before the upgrade (above). The starting point needs notifications allowed and both reminder habits on, on the OLD build: README, \"Reminder habits\""
    check_reminders_before "$OUT/reminders-before.txt" \
      || die "--reminders: the starting point is not the old build's two reminders (reminders-before.txt): README, \"Reminder habits\""
  fi

  section "in-place install of $NEW_V"
  # From before the install: chronod may start the widget before the app's first launch.
  t0="$(date -v-2S '+%Y-%m-%d %H:%M:%S')"
  "$APP_SH" install "$UDID" "$NEW"
  store_sha1 "$grp" >"$OUT/sha1-after-install.txt"
  if diff <(grep -v -- '-shm$' "$OUT/sha1-before.txt") <(grep -v -- '-shm$' "$OUT/sha1-after-install.txt") >/dev/null; then
    echo "Stride.store and its -wal: byte-identical after the install"
  else
    echo "NOTE: Stride.store changed between the install and the launch — something opened it first (the widget?):"
    sed 's/^/  /' "$OUT/sha1-after-install.txt"
  fi

  section "first launch"
  if [[ -n "$SERVER" ]]; then
    require_running "$SERVER" >/dev/null
    log="$(server_home "$SERVER")/server.log"
    mark="$(wc -l <"$log" | tr -d ' ')"
  fi
  pid="$("$APP_SH" launch "$UDID")"
  echo "launched (pid ${pid:-?}); waiting $WAIT s"
  sleep "$WAIT"
  "$APP_SH" shot "$UDID" "$OUT/first-launch.png" >/dev/null || echo "NOTE: no screenshot"
  if "$APP_SH" running "$UDID"; then
    echo "the app is running $WAIT s after the launch (screenshot: first-launch.png)"
  else
    echo "the app is NOT running $WAIT s after the launch: a crash (DiagnosticReports, the device log)"
    fail="$fail; the app was not running after the wait"
  fi
  "$APP_SH" terminate "$UDID" >/dev/null

  section "device log since $t0 (devicelog.txt)"
  xcrun simctl spawn "$UDID" log show --start "$t0" --style compact --predicate "$LOG_PREDICATE" \
    >"$OUT/devicelog.txt" 2>"$OUT/devicelog.err" \
    || die "log show failed, so the run cannot decide: $(tail -3 "$OUT/devicelog.err")"
  check_log "$OUT/devicelog.txt" || fail="$fail; a failed store open in the device log (CoreData 134110/134100, the fallback, or the error screen)"

  section "store gate (devicelog.txt, group-prefs-after.txt)"
  check_gate "$OUT/devicelog.txt" || fail="$fail; the widget opened the store before the app had (the U123 race window)"
  "$APP_SH" prefs "$UDID" group >"$OUT/group-prefs-after.txt" 2>&1 || true
  marker="$(sed -n 's/^ *"stride_store_schema_version" => \([0-9][0-9]*\)$/\1/p' "$OUT/group-prefs-after.txt")"
  if [[ -n "$marker" ]]; then
    echo "App Group marker: stride_store_schema_version = $marker"
  elif [[ $GATE_BUILD -eq 1 ]]; then
    echo "App Group marker: MISSING — the app opened the store but wrote no stride_store_schema_version: the widget would wait forever"
    fail="$fail; no store schema marker in the App Group prefs"
  else
    echo "App Group marker: none (a build before the schema gate)"
  fi

  section "fallback stores"
  grp2="$("$APP_SH" group "$UDID")"
  data="$("$APP_SH" container "$UDID")"
  [[ "$grp2" == "$grp" ]] || echo "NOTE: the app group container moved: $grp → $grp2"
  check_dir "$grp2" "app group container" || fail="$fail; a default.store in the app group container"
  check_dir "$data" "data container" || fail="$fail; a default.store in the data container"

  section "Stride.store after the first launch (copied to after/)"
  copy_store "$grp2" "$OUT/after"
  store_sha1 "$OUT/after" >"$OUT/sha1-after.txt"
  ck_before="$(store_counts "$OUT/before/Stride.store")"
  ck_after="$(store_counts "$OUT/after/Stride.store")"
  echo "before: $ck_before"
  echo "after:  $ck_after"
  if [[ "${ck_before##*model=}" == "${ck_after##*model=}" ]]; then
    echo "model checksum unchanged: the new app did not migrate Stride.store (right only when the release changes no model)"
  else
    echo "model checksum changed: Stride.store was migrated"
  fi

  section "prefs after the first launch (prefs-after.txt)"
  if "$APP_SH" prefs "$UDID" app >"$OUT/prefs-after.txt" 2>&1; then
    delivery_prefs "$OUT/prefs-after.txt"
  else
    echo "no prefs plist: $(tail -1 "$OUT/prefs-after.txt")"
  fi

  if [[ -n "$SERVER" ]]; then
    section "server '$SERVER': the launch's requests (requests.txt)"
    tail -n +"$((mark + 1))" "$log" | grep '^E2E ' >"$OUT/requests.txt" || true
    if [[ -s "$OUT/requests.txt" ]]; then cat "$OUT/requests.txt"; else echo "(no E2E lines)"; fi
    echo "(a good first launch pulls in full with ?deletionsSince= when marks were stamped, and pushes no whole store)"
  fi

  section "delivery marks"
  if [[ "$qualify" == "?" ]]; then
    echo "NOTE: could not count the rows the migration must mark (no last sync in the old prefs, or a store without stamps)"
  elif [[ "$qualify" -eq 0 ]]; then
    echo "no row was 5+ min older than the old app's last sync: the migration has nothing to mark"
  elif grep -q '"stride_delivery_marks_unproven"' "$OUT/prefs-after.txt" 2>/dev/null; then
    echo "marked: $qualify row(s) qualified, and the marks wait for their proof (stride_delivery_marks_unproven)"
  elif [[ -s "$OUT/requests.txt" ]] && grep -Eq 'GET /v1/sync/pull\?([^ ]*&)?deletionsSince=' "$OUT/requests.txt"; then
    echo "marked: $qualify row(s) qualified, and the first full pull asked ?deletionsSince= (the marks' proof ran)"
  else
    echo "NOT MARKED: $qualify row(s) were 5+ min older than the old app's last sync, yet no mark waits and no pull asked ?deletionsSince= — U123's signature: the migration ran on another store"
    fail="$fail; the delivery migration marked none of $qualify qualifying rows"
  fi

  section "recovered edits"
  data="$("$APP_SH" container "$UDID")"
  edits="$(recovered_edits "$data")"
  echo "SyncRecoveryLog lines: $edits_before before the upgrade, $edits after the first launch"
  if [[ "$edits" -gt "$edits_before" ]]; then
    fail="$fail; $((edits - edits_before)) recovered edit(s) after the first launch"
  fi

  if [[ -n "$REM_DAILY" ]]; then
    section "reminders after the first launch (reminders-before.txt, reminders-after.txt, reminders-check.txt)"
    # Retried: usernotificationsd applies the app's removes and adds asynchronously and writes the
    # plist after them, so the first read can still show the old build's state.
    rem_ok=0
    try=1
    while :; do
      rm_under_root "$OUT/reminders-after"
      : >"$OUT/reminders-check.txt"
      if "$APP_SH" reminders "$UDID" "$OUT/reminders-after" >"$OUT/reminders-after.txt" 2>"$OUT/reminders-after.err" \
         && check_reminders "$OUT/reminders-after.txt" >"$OUT/reminders-check.txt"; then
        rem_ok=1
        break
      fi
      [[ $try -lt $REM_TRIES ]] || break
      sleep "$REM_PAUSE"
      try=$((try + 1))
    done
    echo "read $try time(s); pending for the two habits:"
    echo "  before: daily [$(habit_requests "$OUT/reminders-before.txt" "$REM_DAILY")]  M/W/F [$(habit_requests "$OUT/reminders-before.txt" "$REM_MWF")]"
    if [[ -s "$OUT/reminders-check.txt" ]]; then
      echo "  after:  daily [$(habit_requests "$OUT/reminders-after.txt" "$REM_DAILY")]  M/W/F [$(habit_requests "$OUT/reminders-after.txt" "$REM_MWF")]"
      cat "$OUT/reminders-check.txt"
    else
      echo "  after:  could not be read: $(tail -1 "$OUT/reminders-after.err" 2>/dev/null)"
    fi
    if [[ $rem_ok -eq 0 ]]; then
      fail="$fail; the reminders were not converted as D4 requires (reminders-check.txt)"
    fi
  fi

  if [[ $RELAUNCH -eq 1 ]]; then
    section "relaunch (relaunch.png, requests-relaunch.txt)"
    if [[ -n "$SERVER" ]]; then mark2="$(wc -l <"$log" | tr -d ' ')"; fi
    pid="$("$APP_SH" launch "$UDID")"
    echo "launched again (pid ${pid:-?}); waiting $WAIT s"
    sleep "$WAIT"
    "$APP_SH" shot "$UDID" "$OUT/relaunch.png" >/dev/null || echo "NOTE: no screenshot"
    if ! "$APP_SH" running "$UDID"; then
      echo "the app is NOT running $WAIT s after the relaunch"
      fail="$fail; the app was not running after the relaunch"
    fi
    "$APP_SH" terminate "$UDID" >/dev/null
    if [[ -n "$SERVER" ]]; then
      tail -n +"$((mark2 + 1))" "$log" | grep '^E2E ' >"$OUT/requests-relaunch.txt" || true
      if [[ -s "$OUT/requests-relaunch.txt" ]]; then cat "$OUT/requests-relaunch.txt"; else echo "(no E2E lines)"; fi
      echo "(U123's relaunch pushed the whole store here: sentHabits=7 sentEntries=135, 17 answered tombstoned)"
    fi
    data="$("$APP_SH" container "$UDID")"
    edits="$(recovered_edits "$data")"
    echo "SyncRecoveryLog lines after the relaunch: $edits"
    if [[ "$edits" -gt "$edits_before" ]]; then
      fail="$fail; $((edits - edits_before)) recovered edit(s) after the relaunch"
    fi
  fi

  section "verdict"
  if [[ -n "$fail" ]]; then
    echo "FAIL: $OLD_V → $NEW_V on $DEV: ${fail#; }."
    case "$fail" in
      *default.store*|*"failed store open"*|*"before the app had"*|*"marked none"*|*"recovered edit"*)
        echo "The first launch after the upgrade did not open Stride.store: an App Store update would show the user an empty app (the fallback, then a whole-store push on the next launch, E2E U123) or the store error screen, not their habits." ;;
    esac
    case "$fail" in
      *"reminders were not converted"*)
        echo "The 1.3.x reminders were not turned into 1.4.0's: a specific-days habit would keep nagging on rest days (or a daily one fall silent), and the action buttons need the categories (D4)." ;;
    esac
    echo "Evidence: $OUT"
    return 3
  fi
  echo "PASS: $OLD_V → $NEW_V on $DEV: the first launch opened Stride.store; no failed open in the device log, no default.store, no widget open before the app's, no unmarked rows, no recovered edits${REM_DAILY:+; the reminders converted (.2 .4 .6 for the M/W/F habit, the daily bare id kept, both categories registered)}. Evidence: $OUT"
}

run 2>&1 | tee "$OUT/report.txt"
