#!/bin/bash
# Sourced, never run: the Swift package checkout every local xcodebuild in scripts/ shares, and
# the lock that keeps two builds out of one derived-data directory. Bash 3.2 (macOS /bin/bash).
#
# Why: each derived-data root used to clone its own SourcePackages, and about 1.9 GB of every
# ~2.2 GB root is sentry-cocoa (86 %, measured 2026-10-14 in the Documents session's
# trash-inflow investigation, proposal P3). Every cold root an agent made, and later trashed,
# downloaded and unpacked the same package again. CI already shares one per run (ci.yml "Cache
# Swift packages"); this is the local equivalent.
#
#   spm_cache_args <project dir> [the caller's xcodebuild args...]
#     Sets the array SPM_ARGS, for the caller to splice into its xcodebuild line as
#     "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}" (a bare "${SPM_ARGS[@]}" of an empty array is an
#     unbound-variable error under bash 3.2's set -u):
#       -clonedSourcePackagesDirPath <dir> -disableAutomaticPackageResolution
#     after making sure <dir> holds a finished resolve for <project dir>. SPM_ARGS stays empty
#     (xcodebuild resolves into the derived data, as before) when:
#       - CI=true: ci.yml passes its own cache flags;
#       - the caller's args already name -clonedSourcePackagesDirPath;
#       - STRIDE_SPM_DIR=off;
#       - the project has no Package.resolved;
#       - the resolve fails (printed as a warning, with its log): a Package.resolved that no
#         longer satisfies the project's package requirements, or no network. The build then
#         behaves exactly as it did before this file.
#     Returns 1 only when another process holds the resolve lock for too long. Call it in the
#     same shell as the build: SPM_ARGS is a shell variable, and a warm call costs one sha256.
#
#   build_lock_take <lock dir> <what>   wait for, then take, a mkdir lock (pid inside). A lock
#                                       whose holder (and recorded child) are gone is taken
#                                       over. 0 taken, 1 gave up after STRIDE_BUILD_LOCK_WAIT.
#   build_lock_release <lock dir>       stop this shell's own child processes (a signal ran the
#                                       EXIT trap while xcodebuild was still running), then
#                                       remove the lock. Only after build_lock_take succeeded.
#   build_lock_path <derived data dir>  /tmp/lock-stride-dd-<cksum of the path>: the lock for
#                                       one derived-data directory. Pass the path spelled the
#                                       same way every time.
#
# The package directory: ~/Library/Caches/Stride-build/SourcePackages-<8 hex>, the sha256 of
# Package.resolved plus the project's package references (project.pbxproj's
# XCRemote/XCLocalSwiftPackageReference sections). Keying by both means a branch that bumps a
# package gets its own directory instead of re-resolving the one every other checkout is
# building from, a requirement change without a matching Package.resolved gets a fresh resolve
# (which fails, and so falls back) instead of a build against the old checkout, and the old tags
# the upgrade gates build (sim_e2e/build.sh <tag>) key by their own files. STRIDE_SPM_DIR=<dir>
# overrides the location; that directory is re-resolved whenever the key changes, so never
# share one between trees that differ in packages.
#
# Resolution happens here, once per directory, under <dir>.lock, with
# -onlyUsePackageVersionsFromResolvedFile as CI does. <dir>/.stride-resolved (the key) marks a
# finished resolve, so one killed half-way is resolved again rather than trusted. Builds then
# pass -disableAutomaticPackageResolution, which keeps them from resolving to versions other than
# Package.resolved's. They still rewrite <dir>/workspace-state.json: concurrent builds are safe
# because SwiftPM serializes that with its own lock files in $TMPDIR, keyed by the directory's
# path (measured 2026-10-14: a Mac-variant build and an E2E build at once, then hosted tests and
# an a11y sweep at once). So builds that share a directory should share a $TMPDIR, which every
# script here does.
#
# Never delete the directory while a build may be using it. Deleting it otherwise is safe: the
# next build resolves it again (a ~2 GB download).
#
# Environment:
#   STRIDE_SPM_DIR         the package directory, or `off` (above)
#   STRIDE_BUILD_LOCK_WAIT seconds to wait for a held lock before giving up (default 2400)

SPM_ARGS=()

