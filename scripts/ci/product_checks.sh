#!/bin/bash
# Shared assertions about a BUILT Stride.app — sourced, not run.
#
#   source "$(dirname "$0")/product_checks.sh"      (from scripts/ci/)
#
# Used by scripts/ci/check_ios_product.sh and check_macos_product.sh (CI, the pre-push hook)
# and by scripts/verify_archive.sh (the archive that is actually uploaded). They exist because
# the release-blocking bugs of 1.2.x were all invisible in project.yml and in the source, and
# visible only inside the built product:
#   - through 1.2.1 the widget extension built fine and was never copied into Stride.app
#     (no PlugIns/ directory) while the store listing sold it (RELEASE-1.2.2.md §3);
#   - 1.2.0: INFOPLIST_KEY_SentryDSN was dropped from the generated Info.plist without a
#     warning, so Sentry was linked and never started (Shared/SentryBootstrap.swift);
#   - 1.2.2: the first upload with the widget embedded was refused with error 90360 because
#     the appex had no CFBundleDisplayName — and the app itself had none through 1.2.3.
#
# Style: every check prints one ✓/✗ line and failures are COUNTED, not fatal, so a single
# run reports everything that is wrong instead of the first thing. Callers exit non-zero
# when CHECK_FAILED > 0. Written for /bin/bash 3.2 (macOS): no associative arrays, no mapfile.

CHECK_FAILED=0

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; CHECK_FAILED=$((CHECK_FAILED + 1)); }

# plist_get <plist> <:Key[:Sub]>  — prints the value, empty if absent. Binary plists are fine.
plist_get() {
    /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || true
}

# expect_eq <label> <actual> <expected>
expect_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1 = $2"; else fail "$1 is '${2:-<absent>}', expected '$3'"; fi
}

# check_privacy_manifest <label> <path to PrivacyInfo.xcprivacy>
check_privacy_manifest() {
    if [[ ! -f "$2" ]]; then
        fail "$1: PrivacyInfo.xcprivacy missing ($2)"
    elif ! plutil -lint -s "$2" >/dev/null 2>&1; then
        fail "$1: PrivacyInfo.xcprivacy is not a valid plist ($2)"
    else
        pass "$1: PrivacyInfo.xcprivacy present"
    fi
}

