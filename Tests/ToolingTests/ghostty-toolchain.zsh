#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

repo_root=${0:A:h:h:h}
manifest="$repo_root/Config/Toolchains/ghostty.env"
submodule_path="$repo_root/ThirdParty/ghostty"
zig_root="$repo_root/.tools/zig/0.16.0"

fail() {
  print -u2 -- "$1"
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "host is not Darwin"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "host is not arm64"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "missing manifest: $manifest"

typeset -a expected_manifest_lines
expected_manifest_lines=(
  'GHOSTTY_VERSION=1.3.2-dev'
  'GHOSTTY_SOURCE_REF=main'
  'GHOSTTY_COMMIT=05221c11c9db0715666fc6e038915128fc6a563e'
  'GHOSTTY_REPOSITORY_URL=https://github.com/ghostty-org/ghostty.git'
  'ZIG_VERSION=0.16.0'
  'ZIG_AARCH64_MACOS_URL=https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz'
  'ZIG_AARCH64_MACOS_SHA256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489'
  'ZIG_AARCH64_MACOS_SIZE=52238004'
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
[[ "$GHOSTTY_SOURCE_REF" == "main" ]] || fail "Ghostty source ref mismatch"
[[ "$(/usr/bin/git -C "$submodule_path" show "$GHOSTTY_COMMIT:build.zig.zon" | /usr/bin/grep -Fxc '    .version = "1.3.2-dev",')" == "1" ]] || fail "Ghostty source version mismatch"
[[ "$(/usr/bin/git -C "$submodule_path" show "$GHOSTTY_COMMIT:build.zig.zon" | /usr/bin/grep -Fxc '    .minimum_zig_version = "0.16.0",')" == "1" ]] || fail "Ghostty source Zig compatibility mismatch"
[[ -z "$(/usr/bin/git -C "$submodule_path" status --short --untracked-files=no)" ]] || fail "Ghostty tracked source is dirty"

gitlink=$(/usr/bin/git ls-files --stage -- "$submodule_path")
[[ "$gitlink" == "160000 $GHOSTTY_COMMIT 0"$'\t'"ThirdParty/ghostty" ]] || fail "Ghostty gitlink mismatch"

for tool_path in "$repo_root/.tools" "$repo_root/.tools/zig" "$zig_root" "$zig_root/zig"; do
  [[ ! -L "$tool_path" ]] || fail "symlinked tool path: $tool_path"
done
[[ -d "$repo_root/.tools" && -d "$repo_root/.tools/zig" && -d "$zig_root" ]] || fail "missing Zig install directory"
[[ -x "$zig_root/zig" ]] || fail "missing Zig compiler"
/usr/bin/codesign --verify --strict "$zig_root/zig" >/dev/null 2>&1 || fail "Zig code signature is invalid"
[[ "$("$zig_root/zig" version)" == "$ZIG_VERSION" ]] || fail "Zig version mismatch"

/usr/bin/git check-ignore -q --no-index "$repo_root/.tools" || fail ".tools is not ignored"
! /usr/bin/git ls-files | /usr/bin/grep -Eq '(^|/)(\.tools|zig-aarch64-macos-0\.16\.0|zig-cache|\.zig-cache|zig-out)(/|$)|(^|/)zig$' || fail "toolchain or Ghostty build output is tracked"

typeset -a bundle_roots
bundle_roots=("$repo_root/build" "$repo_root/DerivedData")
for bundle_root in "${bundle_roots[@]}"; do
  [[ -d "$bundle_root" ]] || continue
  ! /usr/bin/find "$bundle_root" -type f \( -name zig -o -name 'zig-aarch64-macos-0.16.0.tar.xz' \) -print -quit | /usr/bin/grep -q . || fail "Zig compiler or archive is present in bundle output"
  ! /usr/bin/find "$bundle_root" -type d \( -name 'zig-aarch64-macos-0.16.0' -o -name zig-cache -o -name .zig-cache -o -name zig-out \) -print -quit | /usr/bin/grep -q . || fail "Ghostty build output is present in bundle output"
done

print -- "Ghostty $GHOSTTY_VERSION ($GHOSTTY_COMMIT) and Zig $ZIG_VERSION verified"
