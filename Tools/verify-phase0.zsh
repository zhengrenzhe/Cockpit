#!/bin/zsh
set -euo pipefail

repo_root=${0:P:h:h}
cd "$repo_root"

physical_command() {
  local path=$(/usr/bin/which "$1")
  [[ -n "$path" && -f "${path:A}" && -x "${path:A}" ]] || { print -u2 -- "missing executable: $1"; exit 1; }
  print -r -- "${path:A}"
}

entry_node=$(physical_command node)
entry_pnpm=$(physical_command pnpm)
xcodegen=$(physical_command xcodegen)
entry_node_version=$("$entry_node" --version)
entry_pnpm_version=$("$entry_pnpm" --version)
[[ "$entry_node_version" == v25.9.0 && "$entry_pnpm_version" == 9.15.9 || "$entry_node_version" == v26.7.0 && "$entry_pnpm_version" == 11.20.0 ]] || { print -u2 -- "unsupported paired entry toolchain"; exit 1; }

node=$entry_node
pnpm=$entry_pnpm
if [[ "$entry_node_version" == v25.9.0 ]]; then
  fnm=$(/usr/bin/which fnm)
  [[ -x "${fnm:A}" ]] || { print -u2 -- "Profile A requires local fnm Profile B"; exit 1; }
  node=$(${fnm:A} exec --using 26.7.0 -- /usr/bin/which node)
  pnpm=$(${fnm:A} exec --using 26.7.0 -- /usr/bin/which pnpm)
fi
[[ "$("$node" --version)" == v26.7.0 && "$("$pnpm" --version)" == 11.20.0 ]] || { print -u2 -- "canonical Profile B required"; exit 1; }
export PATH="${node:h}:${pnpm:h}:${xcodegen:h}:/usr/bin:/bin:/usr/sbin:/sbin"

[[ "$(/usr/bin/xcodebuild -version)" == $'Xcode 26.6\nBuild version 17F113' ]]
[[ "$(/usr/bin/swift --version | /usr/bin/sed -n 's/^.*Swift version \([0-9.]*\).*$/\1/p')" == 6.3.3 ]]
[[ "$("$xcodegen" --version)" == 'Version: 2.46.0' ]]
[[ "$("$node" -p "JSON.parse(require('fs').readFileSync('EditorRuntime/package.json')).dependencies['monaco-editor']")" == 0.56.0 ]]
[[ "$("$node" -p "JSON.parse(require('fs').readFileSync('EditorRuntime/package.json')).devDependencies.esbuild")" == 0.28.1 ]]

archive="$repo_root/.tools/archives/zig-aarch64-macos-0.15.2.tar.xz"
zig="$repo_root/.tools/zig/0.15.2/zig"
[[ -f "$archive" && ! -L "$archive" && "$(/usr/bin/stat -f %z "$archive")" == 50635984 && "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == 3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ]]
[[ -x "$zig" && ! -L "$zig" && "$("$zig" version)" == 0.15.2 ]]
[[ -e ThirdParty/ghostty/.git && "$(/usr/bin/git -C ThirdParty/ghostty rev-parse --show-toplevel)" == "$repo_root/ThirdParty/ghostty" && "$(/usr/bin/git -C ThirdParty/ghostty rev-parse HEAD)" == 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28 ]]

"$pnpm" --dir EditorRuntime install --frozen-lockfile --offline
"$pnpm" --dir EditorRuntime build
"$pnpm" --dir EditorRuntime test
/usr/bin/swift build --disable-automatic-resolution --skip-update
Tools/verify-ghostty.zsh --no-bootstrap
Tools/test-remote-tls.zsh
COCKPIT_TLS_FIXTURE_DIR="$repo_root/Tests/Fixtures/TLS/generated" /usr/bin/swift test --disable-automatic-resolution --skip-update
Tests/ProcessIntegrationTests/service-start-failure-cleanup.zsh
Tests/ProcessIntegrationTests/service-keeper-foundation.zsh
"$xcodegen" generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$repo_root/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation build
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
/usr/bin/git diff --check
