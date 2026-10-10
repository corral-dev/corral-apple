#!/usr/bin/env bash
# Public self-build helper for the Corral Apple clients.
#
# Builds the native Mac app or the iPhone app from public source without
# maintainer signing credentials, private update feeds or production relays:
#   bash scripts/build-public-client.sh mac [--configuration Release]
#   CORRAL_TEAM_ID=... CORRAL_APP_BUNDLE_ID=... [DEVICE_ID=...|DEVICE_NAME=...] \
#     bash scripts/build-public-client.sh ios
#
# macOS 26+ with Xcode (macOS 26 SDK) is required. XcodeGen is installed via
# Homebrew when missing. This script never commits, publishes, launches the
# app, boots a simulator, or contacts any relay or update feed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PRODUCT_MAC="CorralMac"
SCHEME_MAC="CorralMac"
SCHEME_IOS="Corral"
MAINTAINER_BUNDLE_PREFIX="com.x0c.corral"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

require_macos26() {
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$major" =~ ^[0-9]+$ ]] || die "cannot parse macOS version"
  (( major >= 26 )) || die "macOS 26 or later is required (found ${major})"
}

require_sdk26() {
  local sdk
  sdk="$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || true)"
  [[ -n "$sdk" ]] || die "Xcode macOS SDK not found; install Xcode from Apple first"
  local major="${sdk%%.*}"
  (( major >= 26 )) || die "macOS 26 SDK or later is required (found ${sdk})"
}

require_xcodegen() {
  command -v xcodegen >/dev/null 2>&1 && return 0
  command -v brew >/dev/null 2>&1 || die "xcodegen is missing and Homebrew is unavailable; install XcodeGen (https://github.com/yonaskolb/XcodeGen) and retry"
  note "installing XcodeGen via Homebrew"
  brew install xcodegen || die "brew install xcodegen failed"
}

generate_project() {
  [[ -f project.yml ]] || die "project.yml not found in ${ROOT}"
  note "xcodegen generate"
  xcodegen generate || die "xcodegen generate failed"
}

build_log_for() {
  local dir="$1"
  mkdir -p "$dir"
  echo "${dir}/build.log"
}

# Self-build condition override: the generated Mac target enables
# CORRAL_DIRECT_DOWNLOAD (maintainer direct-download updater). An empty
# command-line value replaces the target setting, so the updater code and
# its private feed stay out of the self-build. Release defines no DEBUG
# condition to preserve.
SELF_BUILD_SWIFT_CONDITIONS="SWIFT_ACTIVE_COMPILATION_CONDITIONS="

FEED_KEYS=(SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SURequireSignedFeed SUVerifyUpdateBeforeExtraction)

present_feed_keys() {
  # String accumulation (not an array): expanding an empty array under
  # `set -u` fails on the system bash 3.2.
  local app="$1"
  local key out=""
  for key in "${FEED_KEYS[@]}"; do
    if /usr/libexec/PlistBuddy -c "Print :${key}" "${app}/Contents/Info.plist" >/dev/null 2>&1; then
      out="${out}${key}"$'\n'
    fi
  done
  printf '%s' "$out"
}

# The sanitized public snapshot carries no maintainer update feed, so a
# self-build must not contain feed keys. Deleting keys after signing would
# silently break the bundle seal, so feed keys fail closed here — unless the
# user configured their own signing identity, in which case the keys are
# removed before the consistent re-sign step below.
ensure_no_maintainer_feed() {
  local app="$1"
  local present
  present="$(present_feed_keys "$app")"
  [[ -z "$present" ]] && { note "no maintainer update-feed keys present in built app"; return 0; }
  local keys
  keys="$(tr '\n' ' ' <<< "$present")"
  if [[ -z "${CORRAL_CODESIGN_IDENTITY:-}" ]]; then
    die "built app still carries maintainer update-feed keys (${keys}); use the sanitized public snapshot instead of deleting signed bytes"
  fi
  local key
  for key in "${FEED_KEYS[@]}"; do
    /usr/libexec/PlistBuddy -c "Delete :${key}" "${app}/Contents/Info.plist" >/dev/null 2>&1 || true
  done
  note "removed update-feed keys (${keys}); re-sign below uses the configured user identity only"
}

