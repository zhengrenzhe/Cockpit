#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
keeper=${COCKPIT_KEEPER_EXECUTABLE:-}
[[ -n "$keeper" && "$keeper" == /* && -x "$keeper" && ! -L "$keeper" ]] || {
  print -u2 -- "terminal-reconciliation: COCKPIT_KEEPER_EXECUTABLE must be a physical absolute executable"
  exit 64
}

cd "$repo_root"
set +e
output=$(
  COCKPIT_KEEPER_EXECUTABLE="$keeper" \
    /usr/bin/swift test --disable-automatic-resolution --skip-build \
      --filter keeperNaturalExitPublishesVerifiedArchiveAfterBootstrapControlCloses 2>&1
)
test_exit=$?
set -e
print -r -- "$output"
(( test_exit == 0 )) || exit "$test_exit"
[[ "$output" == *"keeperNaturalExitPublishesVerifiedArchiveAfterBootstrapControlCloses"* ]]
[[ "$output" == *"Test run with 1 test"* ]]
[[ "$output" == *"passed"* ]]
