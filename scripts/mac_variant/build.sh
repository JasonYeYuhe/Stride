#!/bin/bash
# The macOS test variant of Stride: a StrideMac build that cannot touch the real store.
#
#   scripts/mac_variant/build.sh [extra xcodebuild args...]   build it (Debug), then preflight it
#   scripts/mac_variant/build.sh --release [extra args...]    the same in the Release configuration
#   scripts/mac_variant/build.sh --entitlements-only          generate and check the entitlements
#   scripts/mac_variant/build.sh --preflight [<app>]          re-check a built variant (default:
#                                                             the one this script builds; add
#                                                             --release for a Release variant)
#
# NEVER RUN the shipping StrideMac (bundle yyh.stride.habittracker) on this Mac, and never run
# this variant before its preflight has passed: the owner's real Stride store lives at
# ~/Library/Group Containers/group.yyh.stride.habittracker/Stride.store. A DEBUG `-demo` launch
# erases whatever store the app opens (StrideApp.swift records that it wiped a real Mac store
# once), and Restore replaces it.
#
# Why a variant, and why this way (RELEASE-1.4.0.md D7; design review mac-variant-not-isolated,
# d7-mac-variant-app-group):
#   - On macOS `containerURL(forSecurityApplicationGroupIdentifier:)` is never nil, entitled or
#     not (MacOSX SDK NSFileManager.h:993), so a build that merely drops the App Group still
#     resolves the REAL store: sandboxed it is denied and shows the store error screen, unsandboxed
#     it opens and migrates the owner's data. The variant is therefore decided at compile time:
#     SWIFT_ACTIVE_COMPILATION_CONDITIONS gains STRIDE_MAC_VARIANT, under which (code in Shared/
#     and Stride/Sources) the store location is forced to .noAppGroup, App Group defaults and the
#     deletion queue's suite resolve inside the variant's container, the keychain service is the
#     bundle id, Sentry is off, and launch preconditions require a sandbox (APP_SANDBOX_CONTAINER_ID),
#     a store under NSHomeDirectory() and a bundle id other than the real one. This script refuses
#     to build when SharedModelContainer.swift has no `#if STRIDE_MAC_VARIANT` branch: without it
#     the variant would be a differently-named app pointed at the real store.
#   - Its own bundle id, yyh.stride.habittracker.mactest, so it gets its own sandbox container
#     (~/Library/Containers/yyh.stride.habittracker.mactest/), its own keychain items and its own
#     notification permission. PRODUCT_NAME stays "Stride", so LaunchServices knows two
#     Stride.app bundles: launch the variant by explicit path or `open -b <variant id>`, NEVER
#     `open -a Stride`, which may pick the shipping app.
#   - Ad-hoc signing (CODE_SIGN_IDENTITY=-, Manual, no team): no keychain, so it builds with the
#     screen locked, and no provisioning profile — so it may carry no com.apple.developer.*
#     entitlement (AMFI refuses to launch an ad-hoc binary that does).
#   - The entitlements are GENERATED from the shipping StrideMac/StrideMac.entitlements, minus
#     com.apple.security.application-groups and com.apple.developer.associated-domains (with
#     PlistBuddy), and the script fails if any com.apple.developer.* key remains. A hand-written
#     file would carry files.user-selected.read-write whether or not the shipping file does, and
#     the Restore/Export panel checks exist to prove the shipping file's entitlement (the 1.3.x bug:
#     no files.user-selected.* → no open or save panel in the sandbox).
#   - Command-line build settings only, no project.yml target: nothing in the committed project,
#     no XcodeGen drift, no extra CI target, and the shipping app cannot compile the variant branch
#     by accident.
#
# Preflight (after every build, and on --preflight), before ANY launch:
#   - Info.plist CFBundleIdentifier and `codesign -dv` Identifier= are yyh.stride.habittracker.mactest;
#   - `codesign -d --entitlements -` shows no com.apple.security.application-groups and no
#     com.apple.developer.* key, and does show com.apple.security.app-sandbox;
#   - files.user-selected.read-write is reported (missing = the shipped panel bug is back; the
#     build still passes, because showing that bug is what the panel checks are for).
# Then it prints how to launch and what to check after the launch. It never launches anything.
#
# --release (1.4.1, RELEASE-1.4.1.md W7, for gate 12 and P1 step 6): the Release configuration,
# with everything above unchanged — still the variant id, still STRIDE_MAC_VARIANT (so the store is
# still forced into the variant's container: the flag is what does that, not DEBUG), still ad-hoc
# signed with the generated entitlements, and the same preflight. What Release changes:
#   - DEBUG is not defined. The settings check requires it absent (and -Onone absent), and the
#     preflight reads the built binary: no Stride.debug.dylib, no DEBUG-only code (the
#     `-windowSize` handler's text is the probe), so `-demo`, `-demoScenario`, `-paywall`,
#     `-statsScrollTo`, `-scrollTo`, `-syncStatus` and `-windowSize` do nothing;
#   - it is a PRODUCTION client: APIClient.defaultBaseURL is https://stride-api.colorarchive.me in
#     every non-DEBUG build (APIClient.swift), and the preflight requires that URL in the binary
#     and http://localhost:3002 absent. Every sign-in on it creates or uses a real account, so it
#     signs in only with the owner's plus-address <owner>+stride-smoke@gmail.com, never the owner's
#     primary address or the demo account, and a delete-account follows a session check that the
#     account is exactly that address (RELEASE-1.4.1.md decision 4). Sentry stays off (the flag).
# Its default root is its own (~/Library/Caches/Stride-build/mac-variant-release), so a Release
# build never makes the Debug root's next build cold, and the reverse.
#
# Environment:
#   STRIDE_MAC_VARIANT_ROOT   everything this writes: entitlements, derived data, build log
#                             (default ~/Library/Caches/Stride-build/mac-variant, or
#                             …/mac-variant-release with --release; persistent, so a rebuild is
#                             incremental; refused under ~/Documents, which is iCloud-synced). Not
#                             $TMPDIR, the default until 1.4.1: macOS purges it on low disk. Give a
#                             build that must outlive the next one (the old version of an in-place
#                             upgrade gate) its own root.
#   STRIDE_SPM_DIR            the shared Swift package checkout (scripts/ci/build_cache.sh)
# Anything else on the command line goes to xcodebuild. Swift packages come from the shared
# checkout unless those args name -clonedSourcePackagesDirPath. Two builds into one root wait for
# each other (the root's lock, build_lock_path in scripts/ci/build_cache.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../ci/build_cache.sh
source "$SCRIPT_DIR/../ci/build_cache.sh"
VARIANT_ID="yyh.stride.habittracker.mactest"
REAL_ID="yyh.stride.habittracker"
SHIPPING_ENTITLEMENTS="$PROJECT_DIR/StrideMac/StrideMac.entitlements"
PLISTBUDDY=/usr/libexec/PlistBuddy
# APIClient.defaultBaseURL (Stride/Sources/Services/APIClient.swift): DEBUG, then every other build.
LOCAL_API="http://localhost:3002"
PRODUCTION_API="https://stride-api.colorarchive.me"
# Text that exists only in DEBUG code: LaunchWindowSize's messages (StrideApp.swift, `#if DEBUG`).
# Long enough to be a real string in the binary; Swift keeps literals of up to 15 bytes, such as
# "-demo" or "-windowSize", inside the instructions, where no text search finds them.
DEBUG_ONLY_PROBE="[LaunchWindowSize]"