# Seal whatever CODE_SIGNING_ALLOWED=NO produced. An ad-hoc seal carries no
# identity and uses no credentials; it only makes the bundle verifiable and
# launchable as a local self-build.
seal_self_build() {
  local app="$1"
  if [[ -n "${CORRAL_CODESIGN_IDENTITY:-}" ]]; then
    note "sealing with the configured user identity (never a maintainer credential)"
    codesign --force --deep --sign "${CORRAL_CODESIGN_IDENTITY}" "$app" || die "sign with user identity failed"
  else
    note "ad-hoc seal (no signing identity configured; no credentials used)"
    codesign --force --sign - --deep "$app" || die "ad-hoc seal failed"
  fi
}

verify_signature() {
  local app="$1"
  codesign --verify "$app" 2>/dev/null || die "built app fails codesign verification: ${app}"
  note "codesign verification passed for ${app}"
}

# Complete compiler output goes to the log file; the console gets a short
# diagnostic summary (warning/error counts) plus the log path.
summarize_build_log() {
  local log="$1"
  local warnings errors
  warnings="$(grep -c "warning:" "$log" 2>/dev/null || true)"
  errors="$(grep -c "error:" "$log" 2>/dev/null || true)"
  note "compiler diagnostics: ${warnings:-0} warnings, ${errors:-0} errors; complete log: ${log}"
}

cmd_mac() {
  local configuration="Release"
  while (( $# )); do
    case "$1" in
      --configuration) configuration="${2:-}"; shift 2 ;;
      --configuration=*) configuration="${1#*=}"; shift ;;
      --help|-h) sed -n '1,12p' "$0"; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_macos26
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode from Apple first"
  require_sdk26
  require_xcodegen
  generate_project

  local derived="${CORRAL_DERIVED_DATA:-${ROOT}/.derivedData-public}"
  local log
  log="$(build_log_for "$derived")"
  local sign_args=()
  if [[ -n "${CORRAL_CODESIGN_IDENTITY:-}" ]]; then
    sign_args+=(CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=${CORRAL_CODESIGN_IDENTITY}" CODE_SIGN_STYLE=Manual)
    [[ -n "${CORRAL_TEAM_ID:-}" ]] && sign_args+=("DEVELOPMENT_TEAM=${CORRAL_TEAM_ID}")
    note "signing with user-configured identity (never a maintainer credential)"
  else
    sign_args+=(CODE_SIGNING_ALLOWED=NO)
    note "no signing identity configured (ad-hoc seal after build; no credentials used)"
  fi
  note "building ${PRODUCT_MAC} (${configuration})"
  # shellcheck disable=SC2086
  set +e
  xcodebuild -project Corral.xcodeproj -scheme "$SCHEME_MAC" -configuration "$configuration" \
    -destination 'platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
    $SELF_BUILD_SWIFT_CONDITIONS "${sign_args[@]}" build >"$log" 2>&1
  local status="$?"
  set -e
  if (( status != 0 )); then
    tail -n 40 "$log"
    die "xcodebuild failed (exit ${status}); complete log: ${log}"
  fi
  summarize_build_log "$log"
  local app="${derived}/Build/Products/${configuration}/Corral.app"
  [[ -d "$app" ]] || die "expected app not found at ${app}"
  ensure_no_maintainer_feed "$app"
  seal_self_build "$app"
  verify_signature "$app"
  local version build
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist" 2>/dev/null || echo unknown)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist" 2>/dev/null || echo unknown)"
  note "built ${app} (v${version} build ${build})"
  echo "$app"
}

setting_of() {
  local target="$1" key="$2" configuration="$3"
  xcodebuild -project Corral.xcodeproj -target "$target" -configuration "$configuration" \
    -showBuildSettings 2>/dev/null | awk -F' = ' -v key="$key" '$1 ~ ("^[[:space:]]*" key "$") {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}'
}

