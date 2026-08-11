#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
namespace=''
fixture_home=''
fixture_path=''
host=''
supervisor=''
keeper=''
runtime_root=''
storage_root=''
output=''

fail() { print -u2 -- "render-test-launchagents: $1"; exit 1; }
take() {
  [[ "$#" == 2 && -n "$2" ]] || fail "missing value for $1"
  case "$1" in
    --namespace) namespace=$2 ;;
    --home) fixture_home=$2 ;;
    --path) fixture_path=$2 ;;
    --host-executable) host=$2 ;;
    --supervisor-executable) supervisor=$2 ;;
    --keeper-executable) keeper=$2 ;;
    --runtime-root) runtime_root=$2 ;;
    --storage-root) storage_root=$2 ;;
    --output-directory) output=$2 ;;
    *) fail "unknown option: $1" ;;
  esac
}

while (( $# > 0 )); do
  (( $# >= 2 )) || fail "missing option value"
  take "$1" "$2"
  shift 2
done

[[ "$namespace" =~ '^[a-z0-9-]{1,32}$' ]] || fail "namespace must match [a-z0-9-]{1,32}"
for directory in "$fixture_home" "$runtime_root" "$storage_root"; do
  [[ "$directory" == /* && -d "$directory" && ! -L "$directory" ]] || fail "directory must be physical and absolute: $directory"
done
[[ -n "$fixture_path" ]] || fail "PATH must not be empty"
for executable in "$host" "$supervisor" "$keeper"; do
  [[ "$executable" == /* && -f "$executable" && -x "$executable" && ! -L "$executable" ]] || fail "executable must be physical and absolute: $executable"
done
[[ "$output" == /* && ! -L "$output" ]] || fail "output must be absolute and not a symlink"
if [[ -e "$output" ]]; then
  [[ -d "$output" && ! -L "$output" ]] || fail "output is not a physical directory"
else
  /bin/mkdir -p "$output"
fi

host_plist="$output/host.plist"
terminal_plist="$output/terminal.plist"
/bin/cp "$repo_root/Config/LaunchAgents/dev.cockpit.host.local.plist.template" "$host_plist"
/bin/cp "$repo_root/Config/LaunchAgents/dev.cockpit.terminal.local.plist.template" "$terminal_plist"

/usr/bin/plutil -replace Label -string "dev.cockpit.host.$namespace" "$host_plist"
/usr/bin/plutil -replace MachServices -json "{\"dev.cockpit.host.$namespace\":true}" "$host_plist"
/usr/bin/plutil -replace ProgramArguments -json "[\"$host\"]" "$host_plist"

/usr/bin/plutil -replace Label -string "dev.cockpit.terminal.$namespace" "$terminal_plist"
/usr/bin/plutil -replace MachServices -json "{\"dev.cockpit.terminal.$namespace\":true}" "$terminal_plist"
/usr/bin/plutil -replace ProgramArguments -json "[\"$supervisor\",\"--keeper-executable\",\"$keeper\",\"--runtime-directory\",\"$runtime_root\"]" "$terminal_plist"

for plist in "$host_plist" "$terminal_plist"; do
  /usr/bin/plutil -replace EnvironmentVariables.COCKPIT_APPLICATION_SUPPORT_ROOT -string "$storage_root" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.HOME -string "$fixture_home" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.PATH -string "$fixture_path" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.COCKPIT_SERVICE_NAMESPACE -string "$namespace" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables.COCKPIT_TERMINAL_RUNTIME_ROOT -string "$runtime_root" "$plist"
done
/usr/bin/plutil -remove EnvironmentVariables.COCKPIT_INTEGRATION_MASTER_KEY "$terminal_plist"

assert_value() {
  local plist=$1 key=$2 expected=$3
  [[ "$(/usr/bin/plutil -extract "$key" raw -o - "$plist")" == "$expected" ]] || fail "$plist $key mismatch"
}
assert_value "$host_plist" Label "dev.cockpit.host.$namespace"
assert_value "$terminal_plist" Label "dev.cockpit.terminal.$namespace"
[[ "$(/usr/bin/plutil -extract MachServices json -o - "$host_plist")" == "{\"dev.cockpit.host.$namespace\":true}" ]] || fail "host MachServices mismatch"
[[ "$(/usr/bin/plutil -extract MachServices json -o - "$terminal_plist")" == "{\"dev.cockpit.terminal.$namespace\":true}" ]] || fail "terminal MachServices mismatch"
assert_value "$host_plist" ProgramArguments.0 "$host"
! /usr/bin/plutil -extract ProgramArguments.1 raw -o - "$host_plist" >/dev/null 2>&1 || fail "host ProgramArguments has extra values"
assert_value "$terminal_plist" ProgramArguments.0 "$supervisor"
assert_value "$terminal_plist" ProgramArguments.1 --keeper-executable
assert_value "$terminal_plist" ProgramArguments.2 "$keeper"
assert_value "$terminal_plist" ProgramArguments.3 --runtime-directory
assert_value "$terminal_plist" ProgramArguments.4 "$runtime_root"
! /usr/bin/plutil -extract ProgramArguments.5 raw -o - "$terminal_plist" >/dev/null 2>&1 || fail "terminal ProgramArguments has extra values"
for plist in "$host_plist" "$terminal_plist"; do
  assert_value "$plist" EnvironmentVariables.HOME "$fixture_home"
  assert_value "$plist" EnvironmentVariables.PATH "$fixture_path"
  assert_value "$plist" EnvironmentVariables.COCKPIT_SERVICE_NAMESPACE "$namespace"
  assert_value "$plist" EnvironmentVariables.COCKPIT_TERMINAL_RUNTIME_ROOT "$runtime_root"
  assert_value "$plist" EnvironmentVariables.COCKPIT_APPLICATION_SUPPORT_ROOT "$storage_root"
  /usr/bin/plutil -lint "$plist" >/dev/null
done

print -- "rendered test LaunchAgents: namespace=$namespace host=$host_plist terminal=$terminal_plist"
