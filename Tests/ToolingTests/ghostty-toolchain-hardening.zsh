#!/bin/zsh
set -euo pipefail

repo_root=${0:P:h:h:h}
archive="$repo_root/.tools/archives/zig-aarch64-macos-0.15.2.tar.xz"
zig_parent="$repo_root/.tools/zig"
install_root="$zig_parent/0.15.2"
fake_bin=$(mktemp -d /tmp/cockpit-zig-fake-bin.XXXXXX)
marker_existing=$(mktemp -d /tmp/cockpit-zig-marker-existing.XXXXXX)
marker_offline=$(mktemp -d /tmp/cockpit-zig-marker-offline.XXXXXX)
backup_dir=''
moved_install=0

fail() {
  print -u2 -- "$1"
  exit 1
}

cleanup() {
  local rc=$?
  if [[ "$moved_install" == "1" && -d "$backup_dir/original" && ! -L "$backup_dir/original" ]]; then
    if [[ -d "$install_root" && ! -L "$install_root" ]]; then
      /bin/rm -rf "$install_root"
    fi
    /bin/mv "$backup_dir/original" "$install_root"
  fi
  [[ -n "$backup_dir" && -d "$backup_dir" && ! -L "$backup_dir" ]] && /bin/rm -rf "$backup_dir"
  /bin/rm -rf "$fake_bin" "$marker_existing" "$marker_offline"
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

[[ -f "$archive" && ! -L "$archive" ]] || fail "missing physical project Zig archive"
[[ -d "$install_root" && ! -L "$install_root" ]] || fail "missing existing Zig installation"

for tool_name in codesign shasum tar curl stat xattr git grep awk sed find mktemp chmod cp mv rm rmdir mkdir ln sleep ps uname; do
  /usr/bin/printf '#!/bin/zsh\n/usr/bin/touch "$COCKPIT_ZIG_TEST_MARKER_DIR/%s"\nexit 97\n' "$tool_name" > "$fake_bin/$tool_name"
  /bin/chmod 700 "$fake_bin/$tool_name"
done

set +e
COCKPIT_ZIG_TEST_MARKER_DIR="$marker_existing" PATH="$fake_bin:$PATH" "$repo_root/Tools/verify-ghostty.zsh" > /tmp/cockpit-hardening-existing.stdout 2> /tmp/cockpit-hardening-existing.stderr
existing_rc=$?
set -e

backup_dir=$(mktemp -d "$zig_parent/.hardening-backup.XXXXXX")
[[ -d "$backup_dir" && ! -L "$backup_dir" ]] || fail "invalid test backup directory"
/bin/mv "$install_root" "$backup_dir/original"
moved_install=1

set +e
COCKPIT_ZIG_TEST_MARKER_DIR="$marker_offline" PATH="$fake_bin:$PATH" "$repo_root/Tools/verify-ghostty.zsh" > /tmp/cockpit-hardening-offline.stdout 2> /tmp/cockpit-hardening-offline.stderr
offline_rc=$?
set -e

[[ "$existing_rc" == "0" ]] || fail "PATH-injected existing install verification exited $existing_rc"
[[ "$offline_rc" == "0" ]] || fail "offline fresh verification exited $offline_rc"
[[ -z "$(/usr/bin/find "$marker_existing" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "PATH-injected command ran for existing install"
[[ -z "$(/usr/bin/find "$marker_offline" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "PATH-injected command ran for offline fresh install"
[[ "$("$install_root/zig" version)" == "0.15.2" ]] || fail "offline fresh install Zig version mismatch"

legacy_owner="$zig_parent/.bootstrap-owner.legacy-empty"
legacy_lock="$zig_parent/.bootstrap-lock"
legacy_staging="$zig_parent/.staging.legacy-empty"
/usr/bin/touch "$legacy_owner" "$legacy_lock"
/bin/mkdir "$legacy_staging"
"$repo_root/Tools/bootstrap-zig.zsh"
[[ ! -e "$legacy_owner" && ! -e "$legacy_lock" && ! -e "$legacy_staging" ]] || fail "empty legacy residue was not recovered"

malformed_staging="$zig_parent/.staging.malformed"
/bin/mkdir "$malformed_staging"
/usr/bin/touch "$malformed_staging/sentinel"
set +e
"$repo_root/Tools/bootstrap-zig.zsh" > /tmp/cockpit-hardening-malformed.stdout 2> /tmp/cockpit-hardening-malformed.stderr
malformed_rc=$?
set -e
[[ "$malformed_rc" != "0" && -f "$malformed_staging/sentinel" ]] || fail "nonempty malformed staging was not conservatively rejected"
/bin/rm -rf "$malformed_staging"

active_owner="$zig_parent/.bootstrap-owner.active"
active_start=$(/bin/ps -o lstart= -p "$$" | /usr/bin/sed 's/^ *//')
/usr/bin/printf '%s\n%s\n' "$$" "$active_start" > "$active_owner"
"$repo_root/Tools/bootstrap-zig.zsh"
[[ -f "$active_owner" ]] || fail "active owner was removed"
/bin/rm -f "$active_owner"

print -- "PATH hardening and offline project archive fallback verified"
