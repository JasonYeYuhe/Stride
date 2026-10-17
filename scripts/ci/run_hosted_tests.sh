#!/bin/bash
# Run the hosted test suite (StrideAppTests, TEST_HOST = Stride.app) on an iOS simulator, and
# fail unless it actually ran tests and none failed.
#
#   scripts/ci/run_hosted_tests.sh [simulator name or UDID] [extra xcodebuild args...]
#
# Without a simulator (or with ""): "iPhone 17" if one exists, else the first available
# iPhone — on the xcode-27 CI image that is whatever the iOS 27 runtime names its phones. An
# existing simulator is always reused — this never creates or erases one (every simulator that
# gets used collects gigabytes; see the global notes).
#
# Why "iPhone 17" and not "iPhone 17 Pro" (the default until 1.4.0): the Pro is the E2E kit's
# device (scripts/sim_e2e, RELEASE-1.4.0.md D7), and a hosted run is not harmless to it. The
# run installs an UNSIGNED Debug Stride.app over the kit's ad-hoc build, so it has no app group
# and opens an empty Documents store; its launch reschedule then removes every
# stride.habit.reminder.* request pending on the device, and it spends the data container's
# once-per-install flags (SyncDeliveryMigration's done key, firstLaunchNoted) that the upgrade
# gate from 1.3.0 depends on (design review: hosted-runs-clobber-e2e-device). After a hosted run
# on the kit's device, `app.sh reset` it; a plain reinstall keeps the spent flags.
#
# The device lock: /tmp/lock-<device slug> (/tmp/lock-iphone-17), taken before the build and
# released on exit, with scripts/ci/sim_lock.sh — the /tmp/lock-<device> convention that
# a11y_sweep.sh, the E2E kit's lock.sh and the other projects on this Mac use, so a hosted run
# no longer lands in the middle of someone's session on the same device.
# Someone else's lock is waited on for at most STRIDE_SIM_LOCK_WAIT minutes (40); then this
# prints BLOCKED and exits 2 having run nothing. If you already hold the device's lock, write
# `label=<yours>` in its holder file and pass STRIDE_SIM_LOCK_LABEL=<yours>: the run then
# happens inside your hold and leaves it held. Without that label it waits on you, then
# BLOCKED. With CI=true (GitHub Actions) no lock is taken: a fresh runner has no other users.
#
# Why a simulator: a hosted bundle is injected into the running app, so it needs a destination
# that can launch Stride.app. A generic device destination cannot, and neither can macOS (the
# app target is iOS-only). Two callers:
#   - ci.yml's Apple job, on the xcode-27 preview image (iOS 27 simulator runtime) — the only
#     GitHub image with Xcode 27, so this CI coverage lasts only as long as that image does;
#   - scripts/ship.sh, before anything is archived — the gate that does not depend on it.
#
# Environment:
#   STRIDE_HOSTED_DERIVED_DATA   derived data to build into (default: a persistent one under
#                                ~/Library/Developer/Xcode/DerivedData, so a rerun is incremental)
#   STRIDE_HOSTED_ALL=1          run the Stride scheme's whole test action (StrideTests too,
#                                on iOS) instead of only StrideAppTests
#   STRIDE_SIM_LOCK_ROOT, STRIDE_SIM_LOCK_LABEL, STRIDE_SIM_LOCK_WAIT
#                                the device lock, above (scripts/ci/sim_lock.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=sim_lock.sh
source "$SCRIPT_DIR/sim_lock.sh"
DERIVED="${STRIDE_HOSTED_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Stride-hosted-tests}"
WANT="${1:-}"
[[ $# -gt 0 ]] && shift

# Resolve the destination to ONE simulator UDID. `name=` alone is ambiguous when the same
# device name exists under several runtimes, and xcodebuild then picks one on its own.
# Preference: exact UDID > exact name (booted first, then newest runtime) > first iPhone.
UDID="$(xcrun simctl list devices available -j | WANT="$WANT" /usr/bin/python3 -c '
import json, os, re, sys
want = os.environ["WANT"]
devices = []
for runtime, devs in json.load(sys.stdin)["devices"].items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in re.findall(r"\d+", runtime.split("iOS-")[-1]))
    for d in devs:
        devices.append((d, version))

def best(candidates):
    # Booted first (no boot wait), then the newest runtime.
    candidates.sort(key=lambda dv: (dv[0]["state"] == "Booted", dv[1]), reverse=True)
    return candidates[0][0]["udid"] if candidates else ""

if want:
    exact = [dv for dv in devices if dv[0]["udid"] == want] or [dv for dv in devices if dv[0]["name"] == want]
    print(best(exact))
else:
    print(best([dv for dv in devices if dv[0]["name"] == "iPhone 17"])
          or best([dv for dv in devices if dv[0]["name"].startswith("iPhone")]))
')" || {
    # Without this, set -e would end the script here with no message at all — and the usual
    # cause (CoreSimulatorService wedged) has a known fix worth printing.
    echo "✗ Could not list simulators (xcrun simctl list failed)."
    echo "  If CoreSimulator is wedged: killall -9 com.apple.CoreSimulator.CoreSimulatorService"
    exit 1
}

