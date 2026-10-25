#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="${PROJECT:-Corral.xcodeproj}"
SCHEME="${SCHEME:-Corral}"
SIM_NAME="${SIM_NAME:-iPhone 17}"
DEVICE_NAME="${DEVICE_NAME:-}"
DEVICE_ID="${DEVICE_ID:-}"
DERIVED_DATA="${DERIVED_DATA:-.derivedData}"
BUNDLE_ID="${BUNDLE_ID:-com.x0c.corral}"
CONFIGURATION="${CONFIGURATION:-Debug}"

# App Store Connect Team Key：真机自动签名需要（含推送能力的描述文件）。
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/Documents/P8 密钥/发布公证密钥/AuthKey_D7YQ9HD7D6_Notarize.p8}"
ASC_KEY_ID="${ASC_KEY_ID:-D7YQ9HD7D6}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-c98fe4b8-d1bf-4b4a-b998-9eb8f3be9fe4}"

if [[ -n "${DESTINATION:-}" ]]; then
  DESTINATION="${DESTINATION}"
elif [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="platform=iOS,id=${DEVICE_ID}"
elif [[ -n "$DEVICE_NAME" ]]; then
  DESTINATION="platform=iOS,name=${DEVICE_NAME}"
else
  DESTINATION="platform=iOS Simulator,name=${SIM_NAME}"
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/ios_sim.sh generate
  scripts/ios_sim.sh build
  scripts/ios_sim.sh test
  scripts/ios_sim.sh run

Environment overrides:
  SIM_NAME / DEVICE_NAME / DEVICE_ID / DESTINATION / DERIVED_DATA
  真机默认装到名为 iPhone Max 的已配对设备（可用 DEVICE_NAME / DEVICE_ID 覆盖）
EOF
}

generate_project() {
  xcodegen generate
}

is_simulator_destination() {
  [[ "$DESTINATION" == platform=iOS\ Simulator,* ]]
}

is_generic_ios_destination() {
  [[ "$DESTINATION" == generic/platform=iOS ]]
}

destination_value() {
  local key="$1"
  local part
  IFS=',' read -r -a parts <<< "$DESTINATION"
  for part in "${parts[@]}"; do
    if [[ "$part" == "${key}="* ]]; then
      echo "${part#${key}=}"
      return 0
    fi
  done
  return 1
}

ensure_destination_exists() {
  # iOS 27 真机在 Xcode 26 上不能当直接构建目标；通用包不依赖手机在线。
  if is_generic_ios_destination; then
    return 0
  fi
  if is_simulator_destination; then
    local sim_name
    sim_name="$(destination_value name || true)"
    if [[ -z "$sim_name" ]]; then
      echo "error: Simulator destination must include name=..." >&2
      exit 1
    fi
    if ! xcrun simctl list devices available | grep -Fq " ${sim_name} ("; then
      echo "error: Simulator not found: ${sim_name}" >&2
      xcrun simctl list devices available | grep -E "iPhone" >&2 || true
      exit 1
    fi
    return 0
  fi
  local device_ref
  device_ref="$(destination_value id || destination_value name || true)"
  if [[ -z "$device_ref" ]]; then
    echo "error: Device destination must include id=... or name=..." >&2
    exit 1
  fi
  # 真机目的地以 xcodebuild -showdestinations 为准（UDID 与 devicectl 列表可能不同）。
  if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | grep -Eq "platform:iOS,.*${device_ref}"; then
    return 0
  fi
  if xcrun xctrace list devices 2>/dev/null | grep -Fq "$device_ref"; then
    return 0
  fi
  echo "error: Connected device not found: ${device_ref}" >&2
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | grep "platform:iOS," >&2 || true
  exit 1
}

build_app() {
  generate_project
  local extra=()
  # 真机自动签名：允许 Xcode 创建带推送能力的 App ID / 描述文件。
  if ! is_simulator_destination; then
    extra+=(-allowProvisioningUpdates)
    if [[ -f "$ASC_KEY_PATH" ]]; then
      extra+=(
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
      )
    fi
  fi
  # set -u 下空数组展开会报 unbound；有参数才展开。
  # SwiftTerm (project terminal) ships a build plugin; unattended builds must skip its trust prompt.
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" -configuration "$CONFIGURATION" -skipPackagePluginValidation \
    ${extra[@]+"${extra[@]}"} build "$@"
}

run_app() {
  local app_platform_dir="iphoneos"
  local app_path
  if is_simulator_destination; then
    local sim_name
    sim_name="$(destination_value name)"
    app_platform_dir="iphonesimulator"
    open -a Simulator
    xcrun simctl boot "$sim_name" >/dev/null 2>&1 || true
    app_path="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-${app_platform_dir}/Corral.app"
    xcrun simctl install booted "$app_path"
    xcrun simctl launch booted "$BUNDLE_ID"
    return 0
  fi
  local device_ref
  if is_generic_ios_destination; then
    device_ref="${DEVICE_ID:-${DEVICE_NAME:-iPhone Max}}"
  else
    device_ref="$(destination_value id || destination_value name)"
  fi
  app_path="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-${app_platform_dir}/Corral.app"
  xcrun devicectl device install app --device "$device_ref" "$app_path"
  xcrun devicectl device process launch --device "$device_ref" --terminate-existing "$BUNDLE_ID"
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage
  exit 2
fi
shift || true

case "$cmd" in
  generate)
    generate_project
    ;;
  build)
    ensure_destination_exists
    build_app "$@"
    ;;
  test)
    ensure_destination_exists
    generate_project
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA" -skipPackagePluginValidation test "$@"
    ;;
  run)
    ensure_destination_exists
    build_app "$@"
    run_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
