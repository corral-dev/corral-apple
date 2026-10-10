#!/usr/bin/env bash
# Public installer for the native Mac client, built from public source.
#
# Clones corral-dev/corral-apple, builds an unsigned self-build with
# scripts/build-public-client.sh, and installs it into a configurable
# application directory (default ~/Applications). The installed official
# /Applications/Corral.app is never altered: CORRAL_APP_DIR resolving to
# /Applications is refused.
#
#   [CORRAL_APPLE_REPO=...] [CORRAL_APPLE_REF=main] \
#   [CORRAL_APPLE_BUILD_ROOT=...] [CORRAL_APP_DIR=~/Applications] \
#   bash apple/install.sh
#
# macOS 26+ with Xcode (macOS 26 SDK) is required; XcodeGen is installed via
# Homebrew when missing (see scripts/build-public-client.sh). No maintainer
# signing credentials, private update feeds or production relays are used.
# The app is not launched automatically.
set -euo pipefail

PUBLIC_REPO_DEFAULT="https://github.com/corral-dev/corral-apple.git"
REPO="${CORRAL_APPLE_REPO:-$PUBLIC_REPO_DEFAULT}"
REF="${CORRAL_APPLE_REF:-main}"
BUILD_ROOT="${CORRAL_APPLE_BUILD_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/corral/build}"
APP_DIR="${CORRAL_APP_DIR:-$HOME/Applications}"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[[ "$(uname)" == "Darwin" ]] || die "this installer targets macOS only"

# Resolve without requiring existence.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"; }
APP_DIR_RESOLVED="$(resolve "$APP_DIR")"
[[ -n "$APP_DIR_RESOLVED" && "$APP_DIR_RESOLVED" != "/" ]] || die "refusing empty or root CORRAL_APP_DIR"
[[ "$APP_DIR_RESOLVED" != "/Applications" ]] || die "refusing to install into /Applications (would touch the official Corral.app); set CORRAL_APP_DIR elsewhere"
mkdir -p "$APP_DIR_RESOLVED" || die "cannot create ${APP_DIR_RESOLVED}"
mkdir -p "$BUILD_ROOT" || die "cannot create ${BUILD_ROOT}"

CHECKOUT="${BUILD_ROOT}/corral-apple"
if [[ -d "${CHECKOUT}/.git" ]]; then
  origin="$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" == "$REPO" ]] || die "existing checkout remote (${origin}) does not match ${REPO}; remove ${CHECKOUT} or point CORRAL_APPLE_REPO at it"
  note "updating existing checkout at ${CHECKOUT}"
  git -C "$CHECKOUT" fetch --depth 1 origin "$REF" || die "fetch failed"
  EXACT="$(git -C "$CHECKOUT" rev-parse FETCH_HEAD)" || die "cannot resolve fetched ${REF}"
  DIRTY="$(git -C "$CHECKOUT" status --porcelain)" || die "cannot inspect checkout"
  if [[ -n "$DIRTY" ]]; then
    echo "dirty files (first 10):" >&2
    head -n 10 <<< "$DIRTY" >&2
    die "refusing to update dirty checkout at ${CHECKOUT}; commit or stash its tracked edits and move untracked files first (a regenerated Corral.xcodeproj alone can be reset with: git -C ${CHECKOUT} checkout -- Corral.xcodeproj)"
  fi
  git -C "$CHECKOUT" checkout --detach "$EXACT" || die "checkout ${EXACT} failed"
  note "checked out exact fetched commit ${EXACT}"
else
  [[ -e "$CHECKOUT" ]] && die "refusing to clobber non-git ${CHECKOUT}"
  note "cloning ${REPO} (${REF}) into ${CHECKOUT}"
  git clone --depth 1 --branch "$REF" "$REPO" "$CHECKOUT" || die "clone failed"
fi

HELPER="${CHECKOUT}/scripts/build-public-client.sh"
[[ -f "$HELPER" ]] || die "build helper missing in checkout: ${HELPER}"
export CORRAL_DERIVED_DATA="${BUILD_ROOT}/derived-data-mac"
HELPER_LOG="${BUILD_ROOT}/helper-output.log"
note "building self-build Mac app"
bash "$HELPER" mac >"$HELPER_LOG" 2>&1 || die "build helper failed; see ${HELPER_LOG}"
cat "$HELPER_LOG"
BUILT_APP="$(tail -n 1 "$HELPER_LOG")"
[[ -d "$BUILT_APP" ]] || die "build helper did not produce an app directory (see ${HELPER_LOG})"

DEST="${APP_DIR_RESOLVED}/Corral.app"
[[ "$DEST" != "/Applications/Corral.app" ]] || die "refusing to overwrite /Applications/Corral.app"
if [[ -e "$DEST" ]]; then
  note "removing previous self-build at ${DEST}"
  rm -rf "$DEST" || die "cannot remove ${DEST}"
fi
note "installing to ${DEST}"
ditto "$BUILT_APP" "$DEST" || die "copy failed"

PLIST="${DEST}/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "installed bundle has no Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" >/dev/null 2>&1; then
  die "installed app still carries a maintainer update feed"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo unknown)"
SIGN_INFO="$(codesign -dv "$DEST" 2>&1 || true)"
if grep -q "code object is not signed" <<< "$SIGN_INFO"; then
  SIGN_STATE="unsigned self-build"
elif grep -q "Signature=adhoc" <<< "$SIGN_INFO"; then
  SIGN_STATE="ad-hoc signed, no identity (self-build)"
else
  SIGN_STATE="signed ($(grep -m1 'Authority' <<< "$SIGN_INFO" || echo "see codesign -dv"))"
fi
codesign --verify "$DEST" 2>/dev/null || die "installed app fails codesign verification"
note "installed ${DEST} (v${VERSION} build ${BUILD}, ${SIGN_STATE})"
note "no production relay or update feed is configured in this build"
echo "Launch (not automatic):"
echo "  open \"${DEST}\""
