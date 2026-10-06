#!/bin/bash
# build.sh current            Debug simulator build of the working tree (this checkout, as it is)
# build.sh <git-ref>          Debug simulator build of a tag/branch/commit (e.g. v1.2.3, v1.3.0),
#                             from a detached worktree under $ROOT/worktrees (removed afterwards;
#                             --keep-worktree keeps it)
# build.sh clean-worktrees    git worktree remove every kit worktree under $ROOT/worktrees, prune
#
# Signed AD-HOC (CODE_SIGN_IDENTITY=-), never CODE_SIGNING_ALLOWED=NO: an unsigned build has no
# entitlements, so the simulator Keychain refuses the session token (-34018) — the app says
# "Signed in" and never syncs — and without the app group the store silently falls back to the
# data container. After the build it checks both, and refuses to print a path otherwise:
#   - the binary has an __entitlements section (the simulator reads entitlements from it);
#   - <dd>/Build/Intermediates.noindex/Stride.build/Debug-iphonesimulator/Stride.build/
#     Stride.app-Simulated.xcent holds application-identifier (and the app group).
#
# Output dirs: $ROOT/builds/<label>/dd (DerivedData; label = current or the ref, / → _), log at
# $ROOT/builds/<label>/build.log. A rebuild of the same label is incremental.
# stdout: the .app path (last line). stderr: version, build, bundle id, app group, checks.
source "$(dirname "$0")/lib.sh"

ARG="${1:-}"
KEEP_WT=0
[[ "${2:-}" == "--keep-worktree" ]] && KEEP_WT=1
[[ -n "$ARG" ]] || die "usage: build.sh current | <git-ref> [--keep-worktree] | clean-worktrees"

WT_ROOT="$ROOT/worktrees"

remove_worktree() {
  local wt="$1"
  under_root "$wt" || die "refusing worktree $wt: not under $ROOT"
  if ! git -C "$PROJECT_DIR" worktree remove "$wt" 2>/dev/null; then
    # A kit worktree is a detached checkout of a ref: anything modified in it is a build by-product.
    note "worktree $wt has changes (build by-products?):"
    git -C "$wt" status --short >&2 || true
    git -C "$PROJECT_DIR" worktree remove --force "$wt"
  fi
}

if [[ "$ARG" == "clean-worktrees" ]]; then
  N=0
  while IFS= read -r line; do
    case "$line" in
      "worktree $WT_ROOT/"*)
        wt="${line#worktree }"
        remove_worktree "$wt"
        note "removed worktree $wt"
        N=$((N + 1)) ;;
    esac
  done < <(git -C "$PROJECT_DIR" worktree list --porcelain)
  git -C "$PROJECT_DIR" worktree prune
  [[ -d "$WT_ROOT" ]] && rmdir "$WT_ROOT" 2>/dev/null || true
  echo "removed $N kit worktree(s)"
  exit 0
fi

if [[ "$ARG" == "current" ]]; then
  LABEL="current"
  SRC="$PROJECT_DIR"
else
  git -C "$PROJECT_DIR" rev-parse --verify --quiet "$ARG^{commit}" >/dev/null || die "unknown git ref '$ARG'"
  LABEL="$(echo "$ARG" | tr '/' '_' | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$LABEL" && "$LABEL" != "current" && "$LABEL" != "clean-worktrees" ]] || die "bad ref label '$LABEL'"
  SRC="$WT_ROOT/$LABEL"
  if [[ -d "$SRC" ]]; then
    [[ "$(git -C "$SRC" rev-parse HEAD)" == "$(git -C "$PROJECT_DIR" rev-parse "$ARG^{commit}")" ]] \
      || { remove_worktree "$SRC"; }
  fi
  if [[ ! -d "$SRC" ]]; then
    mkdir -p "$WT_ROOT"
    git -C "$PROJECT_DIR" worktree add --detach "$SRC" "$ARG" >&2
  fi
fi
[[ -f "$SRC/Stride.xcodeproj/project.pbxproj" ]] || die "no Stride.xcodeproj in $SRC"

OUT="$ROOT/builds/$LABEL"
DD="$OUT/dd"
mkdir -p "$OUT"
note "building $ARG ($SRC) → $DD (log: $OUT/build.log)"
set +e
xcodebuild build \
  -project "$SRC/Stride.xcodeproj" -scheme Stride \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath "$DD" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= \
  >"$OUT/build.log" 2>&1
STATUS=$?
set -e
if [[ $STATUS -ne 0 ]]; then
  grep -E "error:|\*\* BUILD FAILED" "$OUT/build.log" | head -30 >&2 || true
  die "xcodebuild failed ($STATUS); full log: $OUT/build.log"
fi

APP="$DD/Build/Products/Debug-iphonesimulator/Stride.app"
[[ -d "$APP" ]] || die "no app at $APP"
XCENT="$DD/Build/Intermediates.noindex/Stride.build/Debug-iphonesimulator/Stride.build/Stride.app-Simulated.xcent"

# The checks the old kit learned the hard way.
otool -arch arm64 -l "$APP/Stride" | grep -q "sectname __entitlements" \
  || die "$APP/Stride has no __entitlements section: the app would have no Keychain or app group"
[[ -f "$XCENT" ]] || die "no $XCENT"
grep -q "application-identifier" "$XCENT" || die "$XCENT has no application-identifier"
# PlistBuddy, not plutil -extract: plutil's key paths split on the dots in the key's own name.
GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$XCENT" 2>/dev/null || echo '?')"
[[ "$GROUP" == "$APP_GROUP" ]] || note "WARNING: the build's app group is '$GROUP', the kit expects '$APP_GROUP' (set STRIDE_APP_GROUP)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
[[ "$BID" == "$BUNDLE_ID" ]] || note "WARNING: bundle id is '$BID', the kit expects '$BUNDLE_ID'"
COMMIT="$(git -C "$SRC" rev-parse --short HEAD)"
DIRTY=""
[[ -n "$(git -C "$SRC" status --porcelain -- Stride Shared StrideWidget Stride.xcodeproj project.yml 2>/dev/null)" ]] \
  && DIRTY=" (+ uncommitted changes in the app's sources)"

if [[ "$ARG" != "current" && $KEEP_WT -eq 0 ]]; then
  remove_worktree "$SRC"
  git -C "$PROJECT_DIR" worktree prune
fi

note "version $VERSION ($BUILD), bundle $BID, app group $GROUP, from $ARG @ $COMMIT$DIRTY"
note "entitlements: __entitlements section present; application-identifier in Stride.app-Simulated.xcent"
echo "$APP"
