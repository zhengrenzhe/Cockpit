#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
domain="gui/$(/usr/bin/id -u)"
namespace=''
for _ in {1..50}; do
  candidate="p1-$RANDOM-$RANDOM"
  candidate=${candidate[1,32]}
  if ! /bin/launchctl print "$domain/dev.cockpit.host.$candidate" >/dev/null 2>&1 \
    && ! /bin/launchctl print "$domain/dev.cockpit.terminal.$candidate" >/dev/null 2>&1 \
    && [[ -z $(find /private/tmp -maxdepth 1 -name "cockpit-phase1-direct.$candidate.*" -print -quit) ]] \
    && [[ -z $(find "$HOME/Library/Caches" -maxdepth 1 -name "cockpit-phase1-agent.$candidate.*" -print -quit) ]]; then
    namespace=$candidate
    break
  fi
done
[[ -n "$namespace" ]] || { print -u2 -- 'unable to allocate collision-free namespace'; exit 1; }
host_label="dev.cockpit.host.$namespace"
terminal_label="dev.cockpit.terminal.$namespace"
fixture_root=$(/usr/bin/mktemp -d "/private/tmp/cockpit-phase1-direct.$namespace.XXXXXX")
fixture_home="$fixture_root/home"
fixture_bin="$fixture_root/bin"
runtime_root="$fixture_root/runtime"
storage_root="$fixture_root/storage"
project_root="$fixture_root/project"
launchagent_root="$fixture_root/launchagents"
receipt_root="$fixture_root/receipts"
agent_fixture_root=''
agent_fixture_base="$HOME/Library/Caches"
fixture_path="$fixture_bin:/usr/bin:/bin:/usr/sbin:/sbin"
probe="$fixture_bin/CockpitProbe"
app_executable="$repo_root/build/Debug/Cockpit.app/Contents/MacOS/Cockpit"
fixture_keychain="$fixture_home/Library/Keychains/cockpit-phase1.keychain-db"
fixture_keychain_password="cockpit-phase1-$namespace"
bootstrapped_host=0
bootstrapped_terminal=0
deleted_terminal_contexts=''

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  local app_identities=''
  if [[ -d "$receipt_root" ]]; then
    app_identities=$(/usr/bin/python3 - "$receipt_root" <<'PY'
import json
import pathlib
import sys
seen = set()
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    try:
        value = json.loads(path.read_text())
        result = value.get("result", {})
        pid = result.get("appPID")
        identity = result.get("processIdentity", {})
        token = identity.get("auditToken")
        executable = identity.get("executablePath")
        receipt = result.get("receipt")
        if isinstance(pid, int) and pid > 1 and pid not in seen:
            seen.add(pid)
            fields = (pid, token or "", executable or "", receipt or "")
            print("\t".join(map(str, fields)))
    except Exception:
        pass
PY
    )
  fi
  while IFS=$'\t' read -r pid token executable receipt; do
    [[ -n "$pid" ]] || continue
    if /bin/kill -0 "$pid" >/dev/null 2>&1; then
      if [[ -z "$token" || -z "$executable" || -z "$receipt" ]]; then
        print -u2 -- "fixture App identity incomplete; refusing signal: pid=$pid"
        rc=1
        continue
      fi
      local app_cleanup_status=0
      HOME="$fixture_home" PATH="$fixture_path" \
        COCKPIT_SERVICE_NAMESPACE="$namespace" \
        COCKPIT_APPLICATION_SUPPORT_ROOT="$storage_root" \
        COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT="$agent_fixture_root" \
        COCKPIT_TERMINAL_RUNTIME_ROOT="$runtime_root" \
        "$probe" app crash --pid "$pid" --receipt "$receipt" \
          --identity-token "$token" --executable "$executable" \
          >/dev/null 2>&1 || app_cleanup_status=$?
      if (( app_cleanup_status != 0 )); then
        print -u2 -- "fixture App exact-identity cleanup failed without fallback: pid=$pid"
        rc=1
      fi
    fi
  done <<< "$app_identities"
  local terminal_sessions=''
  if [[ -d "$receipt_root" ]]; then
    terminal_sessions=$(/usr/bin/python3 - "$receipt_root" "$deleted_terminal_contexts" <<'PY'
import json
import pathlib
import sys
seen = set()
deleted_contexts = set(filter(None, sys.argv[2].splitlines()))
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    try:
        value = json.loads(path.read_text())
        result = value.get("result", {})
        triple = (
            result.get("workspaceContextID"),
            result.get("environmentID"),
            result.get("terminalSessionID"),
        )
        if (all(isinstance(v, str) and v for v in triple)
                and triple[0] not in deleted_contexts and triple not in seen):
            seen.add(triple)
            print("\t".join(triple))
    except Exception:
        pass
PY
    )
  fi
  local cleanup_services_status=0
  HOME="$fixture_home" PATH="$fixture_path" \
    COCKPIT_SERVICE_NAMESPACE="$namespace" \
    COCKPIT_APPLICATION_SUPPORT_ROOT="$storage_root" \
    COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT="$agent_fixture_root" \
    COCKPIT_TERMINAL_RUNTIME_ROOT="$runtime_root" \
    "$probe" services >/dev/null 2>&1 || cleanup_services_status=$?
  if [[ -n "$terminal_sessions" && "$cleanup_services_status" == 0 ]]; then
    while IFS=$'\t' read -r context environment session; do
      [[ -n "$context" && -n "$environment" && -n "$session" ]] || continue
      local terminate_status=0 inspection_status=0 lifecycle=''
      HOME="$fixture_home" PATH="$fixture_path" \
        COCKPIT_SERVICE_NAMESPACE="$namespace" \
        COCKPIT_APPLICATION_SUPPORT_ROOT="$storage_root" \
        COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT="$agent_fixture_root" \
        COCKPIT_TERMINAL_RUNTIME_ROOT="$runtime_root" \
        "$probe" terminal terminate --context-id "$context" \
          --environment-id "$environment" --session-id "$session" --force \
          >/dev/null 2>&1 || terminate_status=$?
      if (( terminate_status != 0 )); then
        local inspection=''
        inspection=$(HOME="$fixture_home" PATH="$fixture_path" \
          COCKPIT_SERVICE_NAMESPACE="$namespace" \
          COCKPIT_APPLICATION_SUPPORT_ROOT="$storage_root" \
          COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT="$agent_fixture_root" \
          COCKPIT_TERMINAL_RUNTIME_ROOT="$runtime_root" \
          "$probe" terminal inspect --context-id "$context" \
            --environment-id "$environment" --session-id "$session" \
            2>/dev/null) || inspection_status=$?
        if (( inspection_status != 0 )); then
          print -u2 -- "authenticated terminal cleanup inspection failed without PID fallback: session=$session"
          rc=1
        else
          lifecycle=$(/usr/bin/python3 -c \
            'import json,sys; print(json.loads(sys.argv[1])["result"]["lifecycleState"])' \
            "$inspection")
          if [[ "$lifecycle" != terminated && "$lifecycle" != exited ]]; then
            print -u2 -- "authenticated terminal cleanup failed: session=$session state=$lifecycle"
            rc=1
          fi
        fi
      fi
    done <<< "$terminal_sessions"
  elif [[ -n "$terminal_sessions" ]]; then
    print -u2 -- "authenticated terminal cleanup unavailable; refusing PID/PGID fallback"
    rc=1
  fi
  (( bootstrapped_terminal == 0 )) || /bin/launchctl bootout "$domain/$terminal_label" >/dev/null 2>&1 || true
  (( bootstrapped_host == 0 )) || /bin/launchctl bootout "$domain/$host_label" >/dev/null 2>&1 || true
  local receipt_pairs=''
  if [[ -d "$receipt_root" ]]; then
    receipt_pairs=$(/usr/bin/python3 - "$receipt_root" <<'PY'
import json
import pathlib
import sys
seen = set()
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    try:
        result = json.loads(path.read_text()).get("result", {})
        pair = (result.get("keeperPID"), result.get("cliPID"))
        if all(isinstance(v, int) and v > 1 for v in pair) and pair not in seen:
            seen.add(pair)
            print(f"{pair[0]}\t{pair[1]}")
    except Exception:
        pass
PY
    )
  fi
  if [[ -n "$receipt_pairs" ]]; then
    while IFS=$'\t' read -r keeper cli; do
      [[ -n "$keeper" && -n "$cli" ]] || continue
      for _ in {1..20}; do
        /bin/kill -0 "$keeper" >/dev/null 2>&1 || break
        /bin/sleep 0.05
      done
      if /bin/kill -0 "$keeper" >/dev/null 2>&1; then
        print -u2 -- "fixture Keeper remained after authenticated cleanup; refusing PID fallback: pid=$keeper"
        rc=1
      fi
      /bin/kill -0 "$keeper" >/dev/null 2>&1 && rc=1
      /bin/kill -0 -- "-$cli" >/dev/null 2>&1 && rc=1
    done <<< "$receipt_pairs"
  fi
  /bin/launchctl print "$domain/$terminal_label" >/dev/null 2>&1 && rc=1
  /bin/launchctl print "$domain/$host_label" >/dev/null 2>&1 && rc=1
  if [[ -f "$fixture_keychain" ]]; then
    HOME="$fixture_home" /usr/bin/security delete-generic-password \
      -s "dev.cockpit.terminal.master-key.$namespace" \
      -a installation-master-key-v1 "$fixture_keychain" >/dev/null 2>&1 || true
    HOME="$fixture_home" /usr/bin/security delete-generic-password \
      -s "dev.cockpit.client-identity.$namespace" \
      -a device-id-v1 "$fixture_keychain" >/dev/null 2>&1 || true
    local terminal_keychain_status=0 client_keychain_status=0
    HOME="$fixture_home" /usr/bin/security find-generic-password \
      -s "dev.cockpit.terminal.master-key.$namespace" \
      -a installation-master-key-v1 "$fixture_keychain" >/dev/null 2>&1 || terminal_keychain_status=$?
    HOME="$fixture_home" /usr/bin/security find-generic-password \
      -s "dev.cockpit.client-identity.$namespace" \
      -a device-id-v1 "$fixture_keychain" >/dev/null 2>&1 || client_keychain_status=$?
    if (( terminal_keychain_status != 44 || client_keychain_status != 44 )); then
      print -u2 -- "fixture keychain cleanup mismatch: terminal=$terminal_keychain_status client=$client_keychain_status"
      rc=1
    fi
    HOME="$fixture_home" /usr/bin/security delete-keychain "$fixture_keychain" >/dev/null 2>&1 || rc=1
    [[ ! -e "$fixture_keychain" ]] || rc=1
  fi
  local preferences_domain="dev.cockpit.client-identity.$namespace"
  local preferences_path="$HOME/Library/Preferences/$preferences_domain.plist"
  if /usr/bin/defaults read "$preferences_domain" >/dev/null 2>&1; then
    /usr/bin/defaults delete "$preferences_domain" >/dev/null 2>&1 || rc=1
  fi
  /usr/bin/defaults read "$preferences_domain" >/dev/null 2>&1 && rc=1
  if [[ -e "$preferences_path" ]]; then
    [[ "$preferences_path" == "$HOME/Library/Preferences/dev.cockpit.client-identity.p1-"*.plist ]]
    [[ -f "$preferences_path" && ! -L "$preferences_path" ]]
    /bin/unlink "$preferences_path" || rc=1
  fi
  [[ ! -e "$preferences_path" ]] || rc=1
  if [[ -n "$agent_fixture_root" && -e "$agent_fixture_root" ]]; then
    [[ "$agent_fixture_root" == "$agent_fixture_base/cockpit-phase1-agent.$namespace."* ]]
    [[ -d "$agent_fixture_root" && ! -L "$agent_fixture_root" ]]
    /bin/rm -f -- "$agent_fixture_root/agent-fixture" "$agent_fixture_root/exiting-agent"
    /bin/rmdir "$agent_fixture_root" >/dev/null 2>&1 || rc=1
    [[ ! -e "$agent_fixture_root" ]] || rc=1
  fi
  if [[ -e "$fixture_root" ]]; then
    [[ "$fixture_root" == "/private/tmp/cockpit-phase1-direct.$namespace."* ]]
    [[ -d "$fixture_root" && ! -L "$fixture_root" ]]
    /bin/rm -rf -- "$fixture_root"
    [[ ! -e "$fixture_root" ]] || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

