#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

script_path=${0:P}
repo_root=${script_path:h:h}
manifest="$repo_root/Config/Toolchains/ghostty.env"
series="$repo_root/Patches/ghostty/series"
header="$repo_root/Native/CockpitGhosttyBridge/include/cockpit_ghostty.h"
module_map="$repo_root/Native/CockpitGhosttyBridge/include/module.modulemap"
ghostty_root="$repo_root/ThirdParty/ghostty"
configuration=''
output=''
target_triple=aarch64-macos.15.0

fail() {
  print -u2 -- "build-ghostty-bridge: $1"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --configuration)
      (( $# >= 2 )) || fail "missing value for --configuration"
      configuration=$2
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || fail "missing value for --output"
      output=$2
      shift 2
      ;;
    *) fail "usage: $0 --configuration Debug|Release --output <absolute-path>" ;;
  esac
done

[[ "$configuration" == Debug || "$configuration" == Release ]] || fail "configuration must be Debug or Release"
[[ -n "$output" && "$output" == /* ]] || fail "output must be an absolute path"
raw_output=$output
output=${raw_output:A}
[[ "$raw_output" == "$output" && "${output:t}" == Ghostty && \
   "$output" != / && "$output" != "$repo_root" && "$output" != "$ghostty_root" ]] || \
  fail "refusing unsafe output path: $raw_output"
[[ ! -L "$output" ]] || fail "refusing unsafe output path: $raw_output"

output_parent=${output:h}
[[ -d "$output_parent" && ! -L "$output_parent" && "${output_parent:A}" == "$output_parent" ]] || \
  fail "refusing unsafe output path: $raw_output"
derived_root=${DERIVED_FILE_DIR:-}
[[ -n "$derived_root" && "$derived_root" == /* && -d "$derived_root" && \
   ! -L "$derived_root" && "${derived_root:A}" == "$derived_root" && \
   "$output_parent" == "$derived_root" ]] || \
  fail "refusing unsafe output path: $raw_output"
ownership_marker=.cockpit-ghostty-output
ownership_value=cockpit-ghostty-derived-output-v1

output_is_owned() {
  [[ -d "$output" && ! -L "$output" && \
     -f "$output/$ownership_marker" && ! -L "$output/$ownership_marker" && \
     "$(<"$output/$ownership_marker")" == "$ownership_value" ]]
}

output_is_empty_scaffold() {
  [[ -d "$output" && ! -L "$output" && \
     -z "$(/usr/bin/find "$output" -mindepth 1 ! -type d -print -quit)" ]]
}

if [[ -e "$output" ]]; then
  output_is_owned || output_is_empty_scaffold || \
    fail "refusing unowned output directory: $output"
fi

for input in "$manifest" "$series" "$header" "$module_map"; do
  [[ -f "$input" && ! -L "$input" ]] || fail "missing physical input: $input"
done
[[ -d "$ghostty_root" && ! -L "$ghostty_root" ]] || fail "missing physical Ghostty submodule"

source "$manifest"
zig="$repo_root/.tools/zig/$ZIG_VERSION/zig"
[[ -x "$zig" && ! -L "$zig" ]] || fail "missing physical Zig $ZIG_VERSION compiler"
[[ "$("$zig" version)" == "$ZIG_VERSION" ]] || fail "Zig version mismatch"
[[ "$(/usr/bin/git -C "$ghostty_root" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]] || fail "Ghostty commit mismatch"
[[ -z "$(/usr/bin/git -C "$ghostty_root" status --short)" ]] || fail "Ghostty submodule is dirty"

typeset -a patch_names
patch_names=()
while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
  [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
  [[ "$patch_name" == ${patch_name:t} && "$patch_name" == *.patch ]] || fail "invalid patch series entry: $patch_name"
  patch_path="$repo_root/Patches/ghostty/$patch_name"
  [[ -f "$patch_path" && ! -L "$patch_path" ]] || fail "missing physical patch: $patch_name"
  patch_names+=("$patch_name")
done < "$series"
(( ${#patch_names[@]} > 0 )) || fail "Ghostty patch series is empty"

patch_digest=$(
  {
    /bin/cat "$series"
    for patch_name in "${patch_names[@]}"; do
      /bin/cat "$repo_root/Patches/ghostty/$patch_name"
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)
header_digest=$(/usr/bin/shasum -a 256 "$header" | /usr/bin/awk '{print $1}')
module_map_digest=$(/usr/bin/shasum -a 256 "$module_map" | /usr/bin/awk '{print $1}')
cache_key=$(
  /usr/bin/printf '%s\n' \
    "$GHOSTTY_COMMIT" "$patch_digest" "$ZIG_VERSION" "$configuration" "$target_triple" \
    "$header_digest" "$module_map_digest" |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)

cache_is_valid() {
  local derived_header="$output/include/CockpitGhostty/cockpit_ghostty.h"
  local derived_module_map="$output/include/CockpitGhostty/module.modulemap"
  local derived_vt="$output/lib/libCockpitGhosttyVT.a"
  local derived_renderer="$output/CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a"
  local derived_renderer_info="$output/CockpitGhosttyRenderer.xcframework/Info.plist"
  local derived_manifest="$output/manifest.json"
  local vt_digest renderer_digest renderer_info_digest vt_arch renderer_arch

  [[ -d "$output" && ! -L "$output" ]] || return 1
  [[ -f "$output/$ownership_marker" && ! -L "$output/$ownership_marker" && \
     "$(<"$output/$ownership_marker")" == "$ownership_value" ]] || return 1
  for artifact in \
    "$derived_manifest" "$derived_header" "$derived_module_map" \
    "$derived_vt" "$derived_renderer" "$derived_renderer_info"; do
    [[ -f "$artifact" && ! -L "$artifact" ]] || return 1
  done

  /usr/bin/cmp -s "$header" "$derived_header" || return 1
  /usr/bin/cmp -s "$module_map" "$derived_module_map" || return 1
  [[ "$(/usr/bin/plutil -extract ghosttyCommit raw -o - "$derived_manifest" 2>/dev/null || true)" == "$GHOSTTY_COMMIT" ]] || return 1
  [[ "$(/usr/bin/plutil -extract patchSHA256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$patch_digest" ]] || return 1
  [[ "$(/usr/bin/plutil -extract zigVersion raw -o - "$derived_manifest" 2>/dev/null || true)" == "$ZIG_VERSION" ]] || return 1
  [[ "$(/usr/bin/plutil -extract configuration raw -o - "$derived_manifest" 2>/dev/null || true)" == "$configuration" ]] || return 1
  [[ "$(/usr/bin/plutil -extract targetTriple raw -o - "$derived_manifest" 2>/dev/null || true)" == "$target_triple" ]] || return 1
  [[ "$(/usr/bin/plutil -extract cacheKey raw -o - "$derived_manifest" 2>/dev/null || true)" == "$cache_key" ]] || return 1

  vt_digest=$(/usr/bin/shasum -a 256 "$derived_vt" | /usr/bin/awk '{print $1}') || return 1
  renderer_digest=$(/usr/bin/shasum -a 256 "$derived_renderer" | /usr/bin/awk '{print $1}') || return 1
  renderer_info_digest=$(/usr/bin/shasum -a 256 "$derived_renderer_info" | /usr/bin/awk '{print $1}') || return 1
  vt_arch=$(/usr/bin/lipo -archs "$derived_vt" 2>/dev/null) || return 1
  renderer_arch=$(/usr/bin/lipo -archs "$derived_renderer" 2>/dev/null) || return 1

  [[ "$vt_arch" == arm64 && "$renderer_arch" == arm64 ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -o - "$derived_renderer_info" 2>/dev/null || true)" == XFWK ]] || return 1
  [[ "$(/usr/bin/plutil -extract AvailableLibraries.0.LibraryIdentifier raw -o - "$derived_renderer_info" 2>/dev/null || true)" == macos-arm64 ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.header.path raw -o - "$derived_manifest" 2>/dev/null || true)" == 'include/CockpitGhostty/cockpit_ghostty.h' ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.header.sha256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$header_digest" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.moduleMap.path raw -o - "$derived_manifest" 2>/dev/null || true)" == 'include/CockpitGhostty/module.modulemap' ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.moduleMap.sha256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$module_map_digest" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.vt.path raw -o - "$derived_manifest" 2>/dev/null || true)" == 'lib/libCockpitGhosttyVT.a' ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.vt.sha256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$vt_digest" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.vt.architecture raw -o - "$derived_manifest" 2>/dev/null || true)" == "$vt_arch" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.renderer.path raw -o - "$derived_manifest" 2>/dev/null || true)" == 'CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a' ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.renderer.sha256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$renderer_digest" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.renderer.architecture raw -o - "$derived_manifest" 2>/dev/null || true)" == "$renderer_arch" ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.rendererInfo.path raw -o - "$derived_manifest" 2>/dev/null || true)" == 'CockpitGhosttyRenderer.xcframework/Info.plist' ]] || return 1
  [[ "$(/usr/bin/plutil -extract artifacts.rendererInfo.sha256 raw -o - "$derived_manifest" 2>/dev/null || true)" == "$renderer_info_digest" ]]
}

if cache_is_valid; then
  print -- "Cockpit Ghostty bridge cache hit: $cache_key"
  exit 0
fi

temp_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cockpit-ghostty-build.XXXXXX")
replaced_output=''
cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$replaced_output" && -d "$replaced_output" && ! -L "$replaced_output" ]]; then
    if [[ ! -e "$output" ]]; then
      /bin/mv "$replaced_output" "$output" || true
    elif [[ -f "$replaced_output/$ownership_marker" && \
            ! -L "$replaced_output/$ownership_marker" && \
            "$(<"$replaced_output/$ownership_marker")" == "$ownership_value" ]]; then
      /bin/rm -rf -- "$replaced_output"
    fi
  fi
  if [[ -n "$temp_root" && -d "$temp_root" && ! -L "$temp_root" && "$temp_root" == */cockpit-ghostty-build.* ]]; then
    /bin/rm -rf -- "$temp_root"
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

source_root="$temp_root/ghostty"
prefix="$temp_root/prefix"
staging="$temp_root/output"
/bin/mkdir -p "$source_root" "$prefix" "$staging"
/usr/bin/git -C "$ghostty_root" archive "$GHOSTTY_COMMIT" | /usr/bin/tar -x -C "$source_root"

for patch_name in "${patch_names[@]}"; do
  /usr/bin/patch -d "$source_root" -p1 --batch --forward < "$repo_root/Patches/ghostty/$patch_name"
done

/bin/mkdir -p "$source_root/src/cockpit/include/CockpitGhostty"
/bin/cp "$header" "$source_root/src/cockpit/include/CockpitGhostty/cockpit_ghostty.h"

optimize=Debug
[[ "$configuration" == Release ]] && optimize=ReleaseFast
(
  cd "$source_root"
  "$zig" build cockpit-ghostty-vt cockpit-ghostty-renderer \
    -Dtarget="$target_triple" \
    -Doptimize="$optimize" \
    -Dapp-runtime=none \
    -Drenderer=metal \
    --prefix "$prefix"
)

vt_library="$prefix/lib/libCockpitGhosttyVT.a"
renderer_library="$prefix/lib/libCockpitGhosttyRenderer.a"
[[ -f "$vt_library" && ! -L "$vt_library" ]] || fail "Zig did not produce the VT library"
[[ -f "$renderer_library" && ! -L "$renderer_library" ]] || fail "Zig did not produce the renderer library"
[[ "$(/usr/bin/lipo -archs "$vt_library")" == arm64 ]] || fail "VT library is not arm64-only"
[[ "$(/usr/bin/lipo -archs "$renderer_library")" == arm64 ]] || fail "renderer library is not arm64-only"

/bin/mkdir -p "$staging/include/CockpitGhostty" "$staging/lib"
/bin/cp "$header" "$staging/include/CockpitGhostty/cockpit_ghostty.h"
/bin/cp "$module_map" "$staging/include/CockpitGhostty/module.modulemap"
/bin/cp "$vt_library" "$staging/lib/libCockpitGhosttyVT.a"
/usr/bin/xcodebuild -create-xcframework \
  -library "$renderer_library" \
  -headers "$staging/include/CockpitGhostty" \
  -output "$staging/CockpitGhosttyRenderer.xcframework" >/dev/null

staged_vt="$staging/lib/libCockpitGhosttyVT.a"
staged_renderer="$staging/CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a"
staged_renderer_info="$staging/CockpitGhosttyRenderer.xcframework/Info.plist"
vt_digest=$(/usr/bin/shasum -a 256 "$staged_vt" | /usr/bin/awk '{print $1}')
renderer_digest=$(/usr/bin/shasum -a 256 "$staged_renderer" | /usr/bin/awk '{print $1}')
renderer_info_digest=$(/usr/bin/shasum -a 256 "$staged_renderer_info" | /usr/bin/awk '{print $1}')

manifest_plist="$temp_root/manifest.plist"
manifest_path="$staging/manifest.json"
/usr/bin/plutil -create xml1 "$manifest_plist"
/usr/bin/plutil -insert ghosttyCommit -string "$GHOSTTY_COMMIT" "$manifest_plist"
/usr/bin/plutil -insert patchSHA256 -string "$patch_digest" "$manifest_plist"
/usr/bin/plutil -insert zigVersion -string "$ZIG_VERSION" "$manifest_plist"
/usr/bin/plutil -insert configuration -string "$configuration" "$manifest_plist"
/usr/bin/plutil -insert targetTriple -string "$target_triple" "$manifest_plist"
/usr/bin/plutil -insert cacheKey -string "$cache_key" "$manifest_plist"
/usr/bin/plutil -insert artifacts -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.header -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.header.path -string 'include/CockpitGhostty/cockpit_ghostty.h' "$manifest_plist"
/usr/bin/plutil -insert artifacts.header.sha256 -string "$header_digest" "$manifest_plist"
/usr/bin/plutil -insert artifacts.moduleMap -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.moduleMap.path -string 'include/CockpitGhostty/module.modulemap' "$manifest_plist"
/usr/bin/plutil -insert artifacts.moduleMap.sha256 -string "$module_map_digest" "$manifest_plist"
/usr/bin/plutil -insert artifacts.vt -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.vt.path -string 'lib/libCockpitGhosttyVT.a' "$manifest_plist"
/usr/bin/plutil -insert artifacts.vt.sha256 -string "$vt_digest" "$manifest_plist"
/usr/bin/plutil -insert artifacts.vt.architecture -string arm64 "$manifest_plist"
/usr/bin/plutil -insert artifacts.renderer -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.renderer.path -string 'CockpitGhosttyRenderer.xcframework/macos-arm64/libCockpitGhosttyRenderer.a' "$manifest_plist"
/usr/bin/plutil -insert artifacts.renderer.sha256 -string "$renderer_digest" "$manifest_plist"
/usr/bin/plutil -insert artifacts.renderer.architecture -string arm64 "$manifest_plist"
/usr/bin/plutil -insert artifacts.rendererInfo -dictionary "$manifest_plist"
/usr/bin/plutil -insert artifacts.rendererInfo.path -string 'CockpitGhosttyRenderer.xcframework/Info.plist' "$manifest_plist"
/usr/bin/plutil -insert artifacts.rendererInfo.sha256 -string "$renderer_info_digest" "$manifest_plist"
/usr/bin/plutil -convert json -o "$manifest_path" "$manifest_plist"
/usr/bin/printf '%s\n' "$ownership_value" > "$staging/$ownership_marker"

[[ ! -L "$output" ]] || fail "output became symlinked: $output"
if [[ -e "$output" ]]; then
  if output_is_owned; then
    replaced_output="$output_parent/.Ghostty.cockpit-replaced.$$.$RANDOM"
    [[ ! -e "$replaced_output" ]] || fail "replacement quarantine already exists: $replaced_output"
    /bin/mv "$output" "$replaced_output"
    [[ -d "$replaced_output" && ! -L "$replaced_output" && \
       -f "$replaced_output/$ownership_marker" && ! -L "$replaced_output/$ownership_marker" && \
       "$(<"$replaced_output/$ownership_marker")" == "$ownership_value" ]] || {
      /bin/mv "$replaced_output" "$output" || true
      replaced_output=''
      fail "quarantined output lost its ownership marker"
    }
  elif output_is_empty_scaffold; then
    /usr/bin/find "$output" -depth -type d -exec /bin/rmdir {} +
    [[ ! -e "$output" ]] || fail "failed to collapse empty Xcode output scaffold"
  else
    fail "refusing to replace unowned output directory: $output"
  fi
fi
/bin/mv "$staging" "$output" || {
  [[ -z "$replaced_output" || -e "$output" ]] || /bin/mv "$replaced_output" "$output" || true
  replaced_output=''
  fail "failed to install derived output"
}
if [[ -n "$replaced_output" ]]; then
  /bin/rm -rf -- "$replaced_output"
  replaced_output=''
fi
print -- "Built Cockpit Ghostty bridge: $cache_key"