if [[ -z "$UDID" ]]; then
    echo "✗ No available iOS simulator matches '${WANT:-iPhone 17 / any iPhone}'."
    echo "  Available: xcrun simctl list devices available"
    exit 1
fi
NAME="$(xcrun simctl list devices available | grep -F "$UDID" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/' | head -1)"

# The device lock (header), before the build: `xcodebuild test` boots the device, installs and
# launches the host the moment its build ends, so there is no later point to take it at.
if [[ "${CI:-}" == "true" ]]; then
    echo "==> CI=true: no simulator lock (a fresh runner has no other users)"
else
    LOCK_RC=0
    sim_lock_take "${STRIDE_SIM_LOCK_ROOT:-/tmp}/lock-$(sim_lock_slug "$NAME")" run_hosted_tests || LOCK_RC=$?
    [[ $LOCK_RC -eq 0 ]] || exit "$LOCK_RC"
    trap sim_lock_release EXIT
fi

ONLY=(-only-testing:StrideAppTests)
[[ "${STRIDE_HOSTED_ALL:-}" == "1" ]] && ONLY=()

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stride-hosted-tests.XXXXXX")"
RESULT="$RUN_DIR/result.xcresult"
LOG="$RUN_DIR/xcodebuild.log"

echo "==> Hosted tests on $NAME ($UDID)"
echo "    derived data: $DERIVED"
echo "    log: $LOG"

# -collect-test-diagnostics never: on a failure xcodebuild otherwise gathers a sysdiagnose
# from the simulator, and on a loaded Mac that waited out its full 600 s timeout before
# reporting a failure that was known in under a second (measured 2026-09-27).
# CODE_SIGNING_ALLOWED=NO: a simulator needs no signature, and the gate must not depend on the
# login keychain (ship.sh may be running from SSH with the console locked).
set +e
xcodebuild test \
    -project "$PROJECT_DIR/Stride.xcodeproj" \
    -scheme Stride \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULT" \
    -collect-test-diagnostics never \
    "${ONLY[@]+"${ONLY[@]}"}" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    > "$LOG" 2>&1
status=$?
set -e

# xcodebuild can exit 0 having run nothing — a scheme with no test action, a filter that
# matches no bundle — so the exit status alone proves nothing (see project.yml). Count from
# the result bundle, and fall back to the log only if the bundle cannot be read.
counts="$(xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
s = json.load(sys.stdin)
print(s.get("passedTests", 0), s.get("failedTests", 0), s.get("skippedTests", 0), s.get("result", "?"))
' 2>/dev/null || true)"
if [[ -z "$counts" ]]; then
    last="$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$LOG" | tail -1 || true)"
    executed="$(sed -E 's/.*Executed ([0-9]+) tests?.*/\1/' <<<"$last")"
    failed="$(sed -E 's/.*with ([0-9]+) failures?.*/\1/' <<<"$last")"
    counts="$(( ${executed:-0} - ${failed:-0} )) ${failed:-0} 0 from-log"
fi
read -r passed failed skipped result <<<"$counts"

grep -E "error: -\[|' failed \(" "$LOG" | sed 's/^/    /' || true
echo "    xcodebuild exit $status; passed $passed, failed $failed, skipped $skipped ($result)"

if [[ $status -ne 0 || "$failed" != "0" || "$passed" -eq 0 ]]; then
    echo "✗ Hosted tests did not pass. Full log: $LOG"
    [[ $status -ne 0 && "$passed" -eq 0 && "$failed" == "0" ]] && tail -30 "$LOG" | sed 's/^/    /'
    exit 1
fi
echo "✓ Hosted tests passed ($passed tests)."
rm -rf "$RUN_DIR"
