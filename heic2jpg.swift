import Cocoa
import CoreServices
import ImageIO

// MARK: - FSEvents callback (free function for C interop)

private let fsCallback: FSEventStreamCallback = { _, _, numEvents, eventPaths, _, _ in
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    for i in 0..<numEvents {
        let path = paths[i]
        guard path.lowercased().hasSuffix(".heic") else { continue }
        guard FileManager.default.fileExists(atPath: path) else { continue }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > 0 else { continue }

        let jpgPath = (path as NSString).deletingPathExtension + ".jpg"
        guard !FileManager.default.fileExists(atPath: jpgPath) else { continue }

        let sourceURL = URL(fileURLWithPath: path)
        let destURL = URL(fileURLWithPath: jpgPath)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.jpeg" as CFString, 1, nil)
        else { continue }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)

        if CGImageDestinationFinalize(dest) {
            fputs("Converted: \(path) → \(jpgPath)\n", stderr)
        }
    }
}

// MARK: - App

class Heic2Jpg: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stream: FSEventStreamRef?
    private let defaults = UserDefaults(suiteName: "com.heic2jpg")!

    private var dirs: [String] {
        get {
            if let saved = defaults.stringArray(forKey: "watchedDirs") {
                return saved
            }
            // First run: seed from CLI args or defaults
            let initial: [String]
            if CommandLine.arguments.count > 1 {
                initial = Array(CommandLine.arguments.dropFirst())
            } else {
                initial = [
                    (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"),
                    (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                ]
            }
            defaults.set(initial, forKey: "watchedDirs")
            return initial
        }
        set {
            defaults.set(newValue, forKey: "watchedDirs")
        }
    }

    private var isEnabled: Bool {
        get { !defaults.bool(forKey: "disabled") }
        set { defaults.set(!newValue, forKey: "disabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
        if isEnabled { startWatching() }
        updateIcon()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(NSMenuItem.separator())

        // List watched folders
        for dir in dirs {
            let displayPath = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let item = NSMenuItem(title: displayPath, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let addItem = NSMenuItem(title: "Add Folder\u{2026}", action: #selector(addFolder), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        // Remove submenu
        if !dirs.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Folder", action: nil, keyEquivalent: "")
            let removeMenu = NSMenu()
            for dir in dirs {
                let displayPath = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                let sub = NSMenuItem(title: displayPath, action: #selector(removeFolder(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = dir
                removeMenu.addItem(sub)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: isEnabled ? "photo.fill" : "photo",
            accessibilityDescription: "heic2jpg"
        )
        button.alphaValue = isEnabled ? 1.0 : 0.5
    }

    @objc private func toggle() {
        if isEnabled {
            isEnabled = false
            stopWatching()
        } else {
            isEnabled = true
            startWatching()
        }
        rebuildMenu()
        updateIcon()
    }

    @objc private func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders to watch for HEIC files"

        guard panel.runModal() == .OK else { return }

        var current = dirs
        for url in panel.urls {
            let path = url.path
            if !current.contains(path) {
                current.append(path)
            }
        }
        dirs = current
        restartWatching()
        rebuildMenu()
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        var current = dirs
        current.removeAll { $0 == dir }
        dirs = current
        restartWatching()
        rebuildMenu()
    }

    private func restartWatching() {
        guard isEnabled else { return }
        stopWatching()
        if !dirs.isEmpty { startWatching() }
    }

    private func startWatching() {
        guard stream == nil, !dirs.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)

        guard let s = FSEventStreamCreate(
            nil, fsCallback, &context,
            dirs as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    @objc private func quit() {
        stopWatching()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Heic2Jpg()
app.delegate = delegate
app.run()
