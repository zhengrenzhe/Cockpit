#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

repo_root=${0:P:h:h:h}
source_bootstrap="$repo_root/Tools/bootstrap-zig.zsh"
source_manifest="$repo_root/Config/Toolchains/ghostty.env"
project_archive="$repo_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz"
installed_zig="$repo_root/.tools/zig/0.16.0/zig"
suite_root=$(/usr/bin/mktemp -d /tmp/cockpit-zig-hardening.XXXXXX)
global_temp_baseline="$suite_root/global-temp-baseline"

fail() {
  print -u2 -- "$1"
  exit 1
}

cleanup() {
  local rc=$?
  if [[ -n "$suite_root" && -d "$suite_root" && ! -L "$suite_root" && "$suite_root" == /tmp/cockpit-zig-hardening.* ]]; then
    /bin/rm -rf "$suite_root"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

[[ -f "$source_bootstrap" && ! -L "$source_bootstrap" ]] || fail "missing physical Zig bootstrap"
[[ -f "$source_manifest" && ! -L "$source_manifest" ]] || fail "missing physical Ghostty manifest"
[[ -f "$project_archive" && ! -L "$project_archive" ]] || fail "missing physical project Zig archive"
[[ -x "$installed_zig" && ! -L "$installed_zig" ]] || fail "missing physical existing Zig installation"
[[ "$("$installed_zig" version)" == "0.16.0" ]] || fail "existing Zig version mismatch"
/usr/bin/codesign --verify --strict "$installed_zig" >/dev/null || fail "existing Zig code signature is invalid"
/usr/bin/find -P /private/tmp -maxdepth 1 -name 'cockpit-zig.*' -print | /usr/bin/sort > "$global_temp_baseline"

assert_no_new_global_temp() {
  local current="$suite_root/global-temp-current"
  /usr/bin/find -P /private/tmp -maxdepth 1 -name 'cockpit-zig.*' -print | /usr/bin/sort > "$current"
  /usr/bin/cmp -s "$global_temp_baseline" "$current" || fail "bootstrap leaked a global /private/tmp/cockpit-zig.* path"
}

prepare_root() {
  local root="$1"
  /bin/mkdir -p "$root/Tools" "$root/Config/Toolchains" "$root/.tools/archives"
  /bin/cp "$source_bootstrap" "$root/Tools/bootstrap-zig.zsh"
  /bin/cp "$source_manifest" "$root/Config/Toolchains/ghostty.env"
  /bin/chmod 700 "$root/Tools/bootstrap-zig.zsh"
  /bin/ln "$project_archive" "$root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz"
}

assert_valid_install() {
  local root="$1" zig="$1/.tools/zig/0.16.0/zig"
  [[ -x "$zig" && ! -L "$zig" ]] || fail "missing physical Zig compiler in $root"
  [[ "$("$zig" version)" == "0.16.0" ]] || fail "Zig version mismatch in $root"
  /usr/bin/codesign --verify --strict "$zig" >/dev/null || fail "Zig code signature is invalid in $root"
}

assert_no_bootstrap_residue() {
  local root="$1" residue
  residue=$(/usr/bin/find "$root/.tools/zig" -maxdepth 1 \( -name '.bootstrap-lock' -o -name '.bootstrap-owner.*' -o -name '.preparing.*' -o -name '.staging.*' \) -print -quit)
  [[ -z "$residue" ]] || fail "bootstrap residue remains: $residue"
}

run_expect_failure() {
  local root="$1" label="$2"
  local stdout_file="$suite_root/$label.stdout" stderr_file="$suite_root/$label.stderr"
  local started finished rc
  started=$(/bin/date +%s)
  set +e
  "$root/Tools/bootstrap-zig.zsh" --archive "$root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  finished=$(/bin/date +%s)
  [[ "$rc" != "0" ]] || fail "$label unexpectedly succeeded"
  (( finished - started <= 5 )) || fail "$label did not fail immediately"
}

# A fake PATH must not replace any verifier/bootstrap dependency. The fresh
# bootstrap also proves that the repository-local physical archive is selected
# without a network operation.
print -- "hardening stage: PATH and offline archive"
fake_bin="$suite_root/fake-bin"
marker_dir="$suite_root/path-markers"
/bin/mkdir "$fake_bin" "$marker_dir"
for tool_name in codesign shasum tar curl stat xattr git grep awk sed find mktemp chmod cp mv rm rmdir mkdir ln sleep ps uname uuidgen date cmp; do
  /usr/bin/printf '#!/bin/zsh\n/usr/bin/touch "$COCKPIT_ZIG_TEST_MARKER_DIR/%s"\nexit 97\n' "$tool_name" > "$fake_bin/$tool_name"
  /bin/chmod 700 "$fake_bin/$tool_name"
done
COCKPIT_ZIG_TEST_MARKER_DIR="$marker_dir" PATH="$fake_bin:$PATH" "$repo_root/Tools/verify-ghostty.zsh" > "$suite_root/path-verifier.stdout" 2> "$suite_root/path-verifier.stderr"
path_root="$suite_root/path-root"
prepare_root "$path_root"
COCKPIT_ZIG_TEST_MARKER_DIR="$marker_dir" PATH="$fake_bin:$PATH" "$path_root/Tools/bootstrap-zig.zsh" > "$suite_root/path-bootstrap.stdout" 2> "$suite_root/path-bootstrap.stderr"
[[ -z "$(/usr/bin/find "$marker_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "PATH-injected command executed"
assert_valid_install "$path_root"
assert_no_bootstrap_residue "$path_root"
assert_no_new_global_temp
counter_log="${path_root:P}/.tools/zig/.test-events.counter"
print -- "hardening stage: deterministic lock counter"
set +e
COCKPIT_ZIG_BOOTSTRAP_TESTING=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS=0 \
COCKPIT_ZIG_BOOTSTRAP_TEST_EVENT_LOG="$counter_log" \
  "$path_root/Tools/bootstrap-zig.zsh" --archive "$path_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/counter.stdout" 2> "$suite_root/counter.stderr"
counter_rc=$?
set -e
[[ "$counter_rc" == "0" ]] || fail "test lock-wait counter bootstrap exited $counter_rc: $(< "$suite_root/counter.stderr")"
[[ -f "$counter_log" && "$(< "$counter_log")" == "lock-wait-count=0" ]] || fail "test lock-wait counter did not report zero"

# Production ignores every crash hook unless the explicit testing gate is 1.
print -- "hardening stage: production ignores test hooks"
production_root="$suite_root/production-hooks"
prepare_root "$production_root"
production_ignored_events="${production_root:P}/.tools/zig/.test-events.production-ignored"
set +e
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_CREATED=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_READY=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_CREATED=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_READY=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_OWNER_PUBLISHED=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_STAGING_PUBLISHED=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_LOCK_ACQUIRED=1 \
COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS=0 \
COCKPIT_ZIG_BOOTSTRAP_TEST_EVENT_LOG="$production_ignored_events" \
  "$production_root/Tools/bootstrap-zig.zsh" --archive "$production_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/production-hooks.stdout"
production_rc=$?
set -e
[[ "$production_rc" == "0" ]] || fail "production hook isolation bootstrap exited $production_rc"
assert_valid_install "$production_root"
assert_no_bootstrap_residue "$production_root"
[[ ! -e "$production_ignored_events" && ! -L "$production_ignored_events" ]] || fail "production honored test-only lock observability"
assert_no_new_global_temp

# The external wrapper records the real bootstrap PID/start identity before
# exec. Every complete owner record left by SIGKILL must match these bytes.
crash_wrapper="$suite_root/run-crash.zsh"
/usr/bin/printf '%s\n' \
  '#!/bin/zsh' \
  'set -euo pipefail' \
  'expected_owner=$1' \
  'bootstrap=$2' \
  'archive=$3' \
  'hook_name=$4' \
  '/usr/bin/printf "%s\\n" "$$" > "$expected_owner"' \
  '/bin/ps -o lstart= -p "$$" | /usr/bin/sed "s/^ *//" >> "$expected_owner"' \
  'export COCKPIT_ZIG_BOOTSTRAP_TESTING=1' \
  'typeset -gx "${hook_name}=1"' \
  'exec "$bootstrap" --archive "$archive"' > "$crash_wrapper"
/bin/chmod 700 "$crash_wrapper"

assert_owner_records_match() {
  local root="$1" expected="$2" record count=0
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    [[ "$(/usr/bin/stat -f %z "$record")" != "0" ]] || continue
    /usr/bin/cmp -s "$record" "$expected" || fail "owner metadata does not identify the main bootstrap: $record"
    (( count += 1 ))
  done < <(
    /usr/bin/find "$root/.tools/zig" -maxdepth 1 -type f \( -name '.bootstrap-lock' -o -name '.bootstrap-owner.*' -o -name '.preparing.owner.*' \) -print
    /usr/bin/find "$root/.tools/zig" -maxdepth 2 -type f -name '.owner' \( -path '*/.staging.*/*' -o -path '*/.preparing.staging.*/*' \) -print
  )
  print -r -- "$count"
}

typeset -a crash_hooks
crash_hooks=(
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_CREATED
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_READY
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_CREATED
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_READY
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_OWNER_PUBLISHED
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_STAGING_PUBLISHED
  COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_LOCK_ACQUIRED
)

for hook_name in "${crash_hooks[@]}"; do
  print -- "hardening stage: crash $hook_name"
  case_root="$suite_root/crash-${hook_name##*_}"
  prepare_root "$case_root"
  expected_owner="$case_root/expected-owner"
  set +e
  "$crash_wrapper" "$expected_owner" "$case_root/Tools/bootstrap-zig.zsh" "$case_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" "$hook_name" > "$case_root/crash.stdout" 2> "$case_root/crash.stderr" &
  crash_pid=$!
  wait "$crash_pid"
  crash_rc=$?
  set -e
  [[ "$crash_rc" == "137" ]] || fail "$hook_name did not terminate via SIGKILL; exit $crash_rc"
  [[ -f "$expected_owner" && "$(/usr/bin/wc -l < "$expected_owner" | /usr/bin/tr -d ' ')" == "2" ]] || fail "$hook_name did not record main bootstrap identity"

  residue=$(/usr/bin/find "$case_root/.tools/zig" -maxdepth 1 \( -name '.bootstrap-lock' -o -name '.bootstrap-owner.*' -o -name '.preparing.*' -o -name '.staging.*' \) -print -quit)
  [[ -n "$residue" ]] || fail "$hook_name did not leave the crash window residue"
  owner_count=$(assert_owner_records_match "$case_root" "$expected_owner")
  case "$hook_name" in
    *PREPARING_OWNER_READY|*PREPARING_STAGING_READY|*OWNER_PUBLISHED|*STAGING_PUBLISHED|*LOCK_ACQUIRED)
      (( owner_count >= 1 )) || fail "$hook_name left no complete owner metadata"
      ;;
  esac

  recovery_events="${case_root:P}/.tools/zig/.test-events.recovery"
  COCKPIT_ZIG_BOOTSTRAP_TESTING=1 \
  COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS=0 \
  COCKPIT_ZIG_BOOTSTRAP_TEST_EVENT_LOG="$recovery_events" \
    "$case_root/Tools/bootstrap-zig.zsh" --archive "$case_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$case_root/recovery.stdout" 2> "$case_root/recovery.stderr"
  [[ -f "$recovery_events" && "$(< "$recovery_events")" == "lock-wait-count=0" ]] || fail "$hook_name entered the lock-wait path"
  assert_valid_install "$case_root"
  assert_no_bootstrap_residue "$case_root"
  assert_no_new_global_temp
  /bin/rm -rf "$case_root"
done

# Exact empty legacy residue and complete dead-owner residue are recoverable.
print -- "hardening stage: legacy, dead, and active residue"
residue_root="$suite_root/residue-root"
prepare_root "$residue_root"
"$residue_root/Tools/bootstrap-zig.zsh" --archive "$residue_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/residue-install.stdout"
zig_parent="$residue_root/.tools/zig"
/usr/bin/touch "$zig_parent/.bootstrap-owner.legacy-empty" "$zig_parent/.bootstrap-lock" "$zig_parent/.preparing.owner.legacy-empty"
/bin/mkdir "$zig_parent/.staging.legacy-empty" "$zig_parent/.preparing.staging.legacy-empty" "$zig_parent/.preparing.temp.legacy-empty"
"$residue_root/Tools/bootstrap-zig.zsh" --archive "$residue_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/legacy-recovery.stdout"
assert_no_bootstrap_residue "$residue_root"

dead_metadata="$suite_root/dead-owner"
/usr/bin/printf '%s\n%s\n' '999999999' 'Thu Jan  1 00:00:00 1970' > "$dead_metadata"
/bin/cp "$dead_metadata" "$zig_parent/.bootstrap-owner.dead"
/bin/cp "$dead_metadata" "$zig_parent/.bootstrap-lock"
/bin/cp "$dead_metadata" "$zig_parent/.preparing.owner.dead"
/bin/mkdir "$zig_parent/.staging.dead" "$zig_parent/.preparing.staging.dead"
/bin/cp "$dead_metadata" "$zig_parent/.staging.dead/.owner"
/bin/cp "$dead_metadata" "$zig_parent/.preparing.staging.dead/.owner"
dead_token=$(print -rn -- 'Thu Jan  1 00:00:00 1970' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
dead_temp="$zig_parent/.preparing.temp.999999999.${dead_token}.DEAD"
/bin/mkdir "$dead_temp"
/usr/bin/printf 'dead temp payload\n' > "$dead_temp/sentinel"
"$residue_root/Tools/bootstrap-zig.zsh" --archive "$residue_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/dead-recovery.stdout"
assert_no_bootstrap_residue "$residue_root"

# Complete active owner/lock/staging/preparing records, plus active empty
# preparing paths whose names carry PID/start identity, survive two concurrent
# validation-only bootstraps without error.
active_owner="$suite_root/active-owner"
active_start=$(/bin/ps -o lstart= -p "$$" | /usr/bin/sed 's/^ *//')
/usr/bin/printf '%s\n%s\n' "$$" "$active_start" > "$active_owner"
active_token=$(print -rn -- "$active_start" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
/bin/cp "$active_owner" "$zig_parent/.bootstrap-owner.active"
/bin/ln "$zig_parent/.bootstrap-owner.active" "$zig_parent/.bootstrap-lock"
/bin/cp "$active_owner" "$zig_parent/.preparing.owner.active"
/bin/mkdir "$zig_parent/.staging.active" "$zig_parent/.preparing.staging.active"
/bin/cp "$active_owner" "$zig_parent/.staging.active/.owner"
/bin/cp "$active_owner" "$zig_parent/.preparing.staging.active/.owner"
active_empty_owner="$zig_parent/.preparing.owner.$$.${active_token}.ACTIVE"
active_empty_staging="$zig_parent/.preparing.staging.$$.${active_token}.ACTIVE"
active_temp="$zig_parent/.preparing.temp.$$.${active_token}.ACTIVE"
/usr/bin/touch "$active_empty_owner"
/bin/mkdir "$active_empty_staging" "$active_temp"
/usr/bin/printf 'active temp payload\n' > "$active_temp/sentinel"
"$residue_root/Tools/bootstrap-zig.zsh" --archive "$residue_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/active-a.stdout" 2> "$suite_root/active-a.stderr" &
active_a=$!
"$residue_root/Tools/bootstrap-zig.zsh" --archive "$residue_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/active-b.stdout" 2> "$suite_root/active-b.stderr" &
active_b=$!
set +e
wait "$active_a"; active_a_rc=$?
wait "$active_b"; active_b_rc=$?
set -e
[[ "$active_a_rc" == "0" && "$active_b_rc" == "0" ]] || fail "active residue concurrent validation failed: $active_a_rc/$active_b_rc"
for active_path in "$zig_parent/.bootstrap-owner.active" "$zig_parent/.bootstrap-lock" "$zig_parent/.preparing.owner.active" "$zig_parent/.staging.active" "$zig_parent/.preparing.staging.active" "$active_empty_owner" "$active_empty_staging" "$active_temp"; do
  [[ -e "$active_path" && ! -L "$active_path" ]] || fail "active residue was removed: $active_path"
done
/bin/rm -f "$zig_parent/.bootstrap-lock" "$zig_parent/.bootstrap-owner.active" "$zig_parent/.preparing.owner.active" "$active_empty_owner"
/bin/rm -rf "$zig_parent/.staging.active" "$zig_parent/.preparing.staging.active" "$active_empty_staging" "$active_temp"
assert_no_bootstrap_residue "$residue_root"

# Symlink residue is rejected without following or changing its target.
print -- "hardening stage: symlink residue rejection"
typeset -a symlink_cases
symlink_cases=(owner lock staging preparing-owner preparing-staging preparing-temp)
for symlink_case in "${symlink_cases[@]}"; do
  target="$suite_root/symlink-target-$symlink_case"
  case "$symlink_case" in
    staging|preparing-staging|preparing-temp)
      /bin/mkdir "$target"
      /usr/bin/printf 'external-%s\n' "$symlink_case" > "$target/sentinel"
      ;;
    *)
      /usr/bin/printf 'external-%s\n' "$symlink_case" > "$target"
      ;;
  esac
  case "$symlink_case" in
    owner) residue_path="$zig_parent/.bootstrap-owner.symlink" ;;
    lock) residue_path="$zig_parent/.bootstrap-lock" ;;
    staging) residue_path="$zig_parent/.staging.symlink" ;;
    preparing-owner) residue_path="$zig_parent/.preparing.owner.symlink" ;;
    preparing-staging) residue_path="$zig_parent/.preparing.staging.symlink" ;;
    preparing-temp) residue_path="$zig_parent/.preparing.temp.symlink" ;;
  esac
  /bin/ln -s "$target" "$residue_path"
  run_expect_failure "$residue_root" "symlink-$symlink_case"
  [[ -L "$residue_path" ]] || fail "symlink residue was deleted: $symlink_case"
  case "$symlink_case" in
    staging|preparing-staging|preparing-temp) [[ "$(< "$target/sentinel")" == "external-$symlink_case" ]] || fail "symlink directory target changed: $symlink_case" ;;
    *) [[ "$(< "$target")" == "external-$symlink_case" ]] || fail "symlink file target changed: $symlink_case" ;;
  esac
  /bin/rm -f "$residue_path"
