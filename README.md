<div align="center">

<img src="Resources/AppIcon.png" width="128" alt="NotchDeck icon">

# NotchDeck

**A control panel that drops down from your Mac's menu bar.**

English · [简体中文](README.zh-CN.md)

</div>

NotchDeck is a small native macOS menu bar app written in Swift and SwiftUI. Click its menu bar icon, or press
**⌥⌘N**, and a panel opens with your todos, today's agenda, system stats, clipboard history, timers, music controls
and quick system toggles. It has no Dock icon and needs no account.

![NotchDeck home page](docs/media/home.png)

## Screenshots

| System monitor | Clipboard history |
| --- | --- |
| ![System monitor](docs/media/monitor.png) | ![Clipboard history](docs/media/clipboard.png) |
| **Quick controls** | **Search** |
| ![Quick controls](docs/media/controls.png) | ![Search](docs/media/search.png) |
| **Music** | **Timers** |
| ![Music](docs/media/music.png) | ![Timers](docs/media/timer.png) |
| **Second home page** | **AI token usage** |
| ![Second home page](docs/media/home2.png) | ![AI token usage](docs/media/usage.png) |

**Look Busy**

![Look Busy scene](docs/media/lookbusy.png)

The screenshots use made-up demo data and show the Chinese interface. Other languages are available in Settings.

## Features

- **Home cards**: todos, today's agenda, sticky note, clock, system monitor, music, clipboard, timer, month calendar
  and Look Busy. Reorder, hide or move them across two pages. Double-click a to-do to edit it.
- **Today's agenda**: upcoming events from the system Calendar, a countdown to the next one, and a join button for
  Zoom, Google Meet, Teams, Webex, Tencent Meeting, Feishu and DingTalk links.
- **System monitor**: CPU, GPU, battery and SSD temperatures, power draw, memory pressure, swap, disk usage, upload
  and download speed, battery health and cycle count, top processes, and 10-minute history charts. CPU, GPU and temperature readings are smoothed so
  they are easier to read.
- **Menu bar**: show any mix of temperature, CPU load, network speed and battery next to the icon. Right-click the
  icon for search, clipboard, the monitor, audio output, a quick countdown, keep awake, Look Busy, display sleep, screen
  lock and update checks. A cup appears next to the icon while keep awake is on.
- **AI token usage** (optional, off by default): token counts per model for Claude Code and Codex, for today, 7 days or 30 days, split into input, cache reads, cache writes and output, with the cost in US dollars estimated at official API prices. NotchDeck reads only the usage fields of their local records on your Mac, never your conversations.
- **Clipboard history**: text, images and files, with search and pinning. Items marked as sensitive by password
  managers are skipped. Right-click an image to copy the text in it, recognized on your Mac. Text over about 1 MB is not recorded. History stays in memory unless you turn on saving;
  images are never written to disk.
- **Timers**: countdown, stopwatch with laps, and a 25-minute focus timer.
- **Music**: now-playing title, artwork, progress, playback controls and system volume.
- **Search**: apps, files (through Spotlight), todos, notes and clipboard history, with a web search fallback.
- **Quick controls**: Wi-Fi, Bluetooth, dark mode, Night Shift, keep awake (indefinitely or for 15 minutes to 12 hours), mute, audio output, volume, built-in display
  brightness, screenshot, display sleep and lock screen, plus battery levels for connected Bluetooth devices.
- **Reminders sync** (optional): use a list from the system Reminders app as your todo card.
- **Look Busy**: four convincing full-screen work scenes for demos and screenshots. Nothing they show is real.
- **Appearance**: light, dark or follow the system.
- **Languages**: Simplified and Traditional Chinese, English, Japanese, Korean, French, German and Spanish. Switch in Settings without restarting.
- **Update reminders**: checks GitHub for a new release once a day and tells you when one is available. It only reads
  the version number, and you can turn it off in Settings.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⌘N | Open or close the panel |
| ⌃⌥V | Open or close the clipboard page |
| ⌃⌥B | Start or stop Look Busy |
| Esc | Close the panel or leave Look Busy |

Right-click or Control-click the menu bar icon to open the shortcut menu.

## Install

### Download

Download the latest `.dmg` from [Releases](https://github.com/wangwenxuan61/NotchDeck/releases), open it and drag
NotchDeck to Applications. It requires macOS 14 or later on an Apple silicon Mac.

NotchDeck is not notarized by Apple, so macOS blocks it the first time:

1. Open NotchDeck once and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to NotchDeck.

### Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/wangwenxuan61/NotchDeck.git
cd NotchDeck
./build.sh
open build/NotchDeck.app
```

To keep it around, and before you enable *Launch at login*, move `build/NotchDeck.app` to your Applications folder.

Before committing, run the checks. `swift run NotchDeckChecks` covers the logic that needs no UI or permissions, and `python3 scripts/check-translations.py` makes sure every language has every string. GitHub runs both on each push.

## Permissions

NotchDeck only asks when you turn on a feature that needs it:

- **Bluetooth**: for the Bluetooth toggle and device battery levels.
- **Reminders**: for Reminders sync. Turning sync on moves your unfinished local todos into the selected list.
- **Calendar**: for the agenda card. NotchDeck only reads your events.
- **Notifications**: for countdown and focus alerts, so you see them even when you are away. NotchDeck asks the first time you start a timer.

The app is ad-hoc signed, so macOS may ask for these permissions again after an update or rebuild.

Do Not Disturb has no public API. To link it with the focus timer, create two Shortcuts named `NotchDeck 专注开始` and
`NotchDeck 专注结束`, and NotchDeck will run them when a focus session starts and ends.

## Limitations

- Temperatures, now-playing data, dark mode, Night Shift, brightness, Bluetooth power and screen lock rely on private
  macOS interfaces. They can stop working after a system update, and the app cannot be distributed through the Mac App
  Store.
- The brightness slider only controls the built-in display.
- So far it has only been run on an Apple silicon Mac with macOS 27. Sensor names can differ on other models.

## License

[MIT](LICENSE)
