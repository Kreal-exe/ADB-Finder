<p align="center">
  <img src="AndroidDropIcon.png" alt="Android Drop icon" width="128" height="128">
</p>

<h1 align="center">Android Drop</h1>

<p align="center">
  Drag files onto a window, they land on your Android phone.<br>
  A tiny native macOS app on top of <code>adb push</code> — no Android File Transfer, no MTP, no cloud.
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Android Drop window" width="560">
</p>

## Why

Android File Transfer is discontinued and was never reliable; MTP on macOS is worse. ADB, on the other hand, is fast and rock solid — it just has no UI. Android Drop is that UI: one window, one drop zone.

## Features

- **Drop files or whole folders** from Finder — the transfer starts immediately, with a progress bar and a `Sending · 3 of 12` counter
- **Pick the destination on the device**: type a path into *Send to* (default `/sdcard/Downloads`) or click **Browse…** to walk the phone's storage and hit *Send Here*
- **Detects the phone automatically** and shows its marketing name (`Connected · Pixel 8`), refreshing as you plug and unplug
- **Handles awkward file names** — spaces, Cyrillic, emoji, quotes and parentheses are shell-quoted before they reach `adb shell`
- **Creates missing folders** on the device (`mkdir -p`) before pushing
- **Tells you what actually went wrong**: failed transfers show the real ADB output, and everything is logged to `~/Library/Logs/AndroidDrop.log`
- Native Cocoa, a single Objective-C file, ~800 KB app, no dependencies besides `adb`

## Requirements

- macOS 12 Monterey or later (Apple Silicon or Intel)
- `adb` from Android Platform Tools:

  ```bash
  brew install android-platform-tools
  ```

  The app looks for it in `/opt/homebrew/bin`, `/usr/local/bin`, `~/Library/Android/sdk/platform-tools`, `/usr/bin`, then `$PATH`.
- A phone with **USB debugging** enabled: *Settings → About phone →* tap *Build number* seven times, then *Settings → System → Developer options → USB debugging*. Accept the "Allow USB debugging?" prompt the first time you connect.

Wireless debugging works too — anything that shows up in `adb devices` does.

## Install

Grab `AndroidDrop-v17.0.zip` from [Releases](../../releases), unzip and move **Android Drop.app** to `/Applications`.

The build is not notarized, so on first launch right-click the app → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Android Drop.app"
```

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/Kreal-exe/AndroidDrop.git
cd AndroidDrop
./build.command
```

The script compiles `AndroidDrop/main.m` with `clang`, generates the `.icns` from `AndroidDropIcon.png` and assembles **Android Drop.app** next to it. You can also just double-click `build.command` in Finder.

## Usage

1. Connect the phone and wait for the green **Connected** label.
2. Optionally change *Send to* or pick a folder with **Browse…**.
3. Drop files or folders onto the window.

The status line ends with `Done · N file(s)` or `Finished · N sent · M failed`; details for failures are in the alert and in the log.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No Android device` | Check the cable (some are charge-only), unlock the phone, accept the debugging prompt. `adb devices` should list it as `device`, not `unauthorized`. |
| `ADB is not available` | Install Platform Tools (see above) and relaunch. |
| `Cannot create destination` | The path must be under shared storage, e.g. `/sdcard/...`; system folders are read-only without root. |
| Something else | `tail -f ~/Library/Logs/AndroidDrop.log` |

## License

[MIT](LICENSE)
