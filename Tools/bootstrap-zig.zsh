#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_path=${0:P}
repo_root=${script_path:h:h}
manifest="$repo_root/Config/Toolchains/ghostty.env"
archive_override=''

fail() {
  print -u2 -- "$1"
  exit 1
}

case "$#" in
  0) ;;
  2)
    [[ "$1" == "--archive" ]] || fail "usage: $0 [--archive <physical-path>]"
    [[ -f "$2" && ! -L "$2" ]] || fail "archive override is not a physical regular file: $2"
    archive_override=${2:P}
    ;;
  *) fail "usage: $0 [--archive <physical-path>]" ;;
esac

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "Phase 0 Zig bootstrap supports Darwin only"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Phase 0 Zig bootstrap supports arm64 macOS only"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "missing manifest: $manifest"

typeset -a expected_manifest_lines
expected_manifest_lines=(
  'GHOSTTY_VERSION=1.3.1'
  'GHOSTTY_TAG=v1.3.1'
  'GHOSTTY_TAG_OBJECT=22efb0be2bbea73e5339f5426fa3b20edabcaa11'
  'GHOSTTY_COMMIT=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28'
  'GHOSTTY_REPOSITORY_URL=https://github.com/ghostty-org/ghostty.git'
  'ZIG_VERSION=0.15.2'
  'ZIG_AARCH64_MACOS_URL=https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz'
  'ZIG_AARCH64_MACOS_SHA256=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b'
  'ZIG_AARCH64_MACOS_SIZE=50635984'
)
for expected_line in "${expected_manifest_lines[@]}"; do
  [[ "$(/usr/bin/grep -Fxc -- "$expected_line" "$manifest")" == "1" ]] || fail "manifest value is missing, duplicated, or changed: $expected_line"
done
[[ "$(/usr/bin/wc -l < "$manifest" | /usr/bin/tr -d ' ')" == "${#expected_manifest_lines[@]}" ]] || fail "manifest contains an unexpected assignment"
! /usr/bin/grep -Fq '$(' "$manifest" || fail "manifest contains shell command substitution"
! /usr/bin/grep -Fq $'\x60' "$manifest" || fail "manifest contains shell command substitution"
source "$manifest"

tools_root="$repo_root/.tools"
zig_parent="$tools_root/zig"
archive_dir="$tools_root/archives"
project_archive="$archive_dir/zig-aarch64-macos-0.15.2.tar.xz"
install_root="$zig_parent/$ZIG_VERSION"
zig_binary="$install_root/zig"
lock_file="$zig_parent/.bootstrap-lock"

