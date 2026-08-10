#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
keeper=${COCKPIT_KEEPER_EXECUTABLE:-}
[[ -n "$keeper" && "$keeper" == /* && -x "$keeper" && ! -L "$keeper" ]] || {
  print -u2 -- "terminal-pty-exec: COCKPIT_KEEPER_EXECUTABLE must be a physical absolute executable"
  exit 64
}

cd "$repo_root"
output=$(
  COCKPIT_KEEPER_EXECUTABLE="$keeper" \
    /usr/bin/swift test --disable-automatic-resolution --skip-build \
      --filter keeperExecutableProcessIntegration 2>&1
)
print -r -- "$output"
[[ "$output" == *"keeperExecutableProcessIntegration"* ]]
[[ "$output" == *"Test run with 1 test"* ]]
[[ "$output" == *"passed"* ]]