# check_bundle_versions <label> <Info.plist>
# Unexpanded "$(MARKETING_VERSION)" is the failure mode of a hand-written Info.plist (the
# widget has one), so require the shapes App Store Connect accepts, not just non-empty.
check_bundle_versions() {
    local short build
    short="$(plist_get "$2" :CFBundleShortVersionString)"
    build="$(plist_get "$2" :CFBundleVersion)"
    if [[ "$short" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        pass "$1: version $short ($build)"
    else
        fail "$1: version '${short:-<absent>}' build '${build:-<absent>}' — not numeric"
    fi
}

# check_display_name <label> <Info.plist>
check_display_name() {
    local name; name="$(plist_get "$2" :CFBundleDisplayName)"
    if [[ -n "$name" ]]; then pass "$1: CFBundleDisplayName = $name"
    else fail "$1: CFBundleDisplayName missing from the built Info.plist"; fi
}

# check_sentry <Frameworks dir> <main executable>
# Three halves of "crash reporting works", each of which has been — or silently could be —
# missing while the build stayed green:
#   1. Sentry.framework is in the bundle (dyld aborts at launch otherwise, and its privacy
#      manifest lives there);
#   2. the SDK is in the code that runs. Release links it as a MERGEABLE library: the SDK is
#      merged into the app executable and the embedded Sentry binary is a ~50 KB stub, so
#      `otool -L` shows no Sentry at all in a correct archive (checked on 1.2.3). Debug builds
#      put the app's code in <exe>.debug.dylib, which links the framework normally. Accept
#      either: dynamically linked, or the SDK's ObjC class names present in the binary;
#   3. the DSN is compiled in. 1.2.0 had 1 and 2 and still reported nothing, because the DSN
#      came from an Info.plist key Xcode had dropped. Matched by shape, never printed.
check_sentry() {
    local fw="$1/Sentry.framework" exe="$2"
    if [[ -f "$fw/Sentry" || -f "$fw/Versions/A/Sentry" ]]; then
        pass "Sentry.framework embedded"
    else
        fail "Sentry.framework not embedded under $1"
    fi
    if [[ ! -f "$exe" ]]; then
        fail "main executable missing ($exe)"
        return
    fi
    local bins=("$exe") b linked="" dsn=""
    [[ -f "$exe.debug.dylib" ]] && bins+=("$exe.debug.dylib")
    for b in "${bins[@]}"; do
        if otool -L "$b" 2>/dev/null | grep -q "Sentry.framework/" \
            || grep -a -q "SentrySDKInternal" "$b"; then
            linked="$b"
        fi
        if grep -a -q -E "https://[0-9a-f]{32}@o[0-9]+\.ingest\.([a-z]+\.)?sentry\.io/[0-9]+" "$b"; then
            dsn="$b"
        fi
    done
    if [[ -n "$linked" ]]; then pass "Sentry SDK present in $(basename "$linked")"
    else fail "Sentry SDK neither linked nor merged into $(basename "$exe")"; fi
    if [[ -n "$dsn" ]]; then pass "Sentry DSN compiled into $(basename "$dsn")"
    else fail "no Sentry DSN in $(basename "$exe") — SentrySDK.start would bail (the 1.2.0 failure)"; fi
}

# check_app_common <label> <Info.plist> <PrivacyInfo.xcprivacy> <Frameworks dir> <app dir> <executable dir>
check_app_common() {
    local label="$1" info="$2" privacy="$3" frameworks="$4" exe_dir="$6"
    if [[ ! -f "$info" ]]; then
        fail "$label: no Info.plist at $info — is $5 a built app?"
        return
    fi
    expect_eq "$label: CFBundleIdentifier" "$(plist_get "$info" :CFBundleIdentifier)" "yyh.stride.habittracker"
    check_bundle_versions "$label" "$info"
    check_display_name "$label" "$info"
    check_privacy_manifest "$label" "$privacy"
    local exe; exe="$(plist_get "$info" :CFBundleExecutable)"
    check_sentry "$frameworks" "$exe_dir/${exe:-Stride}"
}

# check_ios_app <path to Stride.app>  (flat iOS bundle layout)
check_ios_app() {
    local app="${1%/}"
    local info="$app/Info.plist"
    check_app_common "Stride.app" "$info" "$app/PrivacyInfo.xcprivacy" "$app/Frameworks" "$app" "$app"

    # The widget. With `embed: false` on the dependency in project.yml (or without the
    # dependency) there is no "Embed Foundation Extensions" phase and this directory simply does
    # not exist. XcodeGen 2.45.3 embeds an app's extension dependencies by default, so deleting
    # `embed: true` changes nothing — setting it to false is what reproduces the 1.2.1 bug.
    local appex="$app/PlugIns/StrideWidgetExtension.appex"
    if [[ ! -d "$appex" ]]; then
        fail "PlugIns/StrideWidgetExtension.appex missing — the widget is not embedded"
        return
    fi
    pass "PlugIns/StrideWidgetExtension.appex embedded"
    local ainfo="$appex/Info.plist"
    expect_eq "appex: CFBundleIdentifier" "$(plist_get "$ainfo" :CFBundleIdentifier)" "yyh.stride.habittracker.widget"
    expect_eq "appex: NSExtensionPointIdentifier" \
        "$(plist_get "$ainfo" :NSExtension:NSExtensionPointIdentifier)" "com.apple.widgetkit-extension"
    check_display_name "appex" "$ainfo"
    check_privacy_manifest "appex" "$appex/PrivacyInfo.xcprivacy"
    # App Store Connect rejects an extension whose versions differ from its app's (ITMS-90473).
    local key
    for key in CFBundleShortVersionString CFBundleVersion; do
        expect_eq "appex: $key matches app" "$(plist_get "$ainfo" ":$key")" "$(plist_get "$info" ":$key")"
    done
}

# check_macos_app <path to Stride.app>  (Contents/ bundle layout)
check_macos_app() {
    local app="${1%/}"
    check_app_common "Stride.app (macOS)" "$app/Contents/Info.plist" \
        "$app/Contents/Resources/PrivacyInfo.xcprivacy" "$app/Contents/Frameworks" \
        "$app" "$app/Contents/MacOS"
}
