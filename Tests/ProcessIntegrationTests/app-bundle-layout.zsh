#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h:h}
app="$repo_root/build/Debug/Cockpit.app"
resources="$app/Contents/Resources"
agents="$app/Contents/Library/LaunchAgents"
host_plist="$agents/dev.cockpit.host.plist"
terminal_plist="$agents/dev.cockpit.terminal.plist"
runtime_bundle="$resources/MonacoRuntime.bundle"

test -x "$app/Contents/MacOS/Cockpit"
test -x "$resources/CockpitHost"
test -x "$resources/CockpitTerminalSupervisor"
test -x "$resources/CockpitPTYKeeper"

expected_agents=(
    "$host_plist"
    "$terminal_plist"
)
actual_agents=("$agents"/*(ND))
[[ "${(j:\n:)actual_agents}" == "${(j:\n:)expected_agents}" ]]
test ! -e "$agents/dev.cockpit.keeper.plist"

test "$(/usr/bin/plutil -extract Label raw -o - "$host_plist")" = "dev.cockpit.host"
test "$(/usr/bin/plutil -extract BundleProgram raw -o - "$host_plist")" = \
    "Contents/Resources/CockpitHost"
host_services=$(/usr/bin/plutil -extract MachServices json -o - "$host_plist")
test "$host_services" = '{"dev.cockpit.host":true}'

test "$(/usr/bin/plutil -extract Label raw -o - "$terminal_plist")" = \
    "dev.cockpit.terminal"
test "$(/usr/bin/plutil -extract BundleProgram raw -o - "$terminal_plist")" = \
    "Contents/Resources/CockpitTerminalSupervisor"
terminal_services=$(/usr/bin/plutil -extract MachServices json -o - "$terminal_plist")
test "$terminal_services" = '{"dev.cockpit.terminal":true}'
test "$(/usr/bin/plutil -extract KeepAlive raw -o - "$terminal_plist")" = "true"
[[ "$host_services$terminal_services" != *dev.cockpit.keeper* ]]

test -d "$runtime_bundle"
test ! -L "$runtime_bundle"
expected_runtime_files=(
    "$runtime_bundle/editor.css"
    "$runtime_bundle/editor.js"
    "$runtime_bundle/editor.js.map"
    "$runtime_bundle/index.html"
)
actual_runtime_files=("$runtime_bundle"/*(ND))
[[ "${(j:\n:)actual_runtime_files}" == "${(j:\n:)expected_runtime_files}" ]]
for runtime_file in "${expected_runtime_files[@]}"; do
    test -f "$runtime_file"
    test ! -L "$runtime_file"
    test -s "$runtime_file"
done
/usr/bin/python3 - "$runtime_bundle/editor.js.map" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source_map_file:
    source_map = json.load(source_map_file)
if "sourcesContent" in source_map:
    raise SystemExit("Monaco runtime source map must not contain sourcesContent")
PY

verify_signed_product() {
    local product=$1
    local expected_identifier=$2
    local actual_identifier
    /usr/bin/codesign --verify --strict "$product"
    actual_identifier=$(
        /usr/bin/codesign -d --verbose=4 "$product" 2>&1 \
            | /usr/bin/sed -n 's/^Identifier=//p'
    )
    test "$actual_identifier" = "$expected_identifier"
}

verify_signed_product "$app" "dev.cockpit.Cockpit"
verify_signed_product "$resources/CockpitHost" "dev.cockpit.CockpitHost"
verify_signed_product \
    "$resources/CockpitTerminalSupervisor" \
    "dev.cockpit.CockpitTerminalSupervisor"
verify_signed_product "$resources/CockpitPTYKeeper" "dev.cockpit.CockpitPTYKeeper"
/usr/bin/codesign --verify --deep --strict "$app"
