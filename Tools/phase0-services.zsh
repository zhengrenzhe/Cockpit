#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
fixture_dir="$repo_root/.build/phase0-launchagents"
service_root_record="$fixture_dir/service-root.path"
domain="gui/$(id -u)"

stop_service() {
  /bin/launchctl bootout "$domain/$1" >/dev/null 2>&1 || true
}

load_service_root() {
  [[ -f "$service_root_record" ]] || return 1
  IFS= read -r service_root < "$service_root_record"
  [[ -n "$service_root" ]]
  [[ "$service_root" == /private/tmp/cockpit-phase0.* ]]
  [[ "${service_root:h}" == /private/tmp ]]
}

cleanup_service_root() {
  load_service_root || return 0
  [[ -e "$service_root" ]] || return 0
  [[ -d "$service_root" && ! -L "$service_root" ]]
  [[ "$(/usr/bin/stat -f %u "$service_root")" == "$(id -u)" ]]
  /bin/rm -rf -- "$service_root"
  [[ ! -e "$service_root" ]]
}

render_host() {
  /usr/bin/sed \
    "s|__EXECUTABLE__|$1|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.host.local.plist.template" \
    > "$fixture_dir/host.plist"
}

render_terminal() {
  /usr/bin/sed \
    -e "s|__EXECUTABLE__|$1|g" \
    -e "s|__KEEPER_EXECUTABLE__|$2|g" \
    -e "s|__RUNTIME_DIRECTORY__|$runtime_dir|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.terminal.local.plist.template" \
    > "$fixture_dir/terminal.plist"
}

case "${1:-}" in
  start)
    swift build --package-path "$repo_root"
    /bin/mkdir -p "$fixture_dir"

    stop_service dev.cockpit.host.local
    stop_service dev.cockpit.terminal.local
    cleanup_service_root

    service_root=$(/usr/bin/mktemp -d /private/tmp/cockpit-phase0.XXXXXX)
    runtime_dir="$service_root/runtime"
    binary_dir="$service_root/bin"
    /bin/chmod 700 "$service_root"
    print -r -- "$service_root" > "$service_root_record"
    /bin/mkdir "$runtime_dir" "$binary_dir"
    /bin/chmod 700 "$runtime_dir" "$binary_dir"

    /bin/cp -X "$repo_root/.build/debug/CockpitHost" "$binary_dir/CockpitHost"
    /bin/cp -X \
      "$repo_root/.build/debug/CockpitTerminalSupervisor" \
      "$binary_dir/CockpitTerminalSupervisor"
    /bin/cp -X "$repo_root/.build/debug/CockpitPTYKeeper" "$binary_dir/CockpitPTYKeeper"
    /bin/cp -X "$repo_root/.build/debug/CockpitProbe" "$binary_dir/CockpitProbe"

    host="$binary_dir/CockpitHost"
    terminal="$binary_dir/CockpitTerminalSupervisor"
    keeper="$binary_dir/CockpitPTYKeeper"
    probe="$binary_dir/CockpitProbe"

    /usr/bin/codesign --force --sign - "$host"
    /usr/bin/codesign --force --sign - "$terminal"
    /usr/bin/codesign --force --sign - "$keeper"
    /usr/bin/codesign --force --sign - "$probe"

    render_host "$host"
    render_terminal "$terminal" "$keeper"

    /bin/launchctl bootstrap "$domain" "$fixture_dir/host.plist"
    /bin/launchctl bootstrap "$domain" "$fixture_dir/terminal.plist"
    ;;
  stop)
    stop_service dev.cockpit.host.local
    stop_service dev.cockpit.terminal.local
    cleanup_service_root
    ;;
  probe)
    load_service_root
    "$service_root/bin/CockpitProbe" services
    ;;
  spawn-keeper)
    load_service_root
    "$service_root/bin/CockpitProbe" spawn-keeper
    ;;
  *)
    print -u2 "usage: Tools/phase0-services.zsh start|stop|probe|spawn-keeper"
    exit 64
    ;;
esac
