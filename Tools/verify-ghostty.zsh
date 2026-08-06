#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_path=${0:P}
repo_root=${script_path:h:h}
manifest="$repo_root/Config/Toolchains/ghostty.env"
submodule_path="$repo_root/ThirdParty/ghostty"
tools_root="$repo_root/.tools"
zig_root="$tools_root/zig/0.15.2"
zig_binary="$zig_root/zig"

fail() {
  print -u2 -- "$1"
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "host is not Darwin"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "host is not arm64"
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

[[ -f "$repo_root/.gitmodules" && ! -L "$repo_root/.gitmodules" ]] || fail "missing .gitmodules"
[[ "$(/usr/bin/git config --file "$repo_root/.gitmodules" --get submodule.ThirdParty/ghostty.path)" == "ThirdParty/ghostty" ]] || fail "Ghostty submodule path mismatch"
[[ "$(/usr/bin/git config --file "$repo_root/.gitmodules" --get submodule.ThirdParty/ghostty.url)" == "$GHOSTTY_REPOSITORY_URL" ]] || fail "Ghostty submodule URL mismatch"
[[ -d "$submodule_path" && ! -L "$submodule_path" ]] || fail "missing or symlinked Ghostty submodule"
[[ "$(/usr/bin/git -C "$submodule_path" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]] || fail "Ghostty commit mismatch"
[[ -z "$(/usr/bin/git -C "$submodule_path" status --short --untracked-files=no)" ]] || fail "Ghostty tracked source is dirty"
gitlink=$(/usr/bin/git ls-files --stage -- "$submodule_path")
[[ "$gitlink" == "160000 $GHOSTTY_COMMIT 0"$'\t'"ThirdParty/ghostty" ]] || fail "Ghostty gitlink mismatch"

for tool_path in "$tools_root" "$tools_root/zig" "$zig_root" "$zig_binary"; do
  [[ ! -L "$tool_path" ]] || fail "symlinked tool path: $tool_path"
done
if [[ ! -e "$zig_binary" ]]; then
  "$repo_root/Tools/bootstrap-zig.zsh"
fi
[[ -d "$tools_root" && -d "$tools_root/zig" && -d "$zig_root" && -x "$zig_binary" ]] || fail "missing Zig compiler"
[[ "$("$zig_binary" version)" == "$ZIG_VERSION" ]] || fail "Zig version mismatch"

/usr/bin/git check-ignore -q --no-index "$tools_root" || fail ".tools is not ignored"
! /usr/bin/git ls-files | /usr/bin/grep -Eq '(^|/)(\.tools|zig-aarch64-macos-0\.15\.2|zig-cache|\.zig-cache|zig-out)(/|$)|(^|/)zig$' || fail "toolchain or Ghostty build output is tracked"
for bundle_root in "$repo_root/build" "$repo_root/DerivedData"; do
  [[ -d "$bundle_root" ]] || continue
  ! /usr/bin/find "$bundle_root" -type f \( -name zig -o -name 'zig-aarch64-macos-0.15.2.tar.xz' \) -print -quit | /usr/bin/grep -q . || fail "Zig compiler or archive is present in bundle output"
  ! /usr/bin/find "$bundle_root" -type d \( -name 'zig-aarch64-macos-0.15.2' -o -name zig-cache -o -name .zig-cache -o -name zig-out \) -print -quit | /usr/bin/grep -q . || fail "Ghostty build output is present in bundle output"
done

compatibility_file="$submodule_path/build.zig.zon"
compatibility_line=$(/usr/bin/grep -n -F '.minimum_zig_version = "0.15.2",' "$compatibility_file" || true)
[[ -n "$compatibility_line" ]] || fail "Ghostty source does not declare Zig $ZIG_VERSION compatibility"
print -- "Ghostty $GHOSTTY_VERSION ($GHOSTTY_COMMIT) verified; Zig $ZIG_VERSION; compatibility $compatibility_file:${compatibility_line%%:*}"
