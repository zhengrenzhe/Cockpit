#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_path=${0:P}
repo_root=${script_path:h:h:h}
ghostty_root="$repo_root/ThirdParty/ghostty"
expected_commit=05221c11c9db0715666fc6e038915128fc6a563e
zig="$repo_root/.tools/zig/0.16.0/zig"
series="$repo_root/Patches/ghostty/series"
header="$repo_root/Native/CockpitGhosttyBridge/include/cockpit_ghostty.h"
build_script="$repo_root/Tools/build-ghostty-bridge.zsh"
project_spec="$repo_root/project.yml"
target_triple=aarch64-macos.15.0

fail() {
  print -u2 -- "ghostty-bridge: $1"
  exit 1
}

[[ "$repo_root" != / ]] || fail "invalid repository root"
[[ -d "$ghostty_root" && ! -L "$ghostty_root" ]] || fail "missing Ghostty submodule"
[[ "$(/usr/bin/git -C "$ghostty_root" rev-parse HEAD)" == "$expected_commit" ]] || fail "Ghostty commit mismatch"
[[ -z "$(/usr/bin/git -C "$ghostty_root" status --short)" ]] || fail "Ghostty submodule is dirty"
"$repo_root/Tools/verify-ghostty.zsh" --no-bootstrap
[[ -x "$zig" && "$($zig version)" == 0.16.0 ]] || fail "Zig 0.16.0 is unavailable"

typeset -a missing
missing=()
[[ -f "$series" ]] || missing+=("Patches/ghostty/series")
[[ -f "$header" ]] || missing+=("Native/CockpitGhosttyBridge/include/cockpit_ghostty.h")
[[ -x "$build_script" ]] || missing+=("Tools/build-ghostty-bridge.zsh")
[[ -f "$project_spec" ]] || missing+=("project.yml")
(( ${#missing[@]} == 0 )) || fail "missing Task 11 inputs: ${(j:, :)missing}"

/usr/bin/grep -Fq 'cockpit_ghostty_grid_t' "$header" || \
  fail "renderer header does not expose fixed-cell grid metrics"
/usr/bin/grep -Fq 'double font_points, cockpit_ghostty_grid_t *grid' "$header" || \
  fail "renderer resize does not accept fixed font points and return grid metrics"

temp_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cockpit-ghostty-bridge.XXXXXX")
temp_root=${temp_root:A}
trap '/bin/rm -rf -- "$temp_root"' EXIT INT TERM

output_guard_root="$temp_root/output-guard"
/bin/mkdir -p "$output_guard_root/Tools" "$output_guard_root/Derived" "$output_guard_root/arbitrary"
/bin/cp "$build_script" "$output_guard_root/Tools/build-ghostty-bridge.zsh"

assert_output_rejected() {
  local label=$1
  local candidate=$2
  set +e
  "$output_guard_root/Tools/build-ghostty-bridge.zsh" \
    --configuration Debug --output "$candidate" \
    > "$temp_root/output-guard-$label.stdout" 2> "$temp_root/output-guard-$label.stderr"
  local guard_status=$?
  set -e
  [[ "$guard_status" != 0 ]] || fail "build wrapper accepted unsafe $label output: $candidate"
  /usr/bin/grep -Fq 'refusing unsafe output path' "$temp_root/output-guard-$label.stderr" || \
    fail "build wrapper did not reject unsafe $label output before reading repository inputs"
}

assert_output_rejected normalized "$output_guard_root/Derived/.."
assert_output_rejected home "$HOME"
assert_output_rejected workspace "${repo_root:h}"
assert_output_rejected arbitrary "$output_guard_root/arbitrary"
assert_output_rejected arbitrary-derived-leaf "$output_guard_root/arbitrary/Ghostty"
/bin/ln -s "$output_guard_root/arbitrary" "$output_guard_root/linked-parent"
assert_output_rejected symlink-ancestor "$output_guard_root/linked-parent/Ghostty"

project_dump="$temp_root/project.yml"
/opt/homebrew/bin/xcodegen dump --no-env --type yaml --spec "$project_spec" --file "$project_dump" >/dev/null
/opt/homebrew/bin/rg -Fq 'CockpitGhosttyArtifacts:' "$project_dump" || fail "missing Xcode Ghostty artifact target"
/opt/homebrew/bin/rg -Fq 'Tools/build-ghostty-bridge.zsh' "$project_dump" || fail "missing Xcode Ghostty artifact build script"
/opt/homebrew/bin/rg -Fq -- '--output \"$DERIVED_FILE_DIR/Ghostty\"' "$project_dump" || fail "Xcode Ghostty artifact output is not derived"
[[ "$(/opt/homebrew/bin/rg -c '^[[:space:]]+- target: CockpitGhosttyArtifacts$' "$project_dump")" == 2 ]] || fail "Cockpit and CockpitPTYKeeper must depend on CockpitGhosttyArtifacts"
[[ "$(/opt/homebrew/bin/rg -c 'SWIFT_ACTIVE_COMPILATION_CONDITIONS:.*COCKPIT_GHOSTTY_LINKED' "$project_dump")" == 2 ]] || fail "Xcode production targets do not compile the linked Ghostty path"
[[ "$(/opt/homebrew/bin/rg -c '^[[:space:]]+ARCHS: arm64$' "$project_dump")" == 2 ]] || fail "Ghostty-linked Xcode targets must match the arm64 artifact architecture"
/opt/homebrew/bin/rg -Fq 'CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a' "$project_dump" || fail "Cockpit does not link the static Ghostty renderer slice"
/opt/homebrew/bin/rg -Fq 'lib/libCockpitGhosttyVT.a' "$project_dump" || fail "CockpitPTYKeeper does not link the Ghostty VT archive"

archive_root="$temp_root/ghostty"
/bin/mkdir -p "$archive_root"
/usr/bin/git -C "$ghostty_root" archive "$expected_commit" | /usr/bin/tar -x -C "$archive_root"

typeset -a patch_names
patch_names=()
while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
  [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
  [[ "$patch_name" == ${patch_name:t} && "$patch_name" == *.patch ]] || fail "invalid patch series entry: $patch_name"
  patch_path="$repo_root/Patches/ghostty/$patch_name"
  [[ -f "$patch_path" && ! -L "$patch_path" ]] || fail "missing patch from series: $patch_name"
  /usr/bin/patch -d "$archive_root" -p1 --batch --forward < "$patch_path"
  patch_names+=("$patch_name")
done < "$series"
(( ${#patch_names[@]} > 0 )) || fail "Ghostty patch series is empty"
[[ -z "$(/usr/bin/git -C "$ghostty_root" status --short)" ]] || fail "patch verification modified the Ghostty submodule"

/bin/mkdir -p "$archive_root/src/cockpit/include/CockpitGhostty"
/bin/cp "$header" "$archive_root/src/cockpit/include/CockpitGhostty/cockpit_ghostty.h"
(
  cd "$archive_root"
  "$zig" build cockpit-ghostty-tests \
    -Dtarget="$target_triple" \
    -Doptimize=Debug \
    -Dapp-runtime=none \
    -Drenderer=metal
)

patch_digest=$(
  {
    /bin/cat "$series"
    for patch_name in "${patch_names[@]}"; do
      /bin/cat "$repo_root/Patches/ghostty/$patch_name"
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)
header_digest=$(/usr/bin/shasum -a 256 "$header" | /usr/bin/awk '{print $1}')
module_map_source="$repo_root/Native/CockpitGhosttyBridge/include/module.modulemap"
module_map_digest=$(/usr/bin/shasum -a 256 "$module_map_source" | /usr/bin/awk '{print $1}')
cache_key=$(
  /usr/bin/printf '%s\n' "$expected_commit" "$patch_digest" 0.16.0 Debug "$target_triple" \
    "$header_digest" "$module_map_digest" |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)

/bin/mkdir -p "$temp_root/Derived"
output="$temp_root/Derived/Ghostty"
/bin/mkdir -p "$output/include/CockpitGhostty" "$output/lib"
DERIVED_FILE_DIR="$temp_root/Derived" \
  "$build_script" --configuration Debug --output "$output"

include_root="$output/include/CockpitGhostty"
vt_library="$output/lib/libCockpitGhosttyVT.a"
renderer_xcframework="$output/CockpitGhosttyRenderer.xcframework"
renderer_library="$renderer_xcframework/macos-arm64/libCockpitGhosttyRenderer.a"
manifest="$output/manifest.json"
[[ -f "$include_root/cockpit_ghostty.h" ]] || fail "missing derived C header"
[[ -f "$include_root/module.modulemap" ]] || fail "missing derived module map"
[[ -f "$vt_library" ]] || fail "missing VT static library"
[[ -f "$renderer_library" ]] || fail "missing renderer static library slice"
[[ -f "$renderer_xcframework/Info.plist" ]] || fail "missing renderer XCFramework metadata"
[[ -f "$manifest" ]] || fail "missing artifact manifest"
[[ "$(<"$output/.cockpit-ghostty-output")" == cockpit-ghostty-derived-output-v1 ]] || fail "missing output ownership marker"
/usr/bin/cmp -s "$header" "$include_root/cockpit_ghostty.h" || fail "derived header differs from source header"
/usr/bin/cmp -s "$module_map_source" "$include_root/module.modulemap" || fail "derived module map differs from source module map"
[[ "$(/usr/bin/lipo -archs "$vt_library")" == arm64 ]] || fail "VT library is not arm64-only"
[[ "$(/usr/bin/lipo -archs "$renderer_library")" == arm64 ]] || fail "renderer library is not arm64-only"
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -o - "$renderer_xcframework/Info.plist")" == XFWK ]] || fail "invalid XCFramework package type"
[[ "$(/usr/bin/plutil -extract AvailableLibraries.0.LibraryIdentifier raw -o - "$renderer_xcframework/Info.plist")" == macos-arm64 ]] || fail "invalid XCFramework slice identifier"
[[ "$(/usr/bin/plutil -extract ghosttyCommit raw -o - "$manifest")" == "$expected_commit" ]] || fail "manifest Ghostty commit mismatch"
[[ "$(/usr/bin/plutil -extract patchSHA256 raw -o - "$manifest")" == "$patch_digest" ]] || fail "manifest patch digest mismatch"
[[ "$(/usr/bin/plutil -extract zigVersion raw -o - "$manifest")" == 0.16.0 ]] || fail "manifest Zig version mismatch"
[[ "$(/usr/bin/plutil -extract configuration raw -o - "$manifest")" == Debug ]] || fail "manifest configuration mismatch"
[[ "$(/usr/bin/plutil -extract targetTriple raw -o - "$manifest")" == "$target_triple" ]] || fail "manifest target triple mismatch"
[[ "$(/usr/bin/plutil -extract cacheKey raw -o - "$manifest")" == "$cache_key" ]] || fail "manifest cache key mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.vt.path raw -o - "$manifest")" == lib/libCockpitGhosttyVT.a ]] || fail "manifest VT path mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.renderer.path raw -o - "$manifest")" == CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a ]] || fail "manifest renderer path mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.header.path raw -o - "$manifest")" == include/CockpitGhostty/cockpit_ghostty.h ]] || fail "manifest header path mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.header.sha256 raw -o - "$manifest")" == "$header_digest" ]] || fail "manifest header digest mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.moduleMap.path raw -o - "$manifest")" == include/CockpitGhostty/module.modulemap ]] || fail "manifest module-map path mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.moduleMap.sha256 raw -o - "$manifest")" == "$module_map_digest" ]] || fail "manifest module-map digest mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.vt.sha256 raw -o - "$manifest")" == "$(/usr/bin/shasum -a 256 "$vt_library" | /usr/bin/awk '{print $1}')" ]] || fail "manifest VT digest mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.vt.architecture raw -o - "$manifest")" == arm64 ]] || fail "manifest VT architecture mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.renderer.sha256 raw -o - "$manifest")" == "$(/usr/bin/shasum -a 256 "$renderer_library" | /usr/bin/awk '{print $1}')" ]] || fail "manifest renderer digest mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.renderer.architecture raw -o - "$manifest")" == arm64 ]] || fail "manifest renderer architecture mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.rendererInfo.path raw -o - "$manifest")" == CockpitGhosttyRenderer.xcframework/Info.plist ]] || fail "manifest renderer metadata path mismatch"
[[ "$(/usr/bin/plutil -extract artifacts.rendererInfo.sha256 raw -o - "$manifest")" == "$(/usr/bin/shasum -a 256 "$renderer_xcframework/Info.plist" | /usr/bin/awk '{print $1}')" ]] || fail "manifest renderer metadata digest mismatch"

