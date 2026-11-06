#!/usr/bin/env bash
# collect-entitlements.sh IOS_DIR OUT_DIR
# Copies each target's entitlements file to OUT_DIR/<bundle id>.plist with the $(VARIABLES) from Config/Base.xcconfig expanded
# (the unsigned build does not process entitlements, so they must be literal for ci/public-build/sign-on-pc.sh).
# Runs on the macOS runner (bash 3.2, BSD sed) and in WSL / Git Bash. Fails loudly when a file or a variable is missing.
set -euo pipefail

IOS="${1:?usage: collect-entitlements.sh IOS_DIR OUT_DIR}"
OUT="${2:?usage: collect-entitlements.sh IOS_DIR OUT_DIR}"
XC="$IOS/Config/Base.xcconfig"
[ -f "$XC" ] || { echo "collect-entitlements: $XC not found" >&2; exit 1; }
mkdir -p "$OUT"

# value of KEY in the xcconfig, with $(OTHER) inside it expanded (three passes is plenty: APP_GROUP_ID -> APP_BASE_ID).
val() {
  local v
  v="$(sed -n -E "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^/]*[^/[:space:]])[[:space:]]*(//.*)?$|\1|p" "$XC" | head -n 1)"
  [ -n "$v" ] || { echo "collect-entitlements: $1 is not set in $XC" >&2; exit 1; }
  local i k r
  for i in 1 2 3; do
    for k in $(printf '%s' "$v" | grep -o '\$([A-Z_]*)' | sort -u | tr -d '$()'); do
      r="$(val "$k")"
      v="${v//\$($k)/$r}"
    done
  done
  printf '%s' "$v"
}

APP_ID="$(val APP_BUNDLE_ID)"
GROUP_ID="$(val APP_GROUP_ID)"

emit() {   # file, bundle id
  local src="$IOS/$1" id="$2"
  [ -f "$src" ] || { echo "collect-entitlements: $src is missing" >&2; exit 1; }
  sed -e "s|\$(APP_GROUP_ID)|$GROUP_ID|g" -e "s|\$(APP_BUNDLE_ID)|$APP_ID|g" "$src" > "$OUT/$id.plist"
  if grep -q '\$(' "$OUT/$id.plist"; then
    echo "collect-entitlements: unexpanded variable left in $OUT/$id.plist" >&2; exit 1
  fi
  echo "entitlements: $id.plist"
}

emit App/Support/MGApp.entitlements "$APP_ID"
emit Widgets/Support/MGWidgets.entitlements "$APP_ID.widgets"
emit Extensions/ActivityMonitor/Support/MGActivityMonitor.entitlements "$APP_ID.activitymonitor"
emit Extensions/ActivityReport/Support/MGActivityReport.entitlements "$APP_ID.activityreport"
emit Watch/HealthWatch/Support/HealthWatch.entitlements "$APP_ID.watchkitapp"
