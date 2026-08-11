#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
cache_root="$HOME/Library/Caches"
fixture_root=$(/usr/bin/mktemp -d "$cache_root/cockpit-phase1-conversation-deletion.XXXXXX")
service_root=""
agent_fixture="$repo_root/Tests/Fixtures/Agents/codex"
agent_executable="$fixture_root/codex"

cleanup() {
  if [[ -n "$service_root" && -d "$service_root/runtime" ]]; then
    local descriptor keeper_pid cli_pid cli_group
    for descriptor in "$service_root"/runtime/*.json(N); do
      keeper_pid=$(/usr/bin/plutil -extract processID raw -o - "$descriptor" 2>/dev/null || true)
      [[ "$keeper_pid" == <-> ]] || continue
      for cli_pid in $(/usr/bin/pgrep -P "$keeper_pid" 2>/dev/null || true); do
        cli_group=$(/bin/ps -o pgid= -p "$cli_pid" 2>/dev/null | /usr/bin/tr -d ' ')
        [[ "$cli_group" == <-> ]] && /bin/kill -KILL -- "-$cli_group" >/dev/null 2>&1 || true
      done
      /bin/kill -TERM "$keeper_pid" >/dev/null 2>&1 || true
    done
  fi
  "$repo_root/Tools/phase0-services.zsh" stop >/dev/null 2>&1 || true
  if [[ -e "$fixture_root" ]]; then
    [[ "$fixture_root" == "$cache_root"/cockpit-phase1-conversation-deletion.* ]]
    [[ "${fixture_root:h}" == "$cache_root" ]]
    [[ -d "$fixture_root" && ! -L "$fixture_root" ]]
    /bin/rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT

/bin/chmod 700 "$fixture_root"
[[ -x "$agent_fixture" ]]
/bin/cp -X "$agent_fixture" "$agent_executable"
/bin/chmod 700 "$agent_executable"
/usr/bin/cmp -s "$agent_fixture" "$agent_executable"
print -r -- 'project-file-must-survive' > "$fixture_root/preserved.txt"
print -r -- 'external-agent-history-must-survive' > "$fixture_root/external-history.log"

"$repo_root/Tools/phase0-services.zsh" start
IFS= read -r service_root < "$repo_root/.build/phase0-launchagents/service-root.path"
runtime_directory="$service_root/runtime"
probe="$service_root/bin/CockpitProbe"

receipt=$(
  "$probe" conversation-deletion \
    "$runtime_directory" \
    "$fixture_root" \
    "$agent_executable"
)
IFS=$'\t' read -r project_id environment_id deleted_conversation retained_conversation \
  deleted_session retained_session operation_id create_blocked conversation_count \
  deleted_record_count retained_record_count <<< "$receipt"

for identifier in \
  "$project_id" "$environment_id" "$deleted_conversation" "$retained_conversation" \
  "$deleted_session" "$retained_session" "$operation_id"; do
  [[ "$identifier" == ????????-????-????-????-???????????? ]]
done
[[ "$deleted_conversation" != "$retained_conversation" ]]
[[ "$deleted_session" != "$retained_session" ]]
[[ "$create_blocked" == 1 ]]
[[ "$conversation_count" == 1 ]]
[[ "$deleted_record_count" == 0 ]]
[[ "$retained_record_count" == 1 ]]
[[ "$(<"$fixture_root/preserved.txt")" == 'project-file-must-survive' ]]
[[ "$(<"$fixture_root/external-history.log")" == 'external-agent-history-must-survive' ]]
[[ "$(/usr/bin/sed -n '1p' "$fixture_root/deletion-target-agent.log")" == 'agent=codex' ]]
[[ "$(/usr/bin/sed -n '1p' "$fixture_root/deletion-retained-agent.log")" == 'agent=codex' ]]
[[ ! -e "$service_root/storage/TerminalArchives/$deleted_session" ]]
[[ -f "$service_root/storage/TerminalArchives/$retained_session/manifest.pb" ]]
[[ -f "$service_root/storage/TerminalArchives/$retained_session/final-snapshot.ckgf" ]]

print -r -- \
  "phase1 conversation deletion: operation=$operation_id deleted=$deleted_conversation/$deleted_session retained=$retained_conversation/$retained_session"
