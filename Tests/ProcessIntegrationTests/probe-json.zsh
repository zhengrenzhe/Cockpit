#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
probe="$repo_root/.build/debug/CockpitProbe"
[[ -x "$probe" ]] || { print -u2 -- "probe-json: missing $probe"; exit 1; }

stdout=$(/usr/bin/mktemp /private/tmp/cockpit-probe-json.stdout.XXXXXX)
stderr=$(/usr/bin/mktemp /private/tmp/cockpit-probe-json.stderr.XXXXXX)
composition_root=$(/usr/bin/mktemp -d /private/tmp/cockpit-probe-composition.XXXXXX)
cleanup() {
  /bin/rm -f -- "$stdout" "$stderr"
  if [[ -e "$composition_root" ]]; then
    [[ "$composition_root" == /private/tmp/cockpit-probe-composition.* ]]
    [[ -d "$composition_root" && ! -L "$composition_root" ]]
    /bin/rm -rf -- "$composition_root"
  fi
}
trap cleanup EXIT HUP INT TERM

set +e
COCKPIT_SERVICE_NAMESPACE='INVALID_NAMESPACE' \
  "$probe" invalid-command >"$stdout" 2>"$stderr"
probe_exit_status=$?
set -e
[[ "$probe_exit_status" -ne 0 ]]
[[ -s "$stdout" ]]

/usr/bin/python3 - "$stdout" <<'PY'
import json
import pathlib
import sys
import uuid

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
decoder = json.JSONDecoder()
value, end = decoder.raw_decode(raw)
if raw[end:].strip():
    raise SystemExit("Probe stdout contains more than one JSON value")
if set(value) != {"schemaVersion", "ok", "command", "requestID", "error"}:
    raise SystemExit(f"unexpected Probe envelope keys: {sorted(value)}")
if value["schemaVersion"] != 1 or value["ok"] is not False:
    raise SystemExit("invalid Probe failure envelope")
if value["command"] != "invalid-command":
    raise SystemExit("Probe command echo mismatch")
uuid.UUID(value["requestID"])
if not isinstance(value["error"], dict) or not value["error"]:
    raise SystemExit("Probe error must be a non-empty object")
PY

for product in CockpitHost CockpitTerminalSupervisor; do
  product_root="$composition_root/$product"
  fixture_home="$product_root/home"
  runtime_root="$product_root/runtime"
  /bin/mkdir -p "$fixture_home/Library/Application Support" "$runtime_root"
  /usr/bin/python3 - \
    "$repo_root/.build/debug/$product" \
    "$repo_root/.build/debug/CockpitPTYKeeper" \
    "$fixture_home" "$runtime_root" <<'PY'
import os
import pathlib
import subprocess
import sys

executable, keeper, fixture_home, runtime_root = sys.argv[1:]
environment = dict(os.environ)
environment.update({
    "HOME": fixture_home,
    "CFFIXED_USER_HOME": fixture_home,
    "COCKPIT_SERVICE_NAMESPACE": "p1-missing-storage",
})
environment.pop("COCKPIT_APPLICATION_SUPPORT_ROOT", None)
arguments = [executable]
if pathlib.Path(executable).name == "CockpitTerminalSupervisor":
    arguments += [
        "--keeper-executable", keeper,
        "--runtime-directory", runtime_root,
    ]
process = subprocess.Popen(
    arguments,
    env=environment,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
try:
    stdout, stderr = process.communicate(timeout=3)
except subprocess.TimeoutExpired:
    # poll() has not reaped this exact child, so its PID cannot be reused before terminate().
    process.terminate()
    stdout, stderr = process.communicate(timeout=3)
    raise SystemExit(
        f"{pathlib.Path(executable).name} did not fail closed without fixture storage root"
    )
if process.returncode == 0:
    raise SystemExit(
        f"{pathlib.Path(executable).name} exited successfully without fixture storage root"
    )
PY
  [[ ! -e "$fixture_home/Library/Application Support/dev.cockpit.Cockpit/workspace.sqlite" ]]
  [[ ! -e "$fixture_home/Library/Application Support/dev.cockpit.Cockpit/terminal.sqlite" ]]
done

set +e
COCKPIT_SERVICE_NAMESPACE='p1-contract-red' \
  "$probe" app status --pid 1 --receipt /private/tmp/cockpit-app-receipt.missing \
  >"$stdout" 2>"$stderr"
app_status=$?
set -e
[[ "$app_status" -ne 0 ]]

/usr/bin/python3 - "$stdout" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if value["command"] != "app status":
    raise SystemExit(f"App Probe command echo mismatch: {value['command']!r}")
PY

print -- "probe JSON contract: invalid command emitted one failure object status=$probe_exit_status"