bootstrap_pid=$$
bootstrap_start=$(/bin/ps -o lstart= -p "$bootstrap_pid" | /usr/bin/sed 's/^ *//')
[[ -n "$bootstrap_start" ]] || fail "could not determine Zig bootstrap process identity"
bootstrap_start_token=$(print -rn -- "$bootstrap_start" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
[[ "$bootstrap_start_token" =~ '^[0-9a-f]{64}$' ]] || fail "could not encode Zig bootstrap process identity"

staging_dir=''
temp_dir=''
lock_candidate=''
preparing_path=''
lock_owned=0
lock_wait_count=0
testing=0
[[ "${COCKPIT_ZIG_BOOTSTRAP_TESTING:-}" == "1" ]] && testing=1
test_validation_only=0
[[ "$testing" == "1" && -n "${COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE:-}" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_EXPECT_FAILURE:-}" == "1" ]] && test_validation_only=1
test_force_full=0
[[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_FORCE_FULL:-}" == "1" ]] && test_force_full=1
test_max_lock_waits=''
test_event_log=''
test_event_log_inode=''
if [[ "$testing" == "1" ]]; then
  if [[ -n "${COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS:-}" ]]; then
    [[ "$COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS" == <-> ]] || fail "test max lock waits must be a nonnegative integer"
    test_max_lock_waits="$COCKPIT_ZIG_BOOTSTRAP_TEST_MAX_LOCK_WAITS"
  fi
  [[ -z "${COCKPIT_ZIG_BOOTSTRAP_TEST_EVENT_LOG:-}" ]] || test_event_log="$COCKPIT_ZIG_BOOTSTRAP_TEST_EVENT_LOG"
fi

is_physical_directory_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || return 1
  [[ ! -e "$path" ]] || [[ -d "$path" ]]
}

path_is_absent() {
  [[ ! -e "$1" && ! -L "$1" ]]
}

validate_installed_compiler() {
  [[ -d "$install_root" && ! -L "$install_root" ]] || return 1
  [[ -x "$zig_binary" && ! -L "$zig_binary" ]] || return 1
  /usr/bin/codesign --verify --strict "$zig_binary" >/dev/null 2>&1 || return 1
  [[ "$("$zig_binary" version)" == "$ZIG_VERSION" ]]
}

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$preparing_path" && ! -L "$preparing_path" ]]; then
    if [[ -f "$preparing_path" && "$preparing_path" == "$zig_parent"/.preparing.owner.* ]]; then
      /bin/rm -f "$preparing_path"
    elif [[ -d "$preparing_path" && "$preparing_path" == "$zig_parent"/.preparing.staging.* ]]; then
      /bin/rm -rf "$preparing_path"
    fi
  fi
  if [[ -n "$staging_dir" && -d "$staging_dir" && ! -L "$staging_dir" && "$staging_dir" == "$zig_parent"/.staging.* ]]; then
    /bin/rm -rf "$staging_dir"
  fi
  if [[ -n "$temp_dir" && -d "$temp_dir" && ! -L "$temp_dir" && "$temp_dir" == "$zig_parent"/.preparing.temp.* ]]; then
    /bin/rm -rf "$temp_dir"
  fi
  if [[ "$lock_owned" == "1" && -n "$lock_candidate" && -f "$lock_candidate" && ! -L "$lock_candidate" ]]; then
    local lock_inode candidate_inode
    lock_inode=$(/usr/bin/stat -f %i "$lock_file" 2>/dev/null || true)
    candidate_inode=$(/usr/bin/stat -f %i "$lock_candidate" 2>/dev/null || true)
    if [[ -n "$lock_inode" && "$lock_inode" == "$candidate_inode" && -f "$lock_file" && ! -L "$lock_file" ]]; then
      /bin/rm -f "$lock_file"
    fi
  fi
  if [[ -n "$lock_candidate" && -f "$lock_candidate" && ! -L "$lock_candidate" && "$lock_candidate" == "$zig_parent"/.bootstrap-owner.* ]]; then
    /bin/rm -f "$lock_candidate"
  fi
  if [[ -n "$test_event_log" && -n "$test_event_log_inode" && -f "$test_event_log" && ! -L "$test_event_log" ]]; then
    local current_event_inode
    current_event_inode=$(/usr/bin/stat -f %i "$test_event_log" 2>/dev/null || true)
    if [[ "$current_event_inode" == "$test_event_log_inode" ]]; then
      /usr/bin/printf 'lock-wait-count=%s\n' "$lock_wait_count" > "$test_event_log"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

crash_at_test_point() {
  local point="$1" requested=0
  [[ "$testing" == "1" ]] || return 0
  case "$point" in
    preparing-owner-created) [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_CREATED:-}" == "1" ]] && requested=1 ;;
    preparing-owner-ready) [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_OWNER_READY:-}" == "1" ]] && requested=1 ;;
    preparing-staging-created) [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_CREATED:-}" == "1" ]] && requested=1 ;;
    preparing-staging-ready) [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_PREPARING_STAGING_READY:-}" == "1" ]] && requested=1 ;;
    owner-published)
      if [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_OWNER_PUBLISHED:-}" == "1" || "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_CANDIDATE_PUBLISHED:-}" == "1" || "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_BEFORE_ACQUIRE:-}" == "1" ]]; then
        requested=1
      fi
      ;;
    staging-published) [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_STAGING_PUBLISHED:-}" == "1" ]] && requested=1 ;;
    lock-acquired)
      if [[ "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_LOCK_ACQUIRED:-}" == "1" || "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_AFTER_ACQUIRE:-}" == "1" ]]; then
        requested=1
      fi
      ;;
    *) fail "unknown Zig bootstrap test crash point: $point" ;;
  esac
  [[ "$requested" == "0" ]] || /bin/kill -KILL "$bootstrap_pid"
}