done

# Nonempty malformed/unowned physical residue is rejected and retained.
print -- "hardening stage: malformed residue rejection"
typeset -a malformed_cases
malformed_cases=(owner lock staging preparing-owner preparing-staging preparing-temp)
for malformed_case in "${malformed_cases[@]}"; do
  case "$malformed_case" in
    owner)
      residue_path="$zig_parent/.bootstrap-owner.malformed"
      /usr/bin/printf 'sentinel-owner\n' > "$residue_path"
      sentinel_path="$residue_path"
      ;;
    lock)
      residue_path="$zig_parent/.bootstrap-lock"
      /usr/bin/printf 'sentinel-lock\n' > "$residue_path"
      sentinel_path="$residue_path"
      ;;
    staging)
      residue_path="$zig_parent/.staging.malformed"
      /bin/mkdir "$residue_path"
      /usr/bin/printf 'sentinel-staging\n' > "$residue_path/sentinel"
      sentinel_path="$residue_path/sentinel"
      ;;
    preparing-owner)
      residue_path="$zig_parent/.preparing.owner.malformed"
      /usr/bin/printf 'sentinel-preparing-owner\n' > "$residue_path"
      sentinel_path="$residue_path"
      ;;
    preparing-staging)
      residue_path="$zig_parent/.preparing.staging.malformed"
      /bin/mkdir "$residue_path"
      /usr/bin/printf 'sentinel-preparing-staging\n' > "$residue_path/sentinel"
      sentinel_path="$residue_path/sentinel"
      ;;
    preparing-temp)
      residue_path="$zig_parent/.preparing.temp.malformed"
      /bin/mkdir "$residue_path"
      /usr/bin/printf 'sentinel-preparing-temp\n' > "$residue_path/sentinel"
      sentinel_path="$residue_path/sentinel"
      ;;
  esac
  before_sha=$(/usr/bin/shasum -a 256 "$sentinel_path" | /usr/bin/awk '{print $1}')
  run_expect_failure "$residue_root" "malformed-$malformed_case"
  after_sha=$(/usr/bin/shasum -a 256 "$sentinel_path" | /usr/bin/awk '{print $1}')
  [[ "$after_sha" == "$before_sha" ]] || fail "malformed residue changed: $malformed_case"
  case "$malformed_case" in
    staging|preparing-staging|preparing-temp) /bin/rm -rf "$residue_path" ;;
    *) /bin/rm -f "$residue_path" ;;
  esac