cmd_ios() {
  (( $# == 0 )) || die "ios takes no positional arguments (configure via environment)"
  require_macos26
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode from Apple first"
  require_xcodegen
  local device_ref="${DEVICE_ID:-${DEVICE_NAME:-}}"
  [[ -n "$device_ref" ]] || die "set DEVICE_ID or DEVICE_NAME to an explicit real device (simulators are not supported here)"
  [[ -n "${CORRAL_TEAM_ID:-}" ]] || die "set CORRAL_TEAM_ID to your own Apple development team ID"
  [[ -n "${CORRAL_APP_BUNDLE_ID:-}" ]] || die "set CORRAL_APP_BUNDLE_ID to your own application bundle identifier"
  local nse_id="${CORRAL_NSE_BUNDLE_ID:-${CORRAL_APP_BUNDLE_ID}.nse}"
  generate_project

  local configuration="${CORRAL_IOS_CONFIGURATION:-Release}"
  local app_id
  app_id="$(setting_of Corral PRODUCT_BUNDLE_IDENTIFIER "$configuration")"
  local ext_id
  ext_id="$(setting_of CorralNSE PRODUCT_BUNDLE_IDENTIFIER "$configuration")"
  [[ "$app_id" == "$CORRAL_APP_BUNDLE_ID" ]] || die "snapshot app bundle ID is ${app_id}, not ${CORRAL_APP_BUNDLE_ID}; use your own identifiers (see docs/PUBLIC_BUILD_GUIDE.md)"
  [[ "$ext_id" == "$nse_id" ]] || die "snapshot extension bundle ID is ${ext_id}, not ${nse_id}; use your own identifiers"
  [[ "$app_id" == ${MAINTAINER_BUNDLE_PREFIX}* ]] && die "maintainer bundle identifier ${app_id} must not be signed by anyone else"
  note "verified bundle identifiers: app=${app_id} extension=${ext_id}"

  local destinations
  destinations="$(xcodebuild -project Corral.xcodeproj -scheme "$SCHEME_IOS" -showdestinations 2>/dev/null || true)"
  if ! grep -Fq "$device_ref" <<< "$destinations"; then
    echo "error: device '${device_ref}' not visible to xcodebuild" >&2
    echo "documented command once the device is connected and paired:" >&2
    echo "  DEVICE_ID=<device-id> CORRAL_TEAM_ID=<team> CORRAL_APP_BUNDLE_ID=<app-id> bash scripts/build-public-client.sh ios" >&2
    grep "platform:iOS," <<< "$destinations" >&2 || true
    exit 2
  fi
  local destination="platform=iOS,id=${device_ref}"
  [[ -n "${DEVICE_ID:-}" ]] || destination="platform=iOS,name=${device_ref}"
  local derived="${CORRAL_DERIVED_DATA:-${ROOT}/.derivedData-public-ios}"
  local log
  log="$(build_log_for "$derived")"
  note "building ${SCHEME_IOS} (${configuration}) for ${destination}"
  set +e
  xcodebuild -project Corral.xcodeproj -scheme "$SCHEME_IOS" -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$derived" -skipPackagePluginValidation \
    -allowProvisioningUpdates "DEVELOPMENT_TEAM=${CORRAL_TEAM_ID}" CODE_SIGN_STYLE=Automatic \
    build >"$log" 2>&1
  local status="$?"
  set -e
  if (( status != 0 )); then
    tail -n 40 "$log"
    die "xcodebuild failed (exit ${status}); complete log: ${log}"
  fi
  summarize_build_log "$log"
  local app="${derived}/Build/Products/${configuration}-iphoneos/Corral.app"
  [[ -d "$app" ]] || die "expected app not found at ${app}"
  verify_signature "$app"
  note "built ${app}"
  note "install on the paired device only (documented, not automatic):"
  echo "  xcrun devicectl device install app --device ${device_ref} \"${app}\""
  echo "$app"
}

case "${1:-}" in
  mac) shift; cmd_mac "$@" ;;
  ios) shift; cmd_ios "$@" ;;
  ""|-h|--help) sed -n '1,12p' "$0"; exit 0 ;;
  *) die "usage: $0 {mac|ios}" ;;
esac