agent_fixture_root=$(/usr/bin/mktemp -d "$agent_fixture_base/cockpit-phase1-agent.$namespace.XXXXXX")
/bin/chmod 700 "$agent_fixture_root"

json_field() {
  /usr/bin/python3 -c 'import json,sys; v=json.loads(sys.argv[1]);
for key in sys.argv[2].split("."): v=v[int(key)] if isinstance(v,list) else v[key]
print("true" if v is True else "false" if v is False else v)' "$1" "$2"
}

json_count() {
  /usr/bin/python3 -c 'import json,sys; v=json.loads(sys.argv[1]);
for key in sys.argv[2].split("."): v=v[int(key)] if isinstance(v,list) else v[key]
print(len(v))' "$1" "$2"
}

json_canonical() {
  /usr/bin/python3 -c 'import json,sys; v=json.loads(sys.argv[1]);
for key in sys.argv[2].split("."): v=v[int(key)] if isinstance(v,list) else v[key]
print(json.dumps(v,sort_keys=True,separators=(",",":")))' "$1" "$2"
}

mutated_audit_token() {
  /usr/bin/python3 -c 'import sys
token=bytearray.fromhex(sys.argv[1]); token[-1] ^= 1; print(token.hex())' "$1"
}

assert_envelope() {
  /usr/bin/python3 -c 'import json,sys,uuid; v=json.loads(sys.argv[1]);
assert v["schemaVersion"] == 1 and v["ok"] is True
assert set(v) == {"schemaVersion","ok","command","requestID","result"}
uuid.UUID(v["requestID"])' "$1"
}

