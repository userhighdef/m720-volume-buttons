#!/bin/zsh
set -euo pipefail

service_label="local.m720.volume-buttons"
service_domain="gui/$(id -u)"
support_dir="$HOME/Library/Application Support/M720VolumeButtons"
service_plist="$HOME/Library/LaunchAgents/$service_label.plist"

if launchctl print "$service_domain/$service_label" >/dev/null 2>&1; then
    launchctl bootout "$service_domain/$service_label"
fi

rm -f -- "$service_plist"
rm -rf -- "$support_dir"

print "Removed the M720 volume-button LaunchAgent and binary."
print "You can also remove m720-volume-buttons from"
print "System Settings > Privacy & Security > Accessibility."
