#!/bin/bash
# Keep an archive's dSYMs forever, and upload them to Sentry.
#
#   scripts/upload_dsyms.sh <path.xcarchive> [<path.xcarchive> ...]
#
# Why this exists. Sentry recorded exactly one real crash from 1.2.1: macOS build 15,
# EXC_BREAKPOINT ten seconds after launch. Its in-app frames are "<redacted>" and its
# debug status is "missing", because no dSYM was ever sent to Sentry — and none ever
# can be now: build-appstore.sh archives into build/appstore/ and `rm -rf`s that
# directory at the start of every run, so building 1.2.2 destroyed 1.2.1's only copy.
# A crash report without symbols tells you that something broke, not what.
#
# So, per archive, in this order:
#   1. copy dSYMs/ to build/dsyms/<version>-<build>/<platform>/ — outside build/appstore,
#      so the next build cannot delete it. This step is what makes a failure recoverable.
#   2. upload that copy to Sentry with --wait, so a processing failure is an error
#      rather than a silent success.
#
# Exit status is non-zero if any archive failed either step. build-appstore.sh treats
# that as a loud warning, not a release blocker: a Sentry outage must not stop a ship,
# and the local copy means the upload can be redone later.
#
# Auth comes from ~/.sentryclirc (sentry-cli reads it itself; nothing here touches it).
# Source code is deliberately NOT uploaded (no --include-sources): dSYMs alone give
# function names and file:line.

set -uo pipefail   # no -e: one bad archive must not skip the rest; failures are tracked

SENTRY_ORG="jason-yeyuhe"
SENTRY_PROJECT="stride-apple"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEEP_ROOT="$PROJECT_DIR/build/dsyms"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <path.xcarchive> [<path.xcarchive> ...]"
    exit 2
fi

status=0
for ARCHIVE in "$@"; do
    if [[ ! -d "$ARCHIVE/dSYMs" ]]; then
        echo "  ✗ dSYMs: none found in $ARCHIVE"
        status=1; continue
    fi

    plist="$ARCHIVE/Info.plist"
    version="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$plist" 2>/dev/null)"
    build="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$plist" 2>/dev/null)"
    if [[ -z "$version" || -z "$build" ]]; then
        echo "  ✗ dSYMs: cannot read version/build from $plist"
        status=1; continue
    fi
    # A macOS .app has Contents/MacOS; an iOS .app is flat.
    if [[ -d "$ARCHIVE/Products/Applications/Stride.app/Contents/MacOS" ]]; then
        platform="macos"
    else
        platform="ios"
    fi

    keep="$KEEP_ROOT/${version}-${build}/${platform}"
    mkdir -p "$keep"
    if ! rsync -a --delete "$ARCHIVE/dSYMs/" "$keep/"; then
        echo "  ✗ dSYMs: could not copy to $keep"
        status=1; continue
    fi
    echo "  ✓ dSYMs kept: $keep"

    if ! command -v sentry-cli >/dev/null 2>&1; then
        echo "  ✗ dSYMs: sentry-cli not installed — NOT uploaded ($platform $version/$build)."
        echo "    brew install getsentry/tools/sentry-cli, then re-run: $0 $ARCHIVE"
        status=1; continue
    fi

    if sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" --wait "$keep"; then
        echo "  ✓ dSYMs uploaded to Sentry ($SENTRY_ORG/$SENTRY_PROJECT): $platform $version ($build)"
    else
        echo "  ✗ dSYMs: Sentry upload FAILED for $platform $version ($build). The local copy is safe."
        echo "    Retry: sentry-cli debug-files upload --org $SENTRY_ORG --project $SENTRY_PROJECT --wait \"$keep\""
        status=1
    fi
done

exit $status
