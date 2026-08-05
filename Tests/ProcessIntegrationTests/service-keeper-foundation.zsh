#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
domain="gui/$(id -u)"
keeper_pid=""

cleanup() {
  /bin/launchctl bootout \
    "$domain/dev.cockpit.host.local" >/dev/null 2>&1 || true
  /bin/launchctl bootout \
    "$domain/dev.cockpit.terminal.local" >/dev/null 2>&1 || true
  if [[ -n "$keeper_pid" ]]; then
    /bin/kill -TERM "$keeper_pid" >/dev/null 2>&1 || true
    for _ in {1..100}; do
      /bin/kill -0 "$keeper_pid" >/dev/null 2>&1 || break
      /bin/sleep 0.05
    done
    if /bin/kill -0 "$keeper_pid" >/dev/null 2>&1; then
      /bin/kill -KILL "$keeper_pid" >/dev/null 2>&1 || true
    fi
  fi
  "$repo_root/Tools/phase0-services.zsh" stop
}
trap cleanup EXIT

"$repo_root/Tools/phase0-services.zsh" start

service_output=$("$repo_root/Tools/phase0-services.zsh" probe)
print -r -- "$service_output"
[[ "$service_output" == *"dev.cockpit.host host 1.0"* ]]
[[ "$service_output" == *"dev.cockpit.terminal terminal 1.0"* ]]

receipt=$("$repo_root/Tools/phase0-services.zsh" spawn-keeper)
IFS=$'\t' read -r keeper_pid session_id worker_id descriptor_path <<< "$receipt"

for _ in {1..100}; do
  [[ -f "$descriptor_path" ]] && break
  /bin/sleep 0.05
done

[[ -f "$descriptor_path" ]]
descriptor_session_id=$(
  /usr/bin/plutil -extract sessionID.rawValue raw -o - "$descriptor_path"
)
descriptor_worker_id=$(
  /usr/bin/plutil -extract workerInstanceID.rawValue raw -o - "$descriptor_path"
)
descriptor_pid=$(
  /usr/bin/plutil -extract processID raw -o - "$descriptor_path"
)
descriptor_pgid=$(
  /usr/bin/plutil -extract processGroupID raw -o - "$descriptor_path"
)
[[ "${descriptor_session_id:l}" == "${session_id:l}" ]]
[[ "${descriptor_worker_id:l}" == "${worker_id:l}" ]]
[[ "$descriptor_pid" == "$keeper_pid" ]]
[[ "$(/usr/bin/stat -f %Lp "${descriptor_path:h}")" == 700 ]]
[[ "$(/usr/bin/stat -f %Lp "$descriptor_path")" == 600 ]]
/bin/kill -0 "$keeper_pid"

keeper_process=$(/bin/ps -o pid=,ppid=,pgid=,state=,command= -p "$keeper_pid")
print -r -- "keeper before supervisor crash: $keeper_process"
keeper_pgid=$(/bin/ps -o pgid= -p "$keeper_pid" | /usr/bin/tr -d ' ')
[[ "$keeper_pgid" == "$keeper_pid" ]]
[[ "$descriptor_pgid" == "$keeper_pgid" ]]
keeper_command=$(
  /bin/ps -o command= -p "$keeper_pid" | /usr/bin/sed 's/^[[:space:]]*//'
)
[[ "$keeper_command" == "${descriptor_path:h:h}/bin/CockpitPTYKeeper" ]]
keeper_environment=$(/bin/ps eww -p "$keeper_pid")
[[ "$keeper_environment" != *"$session_id"* ]]
[[ "$keeper_environment" != *"$worker_id"* ]]
[[ "$keeper_environment" != *"$descriptor_path"* ]]
! /usr/sbin/lsof -a -p "$keeper_pid" -d 3 >/dev/null 2>&1

/bin/launchctl kill SIGKILL "$domain/dev.cockpit.terminal.local"
/bin/kill -0 "$keeper_pid"

supervisor_ready=0
for _ in {1..120}; do
  if "$repo_root/Tools/phase0-services.zsh" probe >/dev/null 2>&1; then
    supervisor_ready=1
    break
  fi
  /bin/sleep 0.25
done

[[ "$supervisor_ready" == 1 ]]
/bin/kill -0 "$keeper_pid"
print -r -- "terminal service after restart:"
/bin/launchctl print "$domain/dev.cockpit.terminal.local" \
  | /usr/bin/sed -n '/state =/p; /pid =/p'
print -r -- "keeper after supervisor restart: $(/bin/ps -o pid=,ppid=,pgid=,state=,command= -p "$keeper_pid")"

/bin/kill -TERM "$keeper_pid"
for _ in {1..100}; do
  /bin/kill -0 "$keeper_pid" >/dev/null 2>&1 || break
  /bin/sleep 0.05
done
! /bin/kill -0 "$keeper_pid" >/dev/null 2>&1
print -r -- "keeper terminated without zombie: pid=$keeper_pid"
keeper_pid=""
