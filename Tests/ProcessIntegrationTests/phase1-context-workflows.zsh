#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
cache_root="$HOME/Library/Caches"
fixture_root=$(/usr/bin/mktemp -d "$cache_root/cockpit-phase1-context-workflows.XXXXXX")
codex_executable="$repo_root/Tests/Fixtures/Agents/codex"
claude_executable="$repo_root/Tests/Fixtures/Agents/claude"
agent_output_directory="$fixture_root/agent-output"
service_root=""

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
    [[ "$fixture_root" == "$cache_root"/cockpit-phase1-context-workflows.* ]]
    [[ "${fixture_root:h}" == "$cache_root" ]]
    [[ -d "$fixture_root" && ! -L "$fixture_root" ]]
    /bin/rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT

/bin/chmod 700 "$fixture_root"
[[ -x "$codex_executable" && -x "$claude_executable" ]]
/bin/mkdir "$agent_output_directory"
/bin/chmod 700 "$agent_output_directory"

"$repo_root/Tools/phase0-services.zsh" start
IFS= read -r service_root < "$repo_root/.build/phase0-launchagents/service-root.path"
runtime_directory="$service_root/runtime"
probe="$service_root/bin/CockpitProbe"

receipt=$(
  "$probe" context-workflow \
    "$runtime_directory" \
    "$fixture_root" \
    "$codex_executable" \
    "$claude_executable" \
    "$agent_output_directory"
)
IFS=$'\t' read -r project_id environment_id conversation_one conversation_two \
  project_shell conversation_one_codex conversation_one_claude conversation_one_shell \
  conversation_two_codex exited_session exit_status restarted_session \
  project_count conversation_one_count conversation_two_count <<< "$receipt"

for identifier in \
  "$project_id" "$environment_id" "$conversation_one" "$conversation_two" \
  "$project_shell" "$conversation_one_codex" "$conversation_one_claude" \
  "$conversation_one_shell" "$conversation_two_codex" "$exited_session" \
  "$restarted_session"; do
  [[ "$identifier" == ????????-????-????-????-???????????? ]]
done
[[ "$conversation_one" != "$conversation_two" ]]
[[ "$conversation_one_codex" != "$conversation_one_claude" ]]
[[ "$conversation_one_codex" != "$restarted_session" ]]
[[ "$exited_session" == "$conversation_one_codex" ]]
[[ "$exit_status" == 0 ]]
[[ "$project_count" == 1 ]]
[[ "$conversation_one_count" == 4 ]]
[[ "$conversation_two_count" == 1 ]]
[[ "$(/usr/bin/find "$agent_output_directory" -type f -maxdepth 1 | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 4 ]]
[[ "$(/usr/bin/grep -l '^agent=codex$' "$agent_output_directory"/* | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 3 ]]
[[ "$(/usr/bin/grep -l '^agent=claude$' "$agent_output_directory"/* | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]]

print -r -- \
  "phase1 context workflows: project=$project_id conversations=$conversation_one,$conversation_two sessions=$project_count/$conversation_one_count/$conversation_two_count restart=$exited_session->$restarted_session"