run_probe() {
  local output probe_status=0
  output=$(HOME="$fixture_home" PATH="$fixture_path" \
    COCKPIT_SERVICE_NAMESPACE="$namespace" \
    COCKPIT_APPLICATION_SUPPORT_ROOT="$storage_root" \
    COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT="$agent_fixture_root" \
    COCKPIT_TERMINAL_RUNTIME_ROOT="$runtime_root" \
    "$probe" "$@") || probe_status=$?
  if (( probe_status != 0 )); then
    print -u2 -- "$output"
    return "$probe_status"
  fi
  assert_envelope "$output"
  print -r -- "$output"
}

wait_services() {
  local output
  for _ in {1..120}; do
    if output=$(run_probe services 2>/dev/null); then
      print -r -- "$output"
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

wait_terminal_state() {
  local context_id=$1 session_id=$2 expected=$3 output=''
  for _ in {1..120}; do
    output=$(run_probe terminal inspect --context-id "$context_id" \
      --environment-id "$environment_id" --session-id "$session_id" 2>/dev/null || true)
    if [[ -n "$output" && "$(json_field "$output" result.lifecycleState)" == "$expected" ]]; then
      print -r -- "$output"
      return 0
    fi
    /bin/sleep 0.1
  done
  print -u2 -- "terminal state timeout: session=$session_id expected=$expected output=$output"
  return 1
}

wait_app_status() {
  local pid=$1 receipt=$2 token=$3 executable=$4 output=''
  for _ in {1..120}; do
    output=$(run_probe app status --pid "$pid" --receipt "$receipt" \
      --identity-token "$token" --executable "$executable" 2>/dev/null || true)
    if [[ -n "$output" ]] && /usr/bin/python3 -c \
      'import json,sys; assert json.loads(sys.argv[1]).get("ok") is True' "$output" 2>/dev/null; then
      if /usr/bin/python3 -c \
        'import json,sys; assert json.loads(sys.argv[1])["result"]["error"] is not None' "$output" 2>/dev/null; then
        print -u2 -- "App start failed: $(json_field "$output" result.error)"
        return 1
      fi
    fi
    if [[ -n "$output" ]] && /usr/bin/python3 -c \
      'import json,sys; assert json.loads(sys.argv[1]).get("result",{}).get("ready") is True' "$output" 2>/dev/null; then
      print -r -- "$output"
      return 0
    fi
    /bin/sleep 0.1
  done
  print -u2 -- "App ready timeout: pid=$pid receipt=$receipt output=$output"
  return 1
}

for directory in "$fixture_home" "$fixture_bin" "$runtime_root" "$storage_root" "$project_root" "$launchagent_root" "$receipt_root"; do
  /bin/mkdir -p "$directory"
  /bin/chmod 700 "$directory"
done
/bin/mkdir -p "$fixture_home/Library/Keychains"
/bin/chmod 700 "$fixture_home/Library" "$fixture_home/Library/Keychains"
HOME="$fixture_home" /usr/bin/security create-keychain \
  -p "$fixture_keychain_password" "$fixture_keychain"
HOME="$fixture_home" /usr/bin/security unlock-keychain \
  -p "$fixture_keychain_password" "$fixture_keychain"
HOME="$fixture_home" /usr/bin/security set-keychain-settings \
  -t 21600 "$fixture_keychain"

for product in CockpitHost CockpitTerminalSupervisor CockpitProbe; do
  /bin/cp -X "$repo_root/.build/debug/$product" "$fixture_bin/$product"
done
/bin/cp -X "$repo_root/build/Debug/Cockpit.app/Contents/Resources/CockpitPTYKeeper" "$fixture_bin/CockpitPTYKeeper"
bookmark_requirement='=designated => identifier "dev.cockpit.phase1.bookmark"'
/usr/bin/codesign --force --sign - --identifier dev.cockpit.phase1.bookmark --requirements "$bookmark_requirement" "$fixture_bin/CockpitHost" >/dev/null
/usr/bin/codesign --force --sign - "$fixture_bin/CockpitTerminalSupervisor" >/dev/null
/usr/bin/codesign --force --sign - "$fixture_bin/CockpitPTYKeeper" >/dev/null
/usr/bin/codesign --force --sign - --identifier dev.cockpit.phase1.bookmark --requirements "$bookmark_requirement" "$fixture_bin/CockpitProbe" >/dev/null
"$repo_root/Tools/render-test-launchagents.zsh" \
  --namespace "$namespace" --home "$fixture_home" --path "$fixture_path" \
  --host-executable "$fixture_bin/CockpitHost" \
  --supervisor-executable "$fixture_bin/CockpitTerminalSupervisor" \
  --keeper-executable "$fixture_bin/CockpitPTYKeeper" \
  --runtime-root "$runtime_root" --storage-root "$storage_root" \
  --output-directory "$launchagent_root"
/usr/bin/plutil -insert EnvironmentVariables.COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT \
  -string "$agent_fixture_root" "$launchagent_root/host.plist"

/bin/launchctl bootstrap "$domain" "$launchagent_root/host.plist"
bootstrapped_host=1
/bin/launchctl bootstrap "$domain" "$launchagent_root/terminal.plist"
bootstrapped_terminal=1
services=$(wait_services)
[[ "$(json_field "$services" result.host.machServiceName)" == "dev.cockpit.host.$namespace" ]]
[[ "$(json_field "$services" result.terminal.machServiceName)" == "dev.cockpit.terminal.$namespace" ]]

/usr/bin/printf '\357\273\277alpha\r\nbeta\r\n' > "$project_root/format.txt"
/usr/bin/printf 'recovery-base\n' > "$project_root/recovery.txt"
/usr/bin/printf 'conflict-base\n' > "$project_root/conflict.txt"
/usr/bin/printf 'delete-base\n' > "$project_root/delete.txt"
add=$(run_probe workspace add-project --path "$project_root")
project_id=$(json_field "$add" result.projectID)
project_context=$(json_field "$add" result.workspaceContextID)
environment_id=$(json_field "$add" result.environmentID)
[[ "$(json_field "$add" result.conversationCount)" == 0 ]]
zero_snapshot=$(run_probe workspace snapshot)
[[ "$(json_field "$zero_snapshot" result.projects.0.conversationCount)" == 0 ]]
zero_terminals=$(run_probe terminal list --context-id "$project_context" --environment-id "$environment_id")
[[ "$(json_count "$zero_terminals" result.sessions)" == 0 ]]

run_probe file mkdir --context-id "$project_context" --environment-id "$environment_id" --path work >/dev/null
run_probe file create --context-id "$project_context" --environment-id "$environment_id" --path work/new.txt >/dev/null
run_probe file rename --context-id "$project_context" --environment-id "$environment_id" --path work/new.txt --name renamed.txt >/dev/null
run_probe file move --context-id "$project_context" --environment-id "$environment_id" --path work/renamed.txt --destination . >/dev/null
run_probe file trash --context-id "$project_context" --environment-id "$environment_id" --path renamed.txt >/dev/null
project_tree_before=$(run_probe file tree --context-id "$project_context" --environment-id "$environment_id" --path .)
[[ "$(json_field "$project_tree_before" result.generation)" == 1 ]]

project_recovery_open=$(run_probe document open --context-id "$project_context" --environment-id "$environment_id" --path recovery.txt)
recovery_id=$(json_field "$project_recovery_open" result.documentID)
recovery_edit=$(run_probe document edit --context-id "$project_context" --environment-id "$environment_id" --document-id "$recovery_id" --offset 13 --length 0 --text ACK)
recovery_version=$(json_field "$recovery_edit" result.version)
recovery_text=$(json_field "$recovery_edit" result.text)
[[ "$(json_field "$recovery_edit" result.dirtyState)" == dirty ]]

agent="$agent_fixture_root/agent-fixture"
/usr/bin/clang -x c -o "$agent" - <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

int main(void) {
  static const char consumed[] = "CONSUMED:";
  static const char delta_marker_prefix[] = "after-restart-delta-";
  char bytes[256];
  char line[256];
  char output[(sizeof(consumed) - 1) + sizeof(line)];
  char initial[1024];
  size_t line_count = 0;
  const char *home = getenv("HOME");
  const char *path = getenv("PATH");
  (void)signal(SIGHUP, SIG_IGN);
  (void)signal(SIGTERM, SIG_IGN);
  struct termios settings;
  if (tcgetattr(STDIN_FILENO, &settings) == 0) {
    settings.c_lflag &= (tcflag_t)~(ECHO | ICANON);
    settings.c_cc[VMIN] = 1;
    settings.c_cc[VTIME] = 0;
    (void)tcsetattr(STDIN_FILENO, TCSANOW, &settings);
  }
  int initial_count = snprintf(initial, sizeof(initial), "HOME=%s\nPATH=%s\nREADY\n", home, path);
  if (initial_count <= 0 || (size_t)initial_count >= sizeof(initial) ||
      write(STDOUT_FILENO, initial, (size_t)initial_count) != initial_count) return 2;
  for (;;) {
    ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count <= 0) return 0;
    for (ssize_t index = 0; index < count; ++index) {
      if (line_count == sizeof(line)) return 3;
      line[line_count++] = bytes[index];
      if (bytes[index] != '\n') continue;
      memcpy(output, consumed, sizeof(consumed) - 1);
      size_t payload_count = line_count;
      if (line_count > sizeof(delta_marker_prefix) - 1 &&
          memcmp(line, delta_marker_prefix, sizeof(delta_marker_prefix) - 1) == 0) {
        payload_count -= 1;
      }
      memcpy(output + sizeof(consumed) - 1, line, payload_count);
      size_t output_count = sizeof(consumed) - 1 + payload_count;
      if (write(STDOUT_FILENO, output, output_count) != (ssize_t)output_count) return 4;
      line_count = 0;
    }
  }
}
C
/bin/chmod 700 "$agent"
/usr/bin/codesign --force --sign - "$agent" >/dev/null

