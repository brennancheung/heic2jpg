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

// MARK: - Single Instance

private let kShowSettingsNotification = "com.heic2jpg.showSettings"
private let pidFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".heic2jpg.pid")

private func existingInstancePid() -> pid_t? {
    guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
          let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid != ProcessInfo.processInfo.processIdentifier,
          kill(pid, 0) == 0 else {
        return nil
    }
    return pid
}

private func writePidFile() {
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
        toFile: pidFilePath, atomically: true, encoding: .utf8
    )
}

private func removePidFile() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}

// MARK: - App

class Heic2Jpg: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var statusItem: NSStatusItem?
    private var stream: FSEventStreamRef?
    private let defaults = UserDefaults(suiteName: "com.heic2jpg")!
    private var settingsWindow: NSWindow?
    private var foldersTableView: NSTableView?
    private var enabledCheckbox: NSButton?
    private var menuBarCheckbox: NSButton?

    private var dirs: [String] {
        get {
            if let saved = defaults.stringArray(forKey: "watchedDirs") {
                return saved
            }
            let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("--") }
            let initial: [String]
            if !args.isEmpty {
                initial = args
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

    private var showMenuBarIcon: Bool {
        get { !defaults.bool(forKey: "hideMenuBarIcon") }
        set { defaults.set(!newValue, forKey: "hideMenuBarIcon") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        writePidFile()

        if showMenuBarIcon {
            setupStatusItem()
        }
        if isEnabled { startWatching() }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettings),
            name: NSNotification.Name(kShowSettingsNotification),
            object: nil
        )

        if !CommandLine.arguments.contains("--quiet") {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatching()
        removePidFile()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
        updateIcon()
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func rebuildMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(menuToggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: isEnabled ? "photo.fill" : "photo",
            accessibilityDescription: "heic2jpg"
        )
        button.alphaValue = isEnabled ? 1.0 : 0.5
    }

    @objc private func menuToggleEnabled() {
        isEnabled = !isEnabled
        if isEnabled { startWatching() } else { stopWatching() }
        rebuildMenu()
        updateIcon()
        enabledCheckbox?.state = isEnabled ? .on : .off
    }

    // MARK: - Settings Window

    @objc func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 420
        let height: CGFloat = 360

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "heic2jpg Settings"
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        let content = window.contentView!
        let margin: CGFloat = 20
        var y = height - margin

        // Enabled checkbox
        y -= 24
        let enabled = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(settingsToggleEnabled(_:)))
        enabled.frame = NSRect(x: margin, y: y, width: 200, height: 20)
        enabled.state = isEnabled ? .on : .off
        content.addSubview(enabled)
        enabledCheckbox = enabled

        // Menu bar checkbox
        y -= 28
        let menuBar = NSButton(checkboxWithTitle: "Show in Menu Bar", target: self, action: #selector(settingsToggleMenuBar(_:)))
        menuBar.frame = NSRect(x: margin, y: y, width: 200, height: 20)
        menuBar.state = showMenuBarIcon ? .on : .off
        content.addSubview(menuBar)
        menuBarCheckbox = menuBar

        // Hint
        y -= 18
        let hint = NSTextField(labelWithString: "Relaunch heic2jpg to open this window")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: margin + 18, y: y, width: 300, height: 14)
        content.addSubview(hint)

        // Watched Folders label
        y -= 28
        let label = NSTextField(labelWithString: "Watched Folders:")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: margin, y: y, width: 200, height: 18)
        content.addSubview(label)

        // Table
        y -= 6
        let tableHeight: CGFloat = 130
        let tableY = y - tableHeight
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: tableY, width: width - margin * 2, height: tableHeight))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Folder"
        column.width = scrollView.contentSize.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        content.addSubview(scrollView)
        foldersTableView = tableView
        y = tableY

        // Add / Remove buttons
        y -= 32
        let addBtn = NSButton(title: "Add Folder\u{2026}", target: self, action: #selector(settingsAddFolder))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: margin, y: y, width: 110, height: 24)
        content.addSubview(addBtn)

        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(settingsRemoveFolder))
        removeBtn.bezelStyle = .rounded
        removeBtn.frame = NSRect(x: margin + 118, y: y, width: 80, height: 24)
        content.addSubview(removeBtn)

        // Bottom row
        let bottomY: CGFloat = margin
        let quitBtn = NSButton(title: "Quit heic2jpg", target: self, action: #selector(quit))
        quitBtn.bezelStyle = .rounded
        quitBtn.frame = NSRect(x: margin, y: bottomY, width: 120, height: 24)
        content.addSubview(quitBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(settingsDone))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: width - margin - 80, y: bottomY, width: 80, height: 24)
        content.addSubview(doneBtn)

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsToggleEnabled(_ sender: NSButton) {
        isEnabled = sender.state == .on
        if isEnabled { startWatching() } else { stopWatching() }
        rebuildMenu()
        updateIcon()
    }

    @objc private func settingsToggleMenuBar(_ sender: NSButton) {
        showMenuBarIcon = sender.state == .on
        if showMenuBarIcon {
            setupStatusItem()
        } else {
            removeStatusItem()
        }
    }

    @objc private func settingsAddFolder() {
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
        foldersTableView?.reloadData()
    }

    @objc private func settingsRemoveFolder() {
        guard let tableView = foldersTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < dirs.count else { return }
        var current = dirs
        current.remove(at: row)
        dirs = current
        restartWatching()
        tableView.reloadData()
    }

    @objc private func settingsDone() {
        settingsWindow?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return dirs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FolderCell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
        if cell == nil {
            cell = NSTextField(labelWithString: "")
            cell?.identifier = id
        }
        cell?.stringValue = dirs[row].replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return cell
    }

    // MARK: - FSEvents

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
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

// If an existing instance is running, signal it to show settings and exit
if existingInstancePid() != nil {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name(kShowSettingsNotification),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    Thread.sleep(forTimeInterval: 0.5)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Heic2Jpg()
app.delegate = delegate
app.run()
