#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
domain="gui/$(/usr/bin/id -u)"
user_cache_root="$HOME/Library/Caches"
fixture_root=$(/usr/bin/mktemp -d "$user_cache_root/cockpit-terminal-app-reattach.XXXXXX")
probe_source="$fixture_root/reattach-probe.c"
probe_executable="$fixture_root/reattach-probe"
keeper_pid=""
cli_process_group=""

cleanup() {
  if [[ -n "$cli_process_group" ]]; then
    /bin/kill -KILL -- "-$cli_process_group" >/dev/null 2>&1 || true
  fi
  if [[ -n "$keeper_pid" ]]; then
    /bin/kill -TERM "$keeper_pid" >/dev/null 2>&1 || true
    for _ in {1..100}; do
      /bin/kill -0 "$keeper_pid" >/dev/null 2>&1 || break
      /bin/sleep 0.05
    done
    /bin/kill -KILL "$keeper_pid" >/dev/null 2>&1 || true
  fi
  "$repo_root/Tools/phase0-services.zsh" stop >/dev/null 2>&1 || true
  [[ ! -e "$fixture_root" ]] || /bin/rm -rf -- "$fixture_root"
}
trap cleanup EXIT

/bin/chmod 700 "$fixture_root"
/bin/cat > "$probe_source" <<'C'
#include <termios.h>
#include <unistd.h>

int main(void) {
  static const char ready[] = "READY\n";
  static const char consumed[] = "CONSUMED:";
  char bytes[256];
  struct termios settings;
  if (tcgetattr(STDIN_FILENO, &settings) == 0) {
    settings.c_lflag &= (tcflag_t)~(ECHO | ICANON);
    settings.c_cc[VMIN] = 1;
    settings.c_cc[VTIME] = 0;
    (void)tcsetattr(STDIN_FILENO, TCSANOW, &settings);
  }
  (void)write(STDOUT_FILENO, ready, sizeof(ready) - 1);
  for (;;) {
    ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count <= 0) return 0;
    (void)write(STDOUT_FILENO, consumed, sizeof(consumed) - 1);
    (void)write(STDOUT_FILENO, bytes, (size_t)count);
  }
}
C
/usr/bin/clang "$probe_source" -o "$probe_executable"
/bin/chmod 700 "$probe_executable"

"$repo_root/Tools/phase0-services.zsh" start
"$repo_root/Tools/phase0-services.zsh" probe >/dev/null
service_root_record="$repo_root/.build/phase0-launchagents/service-root.path"
IFS= read -r service_root < "$service_root_record"
runtime_directory="$service_root/runtime"
probe="$service_root/bin/CockpitProbe"
/usr/bin/sqlite3 "$service_root/storage/terminal.sqlite" \
  "INSERT INTO agent_executables (profile_id, canonical_path) VALUES ('codex', '$probe_executable')"

if ! receipt=$(
  "$probe" create-terminal \
    "$runtime_directory" \
    "$fixture_root" \
    "$probe_executable"
); then
  /usr/bin/sqlite3 -header -column "$service_root/storage/terminal.sqlite" \
    'SELECT session_id, worker_id, lifecycle_state, process_id, process_group_id FROM terminal_sessions' \
    >&2
  exit 1
fi
IFS=$'\t' read -r session_id worker_id descriptor_path project_id environment_id \
  <<< "$receipt"

for _ in {1..100}; do
  [[ -f "$descriptor_path" ]] && break
  /bin/sleep 0.05
done
[[ -f "$descriptor_path" ]]
keeper_pid=$(/usr/bin/plutil -extract processID raw -o - "$descriptor_path")
[[ "$keeper_pid" == <-> ]]
/bin/kill -0 "$keeper_pid"

cli_pid=""
for _ in {1..100}; do
  cli_pid=$(/usr/bin/pgrep -P "$keeper_pid" | /usr/bin/head -n 1 || true)
  [[ -n "$cli_pid" ]] && break
  /bin/sleep 0.05
done
[[ "$cli_pid" == <-> ]]
cli_process_group=$(/bin/ps -o pgid= -p "$cli_pid" | /usr/bin/tr -d ' ')
[[ "$cli_process_group" == "$cli_pid" ]]

first_client="00000000-0000-4000-8000-000000000101"
first_result=$(
  "$probe" terminal-viewer \
    "$runtime_directory" \
    "$session_id" \
    "$project_id" \
    "$environment_id" \
    "$first_client" \
    read
)
IFS=$'\t' read -r first_reported_client first_app_pid first_session \
  first_sequence first_kind first_marker <<< "$first_result"
[[ "${first_reported_client:l}" == "${first_client:l}" ]]
[[ "${first_session:l}" == "${session_id:l}" ]]
[[ "$first_app_pid" == <-> ]]
[[ "$first_sequence" == <-> && "$first_sequence" -gt 0 ]]
[[ "$first_kind" == snapshot ]]
[[ "$first_marker" == none ]]
/bin/kill -0 "$keeper_pid"
/bin/kill -0 "$cli_pid"

second_client="00000000-0000-4000-8000-000000000102"
marker="marker-$RANDOM-$RANDOM"
second_result=$(
  "$probe" terminal-viewer \
    "$runtime_directory" \
    "$session_id" \
    "$project_id" \
    "$environment_id" \
    "$second_client" \
    write \
    "$marker"
)
IFS=$'\t' read -r second_reported_client second_app_pid second_session \
  second_sequence second_kind second_marker <<< "$second_result"
[[ "${second_reported_client:l}" == "${second_client:l}" ]]
[[ "${second_session:l}" == "${session_id:l}" ]]
[[ "$second_app_pid" == <-> ]]
[[ "$second_app_pid" != "$first_app_pid" ]]
[[ "$second_sequence" == <-> && "$second_sequence" -gt "$first_sequence" ]]
[[ "$second_marker" == "$marker" ]]

after_keeper_pid=$(/usr/bin/plutil -extract processID raw -o - "$descriptor_path")
after_cli_pid=$(/usr/bin/pgrep -P "$keeper_pid" | /usr/bin/head -n 1)
after_cli_process_group=$(/bin/ps -o pgid= -p "$after_cli_pid" | /usr/bin/tr -d ' ')
[[ "$after_keeper_pid" == "$keeper_pid" ]]
[[ "$after_cli_pid" == "$cli_pid" ]]
[[ "$after_cli_process_group" == "$cli_process_group" ]]
/bin/kill -0 "$keeper_pid"
/bin/kill -0 "$cli_pid"

print -r -- \
  "terminal app reattach: session=$session_id worker=$worker_id keeper=$keeper_pid cli=$cli_pid apps=$first_app_pid,$second_app_pid marker=$marker"
