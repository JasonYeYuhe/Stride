#!/bin/bash
# Point git at the versioned hooks in scripts/git-hooks/ (currently: pre-push, which builds
# the iOS app and checks the product before Apple-side commits are pushed).
#
#   scripts/install-git-hooks.sh
#
# core.hooksPath rather than copying into .git/hooks: the hooks then update with the repo,
# and there is nothing to re-install after editing them. Per clone; run once.
# Undo with:  git config --unset core.hooksPath
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
current="$(git -C "$ROOT" config --get core.hooksPath || true)"
if [[ -n "$current" && "$current" != "scripts/git-hooks" ]]; then
    echo "core.hooksPath is already '$current'; not overwriting it."
    echo "Remove it first (git config --unset core.hooksPath) if scripts/git-hooks should replace it."
    exit 1
fi
if [[ -n "$(ls -A "$ROOT/.git/hooks" 2>/dev/null | grep -v '\.sample$' || true)" ]]; then
    echo "Note: .git/hooks has non-sample hooks; they stop running once core.hooksPath is set:"
    ls -A "$ROOT/.git/hooks" | grep -v '\.sample$' | sed 's/^/    /'
fi
chmod +x "$ROOT"/scripts/git-hooks/*
git -C "$ROOT" config core.hooksPath scripts/git-hooks
echo "✓ core.hooksPath = scripts/git-hooks (pre-push). Skip once with SKIP_STRIDE_HOOKS=1 git push."
