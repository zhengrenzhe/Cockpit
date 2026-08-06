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
    archive_override=${2:P}
    [[ -f "$archive_override" && ! -L "$archive_override" ]] || fail "archive override is not a physical regular file: $2"
    ;;
  *) fail "usage: $0 [--archive <physical-path>]" ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || fail "Phase 0 Zig bootstrap supports Darwin only"
[[ "$(uname -m)" == "arm64" ]] || fail "Phase 0 Zig bootstrap supports arm64 macOS only"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "missing manifest: $manifest"

typeset -a expected_manifest_lines
expected_manifest_lines=(
  'GHOSTTY_VERSION=1.3.1'
  'GHOSTTY_TAG=v1.3.1'
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
staging_dir=''
temp_dir=''
lock_file="$zig_parent/.bootstrap-lock"
lock_candidate=''
lock_owned=0

is_physical_directory_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || return 1
  [[ ! -e "$path" ]] || [[ -d "$path" ]]
}

validate_installed_compiler() {
  [[ -d "$install_root" && ! -L "$install_root" ]] || return 1
  [[ -x "$zig_binary" && ! -L "$zig_binary" ]] || return 1
  /usr/bin/codesign --verify --strict "$zig_binary" >/dev/null 2>&1 || return 1
  [[ "$("$zig_binary" version)" == "$ZIG_VERSION" ]]
}

