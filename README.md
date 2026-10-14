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

- **Drop files or whole folders** from Finder, onto the Dock icon, or click the drop zone to pick them — the transfer starts immediately
- **Real progress**: bytes sent, speed and time left, a Dock badge with the percentage, and a **Cancel** button (the half-written file is removed)
- **Drop more while sending** — new drops are queued and sent next
- **Pick the destination on the device**: type a path into *Send to* (default `/sdcard/Download`, recent folders in the drop-down; `Music/Rock` means `/sdcard/Music/Rock`) or click **Browse…** to walk the phone's storage, create a folder and hit *Send Here*
- **Creates missing folders** on the device, including whole nested paths that don't exist yet
- **Detects the phone automatically** and shows its name, Android version and free space; tells you when the phone is waiting for the USB debugging prompt
- **Handles awkward file names** — spaces, Cyrillic, emoji, quotes and parentheses; Finder litter (`.DS_Store`, `._*`) is skipped
- **Reliable on big libraries**: failed pushes are retried, a disconnected phone stops the transfer instead of failing every remaining file, and a *Retry Failed* button resends only what didn't make it
- Checks free space on the device before starting; keeps the Mac awake while sending
- **See exactly what was sent**: click the summary under the progress bar (or *File → Show Last Transfer*, ⌘R) for a list of every file with its destination, size and, for failures, the ADB error — filter by *Sent*/*Failed* and copy the list
- **Tells you what actually went wrong**: failures show the real ADB output, and everything is logged to `~/Library/Logs/AndroidDrop.log` (*File → Show Log*)
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

Grab `AndroidDrop-v1.0.1.zip` from [Releases](../../releases), unzip and move **Android Drop.app** to `/Applications`.

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
2. Optionally change *Send to* or pick a folder with **Browse…** (⌘B). The path is used as typed — no need to press Return.
3. Drop files or folders onto the window (or press ⌘O).

The status line ends with `Done` and a summary (`302 file(s) · 79 MB in 11 s`) — click it to see which files were sent and where. If anything failed, an alert lists the files with the ADB message and offers **Retry Failed**.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No device connected` | Check the cable (some are charge-only) and that USB debugging is on. |
| `Waiting for permission` | Unlock the phone and accept the "Allow USB debugging?" prompt. |
| `adb not found` | Install Platform Tools (see above) and relaunch. |
| `Can't create the destination folder` | The path must be under shared storage, e.g. `/sdcard/...`; system folders are read-only without root. |
| Something else | `tail -f ~/Library/Logs/AndroidDrop.log` |

## Changelog

### 1.0.1

- Fixed: one random file per transfer could fail with `ADB: The operation couldn't be completed. Bad file descriptor`. adb is now launched with `posix_spawn` instead of `NSTask`, and failed launches and pushes are retried.
- Fixed: a folder typed into *Send to* was ignored unless you pressed Return, so files went to the default folder. Missing nested folders are now created.
- Default destination is `/sdcard/Download` (the folder Android actually uses), not `/sdcard/Downloads`.
- Much faster on big folders: directories are created in a few batched calls instead of one call per file.
- New: click the transfer summary to see the list of sent and failed files.
- Byte progress with speed and time left, Cancel, queued drops, Dock icon drops, *Retry Failed*, free-space check, stop on disconnect.
- Redesigned window with dark mode support, device info (Android version, free space), recent destinations, and *New Folder* in the browser.

### 1.0.0

- First release.

## License

[MIT](LICENSE)
