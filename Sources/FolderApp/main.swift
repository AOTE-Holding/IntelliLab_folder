//
//  main.swift
//  Folder
//
//  App entry point for command-line executable
//

import AppKit
import SwiftUI

// Create app delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: NSWindowController?
    var settingsWindowController: NSWindowController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        Task { @MainActor in
            self.setupStatusBarIcon()
            self.setupGlobalHotkey()
        }

        // Register for URL events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Create the main window using window controller
        let contentView = ContentView()
            .environmentObject(SettingsManager.shared)

        mainWindowController = SwiftUIWindowController(
            rootView: contentView,
            title: "Folder",
            size: NSSize(width: 1000, height: 700)
        )

        mainWindowController?.window?.setFrameAutosaveName("MainWindow")
        mainWindowController?.showWindow(nil)

        // Add to WindowManager for proper lifecycle management
        WindowManager.shared.addWindowController(mainWindowController!)

        // Check for updates silently on launch
        Task {
            await UpdateService.shared.checkForUpdates(silent: true)
            if UpdateService.shared.updateAvailable {
                self.showUpdateAlert()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep app running when window is minimized (like Finder)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Restore main window when clicking dock icon
            mainWindowController?.showWindow(nil)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        // Handle URL: folder://open?path=/path/to/folder
        if url.scheme == "folder" {
            Task { @MainActor in
                handleFolderURL(url)
            }
        }
    }

    @MainActor private func handleFolderURL(_ url: URL) {
        // Parse URL: folder://open?path=/path/to/folder
        if url.host == "open", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let folderPath = pathItem.value {
                let folderURL = URL(fileURLWithPath: folderPath)

                print("Opening folder from URL: \(folderPath)")

                // Navigate main window instead of creating new window
                mainWindowController?.showWindow(nil)
                mainWindowController?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                // Post notification to navigate to path
                NotificationCenter.default.post(
                    name: NSNotification.Name("NavigateToPath"),
                    object: folderURL
                )
            }
        }
    }

    @MainActor @objc func showSettings() {
        if settingsWindowController == nil {
            let settingsView = SettingsView()
                .environmentObject(SettingsManager.shared)

            settingsWindowController = SwiftUIWindowController(
                rootView: settingsView,
                title: "Settings",
                size: NSSize(width: 550, height: 700),
                styleMask: [.titled, .closable]
            )

            settingsWindowController?.window?.level = .floating
        }

        settingsWindowController?.showWindow(nil)
    }

    @MainActor private func setupStatusBarIcon() {
        // Observe settings changes
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusBarVisibility()
            }
        }

        updateStatusBarVisibility()
    }

    @MainActor private func updateStatusBarVisibility() {
        let showIcon = SettingsManager.shared.settings.showMenuBarIcon

        if showIcon && statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")

            let menu = NSMenu()
            menu.addItem(withTitle: "Show Folder", action: #selector(showMainWindow), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
        } else if !showIcon && statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem!)
            statusItem = nil
        }
    }

    @MainActor private func setupGlobalHotkey() {
        // Observe settings changes for hotkey updates
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateGlobalHotkey()
            }
        }

        updateGlobalHotkey()
    }

    @MainActor private func updateGlobalHotkey() {
        let settings = SettingsManager.shared.settings.globalHotkey

        if settings.enabled {
            if let keyCode = GlobalHotkeyManager.keyCodeFromString(settings.key) {
                let modifiers = GlobalHotkeyManager.carbonModifiersFromSettings(settings.modifiers)
                GlobalHotkeyManager.shared.registerHotkey(keyCode: keyCode, modifiers: modifiers)
            }
        } else {
            GlobalHotkeyManager.shared.unregisterHotkey()
        }
    }

    @objc func showMainWindow() {
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates() {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdates(silent: false)
            if UpdateService.shared.updateAvailable {
                self.showUpdateAlert()
            } else {
                let alert = NSAlert()
                alert.messageText = "You're up to date!"
                alert.informativeText = "Folder \(appVersion) is the latest version."
                alert.runModal()
            }
        }
    }

    @MainActor private func showUpdateAlert() {
        let service = UpdateService.shared
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Folder \(service.latestVersion) is available (you have \(appVersion)).\n\n\(service.releaseNotes)"
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await service.downloadAndInstall()
            }
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Folder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Folder", action: nil, keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

}

// Main entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
