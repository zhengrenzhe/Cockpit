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

print -- "PATH hardening and offline project archive fallback verified"
