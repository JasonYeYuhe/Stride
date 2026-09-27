#!/bin/bash
# Which halves of the repo does a range of commits touch?
#
#   scripts/ci/changed_areas.sh <base> [<head>]      (head defaults to HEAD)
#
# Prints `apple=true|false` and `server=true|false`, one per line — the format of
# $GITHUB_OUTPUT, so CI appends it there directly. Used by the `changes` job in
# .github/workflows/ci.yml to decide which jobs run, and by scripts/git-hooks/pre-push to
# decide whether a push needs the iOS build. One list of paths for both, so the hook and CI
# cannot disagree about what counts as an Apple change.
#
# The diff is base...head (from their merge base), which is right for a pull request and
# for a push. When the range cannot be computed — a new branch (base is all zeros), a base
# the clone does not have after a force-push, unrelated histories — it answers "everything
# changed". Running a job for nothing costs minutes; skipping one that mattered costs a
# release.
set -uo pipefail

base="${1:-}"
head="${2:-HEAD}"

everything() { echo "apple=true"; echo "server=true"; exit 0; }

[[ -z "$base" || "$base" =~ ^0+$ ]] && everything
git cat-file -e "${base}^{commit}" 2>/dev/null || everything
files="$(git diff --name-only "${base}...${head}" 2>/dev/null)" || everything

apple=false
server=false
while IFS= read -r f; do
    case "$f" in
        # The checks themselves and the workflow that runs them: exercise both halves.
        .github/workflows/*|scripts/ci/*)
            apple=true; server=true ;;
        # Every app, extension and test target lives in a Stride*/ directory (Stride/,
        # StrideMac/, StrideWidget/, StrideTests/, Stride.xcodeproj/ ...); Shared/ is compiled
        # into all of them.
        project.yml|Stride*/*|Shared/*)
            apple=true ;;
        server/*)
            server=true ;;
    esac
done <<< "$files"

echo "apple=$apple"
echo "server=$server"
