# heic2jpg

A macOS daemon that automatically converts HEIC files to JPEG.

## Architecture

Single-file Swift program (`heic2jpg.swift`) that uses the macOS FSEvents API with file-level event flags (`kFSEventStreamCreateFlagFileEvents`). It watches specified directories and converts any `.heic` file that appears using the native `ImageIO` framework (CGImageSource/CGImageDestination) — no shelling out to CLI tools. EXIF metadata is preserved. The original HEIC is kept; a `.jpg` is created alongside it.

## Key design decisions

- **FSEvents with file-level events** — only notified about individual file changes, never scans directories
- **1-second coalescing** — batches rapid events (e.g., multi-file AirDrop)
- **Zero-byte skip** — ignores files still being written
- **No dependencies** — uses only macOS system frameworks (CoreServices, ImageIO)
- **EXIF preservation** — metadata carries over from HEIC to JPEG via ImageIO
- **No subprocess spawning** — conversion happens in-process via CGImageDestination
- **Custom watch paths** — pass directories as CLI arguments; defaults to ~/Desktop and ~/Downloads

## Building

```
swiftc -O -o heic2jpg heic2jpg.swift
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Install / Uninstall

```
./install.sh                          # watch Desktop + Downloads
./install.sh ~/Pictures ~/Documents   # watch custom directories
./uninstall.sh
```