assert_cache_rebuilt() {
  local label=$1
  local log="$temp_root/cache-$label.log"
  DERIVED_FILE_DIR="$temp_root/Derived" \
    "$build_script" --configuration Debug --output "$output" > "$log"
  /usr/bin/grep -Fq 'Built Cockpit Ghostty bridge:' "$log" || fail "cache accepted $label corruption"
  /usr/bin/cmp -s "$header" "$include_root/cockpit_ghostty.h" || fail "cache did not restore the source header after $label corruption"
  /usr/bin/cmp -s "$module_map_source" "$include_root/module.modulemap" || fail "cache did not restore the source module map after $label corruption"
  [[ "$(/usr/bin/lipo -archs "$vt_library")" == arm64 ]] || fail "cache did not restore an arm64 VT library after $label corruption"
  [[ "$(/usr/bin/lipo -archs "$renderer_library")" == arm64 ]] || fail "cache did not restore an arm64 renderer after $label corruption"
  [[ -f "$renderer_xcframework/Info.plist" ]] || fail "cache did not restore XCFramework metadata after $label corruption"
  [[ "$(/usr/bin/plutil -extract artifacts.vt.sha256 raw -o - "$manifest")" == "$(/usr/bin/shasum -a 256 "$vt_library" | /usr/bin/awk '{print $1}')" ]] || fail "rebuilt VT digest is inconsistent after $label corruption"
  [[ "$(/usr/bin/plutil -extract artifacts.renderer.sha256 raw -o - "$manifest")" == "$(/usr/bin/shasum -a 256 "$renderer_library" | /usr/bin/awk '{print $1}')" ]] || fail "rebuilt renderer digest is inconsistent after $label corruption"
}

/usr/bin/printf '\n/* stale derived header */\n' >> "$include_root/cockpit_ghostty.h"
assert_cache_rebuilt header
/usr/bin/printf '\n/* stale derived module map */\n' >> "$include_root/module.modulemap"
assert_cache_rebuilt module-map
/usr/bin/printf 'corrupt archive' >> "$vt_library"
assert_cache_rebuilt vt-digest

