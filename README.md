<div align="center">

<img src="Resources/AppIcon.png" width="128" alt="NotchDeck icon">

# NotchDeck

**A control panel that drops down from your Mac's menu bar.**

English · [简体中文](README.zh-CN.md)

</div>

NotchDeck is a small native macOS menu bar app written in Swift and SwiftUI. Click its menu bar icon, or press
**⌥⌘N**, and a panel opens with your todos, system stats, clipboard history, timers, music controls and quick
system toggles. It has no Dock icon and needs no account.

## Features

- **Home cards**: todos, sticky note, clock, system monitor, music, clipboard, timer, month calendar and Look Busy.
  Reorder, hide or move them across two pages.
- **System monitor**: CPU, GPU, battery and SSD temperatures, power draw, memory pressure, swap, disk usage, upload
  and download speed, top processes, and 10-minute history charts. The CPU temperature can also be shown in the menu
  bar.
- **Clipboard history**: text, images and files, with search and pinning. Items marked as sensitive by password
  managers are skipped. History stays in memory unless you turn on saving; images are never written to disk.
- **Timers**: countdown, stopwatch with laps, and a 25-minute focus timer.
- **Music**: now-playing title, artwork, progress, playback controls and system volume.
- **Search**: apps, files (through Spotlight), todos, notes and clipboard history, with a web search fallback.
- **Quick controls**: Wi-Fi, Bluetooth, dark mode, Night Shift, keep awake, mute, volume, brightness, screenshot, display
  sleep and lock screen, plus battery levels for connected Bluetooth devices.
- **Reminders sync** (optional): use a list from the system Reminders app as your todo card.
- **Look Busy**: four convincing full-screen work scenes for demos and screenshots. Nothing they show is real.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⌘N | Open or close the panel |
| ⌃⌥V | Open or close the clipboard page |
| ⌃⌥B | Start or stop Look Busy |
| Esc | Close the panel or leave Look Busy |

## Install

NotchDeck requires macOS 14 or later and is built from source. You only need the Xcode Command Line Tools
(`xcode-select --install`).

```bash
git clone https://github.com/wangwenxuan61/NotchDeck.git
cd NotchDeck
./build.sh
open build/NotchDeck.app
```

To keep it around, and before you enable *Launch at login*, move `build/NotchDeck.app` to your Applications folder.

## Permissions

NotchDeck only asks when you turn on a feature that needs it:

- **Bluetooth**: for the Bluetooth toggle and device battery levels.
- **Reminders**: for Reminders sync. Turning sync on moves your unfinished local todos into the selected list.

The app is ad-hoc signed, so macOS may ask for these permissions again after you rebuild it.

Do Not Disturb has no public API. To link it with the focus timer, create two Shortcuts named `NotchDeck 专注开始` and
`NotchDeck 专注结束`, and NotchDeck will run them when a focus session starts and ends.

## Limitations

- Temperatures, now-playing data, dark mode, Night Shift, brightness, Bluetooth power and screen lock rely on private
  macOS interfaces. They can stop working after a system update, and the app cannot be distributed through the Mac App
  Store.
- So far it has only been run on an Apple silicon Mac with macOS 27. Sensor names can differ on other models.

## License

[MIT](LICENSE)