owner_metadata_is_well_formed() {
  local owner_file="$1" owner_pid owner_start
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_pid=$(/usr/bin/sed -n '1p' "$owner_file")
  owner_start=$(/usr/bin/sed -n '2p' "$owner_file")
  [[ "$owner_pid" == <-> && -n "$owner_start" && "$(/usr/bin/wc -l < "$owner_file" | /usr/bin/tr -d ' ')" == "2" ]]
}

owner_metadata_matches_bootstrap() {
  local owner_file="$1" owner_pid owner_start
  owner_metadata_is_well_formed "$owner_file" || return 1
  owner_pid=$(/usr/bin/sed -n '1p' "$owner_file")
  owner_start=$(/usr/bin/sed -n '2p' "$owner_file")
  [[ "$owner_pid" == "$bootstrap_pid" && "$owner_start" == "$bootstrap_start" ]]
}

owner_is_dead() {
  local owner_file="$1" owner_pid owner_start current_start
  owner_metadata_is_well_formed "$owner_file" || return 1
  owner_pid=$(/usr/bin/sed -n '1p' "$owner_file")
  owner_start=$(/usr/bin/sed -n '2p' "$owner_file")
  current_start=$(/bin/ps -o lstart= -p "$owner_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')
  [[ -z "$current_start" || "$current_start" != "$owner_start" ]]
}

preparing_name_has_owner_identity() {
  local leaf
  leaf=${1:t}
  [[ "$leaf" =~ '^\.preparing\.(owner|staging|temp)\.([0-9]+)\.([0-9a-f]{64})\.([A-Za-z0-9-]+)$' ]]
}

preparing_name_owner_is_active() {
  local path="$1" leaf kind owner_pid owner_token current_start current_token
  leaf=${path:t}
  [[ "$leaf" =~ '^\.preparing\.(owner|staging|temp)\.([0-9]+)\.([0-9a-f]{64})\.([A-Za-z0-9-]+)$' ]] || return 1
  kind=$match[1]
  owner_pid=$match[2]
  owner_token=$match[3]
  current_start=$(/bin/ps -o lstart= -p "$owner_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')
  [[ -n "$current_start" ]] || return 1
  current_token=$(print -rn -- "$current_start" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  [[ "$current_token" == "$owner_token" ]]
}

write_owner_metadata() {
  local owner_file="$1"
  /usr/bin/printf '%s\n%s\n' "$bootstrap_pid" "$bootstrap_start" > "$owner_file"
  owner_metadata_is_well_formed "$owner_file" || fail "could not create Zig bootstrap owner metadata"
}

prepare_owner_candidate() {
  local candidate uuid preparing_inode candidate_inode
  preparing_path=$(/usr/bin/mktemp "$zig_parent/.preparing.owner.$bootstrap_pid.$bootstrap_start_token.XXXXXX")
  [[ -f "$preparing_path" && ! -L "$preparing_path" ]] || fail "invalid Zig owner preparation"
  crash_at_test_point preparing-owner-created
  /bin/chmod 600 "$preparing_path"
  write_owner_metadata "$preparing_path"
  crash_at_test_point preparing-owner-ready
  preparing_inode=$(/usr/bin/stat -f %i "$preparing_path")
  uuid=$(/usr/bin/uuidgen)
  candidate="$zig_parent/.bootstrap-owner.$bootstrap_pid.$uuid"
  path_is_absent "$candidate" || fail "Zig owner publication target already exists: $candidate"
  /bin/mv -n "$preparing_path" "$candidate"
  path_is_absent "$preparing_path" || fail "owner candidate publication did not move the preparation"
  preparing_path=''
  [[ -f "$candidate" && ! -L "$candidate" ]] || fail "owner candidate publication failed"
  candidate_inode=$(/usr/bin/stat -f %i "$candidate")
  [[ "$candidate_inode" == "$preparing_inode" ]] || fail "owner candidate publication inode mismatch"
  owner_metadata_matches_bootstrap "$candidate" || fail "owner candidate publication identity mismatch"
  lock_candidate="$candidate"
  crash_at_test_point owner-published
}

prepare_staging_directory() {
  local candidate uuid preparing_inode candidate_inode
  preparing_path=$(/usr/bin/mktemp -d "$zig_parent/.preparing.staging.$bootstrap_pid.$bootstrap_start_token.XXXXXX")
  [[ -d "$preparing_path" && ! -L "$preparing_path" ]] || fail "invalid Zig staging preparation"
  crash_at_test_point preparing-staging-created
  write_owner_metadata "$preparing_path/.owner"
  crash_at_test_point preparing-staging-ready
  preparing_inode=$(/usr/bin/stat -f %i "$preparing_path")
  uuid=$(/usr/bin/uuidgen)
  candidate="$zig_parent/.staging.$bootstrap_pid.$uuid"
  path_is_absent "$candidate" || fail "Zig staging publication target already exists: $candidate"
  /bin/mv -n "$preparing_path" "$candidate"
  path_is_absent "$preparing_path" || fail "staging publication did not move the preparation"
  preparing_path=''
  [[ -d "$candidate" && ! -L "$candidate" && -f "$candidate/.owner" && ! -L "$candidate/.owner" ]] || fail "staging publication failed"
  candidate_inode=$(/usr/bin/stat -f %i "$candidate")
  [[ "$candidate_inode" == "$preparing_inode" ]] || fail "staging publication inode mismatch"
  owner_metadata_matches_bootstrap "$candidate/.owner" || fail "staging publication identity mismatch"
  staging_dir="$candidate"
  crash_at_test_point staging-published
}

reclaim_dead_owner_candidates() {
  local candidate size
  while IFS= read -r candidate; do
    path_is_absent "$candidate" && continue
    [[ ! -L "$candidate" ]] || fail "refusing symlinked Zig owner residue: $candidate"
    [[ -f "$candidate" ]] || { path_is_absent "$candidate" && continue; fail "invalid Zig owner residue: $candidate"; }
    size=$(/usr/bin/stat -f %z "$candidate" 2>/dev/null || true)
    [[ -n "$size" ]] || { path_is_absent "$candidate" && continue; fail "could not inspect Zig owner residue: $candidate"; }
    if [[ "$size" == "0" ]]; then
      /bin/rm -f "$candidate"
      continue
    fi
    owner_metadata_is_well_formed "$candidate" || { path_is_absent "$candidate" && continue; fail "malformed Zig owner residue: $candidate"; }
    owner_is_dead "$candidate" && /bin/rm -f "$candidate"
  done < <(/usr/bin/find "$zig_parent" -maxdepth 1 -name '.bootstrap-owner.*' -print)
}

reclaim_stale_lock() {
  path_is_absent "$lock_file" && return 0
  [[ ! -L "$lock_file" ]] || fail "refusing symlinked bootstrap lock: $lock_file"
  [[ -f "$lock_file" ]] || { path_is_absent "$lock_file" && return 0; fail "refusing non-file bootstrap lock: $lock_file"; }
  local size
  size=$(/usr/bin/stat -f %z "$lock_file" 2>/dev/null || true)
  [[ -n "$size" ]] || { path_is_absent "$lock_file" && return 0; fail "could not inspect bootstrap lock: $lock_file"; }
  if [[ "$size" == "0" ]]; then
    /bin/rm -f "$lock_file"
    return 0
  fi
  owner_metadata_is_well_formed "$lock_file" || { path_is_absent "$lock_file" && return 0; fail "malformed bootstrap lock: $lock_file"; }
  owner_is_dead "$lock_file" || return 1
  /bin/rm -f "$lock_file"
  reclaim_dead_owner_candidates
}

reclaim_dead_staging_dirs() {
  local candidate owner_file first_entry
  while IFS= read -r candidate; do
    path_is_absent "$candidate" && continue
    [[ ! -L "$candidate" ]] || fail "refusing symlinked Zig staging residue: $candidate"
    [[ -d "$candidate" && "$candidate" == "$zig_parent"/.staging.* ]] || { path_is_absent "$candidate" && continue; fail "invalid Zig staging residue: $candidate"; }
    first_entry=$(/usr/bin/find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
    path_is_absent "$candidate" && continue
    if [[ -z "$first_entry" ]]; then
      /bin/rm -rf "$candidate"
      continue
    fi
    owner_file="$candidate/.owner"
    owner_metadata_is_well_formed "$owner_file" || { path_is_absent "$candidate" && continue; fail "unowned nonempty Zig staging residue: $candidate"; }
    owner_is_dead "$owner_file" && /bin/rm -rf "$candidate"
  done < <(/usr/bin/find "$zig_parent" -maxdepth 1 -name '.staging.*' -print)
}

reclaim_preparing_paths() {
  local candidate owner_file size first_entry leaf
  while IFS= read -r candidate; do
    path_is_absent "$candidate" && continue
    [[ ! -L "$candidate" ]] || fail "refusing symlinked Zig preparation: $candidate"
    [[ "$candidate" == "$zig_parent"/.preparing.* ]] || fail "invalid Zig preparation: $candidate"
    leaf=${candidate:t}
    if preparing_name_has_owner_identity "$candidate"; then
      preparing_name_owner_is_active "$candidate" && continue
      case "$leaf" in
        .preparing.owner.*)
          [[ -f "$candidate" ]] || fail "invalid Zig file preparation: $candidate"
          /bin/rm -f "$candidate"
          ;;
        .preparing.staging.*|.preparing.temp.*)
          [[ -d "$candidate" ]] || fail "invalid Zig directory preparation: $candidate"
          /bin/rm -rf "$candidate"
          ;;
        *) fail "invalid owner-identified Zig preparation: $candidate" ;;
      esac
      continue
    fi
    if [[ "$leaf" == .preparing.temp.* ]]; then
      if [[ -d "$candidate" ]]; then
        first_entry=$(/usr/bin/find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
        path_is_absent "$candidate" && continue
        if [[ -z "$first_entry" ]]; then
          /bin/rm -rf "$candidate"
          continue
        fi
      fi
      fail "malformed Zig temp preparation: $candidate"
    fi
    if [[ -f "$candidate" ]]; then
      size=$(/usr/bin/stat -f %z "$candidate" 2>/dev/null || true)
      [[ -n "$size" ]] || { path_is_absent "$candidate" && continue; fail "could not inspect Zig owner preparation: $candidate"; }
      if [[ "$size" == "0" ]]; then
        /bin/rm -f "$candidate"
        continue
      fi
      owner_metadata_is_well_formed "$candidate" || { path_is_absent "$candidate" && continue; fail "malformed Zig owner preparation: $candidate"; }
      owner_is_dead "$candidate" && /bin/rm -f "$candidate"
      continue
    fi
    if [[ -d "$candidate" ]]; then
      first_entry=$(/usr/bin/find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
      path_is_absent "$candidate" && continue
      if [[ -z "$first_entry" ]]; then
        /bin/rm -rf "$candidate"
        continue
      fi
      owner_file="$candidate/.owner"
      owner_metadata_is_well_formed "$owner_file" || { path_is_absent "$candidate" && continue; fail "malformed Zig staging preparation: $candidate"; }
      owner_is_dead "$owner_file" && /bin/rm -rf "$candidate"
      continue
    fi
    path_is_absent "$candidate" && continue
    fail "malformed Zig preparation residue: $candidate"
  done < <(/usr/bin/find "$zig_parent" -maxdepth 1 -name '.preparing.*' -print)
}

acquire_publish_lock() {
  local attempt=0 lock_inode candidate_inode
  while true; do
    prepare_owner_candidate
    if /bin/ln "$lock_candidate" "$lock_file" 2>/dev/null; then
      lock_inode=$(/usr/bin/stat -f %i "$lock_file" 2>/dev/null || true)
      candidate_inode=$(/usr/bin/stat -f %i "$lock_candidate" 2>/dev/null || true)
      [[ -n "$lock_inode" && "$lock_inode" == "$candidate_inode" && -f "$lock_file" && ! -L "$lock_file" ]] || fail "bootstrap lock ownership verification failed"
      lock_owned=1
      crash_at_test_point lock-acquired
      return
    fi
    /bin/rm -f "$lock_candidate"
    lock_candidate=''
    [[ ! -L "$lock_file" ]] || fail "refusing symlinked bootstrap lock: $lock_file"
    reclaim_stale_lock && continue
    if [[ -e "$install_root" || -L "$install_root" ]]; then
      validate_installed_compiler && exit 0
      fail "concurrent bootstrap produced an invalid Zig installation"
    fi
    (( attempt += 1 ))
    (( attempt <= 1200 )) || fail "timed out waiting for concurrent Zig bootstrap"
    (( lock_wait_count += 1 ))
    if [[ -n "$test_max_lock_waits" && "$lock_wait_count" -gt "$test_max_lock_waits" ]]; then
      fail "test lock wait budget exceeded: $lock_wait_count > $test_max_lock_waits"
    fi
    /bin/sleep 0.2
  done
}

for tool_path in "$tools_root" "$zig_parent" "$archive_dir" "$install_root"; do
  is_physical_directory_or_absent "$tool_path" || fail "refusing non-directory or symlinked tool path: $tool_path"
done

/bin/mkdir "$tools_root" 2>/dev/null || true
/bin/mkdir "$zig_parent" 2>/dev/null || true
for tool_path in "$tools_root" "$zig_parent"; do
  [[ -d "$tool_path" && ! -L "$tool_path" ]] || fail "refusing non-directory or symlinked tool path: $tool_path"
done

if [[ -n "$test_event_log" ]]; then
  [[ "$test_event_log" == "$zig_parent"/.test-events.* && "${test_event_log:h}" == "$zig_parent" ]] || fail "test event log must be an exact .tools/zig/.test-events.* path"
  path_is_absent "$test_event_log" || fail "test event log already exists: $test_event_log"
  /usr/bin/printf 'lock-wait-count=pending\n' > "$test_event_log"
  [[ -f "$test_event_log" && ! -L "$test_event_log" ]] || fail "could not create physical test event log"
  test_event_log_inode=$(/usr/bin/stat -f %i "$test_event_log")
fi

reclaim_dead_owner_candidates
reclaim_dead_staging_dirs
reclaim_preparing_paths
if [[ -e "$lock_file" || -L "$lock_file" ]]; then
  reclaim_stale_lock || true
fi
if [[ -e "$install_root" || -L "$install_root" ]]; then
  validate_installed_compiler || fail "existing Zig installation is not version $ZIG_VERSION"
  if [[ "$test_validation_only" == "0" && "$test_force_full" == "0" ]]; then
    print -- "Zig $ZIG_VERSION already installed at $install_root"
    exit 0
  fi
fi

temp_dir=$(/usr/bin/mktemp -d "$zig_parent/.preparing.temp.$bootstrap_pid.$bootstrap_start_token.XXXXXX")
[[ -d "$temp_dir" && ! -L "$temp_dir" ]] || fail "invalid Zig temporary directory"
/bin/chmod 700 "$temp_dir"
archive="$temp_dir/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
if [[ -n "$archive_override" ]]; then
  /bin/cp "$archive_override" "$archive"
elif [[ "$testing" == "1" && -n "${COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE:-}" ]]; then
  [[ -f "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" && ! -L "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" ]] || fail "test archive is not a physical regular file"
  /bin/cp "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" "$archive"
elif [[ -L "$project_archive" ]]; then
  fail "project Zig archive is symlinked: $project_archive"
elif [[ -f "$project_archive" ]]; then
  /bin/cp "$project_archive" "$archive"
elif [[ -e "$project_archive" ]]; then
  fail "project Zig archive is not a regular file: $project_archive"
else
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 1 --retry-max-time 45 "$ZIG_AARCH64_MACOS_URL" -o "$archive"
fi

actual_size=$(/usr/bin/stat -f %z "$archive")
[[ "$actual_size" == "$ZIG_AARCH64_MACOS_SIZE" ]] || fail "Zig archive size mismatch: $actual_size"
actual_sha256=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
[[ "$actual_sha256" == "$ZIG_AARCH64_MACOS_SHA256" ]] || fail "Zig SHA-256 mismatch: $actual_sha256"
[[ "$test_validation_only" == "0" ]] || fail "test archive unexpectedly passed checksum validation"

archive_root="zig-aarch64-macos-$ZIG_VERSION"
/usr/bin/tar -tf "$archive" | while IFS= read -r archive_member; do
  [[ -n "$archive_member" ]] || fail "archive contains an empty member"
  [[ "$archive_member" != /* ]] || fail "archive contains an absolute path: $archive_member"
  [[ "/$archive_member/" != *'/../'* ]] || fail "archive contains path traversal: $archive_member"
  [[ "$archive_member" == "$archive_root" || "$archive_member" == "$archive_root/"* ]] || fail "archive member escapes expected root: $archive_member"
done

/usr/bin/tar -xf "$archive" -C "$temp_dir"
extracted_root="$temp_dir/$archive_root"
[[ -d "$extracted_root" && ! -L "$extracted_root" ]] || fail "archive did not extract the expected root"
[[ -x "$extracted_root/zig" && ! -L "$extracted_root/zig" ]] || fail "archive did not extract a physical Zig compiler"
/usr/bin/xattr -dr com.apple.quarantine "$extracted_root" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$extracted_root/zig" >/dev/null
[[ "$("$extracted_root/zig" version)" == "$ZIG_VERSION" ]] || fail "extracted Zig version mismatch"

prepare_staging_directory
/bin/mv "$extracted_root" "$staging_dir/payload"
[[ -d "$staging_dir/payload" && ! -L "$staging_dir/payload" ]] || fail "invalid Zig staging payload"
[[ -x "$staging_dir/payload/zig" && ! -L "$staging_dir/payload/zig" ]] || fail "staged Zig compiler is not physical"
/usr/bin/codesign --verify --strict "$staging_dir/payload/zig" >/dev/null
[[ "$("$staging_dir/payload/zig" version)" == "$ZIG_VERSION" ]] || fail "staged Zig version mismatch"

acquire_publish_lock
if [[ -e "$install_root" || -L "$install_root" ]]; then
  validate_installed_compiler && exit 0
  fail "Zig install path appeared with an invalid compiler"
fi
/bin/mv -n "$staging_dir/payload" "$install_root"
[[ -d "$install_root" && ! -L "$install_root" ]] || fail "Zig publication failed"
validate_installed_compiler || fail "published Zig compiler version mismatch"
print -- "Installed Zig $ZIG_VERSION at $install_root"