project_shell=$(run_probe terminal create --context-id "$project_context" --environment-id "$environment_id" --kind shell)
project_shell_session=$(json_field "$project_shell" result.terminalSessionID)
print -r -- "$project_shell" > "$receipt_root/$project_shell_session.create.json"
[[ "$(json_field "$project_shell" result.terminalKind)" == shell ]]
project_shell_input=$(run_probe terminal input --context-id "$project_context" --environment-id "$environment_id" --session-id "$project_shell_session" --text 'printf PROJECT-SHELL-READY' --expect-output PROJECT-SHELL-READY)
[[ "$(json_field "$project_shell_input" result.output)" == *PROJECT-SHELL-READY* ]]
print -r -- "$project_shell_input" > "$receipt_root/$project_shell_session.json"
project_codex=$(run_probe terminal create --context-id "$project_context" --environment-id "$environment_id" --kind codex --resolved-executable "$agent")
project_codex_session=$(json_field "$project_codex" result.terminalSessionID)
print -r -- "$project_codex" > "$receipt_root/$project_codex_session.create.json"
[[ "$(json_field "$project_codex" result.terminalKind)" == codex ]]
project_codex_input=$(run_probe terminal input --context-id "$project_context" --environment-id "$environment_id" --session-id "$project_codex_session" --text PROJECT-CODEX-READY)
[[ "$(json_field "$project_codex_input" result.output)" == *CONSUMED:PROJECT-CODEX-READY* ]]
print -r -- "$project_codex_input" > "$receipt_root/$project_codex_session.json"
project_claude=$(run_probe terminal create --context-id "$project_context" --environment-id "$environment_id" --kind claude --resolved-executable "$agent")
project_claude_session=$(json_field "$project_claude" result.terminalSessionID)
print -r -- "$project_claude" > "$receipt_root/$project_claude_session.create.json"
[[ "$(json_field "$project_claude" result.terminalKind)" == claude ]]
project_claude_input=$(run_probe terminal input --context-id "$project_context" --environment-id "$environment_id" --session-id "$project_claude_session" --text PROJECT-CLAUDE-READY)
[[ "$(json_field "$project_claude_input" result.output)" == *CONSUMED:PROJECT-CLAUDE-READY* ]]
print -r -- "$project_claude_input" > "$receipt_root/$project_claude_session.json"
still_zero=$(run_probe workspace snapshot)
[[ "$(json_field "$still_zero" result.projects.0.conversationCount)" == 0 ]]

/bin/launchctl kill SIGKILL "$domain/$host_label"
/bin/launchctl kickstart "$domain/$host_label"
wait_services >/dev/null
recovered=$(run_probe document open --context-id "$project_context" --environment-id "$environment_id" --path recovery.txt)
[[ "$(json_field "$recovered" result.documentID)" == "$recovery_id" ]]
[[ "$(json_field "$recovered" result.version)" == "$recovery_version" ]]
[[ "$(json_field "$recovered" result.text)" == "$recovery_text" ]]
[[ "$(json_field "$recovered" result.dirtyState)" == dirty ]]
recovery_saved=$(run_probe document save --context-id "$project_context" --environment-id "$environment_id" --document-id "$recovery_id")
[[ "$(json_field "$recovery_saved" result.dirtyState)" == clean ]]

opened_project=$(run_probe document open --context-id "$project_context" --environment-id "$environment_id" --path format.txt)
document_id=$(json_field "$opened_project" result.documentID)
edited=$(run_probe document edit --context-id "$project_context" --environment-id "$environment_id" --document-id "$document_id" --offset 5 --length 0 --text '-ack')
[[ "$(json_field "$edited" result.version)" -gt "$(json_field "$opened_project" result.version)" ]]
saved=$(run_probe document save --context-id "$project_context" --environment-id "$environment_id" --document-id "$document_id")
[[ "$(json_field "$saved" result.dirtyState)" == clean ]]
/usr/bin/python3 - "$project_root/format.txt" <<'PY'
import pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
assert data.startswith(b'\xef\xbb\xbf') and b'\r\n' in data and b'\n' not in data.replace(b'\r\n', b'')
PY