build_lock_path() {
    echo "${STRIDE_SIM_LOCK_ROOT:-/tmp}/lock-stride-dd-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

# 0 when the lock's holder, or the child it recorded (a resolve run in the background), is alive.
_build_lock_alive() {
    local p
    for p in "$(cat "$1/pid" 2>/dev/null || true)" "$(cat "$1/child" 2>/dev/null || true)"; do
        [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && return 0
    done
    return 1
}

# Removes a lock whose holder is gone, but only if it still shows the state the caller saw:
# under <lock>.reap, so two waiters that both saw the same dead holder cannot have the second
# remove the lock the first has just retaken.
#   0 removed, or the lock changed since the caller looked (try mkdir again)
#   1 someone else is reaping (retry shortly)
#   2 it could not be removed (treat it as held)
_build_lock_reap() {
    local lock="$1" seen="$2" holder age now rc=0
    now=$(date +%s)
    if ! mkdir "$lock.reap" 2>/dev/null; then
        # Held for microseconds; a minute old means its holder died inside it.
        age=$(( now - $(stat -f %m "$lock.reap" 2>/dev/null || echo "$now") ))
        (( age > 60 )) && rmdir "$lock.reap" 2>/dev/null
        return 1
    fi
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
    if [[ -n "$seen" && "$holder" == "$seen" ]] && ! _build_lock_alive "$lock"; then
        echo "==> $lock was left by pid $seen, which is gone; taking it over" >&2
        rm -f "$lock/pid" "$lock/child" "$lock/what"
        rmdir "$lock" 2>/dev/null || rc=2
    elif [[ -z "$seen" && -d "$lock" && -z "$holder" ]] && (( age > 60 )); then
        # mkdir and the pid write are microseconds apart: no pid a minute later means the holder
        # died in between.
        echo "==> $lock has had no pid for ${age}s; taking it over" >&2
        rm -f "$lock/child" "$lock/what"
        rmdir "$lock" 2>/dev/null || rc=2
    fi
    rmdir "$lock.reap" 2>/dev/null || true
    return $rc
}

build_lock_take() {
    local lock="$1" what="$2" holder age now rc stuck=0 next_note=0
    local deadline=$(( $(date +%s) + ${STRIDE_BUILD_LOCK_WAIT:-2400} ))
    while ! mkdir "$lock" 2>/dev/null; do
        now=$(date +%s)
        if (( now >= deadline )); then
            echo "✗ $lock is still held ($(cat "$lock/what" 2>/dev/null || echo '?'), pid $(cat "$lock/pid" 2>/dev/null || echo '?')); gave up after ${STRIDE_BUILD_LOCK_WAIT:-2400}s" >&2
            return 1
        fi
        holder="$(cat "$lock/pid" 2>/dev/null || true)"
        rc=3
        if [[ -n "$holder" ]] && ! _build_lock_alive "$lock"; then
            rc=0; _build_lock_reap "$lock" "$holder" || rc=$?
        elif [[ -z "$holder" ]]; then
            age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
            if (( age > 60 )); then rc=0; _build_lock_reap "$lock" "" || rc=$?; fi
        fi
        (( rc == 0 )) && continue
        if (( rc == 2 && stuck == 0 )); then
            echo "⚠ $lock belongs to nobody but cannot be removed (not empty?); waiting as if it were held" >&2
            stuck=1
        fi
        if (( rc == 3 && now >= next_note )); then
            echo "==> Waiting for $lock ($(cat "$lock/what" 2>/dev/null || echo '?'), pid ${holder:-?})" >&2
            next_note=$(( now + 300 ))
        fi
        if (( rc == 1 )); then sleep 1; else sleep 5; fi
    done
    echo "$$" >"$lock/pid"
    echo "$what" >"$lock/what"
}

build_lock_release() {
    local lock="$1" i
    # On a signal, bash runs the EXIT trap at once while its foreground xcodebuild keeps going;
    # freeing the lock then would let the next build into a build.db that is still being written.
    # So this shell's own children (by parent pid) are stopped first, with up to 30 s to exit.
    if pgrep -P $$ >/dev/null 2>&1; then
        pkill -TERM -P $$ 2>/dev/null || true
        for i in {1..30}; do
            pgrep -P $$ >/dev/null 2>&1 || break
            sleep 1
        done
    fi
    rm -f "$lock/pid" "$lock/child" "$lock/what"
    rmdir "$lock" 2>/dev/null || true
}

spm_cache_args() {
    local proj="$1" a resolved key dir marker lock log rpid
    shift
    SPM_ARGS=()
    [[ "${CI:-}" == "true" ]] && return 0
    [[ "${STRIDE_SPM_DIR:-}" == "off" ]] && return 0
    for a in "$@"; do
        [[ "$a" == "-clonedSourcePackagesDirPath" ]] && return 0
    done
    resolved="$proj/Stride.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if [[ ! -f "$resolved" ]]; then
        echo "==> No Package.resolved in $proj: packages resolve into the derived data" >&2
        return 0
    fi
    key="$( { cat "$resolved"
              sed -n -e '/Begin XCRemoteSwiftPackageReference section/,/End XCRemoteSwiftPackageReference section/p' \
                     -e '/Begin XCLocalSwiftPackageReference section/,/End XCLocalSwiftPackageReference section/p' \
                     "$proj/Stride.xcodeproj/project.pbxproj" 2>/dev/null || true
            } | shasum -a 256 | awk '{print $1}')"
    dir="${STRIDE_SPM_DIR:-$HOME/Library/Caches/Stride-build/SourcePackages-${key:0:8}}"
    dir="${dir%/}"
    marker="$dir/.stride-resolved"
    if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
        lock="$dir.lock"
        mkdir -p "$(dirname "$dir")"
        build_lock_take "$lock" "resolving packages for $proj" || return 1
        # Someone else may have finished the same resolve while this waited.
        if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
            log="$dir.resolve.log"
            echo "==> Resolving Swift packages into $dir (once per package set; log $log)" >&2
            rm -f "$marker"
            mkdir -p "$dir"
            # In the background with its pid in the lock, so a waiter never takes the lock over
            # from a resolve that outlived its shell.
            xcodebuild -resolvePackageDependencies -project "$proj/Stride.xcodeproj" \
                -clonedSourcePackagesDirPath "$dir" -onlyUsePackageVersionsFromResolvedFile \
                >"$log" 2>&1 &
            rpid=$!
            echo "$rpid" >"$lock/child"
            if ! wait "$rpid"; then
                tail -8 "$log" | sed 's/^/    /' >&2
                echo "⚠ Could not resolve into $dir (log $log); this build resolves into its own derived data instead" >&2
                build_lock_release "$lock"
                return 0
            fi
            if ! echo "$key" 2>/dev/null >"$marker"; then
                echo "⚠ Could not write $marker; this build resolves into its own derived data instead" >&2
                build_lock_release "$lock"
                return 0
            fi
        fi
        build_lock_release "$lock"
    fi
    SPM_ARGS=(-clonedSourcePackagesDirPath "$dir" -disableAutomaticPackageResolution)
}
