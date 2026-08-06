#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
"$repo_root/Tests/Fixtures/TLS/generate.zsh"
cd "$repo_root"
COCKPIT_TLS_FIXTURE_DIR="$repo_root/Tests/Fixtures/TLS/generated" /usr/bin/swift test --disable-automatic-resolution --skip-update --no-parallel --filter CockpitRemoteTransportTests
