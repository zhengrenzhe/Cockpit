#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
fixture_dir="$repo_root/.build/phase0-launchagents"
service_root_record="$fixture_dir/service-root.path"
domain="gui/$(/usr/bin/id -u)"

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

cleanup_service_path() {
  local cleanup_root=$1
  [[ "$cleanup_root" == /private/tmp/cockpit-phase0.* ]]
  [[ "${cleanup_root:h}" == /private/tmp ]]
  [[ -e "$cleanup_root" ]] || return 0
  [[ -d "$cleanup_root" && ! -L "$cleanup_root" ]]
  [[ "$(/usr/bin/stat -f %u "$cleanup_root")" == "$(/usr/bin/id -u)" ]]
  /bin/rm -rf -- "$cleanup_root"
  [[ ! -e "$cleanup_root" ]]
}

cleanup_service_root() {
  load_service_root || return 0
  cleanup_service_path "$service_root"
}

render_host() {
  /usr/bin/sed \
    -e "s|__EXECUTABLE__|$1|g" \
    -e "s|__APPLICATION_SUPPORT_ROOT__|$application_support_root|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.host.local.plist.template" \
    > "$fixture_dir/host.plist"
}

render_terminal() {
  /usr/bin/sed \
    -e "s|__EXECUTABLE__|$1|g" \
    -e "s|__KEEPER_EXECUTABLE__|$2|g" \
    -e "s|__RUNTIME_DIRECTORY__|$runtime_dir|g" \
    -e "s|__APPLICATION_SUPPORT_ROOT__|$application_support_root|g" \
    -e "s|__INTEGRATION_MASTER_KEY__|$integration_master_key|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.terminal.local.plist.template" \
    > "$fixture_dir/terminal.plist"
}

case "${1:-}" in
  start)
    /usr/bin/swift build --package-path "$repo_root" --disable-automatic-resolution --skip-update
    /opt/homebrew/bin/xcodegen generate --no-env
    /usr/bin/xcodebuild \
      -project "$repo_root/Cockpit.xcodeproj" \
      -target CockpitPTYKeeper \
      -configuration Debug \
      OBJROOT="$repo_root/DerivedData/Build/Intermediates.noindex" \
      SYMROOT="$repo_root/DerivedData/Build/Products" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      build >/tmp/cockpit-phase0-keeper-build.log
    /bin/mkdir -p "$fixture_dir"

    stop_service dev.cockpit.host.local
    stop_service dev.cockpit.terminal.local
    cleanup_service_root

    service_root=""
    start_succeeded=0
    cleanup_failed_start() {
      local failure_status=$?
      trap - EXIT
      if [[ "$start_succeeded" == 0 ]]; then
        stop_service dev.cockpit.terminal.local
        stop_service dev.cockpit.host.local
        if [[ -n "$service_root" ]]; then
          cleanup_service_path "$service_root"
        else
          cleanup_service_root
        fi
      fi
      return "$failure_status"
    }
    trap cleanup_failed_start EXIT

    service_root=$(/usr/bin/mktemp -d /private/tmp/cockpit-phase0.XXXXXX)
    runtime_dir="$service_root/runtime"
    binary_dir="$service_root/bin"
    application_support_root="$service_root/storage"
    integration_master_key=$(/usr/bin/openssl rand -base64 32)
    /bin/chmod 700 "$service_root"
    print -r -- "$service_root" > "$service_root_record"
    /bin/mkdir "$runtime_dir" "$binary_dir" "$application_support_root"
    /bin/chmod 700 "$runtime_dir" "$binary_dir" "$application_support_root"

    /bin/cp -X "$repo_root/.build/debug/CockpitHost" "$binary_dir/CockpitHost"
    /bin/cp -X \
      "$repo_root/.build/debug/CockpitTerminalSupervisor" \
      "$binary_dir/CockpitTerminalSupervisor"
    /bin/cp -X \
      "$repo_root/DerivedData/Build/Products/Debug/CockpitPTYKeeper" \
      "$binary_dir/CockpitPTYKeeper"
    /bin/cp -X "$repo_root/.build/debug/CockpitProbe" "$binary_dir/CockpitProbe"

    host="$binary_dir/CockpitHost"
    terminal="$binary_dir/CockpitTerminalSupervisor"
    keeper="$binary_dir/CockpitPTYKeeper"
    probe="$binary_dir/CockpitProbe"

    bookmark_requirement='=designated => identifier "dev.cockpit.phase0.bookmark"'
    /usr/bin/codesign --force --sign - \
      --identifier dev.cockpit.phase0.bookmark \
      --requirements "$bookmark_requirement" \
      "$host"
    /usr/bin/codesign --force --sign - "$terminal"
    /usr/bin/codesign --force --sign - "$keeper"
    /usr/bin/codesign --force --sign - \
      --identifier dev.cockpit.phase0.bookmark \
      --requirements "$bookmark_requirement" \
      "$probe"

    render_host "$host"
    render_terminal "$terminal" "$keeper"

    /bin/launchctl bootstrap "$domain" "$fixture_dir/host.plist"
    if [[ "${COCKPIT_PHASE0_FAIL_AFTER_HOST_BOOTSTRAP:-0}" == 1 ]]; then
      print -u2 "injected failure after Host bootstrap"
      exit 70
    fi
    /bin/launchctl bootstrap "$domain" "$fixture_dir/terminal.plist"
    start_succeeded=1
    trap - EXIT
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
  create-terminal)
    load_service_root
    "$service_root/bin/CockpitProbe" create-terminal \
      "$service_root/runtime" "$repo_root"
    ;;
  *)
    print -u2 "usage: Tools/phase0-services.zsh start|stop|probe|create-terminal"
    exit 64
    ;;
esac