/usr/bin/printf 'int cockpit_wrong_arch_fixture(void) { return 0; }\n' > "$temp_root/wrong-arch.c"
/usr/bin/clang -arch x86_64 -c "$temp_root/wrong-arch.c" -o "$temp_root/wrong-arch.o"
/usr/bin/libtool -static -o "$temp_root/libWrongArch.a" "$temp_root/wrong-arch.o" >/dev/null
/bin/cp "$temp_root/libWrongArch.a" "$vt_library"
wrong_arch_digest=$(/usr/bin/shasum -a 256 "$vt_library" | /usr/bin/awk '{print $1}')
/usr/bin/plutil -replace artifacts.vt.sha256 -string "$wrong_arch_digest" "$manifest"
/usr/bin/plutil -replace artifacts.vt.architecture -string x86_64 "$manifest"
assert_cache_rebuilt vt-architecture

/bin/rm "$renderer_xcframework/Info.plist"
assert_cache_rebuilt xcframework-metadata

/usr/bin/plutil -replace ghosttyCommit -string 0000000000000000000000000000000000000000 "$manifest"
assert_cache_rebuilt manifest-metadata

cache_hit_log="$temp_root/cache-hit.log"
DERIVED_FILE_DIR="$temp_root/Derived" \
  "$build_script" --configuration Debug --output "$output" > "$cache_hit_log"
/usr/bin/grep -Fq 'Cockpit Ghostty bridge cache hit:' "$cache_hit_log" || fail "valid cache did not produce a cache hit"
[[ -z "$(/usr/bin/find "${output:h}" -mindepth 1 -maxdepth 1 -name '.Ghostty.cockpit-replaced.*' -print -quit)" ]] || \
  fail "build wrapper leaked a replaced-output quarantine"

controlled_tmp="$temp_root/controlled-tmp"
cleanup_output_parent="$temp_root/cleanup-output/Derived"
/bin/mkdir -p "$controlled_tmp" "$cleanup_output_parent"
TMPDIR="$controlled_tmp" DERIVED_FILE_DIR="$cleanup_output_parent" "$build_script" \
  --configuration Debug --output "$cleanup_output_parent/Ghostty" \
  > "$temp_root/cleanup-build.log"
[[ -z "$(/usr/bin/find "$controlled_tmp" -mindepth 1 -maxdepth 1 -type d -name 'cockpit-ghostty-build.*' -print -quit)" ]] || \
  fail "successful build leaked a cockpit-ghostty-build temporary directory"

fixtures="$temp_root/fixtures"
/bin/mkdir -p "$fixtures"
/usr/bin/xxd -r -p > "$fixtures/snapshot.ckgf" <<'HEX'
434b474600010101000000000000000000000000000000010000000200000006
0000000601000000000006040000010000001d1f21000001cc6666000002b5bd
68000003f0c67400000481a2be000005b294bb0000068abeb7000007c5c8c600
0008666666000009d54e5300000ab9ca4a00000be7c54700000c7aa6da00000d
c397d800000e70c0b100000feaeaea00001000000000001100005f0000120000
870000130000af0000140000d70000150000ff000016005f00000017005f5f00
0018005f87000019005faf00001a005fd700001b005fff00001c00870000001d
00875f00001e00878700001f0087af0000200087d70000210087ff00002200af
0000002300af5f00002400af8700002500afaf00002600afd700002700afff00
002800d70000002900d75f00002a00d78700002b00d7af00002c00d7d700002d
00d7ff00002e00ff0000002f00ff5f00003000ff8700003100ffaf00003200ff
d700003300ffff0000345f00000000355f005f0000365f00870000375f00af00
00385f00d70000395f00ff00003a5f5f0000003b5f5f5f00003c5f5f8700003d
5f5faf00003e5f5fd700003f5f5fff0000405f87000000415f875f0000425f87
870000435f87af0000445f87d70000455f87ff0000465faf000000475faf5f00
00485faf870000495fafaf00004a5fafd700004b5fafff00004c5fd70000004d
5fd75f00004e5fd78700004f5fd7af0000505fd7d70000515fd7ff0000525fff
000000535fff5f0000545fff870000555fffaf0000565fffd70000575fffff00
005887000000005987005f00005a87008700005b8700af00005c8700d700005d
8700ff00005e875f0000005f875f5f000060875f87000061875faf000062875f
d7000063875fff00006487870000006587875f0000668787870000678787af00
00688787d70000698787ff00006a87af0000006b87af5f00006c87af8700006d
87afaf00006e87afd700006f87afff00007087d70000007187d75f00007287d7
8700007387d7af00007487d7d700007587d7ff00007687ff0000007787ff5f00
007887ff8700007987ffaf00007a87ffd700007b87ffff00007caf000000007d
af005f00007eaf008700007faf00af000080af00d7000081af00ff000082af5f
00000083af5f5f000084af5f87000085af5faf000086af5fd7000087af5fff00
0088af8700000089af875f00008aaf878700008baf87af00008caf87d700008d
af87ff00008eafaf0000008fafaf5f000090afaf87000091afafaf000092afaf
d7000093afafff000094afd700000095afd75f000096afd787000097afd7af00
0098afd7d7000099afd7ff00009aafff0000009bafff5f00009cafff8700009d
afffaf00009eafffd700009fafffff0000a0d700000000a1d7005f0000a2d700
870000a3d700af0000a4d700d70000a5d700ff0000a6d75f000000a7d75f5f00
00a8d75f870000a9d75faf0000aad75fd70000abd75fff0000acd787000000ad
d7875f0000aed787870000afd787af0000b0d787d70000b1d787ff0000b2d7af
000000b3d7af5f0000b4d7af870000b5d7afaf0000b6d7afd70000b7d7afff00
00b8d7d7000000b9d7d75f0000bad7d7870000bbd7d7af0000bcd7d7d70000bd
d7d7ff0000bed7ff000000bfd7ff5f0000c0d7ff870000c1d7ffaf0000c2d7ff
d70000c3d7ffff0000c4ff00000000c5ff005f0000c6ff00870000c7ff00af00
00c8ff00d70000c9ff00ff0000caff5f000000cbff5f5f0000ccff5f870000cd
ff5faf0000ceff5fd70000cfff5fff0000d0ff87000000d1ff875f0000d2ff87
870000d3ff87af0000d4ff87d70000d5ff87ff0000d6ffaf000000d7ffaf5f00
00d8ffaf870000d9ffafaf0000daffafd70000dbffafff0000dcffd7000000dd
ffd75f0000deffd7870000dfffd7af0000e0ffd7d70000e1ffd7ff0000e2ffff
000000e3ffff5f0000e4ffff870000e5ffffaf0000e6ffffd70000e7ffffff00
00e80808080000e91212120000ea1c1c1c0000eb2626260000ec3030300000ed
3a3a3a0000ee4444440000ef4e4e4e0000f05858580000f16262620000f26c6c
6c0000f37676760000f48080800000f58a8a8a0000f69494940000f79e9e9e00
00f8a8a8a80000f9b2b2b20000fabcbcbc0000fbc6c6c60000fcd0d0d00000fd
dadada0000fee4e4e40000ffeeeeee00020000000000000c0000000000000005
0101000003000000000000240000000200000000010000000000000000000005
0000000101000000000000050000000004000000000000680000000500000000
0000000001000000000000010000000100000000000000010100000000000002
0000000100000000000000020100000000000003000000010000000000000003
0100000000000004000000010000000000000004010000000000000500000001
0500000000000031000000050000000100000001680000000200000001650000
0003000000016c00000004000000016c00000005000000016f06000000000000
140000000100000001010000000000000100000000
HEX
/usr/bin/xxd -r -p > "$fixtures/delta.ckgf" <<'HEX'
434b474600010200000000000000000100000000000000020000000200000006
00000005020000000000000c0000000000000001010100000300000000000014
0000000100000000010000000000000000000005040000000000006800000005
0000000000000000010000000000000100000000000000000000000101000000
0000000200000001000000000000000201000000000000030000000100000000
0000000301000000000000040000000100000000000000040100000000000005
0000000105000000000000310000000500000001000000014800000002000000
016500000003000000016c00000004000000016c00000005000000016f060000
00000000140000000100000001010000000000000100000000
HEX
/usr/bin/xxd -r -p > "$fixtures/scrollback.ckgf" <<'HEX'
434b474600010300000000000000000000000000000000010000000200000004
0000000107000000000000230000000000000000000000010000000000000000
0000000000000000000000036f6e65
HEX
[[ "$(/usr/bin/stat -f %z "$fixtures/snapshot.ckgf")" == 1845 ]] || fail "snapshot fixture byte count changed"
[[ "$(/usr/bin/stat -f %z "$fixtures/delta.ckgf")" == 281 ]] || fail "delta fixture byte count changed"
[[ "$(/usr/bin/stat -f %z "$fixtures/scrollback.ckgf")" == 79 ]] || fail "scrollback fixture byte count changed"

