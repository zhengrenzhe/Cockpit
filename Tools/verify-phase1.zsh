#!/bin/zsh
set -euo pipefail

repo_root=${0:P:h:h}
cd "$repo_root"

physical_command() {
  local path=$(/usr/bin/which "$1")
  [[ -n "$path" && -f "${path:A}" && -x "${path:A}" ]] || {
    print -u2 -- "verify-phase1: missing executable: $1"
    exit 1
  }
  print -r -- "${path:A}"
}

entry_node=$(physical_command node)
entry_pnpm=$(physical_command pnpm)
xcodegen=$(physical_command xcodegen)
entry_node_version=$("$entry_node" --version)
entry_pnpm_version=$("$entry_pnpm" --version)
node=$entry_node
pnpm=$entry_pnpm
if [[ "$entry_node_version" == v25.9.0 && "$entry_pnpm_version" == 9.15.9 ]]; then
  fnm=$(physical_command fnm)
  node=$("$fnm" exec --using 26.7.0 -- /usr/bin/which node)
  pnpm=$("$fnm" exec --using 26.7.0 -- /usr/bin/which pnpm)
fi
[[ "$("$node" --version)" == v26.7.0 ]]
[[ "$("$pnpm" --version)" == 11.20.0 ]]
export PATH="${node:h}:${pnpm:h}:${xcodegen:h}:/usr/bin:/bin:/usr/sbin:/sbin"

print -- 'phase1 gate 1/10: canonical toolchain'
[[ "$(/usr/bin/xcodebuild -version)" == $'Xcode 26.6\nBuild version 17F113' ]]
[[ "$(/usr/bin/swift --version | /usr/bin/sed -n 's/^.*Swift version \([0-9.]*\).*$/\1/p')" == 6.3.3 ]]
[[ "$("$xcodegen" --version)" == 'Version: 2.46.0' ]]

print -- 'phase1 gate 2/10: Monaco offline install/build/test'
"$pnpm" --dir EditorRuntime install --frozen-lockfile --offline
"$pnpm" --dir EditorRuntime build
"$pnpm" --dir EditorRuntime test

print -- 'phase1 gate 3/10: Swift build/test'
/usr/bin/swift build --disable-automatic-resolution --skip-update
COCKPIT_TLS_FIXTURE_DIR="$repo_root/Tests/Fixtures/TLS/generated" \
  /usr/bin/swift test --disable-automatic-resolution --skip-update --no-parallel

print -- 'phase1 gate 4/10: Probe JSON contract'
Tests/ProcessIntegrationTests/probe-json.zsh

print -- 'phase1 gate 5/10: Ghostty bridge build/smoke'
Tests/ToolingTests/ghostty-bridge.zsh

print -- 'phase1 gate 6/10: XcodeGen/App build/App tests'
"$xcodegen" generate --no-env
/usr/bin/xcodebuild \
  -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$repo_root/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation build
/usr/bin/xcodebuild \
  -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$repo_root/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation test

print -- 'phase1 gate 7/10: Phase 0 process invariants'
Tests/ProcessIntegrationTests/service-start-failure-cleanup.zsh
Tests/ProcessIntegrationTests/service-keeper-foundation.zsh
COCKPIT_KEEPER_EXECUTABLE="$repo_root/build/Debug/Cockpit.app/Contents/Resources/CockpitPTYKeeper" \
  Tests/ProcessIntegrationTests/terminal-pty-exec.zsh
COCKPIT_KEEPER_EXECUTABLE="$repo_root/build/Debug/Cockpit.app/Contents/Resources/CockpitPTYKeeper" \
  Tests/ProcessIntegrationTests/terminal-reconciliation.zsh
Tests/ProcessIntegrationTests/terminal-app-reattach.zsh

print -- 'phase1 gate 8/10: Phase 1 direct workspace'
Tests/ProcessIntegrationTests/phase1-direct-workspace.zsh

print -- 'phase1 gate 9/10: App bundle layout'
Tests/ProcessIntegrationTests/app-bundle-layout.zsh

print -- 'phase1 gate 10/10: diff check'
/usr/bin/git diff --check
print -- 'Phase 1 unified gate: PASS'
