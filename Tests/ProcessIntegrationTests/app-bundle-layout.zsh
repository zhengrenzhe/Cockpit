#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h:h}
app="$repo_root/build/Debug/Cockpit.app"
test -x "$app/Contents/MacOS/Cockpit"
test -x "$app/Contents/Resources/CockpitHost"
test -x "$app/Contents/Resources/CockpitTerminalSupervisor"
test -x "$app/Contents/Resources/CockpitPTYKeeper"
test -f "$app/Contents/Library/LaunchAgents/dev.cockpit.host.plist"
test -f "$app/Contents/Library/LaunchAgents/dev.cockpit.terminal.plist"
/usr/bin/codesign --verify --deep --strict "$app"