harnesses="$temp_root/harnesses"
/bin/mkdir -p "$harnesses"
/bin/cat > "$harnesses/header.c" <<'C'
#include <CockpitGhostty/cockpit_ghostty.h>
_Static_assert(sizeof(cockpit_ghostty_key_event_t) == 16, "key ABI size");
_Static_assert(sizeof(cockpit_ghostty_mouse_event_t) == 28, "mouse ABI size");
int main(void) { return 0; }
C
/bin/cat > "$harnesses/header.cpp" <<'CPP'
#include <CockpitGhostty/cockpit_ghostty.h>
static_assert(sizeof(cockpit_ghostty_key_event_t) == 16, "key ABI size");
static_assert(sizeof(cockpit_ghostty_mouse_event_t) == 28, "mouse ABI size");
int main() { return 0; }
CPP
/usr/bin/clang -std=c17 -Werror -I "$output/include" -c "$harnesses/header.c" -o "$harnesses/header-c.o"
/usr/bin/clang++ -std=c++20 -Werror -I "$output/include" -c "$harnesses/header.cpp" -o "$harnesses/header-cxx.o"

/bin/cat > "$harnesses/vt.c" <<'C'
#include <CockpitGhostty/cockpit_ghostty.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void assert_bytes(const char *path, cockpit_ghostty_bytes_t actual) {
  FILE *file = fopen(path, "rb");
  assert(file != NULL);
  assert(fseek(file, 0, SEEK_END) == 0);
  long length = ftell(file);
  assert(length >= 0);
  rewind(file);
  uint8_t *expected = malloc((size_t)length);
  assert(expected != NULL);
  assert(fread(expected, 1, (size_t)length, file) == (size_t)length);
  assert(fclose(file) == 0);
  assert(actual.bytes != NULL);
  assert(actual.length == (size_t)length);
  assert(memcmp(actual.bytes, expected, actual.length) == 0);
  free(expected);
  cockpit_ghostty_bytes_free(actual);
}

static void assert_literal(cockpit_ghostty_bytes_t actual, const uint8_t *expected, size_t length) {
  assert(actual.bytes != NULL);
  assert(actual.length == length);
  assert(memcmp(actual.bytes, expected, length) == 0);
  cockpit_ghostty_bytes_free(actual);
}

static uint64_t read_be64(const uint8_t *bytes) {
  uint64_t value = 0;
  for (size_t index = 0; index < 8; ++index)
    value = (value << 8) | bytes[index];
  return value;
}

static uint32_t read_be32(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
         ((uint32_t)bytes[2] << 8) | bytes[3];
}

static const uint8_t *find_section(cockpit_ghostty_bytes_t frame,
                                   uint8_t wanted, uint32_t *length) {
  assert(frame.bytes != NULL && frame.length >= 36);
  uint32_t count = read_be32(frame.bytes + 32);
  size_t offset = 36;
  for (uint32_t index = 0; index < count; ++index) {
    assert(offset + 8 <= frame.length);
    uint8_t kind = frame.bytes[offset];
    uint32_t section_length = read_be32(frame.bytes + offset + 4);
    offset += 8;
    assert(offset + section_length <= frame.length);
    if (kind == wanted) {
      *length = section_length;
      return frame.bytes + offset;
    }
    offset += section_length;
  }
  assert(false && "missing CKGF section");
  return NULL;
}

static bool palette_contains(cockpit_ghostty_bytes_t frame, uint16_t wanted,
                             uint8_t red, uint8_t green, uint8_t blue) {
  uint32_t length = 0;
  const uint8_t *payload = find_section(frame, 1, &length);
  uint32_t count = read_be32(payload);
  assert(length == 4 + count * 6);
  for (uint32_t index = 0; index < count; ++index) {
    const uint8_t *entry = payload + 4 + index * 6;
    uint16_t palette_index = ((uint16_t)entry[0] << 8) | entry[1];
    if (palette_index == wanted)
      return entry[2] == red && entry[3] == green && entry[4] == blue;
  }
  return false;
}

static uint32_t palette_count(cockpit_ghostty_bytes_t frame) {
  uint32_t length = 0;
  const uint8_t *payload = find_section(frame, 1, &length);
  uint32_t count = read_be32(payload);
  assert(length == 4 + count * 6);
  return count;
}

static bool has_background_rgb(cockpit_ghostty_bytes_t frame,
                               uint32_t wanted) {
  uint32_t length = 0;
  const uint8_t *payload = find_section(frame, 6, &length);
  uint32_t count = read_be32(payload);
  assert(length == 4 + count * 16);
  for (uint32_t index = 0; index < count; ++index) {
    const uint8_t *entry = payload + 4 + index * 16;
    if (entry[5] == 2 && read_be32(entry + 12) == wanted) return true;
  }
  return false;
}

typedef struct {
  uint32_t count;
  uint64_t first;
  uint64_t last;
  uint32_t wrapped;
} scrollback_summary_t;

static scrollback_summary_t summarize_scrollback(cockpit_ghostty_bytes_t frame) {
  uint32_t length = 0;
  const uint8_t *payload = find_section(frame, 7, &length);
  scrollback_summary_t result = {.count = read_be32(payload + 8)};
  size_t offset = 16;
  for (uint32_t index = 0; index < result.count; ++index) {
    assert(offset + 16 <= length);
    uint64_t absolute = read_be64(payload + offset);
    if (index == 0) result.first = absolute;
    result.last = absolute;
    result.wrapped += payload[offset + 8] == 1;
    uint32_t text_length = read_be32(payload + offset + 12);
    offset += 16 + text_length;
    assert(offset <= length);
  }
  assert(offset == length);
  return result;
}

