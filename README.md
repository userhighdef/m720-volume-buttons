# M720 Volume Buttons for macOS

A small standalone remapper for the Logitech M720 Triathlon:

- **Forward** → **Volume Up**
- **Back** → **Volume Down**

It runs as a per-user macOS LaunchAgent, starts automatically at login, and keeps working after sleep or Bluetooth reconnection. Logi Options+ and OpenLogi are not runtime dependencies.

## Device scope

The remapper activates only while a Logitech M720 with `VID:PID 046d:b015` is connected. macOS does not retain a physical sender ID on the M720's button 3/4 `CGEvent`s, so while the M720 is connected those two global side-button numbers are remapped. If you use a second mouse at the same time, its Back and Forward buttons will therefore receive the same mapping.

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

```sh
chmod +x install.sh uninstall.sh
./install.sh
```

The installer will:

1. Compile the Objective-C remapper as a native Apple Silicon or Intel binary.
2. Install it at `~/Library/Application Support/M720VolumeButtons/m720-volume-buttons`.
3. Install and load `~/Library/LaunchAgents/local.m720.volume-buttons.plist`.
4. Open the installed-binary folder and the Accessibility settings page.

macOS does not allow a script to grant Accessibility/TCC permission automatically. Click `+` in **System Settings > Privacy & Security > Accessibility**, add the installed `m720-volume-buttons` binary, and enable its switch. The already-running service detects the permission automatically.

When rebuilding, remove the old Accessibility entry and add the new binary again because an ad-hoc signature receives a new `cdhash` after compilation.

## Verification

Check the permission and LaunchAgent:

```sh
~/Library/Application\ Support/M720VolumeButtons/m720-volume-buttons --check
launchctl print gui/$(id -u)/local.m720.volume-buttons
```

Watch remapped button presses:

```sh
tail -f ~/Library/Logs/M720VolumeButtons.out.log
tail -f ~/Library/Logs/M720VolumeButtons.err.log
```

You can also test media-key injection directly:

```sh
~/Library/Application\ Support/M720VolumeButtons/m720-volume-buttons --volume-up
~/Library/Application\ Support/M720VolumeButtons/m720-volume-buttons --volume-down
```

## Using it alongside OpenLogi

This tool does not require OpenLogi. If OpenLogi's mouse-event agent is also running, avoid maintaining different assignments for the M720 Back and Forward buttons in both tools; two active remappers can otherwise make the result depend on event-tap ordering.

## Uninstallation

```sh
./uninstall.sh
```

Afterward, remove `m720-volume-buttons` from Accessibility manually.

## Implementation

The daemon uses a `CGEventTap` at the HID level, confirms through IOKit that an M720 is connected, suppresses button 3/4 events, and posts native macOS system-defined volume-key events. It checks Accessibility permission every 500 ms and tears down the tap if permission is revoked.

## License

MIT
