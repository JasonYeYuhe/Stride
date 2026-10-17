#!/usr/bin/env bash
set -euo pipefail
# Stride — finish a release from an SSH session (phone / Terminus), screen still locked.
#
# The console being locked does not stop signing; a locked LOGIN KEYCHAIN does.
# SSH can unlock the keychain, and the unlock is per-user, not per-session, so
# everything afterwards — including another shell, or an agent already running on
# this Mac — can sign. That is the whole trick. Nothing here needs the display.
#
#   ssh mac-ts
#   cd ~/Documents/Stride && ./scripts/ship.sh 1.2.1 15
#
# The password is typed at the `security` prompt: never an argument, never in the
# environment, never on disk, so it cannot leak into argv or shell history.

VERSION="${1:-1.2.1}"
BUILD="${2:-15}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
cd "$(dirname "$0")/.."

can_sign() {
    local probe; probe="$(mktemp -t stride-sigtest)"
    cp /bin/echo "$probe"
    codesign -f -s "Apple Distribution: Yuhe Ye (KHMK6Q3L3K)" "$probe" >/dev/null 2>&1
    local rc=$?; rm -f "$probe"; return $rc
}

if can_sign; then
    echo "==> Signing already works — no unlock needed."
else
    echo "==> Login keychain is locked. Enter the LOGIN password (input hidden):"
    security unlock-keychain "$KEYCHAIN"
    can_sign || { echo "✗ Still cannot sign after unlocking — stop and investigate;"
                  echo "  this is no longer the lock, so do not just retry."; exit 1; }
    echo "    ✓ Signing works now."
    echo
    echo "    Optional, stops this recurring: drop the keychain's lock-on-sleep and"
    echo "    idle timeout so it stays unlocked while the Mac is powered on —"
    echo "      security set-keychain-settings \"$KEYCHAIN\""
    echo "    Trade-off: anyone with code execution as you can then use your signing"
    echo "    key without the password. It is what made past unattended builds work."
fi
echo

# ~25 min of build ahead — survive the SSH connection dropping on mobile data.
#
# -L stride-ship is load-bearing, not tidiness. Keychain unlock is scoped to the
# caller's security session, and a tmux SERVER outlives the session that started
# it: plain `tmux new-session` attaches to the long-running default server, so the
# build would run as its child, in whatever session that server was born in — with
# the keychain still locked, failing exactly the way it did before you unlocked.
# (Same root cause as needing GH_TOKEN in ~/.zshenv: the old tmux server cannot
# read the keychain either.) A private socket forces a fresh server, spawned from
# THIS ssh session, inheriting the unlock.
if [[ -z "${TMUX:-}" ]] && command -v tmux >/dev/null; then
    echo "==> Re-running inside a private tmux server so a dropped connection"
    echo "    can't kill the build. Reattach with:"
    echo "      tmux -L stride-ship attach -t ship"
    exec tmux -L stride-ship new-session -A -s ship "$0" "$VERSION" "$BUILD"
fi

# The hosted tests (StrideAppTests: APIClient's 401 and decoding, SyncService's push-before-pull
# and acknowledge-after-push, AuthService's token handling, reminder planning) need a simulator
# to host Stride.app. ci.yml also runs them, but only on the xcode-27 preview image, which may
# queue for hours or lack a simulator runtime; this is the run that gates a release whatever
# that image does. First, so a red suite costs minutes rather than an archive and an upload —
# and inside tmux, so a dropped connection does not kill them. The simulator build needs no
# signing.
#
# STRIDE_SKIP_HOSTED_TESTS=1 is for the day the simulator itself is broken (CoreSimulator
# wedged, runtime missing) and a fix has to ship anyway. It is never for a failing test: a red
# test here means the build would ship that bug to everyone.
if [[ "${STRIDE_SKIP_HOSTED_TESTS:-}" == "1" ]]; then
    echo "==> [0/2] Hosted tests: SKIPPED (STRIDE_SKIP_HOSTED_TESTS=1)."
    echo "    ⚠ Shipping WITHOUT the hosted tests. Record why in the release notes."
else
    echo "==> [0/2] Hosted tests (simulator)"
    # Teed to a fixed path: when this runs inside tmux and fails, the session closes with the
    # script and takes the message with it; the file is what is left to read after reattaching.
    # "iPhone 17" by name, never the E2E kit's iPhone 17 Pro: a hosted run there removes the
    # device's pending reminders and spends its once-per-install flags (run_hosted_tests.sh's
    # header). It waits up to 40 min for that device's lock, then stops with BLOCKED.
    mkdir -p build
    ./scripts/ci/run_hosted_tests.sh "iPhone 17" 2>&1 | tee build/ship-hosted-tests.log || {
        echo "✗ Hosted tests failed — nothing was archived or uploaded (build/ship-hosted-tests.log)."
        echo "  Fix them, or, only if the simulator itself is broken, rerun with"
        echo "  STRIDE_SKIP_HOSTED_TESTS=1."
        exit 1
    }
fi
echo

# One call for both platforms, so NOTHING is uploaded until both have archived, exported and
# passed verify_archive.sh. This used to be `ios --upload` then `macos --upload`: a macOS-only
# gate failure left iOS build $BUILD already in App Store Connect, and the rerun with the same
# build number died re-uploading iOS before it ever reached macOS.
echo "==> [1/2] iOS + macOS: archive and verify both, then upload both"
./scripts/build-appstore.sh all --upload
echo "==> [2/2] Attach build $BUILD and submit $VERSION for review"
python3 scripts/release.py finish "$VERSION" "$BUILD"
python3 scripts/release.py show "$VERSION"
echo "✓ Done. Both platforms should read WAITING_FOR_REVIEW above."
