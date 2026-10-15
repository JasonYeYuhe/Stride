#!/usr/bin/env bash
# Stride — ship.sh is RETIRED (1.4.1, RELEASE-1.4.1.md W7). It refuses to run, whatever the
# arguments, and exits 1 before it unlocks, builds, uploads or submits anything.
#
# Why: it was the "whole release in one command" of 1.2.x, and it no longer is one.
#   - With no arguments it shipped 1.2.1 build 15 (VERSION/BUILD defaults).
#   - Its last step was `release.py finish <version> <build>` with no --platform, which submits
#     iOS and macOS together. Since 1.4.0 each platform is submitted on its own go, iOS first and
#     the Mac only after its gate (RELEASE-1.4.1.md gate 10, "Submission checklist").
#   - It never ran `release.py prepare`, so the version records and What's New it relies on had
#     to exist already, and it checked none of the submission checklist.
# Its pieces are what the release runs instead, one at a time, each with its own go. The old
# script is in git history (scripts/ship.sh before 1.4.1), including how it unlocked the login
# keychain over SSH, which the message below keeps.

cat >&2 <<'EOF'
✗ scripts/ship.sh is retired and does nothing (RELEASE-1.4.1.md W7).

  It shipped 1.2.1 build 15 when run with no arguments, and submitted iOS and macOS together
  (release.py finish with no --platform). Since 1.4.0 each platform is submitted on its own go.
  Run the steps instead, from the repository root, in the order of the release's
  "Submission checklist":

    1. Signing preflight (the login keychain must be unlocked):
         security show-keychain-info ~/Library/Keychains/login.keychain-db
         cp /bin/echo /tmp/sigtest && codesign -f -s "Apple Distribution: Yuhe Ye (KHMK6Q3L3K)" /tmp/sigtest
       Over SSH with the screen locked: security unlock-keychain ~/Library/Keychains/login.keychain-db
       (the password at its prompt, never as an argument).
    2. Hosted tests:  scripts/ci/run_hosted_tests.sh "iPhone 17"
    3. Archive, verify, export and upload both platforms (nothing is uploaded until both pass
       scripts/verify_archive.sh):
         scripts/build-appstore.sh all --upload
    4. Version records and What's New (WHATS_NEW_BY_VERSION in scripts/release.py first), then
       the checklist's metadata, screenshots and review notes:
         python3 scripts/release.py prepare <version>
    5. Submit, one platform at a time:
         python3 scripts/release.py finish <version> <build> --platform IOS
         python3 scripts/release.py finish <version> <build> --platform MAC_OS   # after the Mac gate
         python3 scripts/release.py show <version>
EOF
exit 1
