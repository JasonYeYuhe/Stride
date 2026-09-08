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

echo "==> [1/3] iOS archive + upload"
./scripts/build-appstore.sh ios --upload
echo "==> [2/3] macOS archive + upload"
./scripts/build-appstore.sh macos --upload
echo "==> [3/3] Attach build $BUILD and submit $VERSION for review"
python3 scripts/release.py finish "$VERSION" "$BUILD"
python3 scripts/release.py show "$VERSION"
echo "✓ Done. Both platforms should read WAITING_FOR_REVIEW above."
