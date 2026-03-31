# heic2jpg

A tiny macOS daemon that automatically converts HEIC images to JPEG the moment they appear on your system. No manual conversion, no right-click menus, no Shortcuts — just drop a HEIC file in a watched folder and a JPEG appears in its place.

## Why

Apple defaults to HEIC for photos, but almost nothing outside the Apple ecosystem accepts it. Every time you AirDrop a photo, export from Photos, or download from iCloud, you get a file you can't easily share, upload, or use. This fixes that permanently.

## How it works

A lightweight background daemon watches your Desktop and Downloads folders (configurable) using macOS [FSEvents](https://developer.apple.com/documentation/coreservices/file_system_events). When a `.heic` file appears:

1. Converts it to JPEG (90% quality) using Apple's native `ImageIO` framework — in-process, no shelling out
2. Preserves all EXIF metadata (camera info, GPS, timestamps, etc.)
3. The `.jpg` appears right next to the original HEIC (which is kept)

The daemon uses file-level FSEvents — it doesn't scan directories or poll. It reacts only to HEIC files, ignores everything else, and uses near-zero CPU and memory while idle. Events are coalesced with a 1-second window so batch operations (like a multi-file AirDrop) are handled efficiently.

No third-party dependencies. No Apple Developer account required. Just Swift and the macOS system frameworks.

## Requirements

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools

If you don't have the command line tools:

```sh
xcode-select --install
```

## Install

```sh
git clone https://github.com/brennancheung/heic2jpg.git
cd heic2jpg
./install.sh
```

This compiles the Swift source, creates an app bundle at `~/Applications/heic2jpg.app`, and registers a `launchd` agent that starts automatically on login.

By default it watches `~/Desktop` and `~/Downloads`. To watch different directories:

```sh
./install.sh ~/Pictures ~/Documents ~/Desktop
```

You can also add and remove folders from the menu bar icon after installation.

## Uninstall

```sh
./uninstall.sh
```

Stops the daemon and removes the binary and launch agent.

## Logs

Conversion activity is logged to `/tmp/heic2jpg.log`:

```
Watching for HEIC files in: /Users/you/Desktop, /Users/you/Downloads
Converted: /Users/you/Desktop/IMG_1234.heic → /Users/you/Desktop/IMG_1234.jpg
```

## How it works (technical)

The entire program is a single Swift file. It creates an `FSEventStream` with the `kFSEventStreamCreateFlagFileEvents` flag, which provides file-level (not directory-level) notifications from the kernel. The callback checks if the event path ends in `.heic`, verifies the file exists and has a non-zero size (to skip in-progress writes), then converts it using `ImageIO` (`CGImageSource` → `CGImageDestination`) entirely in-process — no subprocess spawning, no CLI tools. EXIF metadata is read from the source and written to the JPEG. The stream is scheduled on a GCD dispatch queue — no run loop, no polling, no periodic scanning.

The `launchd` agent is configured with `KeepAlive: true`, so macOS will restart the daemon if it ever crashes, and `RunAtLoad: true` so it starts on login.

## License

MIT
