#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h}
service_label="local.m720.volume-buttons"
service_domain="gui/$(id -u)"
support_dir="$HOME/Library/Application Support/M720VolumeButtons"
launchagents_dir="$HOME/Library/LaunchAgents"
logs_dir="$HOME/Library/Logs"
program="$support_dir/m720-volume-buttons"
service_plist="$launchagents_dir/$service_label.plist"
stdout_log="$logs_dir/M720VolumeButtons.out.log"
stderr_log="$logs_dir/M720VolumeButtons.err.log"

required_tools=(clang codesign launchctl plutil open)
for required_tool in $required_tools; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        print -u2 "Missing required tool: $required_tool"
        print -u2 "Install the Xcode Command Line Tools, then retry:"
        print -u2 "  xcode-select --install"
        exit 1
    fi
done

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/m720-volume-buttons.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM

program_build="$temporary_root/m720-volume-buttons"
plist_build="$temporary_root/$service_label.plist"

print "Compiling the M720 volume-button remapper..."
clang -fobjc-arc -O2 -Wall -Wextra -Werror \
    "$repo_dir/src/m720_volume_buttons.m" \
    -o "$program_build" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreFoundation \
    -framework IOKit

mkdir -p "$support_dir" "$launchagents_dir" "$logs_dir"
install -m 0755 "$program_build" "$program"
codesign --force --sign - "$program"

cp "$repo_dir/launchagent/local.m720.volume-buttons.plist.in" "$plist_build"
plutil -remove ProgramArguments.0 "$plist_build"
plutil -insert ProgramArguments.0 -string "$program" "$plist_build"
plutil -replace StandardOutPath -string "$stdout_log" "$plist_build"
plutil -replace StandardErrorPath -string "$stderr_log" "$plist_build"
plutil -lint "$plist_build" >/dev/null
install -m 0644 "$plist_build" "$service_plist"

if launchctl print "$service_domain/$service_label" >/dev/null 2>&1; then
    launchctl bootout "$service_domain/$service_label" || true
fi
launchctl bootstrap "$service_domain" "$service_plist"
launchctl kickstart -k "$service_domain/$service_label"

open "$support_dir"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

print ""
print "Build and LaunchAgent installation completed."
print ""
print "macOS does not allow scripts to grant Accessibility permission automatically."
print "In Privacy & Security > Accessibility:"
print "  1. Remove a stale m720-volume-buttons row if one is present."
print "  2. Click + and add this current binary:"
print "     $program"
print "  3. Enable its switch. The running service will activate automatically."
print ""
print "Mapping: Forward -> Volume Up, Back -> Volume Down"
print "LaunchAgent: $service_domain/$service_label"
print "Logs: $stdout_log and $stderr_log"

if pgrep -x openlogi-agent >/dev/null 2>&1; then
    print ""
    print "Note: OpenLogi's mouse-event agent is also running."
    print "Avoid assigning these two buttons in both tools if you later change either mapping."
fi