one=$(run_probe conversation create --project-id "$project_id")
two=$(run_probe conversation create --project-id "$project_id")
conversation_one=$(json_field "$one" result.conversationID)
conversation_two=$(json_field "$two" result.conversationID)
context_one=$(json_field "$one" result.workspaceContextID)
context_two=$(json_field "$two" result.workspaceContextID)
[[ "$conversation_one" != "$conversation_two" && "$context_one" != "$context_two" ]]
[[ "$(json_field "$one" result.environmentID)" == "$environment_id" ]]
[[ "$(json_field "$two" result.environmentID)" == "$environment_id" ]]
run_probe conversation rename --conversation-id "$conversation_one" --title 'Direct One' >/dev/null

project_tree=$(run_probe file tree --context-id "$project_context" --environment-id "$environment_id" --path .)
tree_one=$(run_probe file tree --context-id "$context_one" --environment-id "$environment_id" --path .)
tree_two=$(run_probe file tree --context-id "$context_two" --environment-id "$environment_id" --path .)
[[ "$(json_canonical "$project_tree" result.entries)" == "$(json_canonical "$tree_one" result.entries)" ]]
[[ "$(json_canonical "$project_tree" result.entries)" == "$(json_canonical "$tree_two" result.entries)" ]]
/usr/bin/python3 - "$project_tree" "$tree_one" "$tree_two" "$environment_id" <<'PY'
import json,sys
trees=[json.loads(raw)["result"] for raw in sys.argv[1:4]]
environment=sys.argv[4]
for tree in trees:
    assert tree["environmentID"] == environment
    assert all(entry["environmentID"] == environment for entry in tree["entries"])
    assert {entry["path"] for entry in tree["entries"]} >= {
        "format.txt", "recovery.txt", "conflict.txt", "delete.txt", "work"
    }
PY

opened_one=$(run_probe document open --context-id "$context_one" --environment-id "$environment_id" --path format.txt)
opened_two=$(run_probe document open --context-id "$context_two" --environment-id "$environment_id" --path format.txt)
[[ "$(json_field "$saved" result.documentID)" == "$document_id" ]]
[[ "$(json_field "$opened_one" result.documentID)" == "$document_id" ]]
[[ "$(json_field "$opened_two" result.documentID)" == "$document_id" ]]
[[ "$(json_field "$saved" result.version)" == "$(json_field "$opened_one" result.version)" ]]
[[ "$(json_field "$saved" result.version)" == "$(json_field "$opened_two" result.version)" ]]
[[ "$(json_field "$saved" result.text)" == "$(json_field "$opened_one" result.text)" ]]
[[ "$(json_field "$saved" result.text)" == "$(json_field "$opened_two" result.text)" ]]
run_probe file rename --context-id "$project_context" --environment-id "$environment_id" --path format.txt --name moved.txt >/dev/null
for context_id in "$project_context" "$context_one" "$context_two"; do
  moved=$(run_probe document snapshot --context-id "$context_id" --environment-id "$environment_id" --document-id "$document_id")
  [[ "$(json_field "$moved" result.documentID)" == "$document_id" ]]
  [[ "$(json_field "$moved" result.path)" == moved.txt ]]
done

conflict_open=$(run_probe document open --context-id "$context_one" --environment-id "$environment_id" --path conflict.txt)
conflict_id=$(json_field "$conflict_open" result.documentID)
conflict_edit=$(run_probe document edit --context-id "$context_one" --environment-id "$environment_id" --document-id "$conflict_id" --offset 13 --length 0 --text ACK)
conflict_version=$(json_field "$conflict_edit" result.version)
conflict_text=$(json_field "$conflict_edit" result.text)
/usr/bin/printf 'external-disk\n' > "$project_root/conflict.txt"
conflict=''
for _ in {1..120}; do
  conflict=$(run_probe document snapshot --context-id "$context_one" --environment-id "$environment_id" --document-id "$conflict_id" 2>/dev/null || true)
  [[ -n "$conflict" && "$(json_field "$conflict" result.dirtyState)" == conflict ]] && break
  /bin/sleep 0.1
done
[[ "$(json_field "$conflict" result.dirtyState)" == conflict ]]
[[ "$(json_field "$conflict" result.documentID)" == "$conflict_id" ]]
[[ "$(json_field "$conflict" result.version)" == "$conflict_version" ]]
[[ "$(json_field "$conflict" result.text)" == "$conflict_text" ]]
/usr/bin/python3 - "$project_root/conflict.txt" <<'PY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).read_bytes() == b'external-disk\n'
PY

exiting_agent="$agent_fixture_root/exiting-agent"
/usr/bin/clang -x c -o "$exiting_agent" - <<'C'
#include <stdio.h>
int main(void) {
  for (int index = 0; index < 40; ++index) {
    (void)printf("EXITED-SCROLLBACK-%02d\n", index);
  }
  (void)printf("EXITED-AGENT\n");
  (void)fflush(stdout);
  return 23;
}
C
/bin/chmod 700 "$exiting_agent"
/usr/bin/codesign --force --sign - "$exiting_agent" >/dev/null

shell=$(run_probe terminal create --context-id "$context_one" --environment-id "$environment_id" --kind shell)
shell_session=$(json_field "$shell" result.terminalSessionID)
print -r -- "$shell" > "$receipt_root/$shell_session.create.json"
shell_inspect=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$shell_session")
print -r -- "$shell_inspect" > "$receipt_root/$shell_session.json"
codex=$(run_probe terminal create --context-id "$context_one" --environment-id "$environment_id" --kind codex --resolved-executable "$agent")
codex_session=$(json_field "$codex" result.terminalSessionID)
print -r -- "$codex" > "$receipt_root/$codex_session.create.json"
codex_inspect=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session")
print -r -- "$codex_inspect" > "$receipt_root/$codex_session.json"
claude=$(run_probe terminal create --context-id "$context_one" --environment-id "$environment_id" --kind claude --resolved-executable "$agent")
claude_session=$(json_field "$claude" result.terminalSessionID)
print -r -- "$claude" > "$receipt_root/$claude_session.create.json"
claude_inspect=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$claude_session")
print -r -- "$claude_inspect" > "$receipt_root/$claude_session.json"
exiting=$(run_probe terminal create --context-id "$context_one" --environment-id "$environment_id" --kind codex --resolved-executable "$exiting_agent")
exiting_session=$(json_field "$exiting" result.terminalSessionID)
print -r -- "$exiting" > "$receipt_root/$exiting_session.create.json"
exited=$(wait_terminal_state "$context_one" "$exiting_session" exited)
[[ "$(json_field "$exited" result.terminalKind)" == codex ]]
[[ "$(json_field "$exited" result.exitStatus)" == 23 ]]
print -r -- "$exited" > "$receipt_root/$exiting_session.json"
archive_chunk="$storage_root/TerminalArchives/$exiting_session/chunks/00000000000000000001.ckgs"
for _ in {1..120}; do
  [[ -f "$archive_chunk" ]] && break
  /bin/sleep 0.1