int main(int argc, char **argv) {
  assert(argc == 4);
  assert(cockpit_ghostty_vt_create(0, 2, 128) == NULL);
  assert(cockpit_ghostty_vt_create(6, 0, 128) == NULL);
  cockpit_ghostty_vt_t *vt = cockpit_ghostty_vt_create(6, 2, 128);
  assert(vt != NULL);
  const uint8_t styled[] = "\x1b[31mhello\x1b[0m";
  assert(cockpit_ghostty_vt_feed(vt, styled, sizeof(styled) - 1) == 0);
  cockpit_ghostty_bytes_t bytes = {(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_snapshot(vt, &bytes) == 0);
  assert(palette_count(bytes) == 256);
  assert_bytes(argv[1], bytes);

  const uint8_t row_change[] = "\rH";
  assert(cockpit_ghostty_vt_feed(vt, row_change, sizeof(row_change) - 1) == 0);
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_delta(vt, 1, &bytes) == 0);
  assert_bytes(argv[2], bytes);
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_delta(vt, 1, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  assert(cockpit_ghostty_vt_scrollback(vt, 0, 0, &bytes) == 0);
  assert(bytes.length >= 24);
  assert(read_be64(bytes.bytes + 8) == 2);
  assert(read_be64(bytes.bytes + 16) == 2);
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t later_row_change[] = "\rJ";
  assert(cockpit_ghostty_vt_feed(vt, later_row_change,
                                 sizeof(later_row_change) - 1) == 0);
  assert(cockpit_ghostty_vt_delta(vt, 2, &bytes) == 0);
  assert(bytes.length >= 24);
  assert(read_be64(bytes.bytes + 8) == 2);
  assert(read_be64(bytes.bytes + 16) == 3);
  cockpit_ghostty_bytes_free(bytes);
  assert(cockpit_ghostty_vt_resize(vt, 7, 3) == 0);
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_delta(vt, 3, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  assert(cockpit_ghostty_vt_snapshot(vt, &bytes) == 0);
  assert(bytes.bytes != NULL && bytes.length > 0);
  cockpit_ghostty_bytes_free(bytes);
  assert(cockpit_ghostty_vt_resize(vt, 0, 3) == -1);
  cockpit_ghostty_vt_destroy(vt);

  cockpit_ghostty_vt_t *input = cockpit_ghostty_vt_create(80, 24, 128);
  assert(input != NULL);
  const uint8_t modes[] = "\x1b[?2004h\x1b[?1000h\x1b[?1006h";
  assert(cockpit_ghostty_vt_feed(input, modes, sizeof(modes) - 1) == 0);
  cockpit_ghostty_key_event_t key = {
      .logical_key = 'a', .physical_key = 0x04,
      .modifiers = COCKPIT_GHOSTTY_MOD_CONTROL,
      .action = COCKPIT_GHOSTTY_KEY_PRESS};
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  const uint8_t control_a[] = {0x01};
  assert_literal(bytes, control_a, sizeof(control_a));
  key.action = COCKPIT_GHOSTTY_KEY_RELEASE;
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  key.action = 99;
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  key = (cockpit_ghostty_key_event_t){
      .logical_key = 0, .physical_key = 0x3A,
      .modifiers = COCKPIT_GHOSTTY_MOD_CONTROL,
      .action = COCKPIT_GHOSTTY_KEY_PRESS};
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  const uint8_t control_f1[] = "\x1b[1;5P";
  assert_literal(bytes, control_f1, sizeof(control_f1) - 1);
  key = (cockpit_ghostty_key_event_t){
      .logical_key = 'a', .physical_key = 0x04,
      .modifiers = COCKPIT_GHOSTTY_MOD_SHIFT,
      .action = COCKPIT_GHOSTTY_KEY_PRESS};
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  key.modifiers = COCKPIT_GHOSTTY_MOD_CAPS_LOCK;
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  const uint8_t kitty_keyboard_all[] = "\x1b[>31u";
  assert(cockpit_ghostty_vt_feed(input, kitty_keyboard_all,
                                 sizeof(kitty_keyboard_all) - 1) == 0);
  key = (cockpit_ghostty_key_event_t){
      .logical_key = 1095, .physical_key = 0x33,
      .modifiers = 0, .action = COCKPIT_GHOSTTY_KEY_PRESS};
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  const uint8_t kitty_non_us_press[] = "\x1b[1095::59u";
  assert_literal(bytes, kitty_non_us_press, sizeof(kitty_non_us_press) - 1);
  key.action = COCKPIT_GHOSTTY_KEY_RELEASE;
  assert(cockpit_ghostty_vt_encode_key(input, &key, &bytes) == 0);
  const uint8_t kitty_non_us_release[] = "\x1b[1095::59;1:3u";
  assert_literal(bytes, kitty_non_us_release,
                 sizeof(kitty_non_us_release) - 1);
  const uint8_t paste[] = "x\ny";
  assert(cockpit_ghostty_vt_encode_paste(input, paste, sizeof(paste) - 1, &bytes) == 0);
  const uint8_t bracketed[] = "\x1b[200~x\ny\x1b[201~";
  assert_literal(bytes, bracketed, sizeof(bracketed) - 1);
  cockpit_ghostty_mouse_event_t mouse = {
      .cell_x = 1, .cell_y = 2, .buttons = 1,
      .wheel_x = 0, .wheel_y = 0,
      .modifiers = 0, .action = COCKPIT_GHOSTTY_MOUSE_PRESS};
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_press[] = "\x1b[<0;2;3M";
  assert_literal(bytes, mouse_press, sizeof(mouse_press) - 1);
  mouse.buttons = 0;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_RELEASE;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_release[] = "\x1b[<0;2;3m";
  assert_literal(bytes, mouse_release, sizeof(mouse_release) - 1);
  mouse.cell_x = -4;
  mouse.cell_y = 99;
  mouse.buttons = 1;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_PRESS;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  mouse.buttons = 0;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_RELEASE;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_clamped_release[] = "\x1b[<0;1;24m";
  assert_literal(bytes, mouse_clamped_release, sizeof(mouse_clamped_release) - 1);
  const uint8_t any_mouse_mode[] = "\x1b[?1003h";
  assert(cockpit_ghostty_vt_feed(input, any_mouse_mode,
                                 sizeof(any_mouse_mode) - 1) == 0);
  mouse.buttons = 1;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_PRESS;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_clamped_press[] = "\x1b[<0;1;24M";
  assert_literal(bytes, mouse_clamped_press, sizeof(mouse_clamped_press) - 1);
  mouse.action = COCKPIT_GHOSTTY_MOUSE_MOTION;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_clamped_drag[] = "\x1b[<32;1;24M";
  assert_literal(bytes, mouse_clamped_drag, sizeof(mouse_clamped_drag) - 1);
  mouse.buttons = 0;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_RELEASE;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert_literal(bytes, mouse_clamped_release,
                 sizeof(mouse_clamped_release) - 1);
  mouse.action = COCKPIT_GHOSTTY_MOUSE_MOTION;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  mouse.cell_x = 1;
  mouse.cell_y = 2;
  mouse.buttons = 1u << 10;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_PRESS;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_button11[] = "\x1b[<131;2;3M";
  assert_literal(bytes, mouse_button11, sizeof(mouse_button11) - 1);
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  cockpit_ghostty_vt_reset_input_state(input);
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert_literal(bytes, mouse_button11, sizeof(mouse_button11) - 1);
  mouse.buttons = 0;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_RELEASE;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_button11_release[] = "\x1b[<131;2;3m";
  assert_literal(bytes, mouse_button11_release,
                 sizeof(mouse_button11_release) - 1);
  mouse.buttons = 1u << 9;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_PRESS;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_button10[] = "\x1b[<130;2;3M";
  assert_literal(bytes, mouse_button10, sizeof(mouse_button10) - 1);
  mouse.buttons = 0;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_RELEASE;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_button10_release[] = "\x1b[<130;2;3m";
  assert_literal(bytes, mouse_button10_release,
                 sizeof(mouse_button10_release) - 1);
  mouse.buttons = 0;
  mouse.wheel_y = -65536;
  mouse.action = COCKPIT_GHOSTTY_MOUSE_SCROLL;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_scroll[] = "\x1b[<65;2;3M";
  assert_literal(bytes, mouse_scroll, sizeof(mouse_scroll) - 1);
  mouse.wheel_y = -2 * 65536;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_scroll_twice[] = "\x1b[<65;2;3M\x1b[<65;2;3M";
  assert_literal(bytes, mouse_scroll_twice, sizeof(mouse_scroll_twice) - 1);
  mouse.wheel_y = -32768;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert_literal(bytes, mouse_scroll, sizeof(mouse_scroll) - 1);
  mouse.wheel_y = -32768;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  cockpit_ghostty_vt_reset_input_state(input);
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  assert(bytes.bytes == NULL && bytes.length == 0);
  mouse.wheel_y = 0;
  mouse.wheel_x = 65536;
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == 0);
  const uint8_t mouse_scroll_right[] = "\x1b[<67;2;3M";
  assert_literal(bytes, mouse_scroll_right, sizeof(mouse_scroll_right) - 1);
  mouse.buttons = 1u << 11;
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_encode_mouse(input, &mouse, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  cockpit_ghostty_vt_destroy(input);

  cockpit_ghostty_vt_t *pixel_mouse = cockpit_ghostty_vt_create(80, 24, 128);
  assert(pixel_mouse != NULL);
  const uint8_t pixel_mode[] = "\x1b[?1000h\x1b[?1016h";
  assert(cockpit_ghostty_vt_feed(pixel_mouse, pixel_mode,
                                 sizeof(pixel_mode) - 1) == 0);
  mouse = (cockpit_ghostty_mouse_event_t){
      .cell_x = 1, .cell_y = 2, .buttons = 1,
      .action = COCKPIT_GHOSTTY_MOUSE_PRESS};
  assert(cockpit_ghostty_vt_encode_mouse(pixel_mouse, &mouse, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  cockpit_ghostty_vt_destroy(pixel_mouse);

  cockpit_ghostty_vt_t *style_vt = cockpit_ghostty_vt_create(6, 2, 128);
  assert(style_vt != NULL);
  const uint8_t background_only[] = "\x1b[48;2;1;2;3m\x1b[2J";
  assert(cockpit_ghostty_vt_feed(style_vt, background_only,
                                 sizeof(background_only) - 1) == 0);
  assert(cockpit_ghostty_vt_snapshot(style_vt, &bytes) == 0);
  assert(has_background_rgb(bytes, 0x010203));
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t background_delta[] = "\x1b[48;2;4;5;6m\x1b[2K";
  assert(cockpit_ghostty_vt_feed(style_vt, background_delta,
                                 sizeof(background_delta) - 1) == 0);
  assert(cockpit_ghostty_vt_delta(style_vt, 1, &bytes) == 0);
  assert(has_background_rgb(bytes, 0x040506));
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t palette_change[] = "\x1b]4;42;rgb:01/02/03\x07";
  assert(cockpit_ghostty_vt_feed(style_vt, palette_change,
                                 sizeof(palette_change) - 1) == 0);
  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_delta(style_vt, 2, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  assert(cockpit_ghostty_vt_snapshot(style_vt, &bytes) == 0);
  assert(palette_contains(bytes, 42, 1, 2, 3));
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(style_vt);

  cockpit_ghostty_vt_t *wide_cursor = cockpit_ghostty_vt_create(6, 2, 128);
  assert(wide_cursor != NULL);
  const uint8_t wide_then_left[] = "\xe7\x95\x8c\x1b[D";
  assert(cockpit_ghostty_vt_feed(wide_cursor, wide_then_left,
                                 sizeof(wide_then_left) - 1) == 0);
  assert(cockpit_ghostty_vt_snapshot(wide_cursor, &bytes) == 0);
  uint32_t cursor_length = 0;
  const uint8_t *cursor = find_section(bytes, 2, &cursor_length);
  assert(cursor_length == 12 && read_be32(cursor + 4) == 0);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(wide_cursor);

  cockpit_ghostty_vt_t *scrollback = cockpit_ghostty_vt_create(4, 2, 128);
  assert(scrollback != NULL);
  const uint8_t lines[] = "one\r\ntwo\r\nthree";
  assert(cockpit_ghostty_vt_feed(scrollback, lines, sizeof(lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(scrollback, 0, 1, &bytes) == 0);
  assert_bytes(argv[3], bytes);
  cockpit_ghostty_vt_destroy(scrollback);

  cockpit_ghostty_vt_t *history = cockpit_ghostty_vt_create(4, 2, 4);
  assert(history != NULL);
  const uint8_t wrapped_history[] =
      "abcde\r\nfghij\r\nklmno\r\npqrst\r\nuvwxy";
  assert(cockpit_ghostty_vt_feed(history, wrapped_history,
                                 sizeof(wrapped_history) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(history, 0, 32, &bytes) == 0);
  scrollback_summary_t before = summarize_scrollback(bytes);
  assert(before.count > 0 && before.wrapped > 0);
  cockpit_ghostty_bytes_free(bytes);
  for (unsigned index = 0; index < 16384; ++index) {
    char evict_history[16];
    int length = snprintf(evict_history, sizeof(evict_history),
                          "%04xZ\r\n", index);
    assert(length > 0 && (size_t)length < sizeof(evict_history));
    assert(cockpit_ghostty_vt_feed(history,
                                   (const uint8_t *)evict_history,
                                   (size_t)length) == 0);
  }
  assert(cockpit_ghostty_vt_scrollback(history, 0, 32, &bytes) == 0);
  scrollback_summary_t after = summarize_scrollback(bytes);
  assert(after.count > 0 && after.first > before.first &&
         after.last > before.last && after.wrapped > 0);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(history);

  cockpit_ghostty_vt_t *reset_history = cockpit_ghostty_vt_create(4, 2, 128);
  assert(reset_history != NULL);
  const uint8_t reset_lines[] = "one\r\ntwo\r\nthree";
  assert(cockpit_ghostty_vt_feed(reset_history, reset_lines,
                                 sizeof(reset_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(reset_history, 0, 32, &bytes) == 0);
  scrollback_summary_t before_reset = summarize_scrollback(bytes);
  assert(before_reset.count > 0);
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t reset_terminal[] = "\x1b" "c";
  assert(cockpit_ghostty_vt_feed(reset_history, reset_terminal,
                                 sizeof(reset_terminal) - 1) == 0);
  assert(cockpit_ghostty_vt_feed(reset_history, reset_lines,
                                 sizeof(reset_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(reset_history, 0, 32, &bytes) == 0);
  scrollback_summary_t after_reset = summarize_scrollback(bytes);
  assert(after_reset.count > 0 && after_reset.first > before_reset.last);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(reset_history);

  cockpit_ghostty_vt_t *repeated_history = cockpit_ghostty_vt_create(6, 2, 4);
  assert(repeated_history != NULL);
  const uint8_t repeated_lines[] = "same\r\nsame\r\nsame\r\nsame";
  assert(cockpit_ghostty_vt_feed(repeated_history, repeated_lines,
                                 sizeof(repeated_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(repeated_history, 0, 32, &bytes) == 0);
  scrollback_summary_t before_repeated_eviction = summarize_scrollback(bytes);
  assert(before_repeated_eviction.count > 0);
  cockpit_ghostty_bytes_free(bytes);
  for (unsigned index = 0; index < 16384; ++index) {
    const uint8_t repeated_line[] = "same\r\n";
    assert(cockpit_ghostty_vt_feed(repeated_history, repeated_line,
                                   sizeof(repeated_line) - 1) == 0);
  }
  assert(cockpit_ghostty_vt_scrollback(repeated_history, 0, 32, &bytes) == 0);
  scrollback_summary_t after_repeated_eviction = summarize_scrollback(bytes);
  assert(after_repeated_eviction.count > 0 &&
         after_repeated_eviction.first > before_repeated_eviction.last);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(repeated_history);

  cockpit_ghostty_vt_t *cleared_history = cockpit_ghostty_vt_create(6, 2, 128);
  assert(cleared_history != NULL);
  assert(cockpit_ghostty_vt_feed(cleared_history, repeated_lines,
                                 sizeof(repeated_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(cleared_history, 0, 32, &bytes) == 0);
  scrollback_summary_t before_history_clear = summarize_scrollback(bytes);
  assert(before_history_clear.count > 0);
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t clear_and_repeat[] =
      "\x1b[3J\x1b[2J\x1b[Hsame\r\nsame\r\nsame\r\nsame";
  assert(cockpit_ghostty_vt_feed(cleared_history, clear_and_repeat,
                                 sizeof(clear_and_repeat) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(cleared_history, 0, 32, &bytes) == 0);
  scrollback_summary_t after_history_clear = summarize_scrollback(bytes);
  assert(after_history_clear.count > 0 &&
         after_history_clear.first > before_history_clear.last);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(cleared_history);

  cockpit_ghostty_vt_t *screen_history = cockpit_ghostty_vt_create(8, 2, 128);
  assert(screen_history != NULL);
  const uint8_t primary_lines[] = "primary1\r\nprimary2\r\nprimary3";
  assert(cockpit_ghostty_vt_feed(screen_history, primary_lines,
                                 sizeof(primary_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(screen_history, 0, 32, &bytes) == 0);
  scrollback_summary_t primary_before_alternate = summarize_scrollback(bytes);
  assert(primary_before_alternate.count > 0);
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t enter_alternate[] = "\x1b[?1049h";
  assert(cockpit_ghostty_vt_feed(screen_history, enter_alternate,
                                 sizeof(enter_alternate) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(screen_history, 0, 32, &bytes) == 0);
  assert(summarize_scrollback(bytes).count == 0);
  cockpit_ghostty_bytes_free(bytes);
  const uint8_t leave_alternate[] = "\x1b[?1049l";
  assert(cockpit_ghostty_vt_feed(screen_history, leave_alternate,
                                 sizeof(leave_alternate) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(screen_history, 0, 32, &bytes) == 0);
  scrollback_summary_t primary_after_alternate = summarize_scrollback(bytes);
  assert(primary_after_alternate.count == primary_before_alternate.count &&
         primary_after_alternate.first == primary_before_alternate.first &&
         primary_after_alternate.last == primary_before_alternate.last);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(screen_history);

  cockpit_ghostty_vt_t *resized_history = cockpit_ghostty_vt_create(16, 2, 128);
  assert(resized_history != NULL);
  const uint8_t resize_lines[] = "a\r\nb\r\nc\r\nd\r\ne";
  assert(cockpit_ghostty_vt_feed(resized_history, resize_lines,
                                 sizeof(resize_lines) - 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(resized_history, 0, 32, &bytes) == 0);
  scrollback_summary_t before_viewport_growth = summarize_scrollback(bytes);
  assert(before_viewport_growth.count == 3);
  cockpit_ghostty_bytes_free(bytes);
  assert(cockpit_ghostty_vt_resize(resized_history, 16, 3) == 0);
  assert(cockpit_ghostty_vt_scrollback(resized_history, 0, 32, &bytes) == 0);
  scrollback_summary_t after_viewport_growth = summarize_scrollback(bytes);
  assert(after_viewport_growth.count == 2 &&
         after_viewport_growth.first == before_viewport_growth.first &&
         after_viewport_growth.last + 1 == before_viewport_growth.last);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(resized_history);

  cockpit_ghostty_vt_t *pruned_resize_history =
      cockpit_ghostty_vt_create(16, 4096, 4);
  assert(pruned_resize_history != NULL);
  for (unsigned index = 0; index < 12000; ++index) {
    char numbered_line[16];
    int length = snprintf(numbered_line, sizeof(numbered_line),
                          "%05u\r\n", index);
    assert(length > 0 && (size_t)length < sizeof(numbered_line));
    assert(cockpit_ghostty_vt_feed(pruned_resize_history,
                                   (const uint8_t *)numbered_line,
                                   (size_t)length) == 0);
  }
  assert(cockpit_ghostty_vt_scrollback(pruned_resize_history, 0, 16384,
                                       &bytes) == 0);
  scrollback_summary_t before_resize_pruning = summarize_scrollback(bytes);
  assert(before_resize_pruning.count > 0);
  cockpit_ghostty_bytes_free(bytes);
  assert(cockpit_ghostty_vt_resize(pruned_resize_history, 16, 1) == 0);
  assert(cockpit_ghostty_vt_scrollback(pruned_resize_history, 0, 16384,
                                       &bytes) == 0);
  scrollback_summary_t after_resize_pruning = summarize_scrollback(bytes);
  assert(after_resize_pruning.count > 0 &&
         after_resize_pruning.first > before_resize_pruning.last &&
         after_resize_pruning.last >= after_resize_pruning.first);
  cockpit_ghostty_bytes_free(bytes);
  cockpit_ghostty_vt_destroy(pruned_resize_history);

  bytes = (cockpit_ghostty_bytes_t){(const uint8_t *)1, 99};
  assert(cockpit_ghostty_vt_snapshot(NULL, &bytes) == -1);
  assert(bytes.bytes == NULL && bytes.length == 0);
  cockpit_ghostty_bytes_free((cockpit_ghostty_bytes_t){NULL, 0});
  return 0;
}
C
/usr/bin/clang -std=c17 -Werror -I "$output/include" "$harnesses/vt.c" "$vt_library" -o "$harnesses/vt"
"$harnesses/vt" "$fixtures/snapshot.ckgf" "$fixtures/delta.ckgf" "$fixtures/scrollback.ckgf"

/bin/cat > "$harnesses/renderer.mm" <<'OBJCXX'
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CockpitGhostty/cockpit_ghostty.h>
#include <assert.h>

static NSData *fixture(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  assert(data != nil);
  return data;
}

static uint32_t read_u32(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
         ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void write_u32(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value >> 24);
  bytes[1] = (uint8_t)(value >> 16);
  bytes[2] = (uint8_t)(value >> 8);
  bytes[3] = (uint8_t)value;
}

static size_t section_payload(NSData *data, uint8_t wanted) {
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  size_t offset = 36;
  uint32_t count = read_u32(bytes + 32);
  for (uint32_t index = 0; index < count; ++index) {
    assert(offset + 8 <= data.length);
    uint8_t type = bytes[offset];
    uint32_t length = read_u32(bytes + offset + 4);
    offset += 8;
    assert(offset + length <= data.length);
    if (type == wanted) return offset;
    offset += length;
  }
  assert(false && "missing fixture section");
  return 0;
}

static void assert_rejected(cockpit_ghostty_renderer_t *renderer,
                            NSMutableData *frame) {
  assert(cockpit_ghostty_renderer_apply(
             renderer, (const uint8_t *)frame.bytes, frame.length) == -1);
}

int main(int argc, char **argv) {
  assert(argc == 4);
  @autoreleasepool {
    assert(cockpit_ghostty_renderer_create(NULL, 2.0) == NULL);
  }
  __weak NSView *retainedView = nil;
  cockpit_ghostty_renderer_t *renderer = NULL;
  @autoreleasepool {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    retainedView = view;
    renderer = cockpit_ghostty_renderer_create((__bridge void *)view, 2.0);
    assert(renderer != NULL);
    cockpit_ghostty_grid_t grid = {0};
    assert(cockpit_ghostty_renderer_resize(renderer, 1280, 960, 2.0, 13.0, &grid) == 1);
    assert(grid.columns > 0 && grid.rows > 0);
    view = nil;
    assert(retainedView != nil);
    assert(retainedView.wantsLayer);
    assert([retainedView.layer isKindOfClass:[CAMetalLayer class]]);
    CAMetalLayer *layer = (CAMetalLayer *)retainedView.layer;
    assert(layer.device != nil);
    assert(layer.contentsScale == 2.0);
    assert(layer.drawableSize.width == 1280 && layer.drawableSize.height == 960);
    NSData *snapshot = fixture([NSString stringWithUTF8String:argv[1]]);
    NSData *delta = fixture([NSString stringWithUTF8String:argv[2]]);
    NSData *scrollback = fixture([NSString stringWithUTF8String:argv[3]]);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)snapshot.bytes, snapshot.length) == 1);
    assert(cockpit_ghostty_renderer_set_visible(renderer, true) == 1);
    assert(!layer.hidden);
    assert(cockpit_ghostty_renderer_resize(renderer, UINT32_MAX, UINT32_MAX, 1.0, 13.0, &grid) == 0);
    assert(layer.hidden);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)delta.bytes, delta.length) == 0);
    assert(cockpit_ghostty_renderer_resize(renderer, 1280, 960, 2.0, 13.0, &grid) == 1);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)delta.bytes, delta.length) == 1);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)delta.bytes, delta.length) == -1);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)scrollback.bytes, scrollback.length) == 1);

    NSMutableData *invalidRows = [snapshot mutableCopy];
    write_u32((uint8_t *)invalidRows.mutableBytes + section_payload(invalidRows, 3), 1);
    assert_rejected(renderer, invalidRows);
    NSMutableData *invalidRange = [snapshot mutableCopy];
    write_u32((uint8_t *)invalidRange.mutableBytes + section_payload(invalidRange, 3) + 16, 6);
    assert_rejected(renderer, invalidRange);
    NSMutableData *invalidReference = [snapshot mutableCopy];
    write_u32((uint8_t *)invalidReference.mutableBytes + section_payload(invalidReference, 4) + 16, 6);
    assert_rejected(renderer, invalidReference);
    NSMutableData *invalidGrapheme = [snapshot mutableCopy];
    write_u32((uint8_t *)invalidGrapheme.mutableBytes + section_payload(invalidGrapheme, 5) + 4, 2);
    assert_rejected(renderer, invalidGrapheme);
    NSMutableData *invalidStyle = [snapshot mutableCopy];
    write_u32((uint8_t *)invalidStyle.mutableBytes + section_payload(invalidStyle, 6) + 4, 2);
    assert_rejected(renderer, invalidStyle);
    NSMutableData *shortPalette = [snapshot mutableCopy];
    size_t paletteOffset = section_payload(shortPalette, 1);
    write_u32((uint8_t *)shortPalette.mutableBytes + paletteOffset, 255);
    write_u32((uint8_t *)shortPalette.mutableBytes + paletteOffset - 4,
              4 + 255 * 6);
    [shortPalette replaceBytesInRange:NSMakeRange(paletteOffset + 4 + 255 * 6, 6)
                            withBytes:NULL
                               length:0];
    assert_rejected(renderer, shortPalette);
    uint8_t invalid[] = {'N', 'O', 'P', 'E'};
    assert(cockpit_ghostty_renderer_apply(renderer, invalid, sizeof(invalid)) == -1);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)snapshot.bytes, 16 * 1024 * 1024 + 1) == -1);
    cockpit_ghostty_grid_t compact_grid = {0};
    assert(cockpit_ghostty_renderer_resize(renderer, 800, 600, 1.5, 13.0, &compact_grid) == 1);
    cockpit_ghostty_grid_t expanded_grid = {0};
    assert(cockpit_ghostty_renderer_resize(renderer, 1200, 900, 1.5, 13.0, &expanded_grid) == 1);
    assert(compact_grid.cell_width == expanded_grid.cell_width);
    assert(compact_grid.cell_height == expanded_grid.cell_height);
    assert(expanded_grid.columns > compact_grid.columns);
    assert(expanded_grid.rows > compact_grid.rows);
    assert(layer.contentsScale == 1.5);
    assert(layer.drawableSize.width == 1200 && layer.drawableSize.height == 900);
    assert(cockpit_ghostty_renderer_set_visible(renderer, false) == 1);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)snapshot.bytes, snapshot.length) == 1);
    id<MTLDevice> retainedDevice = layer.device;
    layer.device = nil;
    assert(cockpit_ghostty_renderer_set_visible(renderer, true) == 0);
    assert(layer.hidden);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)delta.bytes, delta.length) == 0);
    layer.device = retainedDevice;
    assert(cockpit_ghostty_renderer_set_visible(renderer, true) == 1);
    assert(!layer.hidden);
    assert(cockpit_ghostty_renderer_apply(renderer, (const uint8_t *)delta.bytes, delta.length) == 1);
    layer.device = nil;
    assert(cockpit_ghostty_renderer_resize(renderer, 640, 480, 1.0, 13.0, &grid) == 0);
    assert(layer.hidden);
    layer.device = retainedDevice;
    assert(cockpit_ghostty_renderer_resize(renderer, 640, 480, 1.0, 13.0, &grid) == 1);
    assert(!layer.hidden);
    cockpit_ghostty_renderer_destroy(renderer);
    renderer = NULL;
  }
  assert(retainedView == nil);

  @autoreleasepool {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
    CALayer *originalLayer = [CALayer layer];
    view.wantsLayer = YES;
    view.layer = originalLayer;
    cockpit_ghostty_renderer_t *restoring =
        cockpit_ghostty_renderer_create((__bridge void *)view, 1.0);
    assert(restoring != NULL && view.layer != originalLayer);
    cockpit_ghostty_renderer_destroy(restoring);
    assert(view.wantsLayer && view.layer == originalLayer);
  }

  @autoreleasepool {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
    assert(!view.wantsLayer && view.layer == nil);
    cockpit_ghostty_renderer_t *restoring =
        cockpit_ghostty_renderer_create((__bridge void *)view, 1.0);
    assert(restoring != NULL);
    cockpit_ghostty_renderer_destroy(restoring);
    assert(!view.wantsLayer && view.layer == nil);
  }
  return 0;
}
OBJCXX
/usr/bin/clang++ -std=c++20 -fobjc-arc -Werror -I "$output/include" \
  "$harnesses/renderer.mm" "$renderer_library" -o "$harnesses/renderer" \
  -framework AppKit -framework Foundation -framework Metal -framework QuartzCore \
  -framework CoreText -framework CoreGraphics
"$harnesses/renderer" "$fixtures/snapshot.ckgf" "$fixtures/delta.ckgf" "$fixtures/scrollback.ckgf"

[[ -z "$(/usr/bin/git -C "$ghostty_root" status --short)" ]] || fail "tooling test modified the Ghostty submodule"
print -- "ghostty bridge tooling: PASS (3 literal CKGF fixtures, 2 arm64 static libraries, C and C++ headers, VT and offscreen Metal runtimes)"
