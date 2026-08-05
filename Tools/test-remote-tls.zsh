#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
"$repo_root/Tests/Fixtures/TLS/generate.zsh"
cd "$repo_root"
COCKPIT_TLS_FIXTURE_DIR="$repo_root/Tests/Fixtures/TLS/generated" swift test --filter CockpitRemoteTransportTests