done
/usr/bin/python3 - "$archive_chunk" <<'PY'
import pathlib,struct,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
assert len(data) >= 36 and data[:4] == b'CKGF' and data[6] == 3
offset=36
scrollback=None
for _ in range(struct.unpack('>I', data[32:36])[0]):
    kind=data[offset]
    length=struct.unpack('>I', data[offset+4:offset+8])[0]
    payload=data[offset+8:offset+8+length]
    if kind == 7:
        scrollback=payload
    offset += 8 + length
assert scrollback is not None
assert struct.unpack('>I', scrollback[8:12])[0] > 0
assert b'EXITED-SCROLLBACK-00' in scrollback
PY
other=$(run_probe terminal create --context-id "$context_two" --environment-id "$environment_id" --kind codex --resolved-executable "$agent")
other_session=$(json_field "$other" result.terminalSessionID)
print -r -- "$other" > "$receipt_root/$other_session.create.json"
other_inspect=$(run_probe terminal inspect --context-id "$context_two" --environment-id "$environment_id" --session-id "$other_session")
print -r -- "$other_inspect" > "$receipt_root/$other_session.json"

project_sessions=$(run_probe terminal list --context-id "$project_context" --environment-id "$environment_id")
one_sessions=$(run_probe terminal list --context-id "$context_one" --environment-id "$environment_id")
two_sessions=$(run_probe terminal list --context-id "$context_two" --environment-id "$environment_id")
/usr/bin/python3 - "$project_sessions" "$one_sessions" "$two_sessions" \
  "$project_context" "$context_one" "$context_two" \
  "$project_shell_session" "$project_codex_session" "$project_claude_session" \
  "$shell_session" "$codex_session" "$claude_session" "$exiting_session" "$other_session" <<'PY'
import json,sys
project,one,two=(json.loads(raw)["result"] for raw in sys.argv[1:4])
project_context,one_context,two_context=sys.argv[4:7]
expected=[{sys.argv[7],sys.argv[8],sys.argv[9]},{sys.argv[10],sys.argv[11],sys.argv[12],sys.argv[13]},{sys.argv[14]}]
for result,context,sessions in zip((project,one,two),(project_context,one_context,two_context),expected):
    assert result["workspaceContextID"] == context
    assert {session["terminalSessionID"] for session in result["sessions"]} == sessions
    assert all(session["workspaceContextID"] == context for session in result["sessions"])
PY