MODE=build
CONFIG=Debug
PREFLIGHT_APP=""
XCB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --entitlements-only) MODE=entitlements; shift ;;
        --preflight) MODE=preflight; shift
                     if [[ $# -gt 0 && "$1" != -* ]]; then PREFLIGHT_APP="$1"; shift; fi ;;
        --release) CONFIG=Release; shift ;;
        -configuration|-configuration=*)
            echo "✗ no -configuration: the variant is Debug, or Release with --release"; exit 2 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) XCB_ARGS+=("$1"); shift ;;
    esac
done

if [[ "$CONFIG" == Release ]]; then
    ROOT="${STRIDE_MAC_VARIANT_ROOT:-$HOME/Library/Caches/Stride-build/mac-variant-release}"
else
    ROOT="${STRIDE_MAC_VARIANT_ROOT:-$HOME/Library/Caches/Stride-build/mac-variant}"
fi
case "$ROOT" in
    /*) ;;
    *) echo "✗ STRIDE_MAC_VARIANT_ROOT must be an absolute path (got $ROOT)"; exit 2 ;;
esac
case "$ROOT" in
    "$HOME/Documents"|"$HOME/Documents/"*|"$HOME/Library/Mobile Documents"*|"$HOME/Library/CloudStorage"*)
        echo "✗ refusing $ROOT: it is iCloud-synced; build output lives elsewhere"; exit 2 ;;
    /|/tmp|/private/tmp|"$HOME"|"$PROJECT_DIR"|"$PROJECT_DIR"/*)
        echo "✗ refusing $ROOT: use a dedicated directory"; exit 2 ;;
esac
ENTITLEMENTS="$ROOT/StrideMacVariant.entitlements"
DERIVED="$ROOT/DerivedData"
APP_DEFAULT="$DERIVED/Build/Products/$CONFIG/Stride.app"

# The top-level keys of a plist file, one per line. Not `plutil -extract`: it splits key paths on
# the dots in "com.apple.security.application-groups" (scripts/sim_e2e/README.md, Gotchas).
plist_keys() {
    plutil -convert json -o - "$1" | /usr/bin/python3 -I -c 'import json, sys; print("\n".join(sorted(json.load(sys.stdin))))'
}
plist_true() { [[ "$("$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null || true)" == "true" ]]; }

# ---- 1. entitlements, generated from the shipping file ------------------------------------
generate_entitlements() {
    local key keys bad
    [[ -f "$SHIPPING_ENTITLEMENTS" ]] || { echo "✗ no $SHIPPING_ENTITLEMENTS"; exit 1; }
    mkdir -p "$ROOT"
    cp "$SHIPPING_ENTITLEMENTS" "$ENTITLEMENTS"
    for key in com.apple.security.application-groups com.apple.developer.associated-domains; do
        # Deleted when present; a key the shipping file no longer has is nothing to remove.
        if "$PLISTBUDDY" -c "Print :$key" "$ENTITLEMENTS" >/dev/null 2>&1; then
            "$PLISTBUDDY" -c "Delete :$key" "$ENTITLEMENTS"
        fi
    done
    keys="$(plist_keys "$ENTITLEMENTS")" || { echo "✗ could not read $ENTITLEMENTS"; exit 1; }
    bad="$(grep -E '^com\.apple\.developer\.|^com\.apple\.security\.application-groups$' <<<"$keys" || true)"
    if [[ -n "$bad" ]]; then
        echo "✗ the variant's entitlements still hold keys an ad-hoc build cannot carry, or the App Group:"
        sed 's/^/    /' <<<"$bad"
        echo "  StrideMac.entitlements gained one; extend the delete list in this script, reviewed —"
        echo "  never by giving the variant a profile or the App Group."
        exit 1
    fi
    plist_true "$ENTITLEMENTS" com.apple.security.app-sandbox \
        || { echo "✗ the shipping entitlements have no com.apple.security.app-sandbox = true: the variant must be sandboxed (its store-location precondition)"; exit 1; }
    echo "==> Variant entitlements ($ENTITLEMENTS), from StrideMac.entitlements minus the App Group and associated domains:"
    sed 's/^/    /' <<<"$keys"
    if ! plist_true "$ENTITLEMENTS" com.apple.security.files.user-selected.read-write; then
        echo "⚠ StrideMac.entitlements has no files.user-selected.read-write: Restore's open panel and"
        echo "  Export's save panel will not appear (the 1.3.x bug RELEASE-1.4.0.md fixes). The variant"
        echo "  shows the shipping file's behaviour; that is the point, so it is built anyway."
    fi
}

# binary_has <text> <file>... — whether any of the files holds the text, byte for byte.
binary_has() {
    local text="$1" f
    shift
    for f in "$@"; do
        [[ -f "$f" ]] && grep -a -q -F -- "$text" "$f" && return 0
    done
    return 1
}

# check_configuration <app> — what the built code says about its configuration and its server:
# the executable, and a Debug build's Stride.debug.dylib, where Xcode puts a Debug app's code.
# Release (--release): no debug dylib, no DEBUG-only code, the production API and not the local
# one. Debug: the local API; the production one means the build is not what was asked for. Prints
# ✓/⚠/✗ lines; returns 1 on a ✗.
check_configuration() {
    local app="$1" exe bins failed=0
    exe="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
    exe="$app/Contents/MacOS/${exe:-Stride}"
    if [[ ! -f "$exe" ]]; then echo "    ✗ no executable at $exe"; return 1; fi
    bins=("$exe")
    [[ -f "$exe.debug.dylib" ]] && bins+=("$exe.debug.dylib")
    if [[ "$CONFIG" == Release ]]; then
        if [[ -f "$exe.debug.dylib" ]]; then
            echo "    ✗ $(basename "$exe").debug.dylib present: a Debug build's layout"; failed=1
        elif binary_has "$DEBUG_ONLY_PROBE" "${bins[@]}"; then
            echo "    ✗ DEBUG-only code is compiled in (\"$DEBUG_ONLY_PROBE\" found): not a Release build"; failed=1
        else
            echo "    ✓ Release: no DEBUG-only code (no \"$DEBUG_ONLY_PROBE\", no debug dylib), so -demo, -paywall, -statsScrollTo, -scrollTo, -syncStatus and -windowSize do nothing"
        fi
        if binary_has "$LOCAL_API" "${bins[@]}"; then echo "    ✗ the binary holds $LOCAL_API, the DEBUG server"; failed=1; fi
        if binary_has "$PRODUCTION_API" "${bins[@]}"; then
            echo "    ✓ a PRODUCTION client: $PRODUCTION_API (APIClient.defaultBaseURL)"
        else
            echo "    ✗ $PRODUCTION_API not found in the binary: cannot tell which server it talks to"; failed=1
        fi
    else
        if binary_has "$LOCAL_API" "${bins[@]}"; then
            echo "    ✓ Debug: talks to $LOCAL_API, a local server"
        elif binary_has "$PRODUCTION_API" "${bins[@]}"; then
            echo "    ✗ this build talks to production ($PRODUCTION_API): not a Debug build. Preflight it with --release, whose sign-in rules apply"; failed=1
        else
            echo "    ⚠ neither $LOCAL_API nor $PRODUCTION_API found in the binary: which server it talks to is unknown"
        fi
    fi
    return $failed
}

# ---- 3. preflight: what codesign says the built app is --------------------------------------
preflight() {
    local app="$1" bid sig ents keys bad failed=0
    [[ -d "$app" ]] || { echo "✗ no app at $app"; return 1; }
    echo "==> Preflight of $app (nothing is launched)"
    bid="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$bid" == "$VARIANT_ID" ]]; then echo "    ✓ Info.plist CFBundleIdentifier $bid"
    else echo "    ✗ Info.plist CFBundleIdentifier is '${bid:-?}', not $VARIANT_ID"; failed=1; fi
    sig="$(codesign -dv "$app" 2>&1 || true)"
    if grep -qx "Identifier=$VARIANT_ID" <<<"$sig"; then echo "    ✓ codesign Identifier=$VARIANT_ID"
    else echo "    ✗ codesign says $(grep -E '^Identifier=' <<<"$sig" || echo 'no Identifier (unsigned?)'), not Identifier=$VARIANT_ID"; failed=1; fi
    if grep -q '^Signature=adhoc' <<<"$sig"; then echo "    ✓ ad-hoc signature"
    else echo "    ⚠ not an ad-hoc signature: $(grep -E '^(Signature|TeamIdentifier)' <<<"$sig" | head -1 || echo '?')"; fi
    ents="$ROOT/preflight-entitlements.plist"
    mkdir -p "$ROOT"
    if codesign -d --entitlements - --xml "$app" >"$ents" 2>/dev/null && [[ -s "$ents" ]] && keys="$(plist_keys "$ents")"; then
        bad="$(grep -E '^com\.apple\.developer\.|^com\.apple\.security\.application-groups$' <<<"$keys" || true)"
        if [[ -z "$bad" ]]; then echo "    ✓ signed entitlements: no App Group, no com.apple.developer.* key"
        else echo "    ✗ signed entitlements carry: $(tr '\n' ' ' <<<"$bad")"; failed=1; fi
        if plist_true "$ents" com.apple.security.app-sandbox; then echo "    ✓ sandboxed (com.apple.security.app-sandbox)"
        else echo "    ✗ not sandboxed: the variant's launch precondition (APP_SANDBOX_CONTAINER_ID) would stop it, and unsandboxed it could reach the real store"; failed=1; fi
        if plist_true "$ents" com.apple.security.files.user-selected.read-write; then echo "    ✓ files.user-selected.read-write (Restore/Export panels)"
        else echo "    ⚠ no files.user-selected.read-write: the Restore/Export panels will not open"; fi
    else
        echo "    ✗ codesign shows no entitlements for $app (unsigned?)"
        failed=1
    fi
    check_configuration "$app" || failed=1
    if [[ $failed -ne 0 ]]; then
        echo "✗ PREFLIGHT FAILED: do not launch $app."
        return 1
    fi
    echo "✓ Preflight passed ($CONFIG)."
    if [[ "$CONFIG" == Release ]]; then
        cat <<EOF

THIS IS A PRODUCTION CLIENT. It talks to $PRODUCTION_API, so a sign-in creates or uses a real
account (RELEASE-1.4.1.md decision 4):
  - sign in only with the owner's plus-address <owner>+stride-smoke@gmail.com, by token paste (no
    universal link: the variant carries no associated domains); never the owner's primary address,
    never the demo account;
  - before any delete-account, GET /v1/auth/session with the same token, and delete only if
    user.email is exactly that address;
  - at most one request-link per sitting (3 per 15 min per IP, shared with every device here).
-demo and -windowSize do not exist in Release: no demo data, no screenshot frame. Sentry stays off.
It shares the Debug variant's bundle id and container (store, defaults, Keychain service): sign
out before switching between the two.
EOF
    fi
    cat <<EOF

Launch it (only this way — by its path or its bundle id; NEVER \`open -a Stride\`, which can start
the shipping app on the owner's real store; and no -demo until the checks below have passed):
    open "$app"
    open -b $VARIANT_ID          # once LaunchServices has registered the bundle
    open "$app" --args -tab 2    # launch arguments go after --args
The Debug and the Release variant share the bundle id: while both are built, \`open -b\` may start
either (Release talks to production), so launch by path.

Right after the first launch, before any UI action:
    log show --last 5m --style compact --predicate 'subsystem == "$REAL_ID" AND category == "ModelContainer"' | grep 'outside the App Group'
        → "Store opened by the app, outside the App Group" (SharedModelContainer). Anything else — no
          line, an App Group path, the store error screen — quit the variant and stop.
    ls -la ~/Library/Containers/$VARIANT_ID/Data/Documents/
        → Stride.store (+ -wal, -shm) here, and only here.
    ls -la ~/Library/Group\\ Containers/group.$REAL_ID/
        → unchanged: no new file, no new modification time on Stride.store.
Quit it with ⌘Q (or: osascript -e 'tell application id "$VARIANT_ID" to quit').
EOF
}

if [[ "$MODE" == entitlements ]]; then
    generate_entitlements
    exit 0
fi
if [[ "$MODE" == preflight ]]; then
    preflight "${PREFLIGHT_APP:-$APP_DEFAULT}"
    exit $?
fi

# ---- 0. the variant's code paths must exist -------------------------------------------------
if ! grep -Eq '^[[:space:]]*#(if|elseif).*\bSTRIDE_MAC_VARIANT\b' "$PROJECT_DIR/Shared/SharedModelContainer.swift"; then
    echo "✗ Shared/SharedModelContainer.swift has no #if STRIDE_MAC_VARIANT branch."
    echo "  Without it the variant's store location is the App Group's — the owner's real store —"
    echo "  so it is not built. The code paths are part of RELEASE-1.4.0.md W7/D7."
    exit 1
fi
echo "==> STRIDE_MAC_VARIANT code paths:"
grep -rlE '#(if|elseif).*\bSTRIDE_MAC_VARIANT\b' "$PROJECT_DIR/Shared" "$PROJECT_DIR/Stride/Sources" | sed "s#^$PROJECT_DIR/#    #"

# One build per root at a time: the entitlements file and the derived data are shared.
mkdir -p "$ROOT"
ROOT_LOCK="$(build_lock_path "$ROOT")"
build_lock_take "$ROOT_LOCK" "mac_variant/build.sh" || exit 1
trap 'build_lock_release "$ROOT_LOCK"' EXIT

generate_entitlements
spm_cache_args "$PROJECT_DIR" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" || exit 1

# The overrides, passed to -showBuildSettings and to the build alike. On the command line they
# apply to every target the scheme builds (StrideMac and its Swift packages); a package ignores
# the ones it has no use for. '$(inherited)' keeps the configuration's own conditions: Debug's
# DEBUG, none in Release. The same overrides in both: Release changes only -configuration.
OVERRIDES=(
    "PRODUCT_BUNDLE_IDENTIFIER=$VARIANT_ID"
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) STRIDE_MAC_VARIANT'
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM="
    "PROVISIONING_PROFILE_SPECIFIER="
    "CODE_SIGN_ENTITLEMENTS=$ENTITLEMENTS"
)
XCB=(-project "$PROJECT_DIR/Stride.xcodeproj" -scheme StrideMac -configuration "$CONFIG"
     -destination 'platform=macOS' -derivedDataPath "$DERIVED"
     "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}")
LOG="$ROOT/build.log"

# ---- 2. what xcodebuild will actually use, checked before building ------------------------
echo "==> Resolving the build settings"
SETTINGS="$ROOT/build-settings.txt"
xcodebuild -showBuildSettings "${XCB[@]}" "${OVERRIDES[@]}" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" >"$SETTINGS" 2>"$ROOT/build-settings.err" \
    || { echo "✗ xcodebuild -showBuildSettings failed: $(tail -3 "$ROOT/build-settings.err")"; exit 1; }
# Only the StrideMac target's section (packages print their own).
setting() {
    awk -v want="$1" '
        /^Build settings for action build and target / { inapp = ($0 ~ /target StrideMac:$/) }
        inapp && $1 == want && $2 == "=" { sub(/^[^=]*= ?/, ""); print; exit }
    ' "$SETTINGS"
}
conds="$(setting SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
bad=0
[[ "$(setting PRODUCT_BUNDLE_IDENTIFIER)" == "$VARIANT_ID" ]] || { echo "✗ PRODUCT_BUNDLE_IDENTIFIER resolves to '$(setting PRODUCT_BUNDLE_IDENTIFIER)'"; bad=1; }
[[ "$(setting PRODUCT_NAME)" == "Stride" ]] || { echo "✗ PRODUCT_NAME resolves to '$(setting PRODUCT_NAME)', not Stride"; bad=1; }
[[ " $conds " == *" STRIDE_MAC_VARIANT "* ]] || { echo "✗ SWIFT_ACTIVE_COMPILATION_CONDITIONS '$conds' lacks STRIDE_MAC_VARIANT"; bad=1; }
[[ "$(setting CONFIGURATION)" == "$CONFIG" ]] || { echo "✗ CONFIGURATION resolves to '$(setting CONFIGURATION)', not $CONFIG"; bad=1; }
if [[ "$CONFIG" == Release ]]; then
    # Release must compile DEBUG out: DEBUG is what points APIClient at localhost and keeps the
    # launch flags (-demo erases the store it opens). STRIDE_MAC_VARIANT, checked above, is what
    # keeps the store in the variant's container, in both configurations.
    [[ " $conds " != *" DEBUG "* ]] || { echo "✗ SWIFT_ACTIVE_COMPILATION_CONDITIONS '$conds' defines DEBUG in Release"; bad=1; }
    [[ "$(setting SWIFT_OPTIMIZATION_LEVEL)" != "-Onone" ]] || { echo "✗ SWIFT_OPTIMIZATION_LEVEL is -Onone in Release"; bad=1; }
else
    [[ " $conds " == *" DEBUG "* ]] || { echo "✗ SWIFT_ACTIVE_COMPILATION_CONDITIONS '$conds' lacks DEBUG (\$(inherited) did not expand)"; bad=1; }
fi
[[ "$(setting CODE_SIGN_ENTITLEMENTS)" == "$ENTITLEMENTS" ]] || { echo "✗ CODE_SIGN_ENTITLEMENTS resolves to '$(setting CODE_SIGN_ENTITLEMENTS)'"; bad=1; }
[[ $bad -eq 0 ]] || { echo "  ($SETTINGS)"; exit 1; }
echo "    StrideMac $CONFIG: $VARIANT_ID, PRODUCT_NAME Stride, conditions '$conds', optimization $(setting SWIFT_OPTIMIZATION_LEVEL), ad-hoc, generated entitlements"

# ---- the build -----------------------------------------------------------------------------
echo "==> Building StrideMac $CONFIG as $VARIANT_ID into $DERIVED (log: $LOG)"
if ! xcodebuild build "${XCB[@]}" "${OVERRIDES[@]}" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 | sed 's/^/    /' || true
    echo "✗ Build failed. Full log: $LOG"
    exit 1
fi
[[ -d "$APP_DEFAULT" ]] || { echo "✗ the build succeeded but there is no $APP_DEFAULT"; exit 1; }

preflight "$APP_DEFAULT"
