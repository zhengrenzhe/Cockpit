#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
domain="gui/$(/usr/bin/id -u)"
service_root_record="$repo_root/.build/phase0-launchagents/service-root.path"

cleanup() {
  "$repo_root/Tools/phase0-services.zsh" stop
}
trap cleanup EXIT

"$repo_root/Tools/phase0-services.zsh" stop

set +e
failure_output=$(
  COCKPIT_PHASE0_FAIL_AFTER_HOST_BOOTSTRAP=1 \
    "$repo_root/Tools/phase0-services.zsh" start 2>&1
)
failure_status=$?
set -e

print -r -- "$failure_output"
[[ "$failure_status" -ne 0 ]]
[[ -f "$service_root_record" ]]
IFS= read -r service_root < "$service_root_record"
[[ "$service_root" == /private/tmp/cockpit-phase0.* ]]
[[ ! -e "$service_root" ]]
! /bin/launchctl print "$domain/dev.cockpit.host.local" >/dev/null 2>&1
! /bin/launchctl print "$domain/dev.cockpit.terminal.local" >/dev/null 2>&1

print -r -- "start failure cleanup verified: status=$failure_status root=$service_root"
