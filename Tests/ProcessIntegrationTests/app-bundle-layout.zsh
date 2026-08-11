#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h:h}
default_app="$repo_root/build/Debug/Cockpit.app"
app=${COCKPIT_APP_BUNDLE_UNDER_TEST:-$default_app}
resources="$app/Contents/Resources"
agents="$app/Contents/Library/LaunchAgents"
host_plist="$agents/dev.cockpit.host.plist"
terminal_plist="$agents/dev.cockpit.terminal.plist"
runtime_bundle="$resources/MonacoRuntime.bundle"

if [[ ${COCKPIT_BUNDLE_GATE_SELF_TEST:-0} == 1 ]]; then
    fixture_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cockpit-task10c-bundle-self-test.XXXXXX")
    trap '/bin/rm -rf -- "$fixture_root"' EXIT
    forbidden_paths=(
        "Contents/Resources/node/bin/node"
        "Contents/Resources/pnpm/bin/pnpm"
        "Contents/Resources/node_modules/example/index.js"
        "Contents/Resources/EditorRuntime/src/bootstrap.ts"
        "Contents/Resources/monaco-editor/esm/vs/editor/editor.api.js"
    )
    accepted=0
    index=0
    for forbidden_path in "${forbidden_paths[@]}"; do
        fixture="$fixture_root/Forbidden-$index.app"
        /bin/cp -R "$app" "$fixture"
        /bin/mkdir -p "${fixture}/${forbidden_path:h}"
        print -r -- forbidden > "${fixture}/${forbidden_path}"
        /usr/bin/codesign --force --deep --sign - "$fixture" >/dev/null 2>&1
        if COCKPIT_BUNDLE_GATE_SELF_TEST=0 \
            COCKPIT_APP_BUNDLE_UNDER_TEST="$fixture" \
            "$0" >/dev/null 2>&1; then
            print -u2 -- "bundle gate accepted forbidden fixture: $forbidden_path"
            (( accepted += 1 ))
        fi
        (( index += 1 ))
    done
    test "$accepted" -eq 0
    exit 0
fi

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
! /usr/bin/plutil -extract EnvironmentVariables.COCKPIT_SERVICE_NAMESPACE raw -o - \
    "$host_plist" >/dev/null 2>&1

test "$(/usr/bin/plutil -extract Label raw -o - "$terminal_plist")" = \
    "dev.cockpit.terminal"
test "$(/usr/bin/plutil -extract BundleProgram raw -o - "$terminal_plist")" = \
    "Contents/Resources/CockpitTerminalSupervisor"
terminal_services=$(/usr/bin/plutil -extract MachServices json -o - "$terminal_plist")
test "$terminal_services" = '{"dev.cockpit.terminal":true}'
! /usr/bin/plutil -extract EnvironmentVariables.COCKPIT_SERVICE_NAMESPACE raw -o - \
    "$terminal_plist" >/dev/null 2>&1
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

/usr/bin/python3 - "$app" <<'PY'
import os
import pathlib
import sys

app = pathlib.Path(sys.argv[1])
for root, directories, files in os.walk(app):
    for name in [*directories, *files]:
        relative = pathlib.Path(root, name).relative_to(app)
        parts = relative.parts
        forbidden = (
            "node" in parts
            or "pnpm" in parts
            or "node_modules" in parts
            or any(parts[index:index + 2] == ("EditorRuntime", "src") for index in range(len(parts) - 1))
            or "monaco-editor" in parts
        )
        if forbidden:
            raise SystemExit(f"forbidden development artifact in App bundle: {relative}")
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