done

# Two fresh bootstraps race through extraction and publication. Both succeed,
# their shared result is signed Zig 0.16.0, and all ownership state is gone.
print -- "hardening stage: fresh concurrent bootstrap"
concurrent_root="$suite_root/concurrent-root"
prepare_root "$concurrent_root"
"$concurrent_root/Tools/bootstrap-zig.zsh" --archive "$concurrent_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/concurrent-a.stdout" 2> "$suite_root/concurrent-a.stderr" &
concurrent_a=$!
"$concurrent_root/Tools/bootstrap-zig.zsh" --archive "$concurrent_root/.tools/archives/zig-aarch64-macos-0.16.0.tar.xz" > "$suite_root/concurrent-b.stdout" 2> "$suite_root/concurrent-b.stderr" &
concurrent_b=$!
set +e
wait "$concurrent_a"; concurrent_a_rc=$?
wait "$concurrent_b"; concurrent_b_rc=$?
set -e
[[ "$concurrent_a_rc" == "0" && "$concurrent_b_rc" == "0" ]] || fail "fresh concurrent bootstrap failed: $concurrent_a_rc/$concurrent_b_rc"
assert_valid_install "$concurrent_root"
assert_no_bootstrap_residue "$concurrent_root"
assert_no_new_global_temp

print -- "Zig bootstrap PATH, offline, crash recovery, ownership, residue, and concurrency hardening verified"
