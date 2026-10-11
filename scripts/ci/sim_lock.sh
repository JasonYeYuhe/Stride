#!/bin/bash
# Sourced, never run: the per-simulator mutex of scripts/a11y_sweep.sh and
# scripts/ci/run_hosted_tests.sh. Bash 3.2 (macOS /bin/bash).
#
# The lock is a directory, /tmp/lock-<device slug> (mkdir is atomic): the convention every
# project on this Mac uses for the shared simulators, and the one scripts/sim_e2e/lock.sh takes
# for the kit's iPhones. Before 1.4.0 these two scripts did not meet it:
#   - a11y_sweep.sh locked under $TMPDIR (a per-user /var/folders/… path), so it never excluded
#     the kit or another project on the same iPhone, and kept the parentheses of
#     "iPad Pro 13-inch (M5)" in its slug — not the /tmp/lock-ipad-pro-13-inch-m5 that
#     RELEASE-1.4.0.md D7 names (design review: ipad-lock-ineffective);
#   - run_hosted_tests.sh took no lock at all, on the kit's own iPhone 17 Pro, so a hosted run
#     during an E2E session removed the device's pending reminders and spent its once-per-install
#     flags (design review: hosted-runs-clobber-e2e-device).
#
#   sim_lock_slug <device name>   "iPad Pro 13-inch (M5)" → ipad-pro-13-inch-m5,
#                                 "iPhone 17 Pro Max" → iphone-17-pro-max (unchanged from before)
#   sim_lock_take <dir> <by>      0 held, 1 bad settings, 2 BLOCKED (the code lock.sh uses)
#   sim_lock_release              removes the lock only when sim_lock_take created it
#
# sim_lock_take:
#   - mkdir succeeds: taken here. A `holder` file goes inside (label, pid, since, by — the
#     format of scripts/sim_e2e/lock.sh, so `lock.sh status` and a person can tell who has it).
#   - the lock exists and its holder label equals $STRIDE_SIM_LOCK_LABEL: the caller already
#     holds it (an agent that took the device for a whole session, then runs a sweep or the
#     hosted tests on it). Run inside that hold; it is NOT removed afterwards. Without this a
#     caller following the rule "hold the lock while you use the device" waited on itself
#     forever, which the old `until mkdir; do sleep 15; done` did.
#   - otherwise: poll every $SIM_LOCK_POLL s (20) for at most $STRIDE_SIM_LOCK_WAIT minutes
#     (40, as lock.sh --wait), then print BLOCKED and return 2. A lock with no holder file was
#     taken outside these scripts; it is waited on like any other and never removed.
#
# Environment:
#   STRIDE_SIM_LOCK_ROOT    where the lock directories live (default /tmp)
#   STRIDE_SIM_LOCK_LABEL   your label (letters, digits, . _ @ : -); see above
#   STRIDE_SIM_LOCK_WAIT    minutes to wait before BLOCKED (default 40; 0 = do not wait)

SIM_LOCK_DIR=""
SIM_LOCK_TAKEN=0

sim_lock_slug() { tr '[:upper:] ' '[:lower:]-' <<<"$1" | tr -cd 'a-z0-9-'; }

sim_lock_holder_label() { sed -n '/^label=/{s///p;q;}' "$1/holder" 2>/dev/null || true; }

sim_lock_describe() {
    if [[ -f "$1/holder" ]]; then
        echo "held — $(tr '\n' ' ' <"$1/holder" | sed 's/ *$//')"
    else
        echo "held (no holder file: taken outside these scripts, $(stat -f '%Sm' "$1" 2>/dev/null || echo '?'))"
    fi
}

sim_lock_take() {
    local dir="$1" by="$2" label="${STRIDE_SIM_LOCK_LABEL:-}" wait_min="${STRIDE_SIM_LOCK_WAIT:-40}"
    local poll="${SIM_LOCK_POLL:-20}" deadline next_note now
    if [[ ! "$wait_min" =~ ^[0-9]+$ ]]; then
        echo "✗ STRIDE_SIM_LOCK_WAIT must be whole minutes (got '$wait_min')"
        return 1
    fi
    if [[ -n "$label" && ! "$label" =~ ^[A-Za-z0-9._@:-]+$ ]]; then
        echo "✗ STRIDE_SIM_LOCK_LABEL may hold letters, digits and . _ @ : - only (got '$label')"
        return 1
    fi
    SIM_LOCK_DIR="$dir"
    SIM_LOCK_TAKEN=0
    deadline=$(( $(date +%s) + wait_min * 60 ))
    next_note=0
    while :; do
        if mkdir "$dir" 2>/dev/null; then
            SIM_LOCK_TAKEN=1
            printf 'label=%s\npid=%s\nsince=%s\nby=%s\n' "${label:-$by}" "$$" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$by" >"$dir/holder"
            echo "==> Took $dir (label ${label:-$by})"
            return 0
        fi
        if [[ -n "$label" && "$(sim_lock_holder_label "$dir")" == "$label" ]]; then
            echo "==> $dir is held by '$label' (STRIDE_SIM_LOCK_LABEL): running inside that hold; it stays held afterwards"
            return 0
        fi
        now=$(date +%s)
        if (( now >= deadline )); then
            echo "BLOCKED: $dir still $(sim_lock_describe "$dir") after $wait_min min"
            return 2
        fi
        # Once at the start, then every 5 minutes: a 40-minute wait should not print 120 lines.
        if (( now >= next_note )); then
            echo "==> Waiting for $dir ($(sim_lock_describe "$dir")); BLOCKED in $(( (deadline - now + 59) / 60 )) min"
            next_note=$(( now + 300 ))
        fi
        sleep "$poll"
    done
}

sim_lock_release() {
    [[ $SIM_LOCK_TAKEN -eq 1 && -n "$SIM_LOCK_DIR" ]] || return 0
    SIM_LOCK_TAKEN=0
    rm -f "$SIM_LOCK_DIR/holder"
    rmdir "$SIM_LOCK_DIR" 2>/dev/null \
        || echo "⚠ $SIM_LOCK_DIR is not empty after removing its holder file; left as it is"
}
