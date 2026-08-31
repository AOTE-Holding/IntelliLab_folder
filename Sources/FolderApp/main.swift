//
//  main.swift
//  Folder
//
//  App entry point for command-line executable
//

import AppKit
import SwiftUI

// Create app delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: NSWindowController?
    var settingsWindowController: NSWindowController?
    var onboardingWindowController: NSWindowController?
    var statusItem: NSStatusItem?
    private var pendingFolderURLs: [URL] = []
    private var didStartUpdateCheck = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A process-local reset is deliberately handled before any window is
        // chosen. It bypasses delayed CFPreferences writes, so support and
        // development can always reopen the first-run permission walkthrough.
        if ProcessInfo.processInfo.arguments.contains("--reset-permissions") {
            PermissionCenter.shared.resetAll()
        }

        // Vor dem ersten Fenster: sonst erscheint es kurz im Systemwert und
        // wechselt danach sichtbar auf das eingestellte Erscheinungsbild.
        AppearanceController.start()

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

        // On a clean install the permission walkthrough is the only window.
        // Constructing ContentView eagerly would immediately enumerate the
        // last folder and let macOS present a Files & Folders prompt in front
        // of our explanation.
        if PermissionCenter.shared.hasSeenOnboarding {
            showMainWindow()
        } else {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep app running when window is minimized (like Finder)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if PermissionCenter.shared.hasSeenOnboarding {
                showMainWindow()
            } else {
                showOnboarding()
            }
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

    /// Handle the native URL-delivery path as well as the Apple event path.
    /// Launch Services delivers directories as file URLs when Folder is the
    /// user's preferred handler for `public.folder`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "folder" {
            handleFolderURL(url)
        }

        let folderURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        openFolders(folderURLs)
    }

    @MainActor private func handleFolderURL(_ url: URL) {
        // Parse URL: folder://open?path=/folder or folder://open-file?path=/file
        if ["open", "open-file"].contains(url.host),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let folderPath = pathItem.value {
                let folderURL = URL(fileURLWithPath: folderPath)

                print("Opening folder from URL: \(folderPath)")

                guard PermissionCenter.shared.hasSeenOnboarding else {
                    pendingFolderURLs = [folderURL]
                    showOnboarding()
                    return
                }

                if url.host == "open-file" {
                    let access = PermissionCenter.shared.beginAccess(to: folderURL)
                    _ = NSWorkspace.shared.open(access?.url ?? folderURL)
                    access?.stop()
                    return
                }

                openFolders([folderURL])
            }
        }
    }

    @MainActor private func openFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        guard PermissionCenter.shared.hasSeenOnboarding else {
            pendingFolderURLs = urls
            showOnboarding()
            return
        }

        showMainWindow()
        // `showMainWindow` can create ContentView. Post on the following
        // run-loop turn so its notification subscriptions are installed.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openFolders, object: urls)
        }
    }

    /// Öffnet die Einstellungen direkt im Bereich Berechtigungen.
    ///
    /// Vorher hing dieser Menüpunkt an derselben Funktion wie „Settings…" und
    /// landete deshalb immer im allgemeinen Bereich.
    @MainActor @objc func showPermissions() {
        SettingsNavigation.shared.selectedTab = .permissions
        showSettings()
    }

    @MainActor @objc func showSettings() {
        guard PermissionCenter.shared.hasSeenOnboarding else {
            showOnboarding()
            return
        }
        if settingsWindowController == nil {
            let settingsView = SettingsView()
                .environmentObject(SettingsManager.shared)

            settingsWindowController = SwiftUIWindowController(
                rootView: settingsView,
                title: "Settings",
                size: NSSize(width: 640, height: 720),
                styleMask: [.titled, .closable]
            )

            settingsWindowController?.window?.level = .floating
        }

        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the first-launch permission assistant.
    @MainActor private func showOnboarding() {
        guard onboardingWindowController == nil else {
            onboardingWindowController?.showWindow(nil)
            onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = PermissionOnboardingView {
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
            self.showMainWindow()

            if !self.pendingFolderURLs.isEmpty {
                let pendingURLs = self.pendingFolderURLs
                self.pendingFolderURLs = []
                self.openFolders(pendingURLs)
            }
        }

        let controller = SwiftUIWindowController(
            rootView: onboardingView,
            title: "Folder — Permissions",
            size: NSSize(width: 660, height: 600),
            styleMask: [.titled]
        )

        onboardingWindowController = controller
        controller.window?.level = .floating
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func setupStatusBarIcon() {
        // Observe settings changes
        NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.updateStatusBarVisibility()
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
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.updateGlobalHotkey()
            }
        }

        updateGlobalHotkey()
    }

    @MainActor private func updateGlobalHotkey() {
        let settings = SettingsManager.shared.settings.globalHotkey

        if settings.enabled && !settings.modifiers.isEmpty {
            if let keyCode = GlobalHotkeyManager.keyCodeFromString(settings.key) {
                let modifiers = GlobalHotkeyManager.carbonModifiersFromSettings(settings.modifiers)
                GlobalHotkeyManager.shared.registerHotkey(keyCode: keyCode, modifiers: modifiers)
            }
        } else {
            GlobalHotkeyManager.shared.unregisterHotkey()
        }
    }

    @objc func showMainWindow() {
        guard PermissionCenter.shared.hasSeenOnboarding else {
            showOnboarding()
            return
        }

        if mainWindowController == nil {
            let contentView = ContentView()
                .environmentObject(SettingsManager.shared)

            let controller = SwiftUIWindowController(
                rootView: contentView,
                title: "Folder",
                size: NSSize(width: 1000, height: 700),
                hidesTitle: true
            )
            controller.window?.setFrameAutosaveName("MainWindow")
            mainWindowController = controller
            WindowManager.shared.addWindowController(controller)
        }

        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !didStartUpdateCheck {
            didStartUpdateCheck = true
            UpdateService.shared.checkInBackground()
        }
    }

    @objc func checkForUpdates() {
        UpdateService.shared.checkForUpdates()
    }

    @objc func createFolderTab() {
        guard SettingsManager.shared.settings.tabsEnabled ?? false else { return }
        showMainWindow()
        NotificationCenter.default.post(name: .createFolderTab, object: nil)
    }

    @objc func closeFolderTab() {
        if SettingsManager.shared.settings.tabsEnabled ?? false {
            NotificationCenter.default.post(name: .closeFolderTab, object: nil)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(createFolderTab) {
            return SettingsManager.shared.settings.tabsEnabled ?? false
        }
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Permissions...", action: #selector(showPermissions), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Folder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Folder", action: nil, keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(createFolderTab), keyEquivalent: "t")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(closeFolderTab), keyEquivalent: "w")

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
// AppKit starts the application on the main thread, while Swift 6 treats
// top-level executable code as nonisolated. Bridge that boundary explicitly
// before constructing the main-actor UI delegate.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
