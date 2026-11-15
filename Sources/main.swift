import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = Settings.shared
    private let indexer = Indexer.shared
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = event.eventID == AEEventID(kAEOpenApplication)
                && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerMoveToApplications() { return }
        // Indexing reads at low priority so it never gets in the way of copying to or from the drive.
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)

        NSApp.mainMenu = makeMainMenu()
        settings.onMenuBarChange = { [weak self] in self?.updateStatusItem() }
        settings.onChange = { [weak self] in self?.indexer.rewriteAllReports() }
        updateStatusItem()
        indexer.start()

        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMain()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return false
    }

    // MARK: Windows

    @objc func showMain() {
        if mainWindow == nil {
            mainWindow = makeWindow(title: "Drive Index Utility",
                                    view: MainView(openSettings: { [weak self] in self?.showSettings() }))
        }
        present(mainWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Settings", view: SettingsView(chooseFolder: { [weak self] in self?.chooseFolder() }))
        }
        present(settingsWindow)
    }

    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let open = [self.mainWindow, self.settingsWindow].contains { $0?.isVisible == true }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Reports and the drive catalog are saved here. Pick a folder in iCloud Drive, Dropbox or Google Drive to see them on other devices."
        panel.directoryURL = settings.outputFolder.deletingLastPathComponent()
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.outputFolder = url
        }
        if let window = settingsWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if settings.showInMenuBar {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Drive Index Utility")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "Drive Index Utility"
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if indexer.drives.isEmpty {
            let none = NSMenuItem(title: "No drives connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for drive in indexer.drives {
            let item = NSMenuItem(title: drive.name, action: nil, keyEquivalent: "")
            item.attributedTitle = twoLine(drive.name, status(of: drive))
            item.image = NSImage(systemSymbolName: drive.symbol, accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            let busy = indexer.isBusy(drive.id)
            sub.addItem(action(busy ? "Cancel" : "Index Now", drive) { [weak self] d in
                guard let self else { return }
                if self.indexer.isBusy(d.id) { self.indexer.cancel(d.id) } else { self.indexer.index(d) }
            })
            if drive.isEjectable {
                sub.addItem(action("Index and Eject", drive) { [weak self] in self?.indexer.indexAndEject($0) })
            }
            let report = action("Open Report", drive) { [weak self] d in
                if let url = self?.indexer.reportURL(for: d.id) { NSWorkspace.shared.open(url) }
            }
            report.isEnabled = indexer.reportURL(for: drive.id) != nil
            sub.addItem(report)
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let catalog = NSMenuItem(title: "Open Catalog", action: #selector(openCatalog), keyEquivalent: "")
        catalog.target = self
        catalog.isEnabled = FileManager.default.fileExists(atPath: indexer.catalogURL.path)
        catalog.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        menu.addItem(catalog)
        let open = NSMenuItem(title: "Open Drive Index Utility", action: #selector(showMain), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    private func status(of drive: Drive) -> String {
        switch indexer.activity[drive.id] ?? .idle {
        case .scanning(_, let fraction):
            return fraction.map { "Indexing · \(Int($0 * 100))%" } ?? "Indexing…"
        case .failed: return "Couldn't index"
        case .idle:
            if let date = indexer.lastIndexed[drive.id] { return "Indexed \(Format.relative(date))" }
            return "Not indexed"
        }
    }

    private func twoLine(_ title: String, _ subtitle: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        s.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return s
    }

    private func action(_ title: String, _ drive: Drive, _ run: @escaping (Drive) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runHandler(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = { run(drive) } as () -> Void
        return item
    }

    @objc private func runHandler(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    @objc private func openCatalog() {
        NSWorkspace.shared.open(indexer.catalogURL)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Drive Index Utility", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Drive Index Utility", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Drive Index Utility", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let drives = NSMenuItem(title: "Drives", action: #selector(showMain), keyEquivalent: "0")
        drives.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(drives)
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    // MARK: Move to Applications

    /// If the app was opened straight from the disk image (or a quarantined copy that macOS translocated),
    /// offer to copy it into /Applications and relaunch from there.
    private func offerMoveToApplications() -> Bool {
        let source = Bundle.main.bundleURL
        let path = source.path
        let onDiskImage = path.hasPrefix("/Volumes/")
        guard onDiskImage || path.contains("/AppTranslocation/") else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Drive Index Utility to Applications?"
        alert.informativeText = onDiskImage
            ? "It's running from the disk image. Move it to Applications so it keeps working after you eject the disk image."
            : "Move it to Applications so it can open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != NSRunningApplication.current {
            other.terminate()
        }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try fm.copyItem(at: source, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move Drive Index Utility"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Drive Index Utility into the Applications folder yourself."
            failure.runModal()
            return false
        }

        let volume = onDiskImage ? "/" + source.pathComponents.prefix(3).dropFirst().joined(separator: "/") : ""
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; [ -n \"$3\" ] && hdiutil detach \"$3\" -quiet; open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path, volume,
        ]
        do { try relaunch.run() } catch { return false }
        NSApp.terminate(nil)
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