cleanup() {
  local rc=$?
  if [[ -n "$staging_dir" && -d "$staging_dir" && ! -L "$staging_dir" && "$staging_dir" == "$zig_parent"/.staging.* ]]; then
    rm -rf "$staging_dir"
  fi
  if [[ -n "$temp_dir" && -d "$temp_dir" && ! -L "$temp_dir" && "$temp_dir" == /tmp/cockpit-zig.* ]]; then
    rm -rf "$temp_dir"
  fi
  if [[ "$lock_owned" == "1" && -n "$lock_candidate" && -f "$lock_candidate" && ! -L "$lock_candidate" ]]; then
    if [[ -f "$lock_file" && ! -L "$lock_file" && "$(stat -f %i "$lock_file")" == "$(stat -f %i "$lock_candidate")" ]]; then
      rm -f "$lock_file"
    fi
    rm -f "$lock_candidate"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

owner_is_dead() {
  local owner_file="$1"
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  local owner_pid owner_start current_start
  owner_pid=$(/usr/bin/sed -n '1p' "$owner_file")
  owner_start=$(/usr/bin/sed -n '2p' "$owner_file")
  [[ "$owner_pid" == <-> && -n "$owner_start" ]] || return 1
  [[ "$(/usr/bin/wc -l < "$owner_file" | /usr/bin/tr -d ' ')" == "2" ]] || return 1
  current_start=$(ps -o lstart= -p "$owner_pid" 2>/dev/null | /usr/bin/sed 's/^ *//')
  [[ -z "$current_start" || "$current_start" != "$owner_start" ]] || return 1
}

write_owner_metadata() {
  local owner_file="$1" owner_start
  owner_start=$(ps -o lstart= -p "$$" | /usr/bin/sed 's/^ *//')
  [[ -n "$owner_start" ]] || fail "could not record Zig bootstrap owner"
  printf '%s\n%s\n' "$$" "$owner_start" > "$owner_file"
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || fail "could not create Zig bootstrap owner metadata"
}

reclaim_dead_owner_candidates() {
  local candidate
  while IFS= read -r candidate; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    [[ "$(/usr/bin/stat -f %z "$candidate")" == "0" ]] && { /bin/rm -f "$candidate"; continue; }
    owner_is_dead "$candidate" && rm -f "$candidate"
  done < <(find "$zig_parent" -maxdepth 1 -type f -name '.bootstrap-owner.*' -print)
}

reclaim_stale_lock() {
  [[ ! -L "$lock_file" ]] || fail "refusing symlinked bootstrap lock: $lock_file"
  [[ -e "$lock_file" ]] || return 0
  [[ -f "$lock_file" ]] || fail "refusing non-file bootstrap lock: $lock_file"
  [[ "$(/usr/bin/stat -f %z "$lock_file")" == "0" ]] && { /bin/rm -f "$lock_file"; return 0; }
  owner_is_dead "$lock_file" || return 1
  rm -f "$lock_file"
  reclaim_dead_owner_candidates
}

reclaim_dead_staging_dirs() {
  local candidate owner_file
  while IFS= read -r candidate; do
    [[ -d "$candidate" && ! -L "$candidate" && "$candidate" == "$zig_parent"/.staging.* ]] || continue
    owner_file="$candidate/.owner"
    if [[ -z "$(/usr/bin/find "$candidate" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      /bin/rm -rf "$candidate"
      continue
    fi
    [[ -f "$owner_file" && ! -L "$owner_file" ]] || fail "unowned nonempty Zig staging residue: $candidate"
    owner_is_dead "$owner_file" && rm -rf "$candidate"
  done < <(find "$zig_parent" -maxdepth 1 -type d -name '.staging.*' -print)
}

acquire_publish_lock() {
  local attempt=0
  while true; do
    lock_candidate=$(mktemp "$zig_parent/.bootstrap-owner.XXXXXX")
    [[ -f "$lock_candidate" && ! -L "$lock_candidate" ]] || fail "invalid Zig lock candidate"
    if [[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_CANDIDATE_CREATED:-}" == "1" ]]; then
      kill -KILL "$$"
    fi
    chmod 600 "$lock_candidate"
    write_owner_metadata "$lock_candidate"
    if [[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_BEFORE_ACQUIRE:-}" == "1" ]]; then
      kill -KILL "$$"
    fi
    if ln "$lock_candidate" "$lock_file" 2>/dev/null; then
      [[ -f "$lock_file" && ! -L "$lock_file" && "$(stat -f %i "$lock_file")" == "$(stat -f %i "$lock_candidate")" ]] || fail "bootstrap lock ownership verification failed"
      lock_owned=1
      if [[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_AFTER_ACQUIRE:-}" == "1" ]]; then
        kill -KILL "$$"
      fi
      return
    fi
    rm -f "$lock_candidate"
    lock_candidate=''
    [[ ! -L "$lock_file" ]] || fail "refusing symlinked bootstrap lock: $lock_file"
    reclaim_stale_lock && continue
    if [[ -e "$install_root" || -L "$install_root" ]]; then
      validate_installed_compiler && exit 0
      fail "concurrent bootstrap produced an invalid Zig installation"
    fi
    (( attempt += 1 ))
    (( attempt <= 1200 )) || fail "timed out waiting for concurrent Zig bootstrap"
    sleep 0.2
  done
}

for tool_path in "$tools_root" "$zig_parent" "$archive_dir" "$install_root"; do
  is_physical_directory_or_absent "$tool_path" || fail "refusing non-directory or symlinked tool path: $tool_path"
done

testing=0
[[ "${COCKPIT_ZIG_BOOTSTRAP_TESTING:-}" == "1" ]] && testing=1
test_validation_only=0
[[ "$testing" == "1" && -n "${COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE:-}" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_EXPECT_FAILURE:-}" == "1" ]] && test_validation_only=1
test_force_full=0
[[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_FORCE_FULL:-}" == "1" ]] && test_force_full=1
mkdir "$tools_root" 2>/dev/null || true
mkdir "$zig_parent" 2>/dev/null || true
for tool_path in "$tools_root" "$zig_parent"; do
  [[ -d "$tool_path" && ! -L "$tool_path" ]] || fail "refusing non-directory or symlinked tool path: $tool_path"
done
reclaim_dead_owner_candidates
reclaim_dead_staging_dirs
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

temp_dir=$(mktemp -d /tmp/cockpit-zig.XXXXXX)
chmod 700 "$temp_dir"
archive="$temp_dir/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
if [[ -n "$archive_override" ]]; then
  cp "$archive_override" "$archive"
elif [[ "$testing" == "1" && -n "${COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE:-}" ]]; then
  [[ -f "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" && ! -L "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" ]] || fail "test archive is not a regular file"
  cp "$COCKPIT_ZIG_BOOTSTRAP_TEST_ARCHIVE" "$archive"
elif [[ -f "$project_archive" && ! -L "$project_archive" ]]; then
  cp "$project_archive" "$archive"
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

staging_dir=$(mktemp -d "$zig_parent/.staging.XXXXXX")
[[ -d "$staging_dir" && ! -L "$staging_dir" && "$staging_dir" == "$zig_parent"/.staging.* ]] || fail "invalid Zig staging directory"
if [[ "$testing" == "1" && "${COCKPIT_ZIG_BOOTSTRAP_TEST_CRASH_STAGING_CREATED:-}" == "1" ]]; then
  kill -KILL "$$"
fi
write_owner_metadata "$staging_dir/.owner"
mv "$extracted_root" "$staging_dir/payload"
[[ -d "$staging_dir/payload" && ! -L "$staging_dir/payload" ]] || fail "invalid Zig staging payload"
[[ -x "$staging_dir/payload/zig" && ! -L "$staging_dir/payload/zig" ]] || fail "staged Zig compiler is not physical"
/usr/bin/codesign --verify --strict "$staging_dir/payload/zig" >/dev/null
[[ "$("$staging_dir/payload/zig" version)" == "$ZIG_VERSION" ]] || fail "staged Zig version mismatch"

acquire_publish_lock
if [[ -e "$install_root" || -L "$install_root" ]]; then
  validate_installed_compiler && exit 0
  fail "Zig install path appeared with an invalid compiler"
fi
mv "$staging_dir/payload" "$install_root"
[[ -d "$install_root" && ! -L "$install_root" ]] || fail "Zig publication failed"
validate_installed_compiler || fail "published Zig compiler version mismatch"
print -- "Installed Zig $ZIG_VERSION at $install_root"