before=$(run_probe terminal input --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session" --text phase1-marker)
agent_output=$(json_field "$before" result.output)
[[ "$agent_output" == *"HOME=$fixture_home"* ]]
[[ "$agent_output" == *"PATH="*"$fixture_bin"* ]]
[[ "$agent_output" == *"READY"* ]]
[[ "$agent_output" == *"CONSUMED:phase1-marker"* ]]
keeper_before=$(json_field "$before" result.keeperPID)
cli_before=$(json_field "$before" result.cliPID)
worker_before=$(json_field "$before" result.workerInstanceID)
print -r -- "$before" > "$receipt_root/$codex_session.json"
sequence_before=$(json_field "$before" result.latestSequence)
surviving_scrollback_marker="SURVIVING-SCROLLBACK-$namespace"
surviving_scrollback_payload=$(/usr/bin/python3 - "$surviving_scrollback_marker" <<'PY'
import sys
marker=sys.argv[1]
print("\n".join(f"{marker}-{index:03d}" for index in range(1, 81)))
PY
)
scrollback_frame=$(run_probe terminal input --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$codex_session" \
  --text "$surviving_scrollback_payload" --expect-output "$surviving_scrollback_marker-080")
[[ "$(json_field "$scrollback_frame" result.output)" == *"$surviving_scrollback_marker-080"* ]]
scrollback_sequence=$(json_field "$scrollback_frame" result.latestSequence)
[[ "$scrollback_sequence" -gt "$sequence_before" ]]
print -r -- "$scrollback_frame" > "$receipt_root/$codex_session.json"

app_one_receipt="$fixture_root/app-one.receipt.json"
app_one=$(run_probe app launch --executable "$app_executable" --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$codex_session" --terminal-kind codex \
  --receipt "$app_one_receipt" --close-tab)
app_one_pid=$(json_field "$app_one" result.appPID)
app_one_token=$(json_field "$app_one" result.processIdentity.auditToken)
app_one_executable=$(json_field "$app_one" result.processIdentity.executablePath)
print -r -- "$app_one" > "$receipt_root/app-one.launch.json"
app_one_status=$(wait_app_status "$app_one_pid" "$app_one_receipt" \
  "$app_one_token" "$app_one_executable")
[[ "$(json_field "$app_one_status" result.closedTab)" == true ]]
[[ "$(json_field "$app_one_status" result.tabCountBefore)" == 1 ]]
[[ "$(json_field "$app_one_status" result.tabCountAfter)" == 0 ]]
[[ "$(json_field "$app_one_status" result.terminalSessionID)" == "$codex_session" ]]
after_tab_close=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session")
[[ "$(json_field "$after_tab_close" result.keeperPID)" == "$keeper_before" ]]
[[ "$(json_field "$after_tab_close" result.cliPID)" == "$cli_before" ]]
app_one_quit=$(run_probe app quit --pid "$app_one_pid" --receipt "$app_one_receipt" \
  --identity-token "$app_one_token" --executable "$app_one_executable")
[[ "$(json_field "$app_one_quit" result.terminated)" == true ]]
[[ "$(json_field "$app_one_quit" result.applicationWillTerminate)" == true ]]

/bin/launchctl kill SIGKILL "$domain/$host_label"
/bin/launchctl kickstart "$domain/$host_label"
wait_services >/dev/null
/bin/launchctl kill SIGKILL "$domain/$terminal_label"
wait_services >/dev/null

app_two_receipt="$fixture_root/app-two.receipt.json"
app_two=$(run_probe app launch --executable "$app_executable" --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$codex_session" --terminal-kind codex \
  --receipt "$app_two_receipt" --expect-reconnected)
app_two_pid=$(json_field "$app_two" result.appPID)
app_two_token=$(json_field "$app_two" result.processIdentity.auditToken)
app_two_executable=$(json_field "$app_two" result.processIdentity.executablePath)
print -r -- "$app_two" > "$receipt_root/app-two.launch.json"
app_two_status=$(wait_app_status "$app_two_pid" "$app_two_receipt" \
  "$app_two_token" "$app_two_executable")
[[ "$(json_field "$app_two_status" result.reconnected)" == true ]]
[[ "$(json_field "$app_two_status" result.terminalSessionID)" == "$codex_session" ]]

snapshot=$(run_probe terminal attach --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session")
[[ "$(json_field "$snapshot" result.terminalSessionID)" == "$codex_session" ]]
[[ "$(json_field "$snapshot" result.workerInstanceID)" == "$worker_before" ]]
[[ "$(json_field "$snapshot" result.keeperPID)" == "$keeper_before" ]]
[[ "$(json_field "$snapshot" result.cliPID)" == "$cli_before" ]]
[[ "$(json_field "$snapshot" result.frameKind)" == snapshot ]]
[[ "$(json_field "$snapshot" result.output)" == *"$surviving_scrollback_marker"* ]]
snapshot_sequence=$(json_field "$snapshot" result.latestSequence)
[[ "$snapshot_sequence" -ge "$scrollback_sequence" ]]

app_two_stale_token=$(mutated_audit_token "$app_two_token")
set +e
app_two_stale_result=$(run_probe app crash --pid "$app_two_pid" \
  --receipt "$app_two_receipt" --identity-token "$app_two_stale_token" \
  --executable "$app_two_executable" 2>/dev/null)
app_two_stale_status=$?
set -e
[[ "$app_two_stale_status" -ne 0 ]]
[[ -z "$app_two_stale_result" ]]
/bin/kill -0 "$app_two_pid"
app_two_crash=$(run_probe app crash --pid "$app_two_pid" --receipt "$app_two_receipt" \
  --identity-token "$app_two_token" --executable "$app_two_executable")
[[ "$(json_field "$app_two_crash" result.signalled)" == true ]]
app_two_identity_status=0
for _ in {1..200}; do
  set +e
  app_two_identity_result=$(run_probe app status --pid "$app_two_pid" \
    --receipt "$app_two_receipt" --identity-token "$app_two_token" \
    --executable "$app_two_executable" 2>/dev/null)
  app_two_identity_status=$?
  set -e
  (( app_two_identity_status != 0 )) && break
  /bin/sleep 0.025
done
[[ "$app_two_identity_status" -ne 0 ]]
[[ -z "$app_two_identity_result" ]]

after=$(run_probe terminal input --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session" --text after-restart)
[[ "$(json_field "$after" result.terminalSessionID)" == "$codex_session" ]]
[[ "$(json_field "$after" result.workerInstanceID)" == "$worker_before" ]]
[[ "$(json_field "$after" result.keeperPID)" == "$keeper_before" ]]
[[ "$(json_field "$after" result.cliPID)" == "$cli_before" ]]
[[ "$(json_field "$after" result.latestSequence)" -gt "$snapshot_sequence" ]]
[[ "$(json_field "$after" result.output)" == *CONSUMED:after-restart* ]]
print -r -- "$after" > "$receipt_root/$codex_session.json"
after_sequence=$(json_field "$after" result.latestSequence)
after_delta=''
after_delta_marker=''
delta=''
for delta_index in {1..8}; do
  candidate_marker="after-restart-delta-$delta_index"
  candidate_frame=$(run_probe terminal input --context-id "$context_one" \
    --environment-id "$environment_id" --session-id "$codex_session" --text "$candidate_marker")
  candidate_sequence=$(json_field "$candidate_frame" result.latestSequence)
  candidate_ack=$(( candidate_sequence - 1 ))
  candidate_delta=$(run_probe terminal attach --context-id "$context_one" \
    --environment-id "$environment_id" --session-id "$codex_session" \
    --last-ack "$candidate_ack" --expect-output "CONSUMED:$candidate_marker")
  if [[ "$(json_field "$candidate_delta" result.frameKind)" == delta ]]; then
    after_delta=$candidate_frame
    after_delta_marker=$candidate_marker
    delta=$candidate_delta
    break
  fi
done
[[ -n "$after_delta" ]]
[[ -n "$delta" ]]
[[ "$(json_field "$after_delta" result.output)" == *"CONSUMED:$after_delta_marker"* ]]
after_delta_sequence=$(json_field "$after_delta" result.latestSequence)
[[ "$after_delta_sequence" -gt "$after_sequence" ]]
[[ "$(json_field "$delta" result.frameKind)" == delta ]]
[[ "$(json_field "$delta" result.output)" == *"CONSUMED:$after_delta_marker"* ]]
[[ "$(json_field "$delta" result.latestSequence)" == "$after_delta_sequence" ]]

app_three_receipt="$fixture_root/app-three.receipt.json"
app_three=$(run_probe app launch --executable "$app_executable" --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$codex_session" --terminal-kind codex \
  --receipt "$app_three_receipt" --expect-reconnected)
app_three_pid=$(json_field "$app_three" result.appPID)
app_three_token=$(json_field "$app_three" result.processIdentity.auditToken)
app_three_executable=$(json_field "$app_three" result.processIdentity.executablePath)
print -r -- "$app_three" > "$receipt_root/app-three.launch.json"
app_three_status=$(wait_app_status "$app_three_pid" "$app_three_receipt" \
  "$app_three_token" "$app_three_executable")
[[ "$(json_field "$app_three_status" result.ready)" == true ]]
[[ "$(json_field "$app_three_status" result.reconnected)" == true ]]
[[ "$(json_field "$app_three_status" result.terminalSessionID)" == "$codex_session" ]]
app_three_frame=$(run_probe terminal attach --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$codex_session" \
  --expect-output "CONSUMED:$after_delta_marker")
[[ "$(json_field "$app_three_frame" result.terminalSessionID)" == "$codex_session" ]]
[[ "$(json_field "$app_three_frame" result.workerInstanceID)" == "$worker_before" ]]
[[ "$(json_field "$app_three_frame" result.keeperPID)" == "$keeper_before" ]]
[[ "$(json_field "$app_three_frame" result.cliPID)" == "$cli_before" ]]
[[ "$(json_field "$app_three_frame" result.latestSequence)" -ge "$after_delta_sequence" ]]
[[ "$(json_field "$app_three_frame" result.output)" == *"CONSUMED:$after_delta_marker"* ]]
app_three_quit=$(run_probe app quit --pid "$app_three_pid" --receipt "$app_three_receipt" \
  --identity-token "$app_three_token" --executable "$app_three_executable")
[[ "$(json_field "$app_three_quit" result.terminated)" == true ]]
[[ "$(json_field "$app_three_quit" result.applicationWillTerminate)" == true ]]

other_before=$(run_probe terminal inspect --context-id "$context_two" --environment-id "$environment_id" --session-id "$other_session")
other_keeper=$(json_field "$other_before" result.keeperPID)
other_cli=$(json_field "$other_before" result.cliPID)
other_worker=$(json_field "$other_before" result.workerInstanceID)
other_sequence=$(json_field "$other_before" result.latestSequence)
print -r -- "$other_before" > "$receipt_root/$other_session.json"
peer_before=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$claude_session")
peer_keeper=$(json_field "$peer_before" result.keeperPID)
peer_worker=$(json_field "$peer_before" result.workerInstanceID)
peer_keeper_token=$(json_field "$peer_before" result.keeperProcessIdentity.auditToken)
peer_keeper_executable=$(json_field "$peer_before" result.keeperProcessIdentity.executablePath)
print -r -- "$peer_before" > "$receipt_root/$claude_session.json"
peer_stale_token=$(mutated_audit_token "$peer_keeper_token")
set +e
peer_stale_result=$(run_probe terminal crash-keeper --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$claude_session" \
  --worker-id "$peer_worker" --pid "$peer_keeper" \
  --identity-token "$peer_stale_token" --executable "$peer_keeper_executable" \
  2>/dev/null)
peer_stale_status=$?
set -e
[[ "$peer_stale_status" -ne 0 ]]
[[ -z "$peer_stale_result" ]]
/bin/kill -0 "$peer_keeper"
peer_crash=$(run_probe terminal crash-keeper --context-id "$context_one" \
  --environment-id "$environment_id" --session-id "$claude_session" \
  --worker-id "$peer_worker" --pid "$peer_keeper" \
  --identity-token "$peer_keeper_token" --executable "$peer_keeper_executable")
[[ "$(json_field "$peer_crash" result.signalled)" == true ]]
/bin/launchctl kill SIGKILL "$domain/$terminal_label"
wait_services >/dev/null
interrupted=''
for _ in {1..100}; do
  interrupted=$(run_probe terminal inspect --context-id "$context_one" --environment-id "$environment_id" --session-id "$claude_session" 2>/dev/null || true)
  [[ -n "$interrupted" && "$(json_field "$interrupted" result.lifecycleState)" == interrupted ]] && break
  /bin/sleep 0.1
done
if [[ -z "$interrupted" || "$(json_field "$interrupted" result.lifecycleState)" != interrupted ]]; then
  print -u2 -- "killed Keeper session did not reconcile to interrupted: $interrupted"
  false
fi
other_after=$(run_probe terminal input --context-id "$context_two" --environment-id "$environment_id" --session-id "$other_session" --text survivor-after-peer-kill)
[[ "$(json_field "$other_after" result.terminalSessionID)" == "$other_session" ]]
[[ "$(json_field "$other_after" result.workerInstanceID)" == "$other_worker" ]]
[[ "$(json_field "$other_after" result.keeperPID)" == "$other_keeper" ]]
[[ "$(json_field "$other_after" result.cliPID)" == "$other_cli" ]]
[[ "$(json_field "$other_after" result.latestSequence)" -gt "$other_sequence" ]]
[[ "$(json_field "$other_after" result.output)" == *CONSUMED:survivor-after-peer-kill* ]]
print -r -- "$other_after" > "$receipt_root/$other_session.json"

run_probe terminal terminate --context-id "$context_one" --environment-id "$environment_id" --session-id "$codex_session" --force >/dev/null
target_final=$(wait_terminal_state "$context_one" "$codex_session" terminated)
[[ "$(json_field "$target_final" result.terminalSessionID)" == "$codex_session" ]]
[[ "$(json_field "$target_final" result.workerInstanceID)" == "$worker_before" ]]
[[ "$(json_field "$target_final" result.latestSequence)" -ge "$(json_field "$after_delta" result.latestSequence)" ]]
print -r -- "$target_final" > "$receipt_root/$codex_session.json"
surviving_archive_chunk="$storage_root/TerminalArchives/$codex_session/chunks/00000000000000000001.ckgs"
for _ in {1..120}; do
  [[ -f "$surviving_archive_chunk" ]] && break
  /bin/sleep 0.1
done
/usr/bin/python3 - "$surviving_archive_chunk" "$surviving_scrollback_marker" <<'PY'
import pathlib,struct,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
marker=sys.argv[2].encode()
assert len(data) >= 36 and data[:4] == b'CKGF' and data[6] == 3
offset=36
scrollback=None
for _ in range(struct.unpack('>I', data[32:36])[0]):
    kind=data[offset]
    length=struct.unpack('>I', data[offset+4:offset+8])[0]
    payload=data[offset+8:offset+8+length]
    if kind == 7:
        scrollback=payload
    offset += 8 + length
assert scrollback is not None
assert struct.unpack('>I', scrollback[8:12])[0] > 0
assert marker in scrollback
PY

delete_open=$(run_probe document open --context-id "$context_one" --environment-id "$environment_id" --path delete.txt)
delete_document_id=$(json_field "$delete_open" result.documentID)
delete_edit=$(run_probe document edit --context-id "$context_one" --environment-id "$environment_id" --document-id "$delete_document_id" --offset 11 --length 0 --text DIRTY)
[[ "$(json_field "$delete_edit" result.dirtyState)" == dirty ]]
dirty_deletion=$(run_probe conversation delete --conversation-id "$conversation_one" --document-id "$delete_document_id")
[[ "$(json_field "$dirty_deletion" result.deleted)" == false ]]
[[ "$(json_field "$dirty_deletion" result.dirtyDocumentCount)" == 1 ]]
[[ "$(json_field "$dirty_deletion" result.dirtyDocumentID)" == "$delete_document_id" ]]
delete_saved=$(run_probe document save --context-id "$context_one" --environment-id "$environment_id" --document-id "$delete_document_id")
[[ "$(json_field "$delete_saved" result.dirtyState)" == clean ]]

force_required=$(run_probe conversation delete --conversation-id "$conversation_one" --document-id "$delete_document_id")
[[ "$(json_field "$force_required" result.deleted)" == false ]]
[[ "$(json_field "$force_required" result.normalTerminationAttempted)" == true ]]
[[ "$(json_field "$force_required" result.forceRequired)" == true ]]
deletion_operation=$(json_field "$force_required" result.operationID)
/bin/launchctl kill SIGKILL "$domain/$host_label"
/bin/launchctl kill SIGKILL "$domain/$terminal_label"
/bin/launchctl kickstart "$domain/$host_label"
wait_services >/dev/null
deletion=$(run_probe conversation delete --conversation-id "$conversation_one" \
  --resume-operation-id "$deletion_operation" --force)
[[ "$(json_field "$deletion" result.deleted)" == true ]]
[[ "$(json_field "$deletion" result.operationID)" == "$deletion_operation" ]]
[[ "$(json_field "$deletion" result.projectID)" == "$project_id" ]]
[[ "$(json_field "$deletion" result.environmentID)" == "$environment_id" ]]
deleted_terminal_contexts=$(json_field "$deletion" result.workspaceContextID)
[[ "$deleted_terminal_contexts" == "$context_one" ]]
retained=$(run_probe workspace snapshot)
[[ "$(json_count "$retained" result.projects)" == 1 ]]
[[ "$(json_field "$retained" result.projects.0.projectID)" == "$project_id" ]]
[[ "$(json_field "$retained" result.projects.0.environmentID)" == "$environment_id" ]]
[[ "$(json_field "$retained" result.projects.0.conversationCount)" == 1 ]]
retained_tree=$(run_probe file tree --context-id "$project_context" --environment-id "$environment_id" --path .)
[[ "$(json_canonical "$retained_tree" result.entries)" == *moved.txt* ]]
[[ -e "$project_root/moved.txt" && -e "$project_root/recovery.txt" && -e "$project_root/delete.txt" ]]

print -- "phase 1 direct workspace: namespace=$namespace project=$project_id environment=$environment_id conversations=$conversation_one,$conversation_two sessions=$codex_session,$other_session keeper=$keeper_before cli=$cli_before sequence=$(json_field "$after" result.latestSequence) operation=$deletion_operation apps=$app_one_pid,$app_two_pid,$app_three_pid"
