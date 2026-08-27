//
//  SettingsView.swift
//  Folder
//
//  App settings and preferences panel
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var loginItemService = LoginItemService.shared
    @StateObject private var folderDefaultHandlerService = FolderDefaultHandlerService.shared
    @State private var showingMakeFolderDefaultConfirmation = false
    @State private var showingRestoreFolderHandlerConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            Divider()

            TabView {
                Form {
                // View Settings
                Section(header: Text("View").font(.headline)) {
                    // Default View Mode
                    Picker("Default View Mode:", selection: $settingsManager.settings.defaultViewMode) {
                        Text("Icon Grid").tag(AppSettings.DisplayMode.iconGrid)
                        Text("List").tag(AppSettings.DisplayMode.list)
                    }
                    .pickerStyle(.radioGroup)

                    // Icon Size Slider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon Size (Grid View): \(settingsManager.settings.iconSize)px")
                            .font(.subheadline)

                        Slider(
                            value: Binding(
                                get: { Double(settingsManager.settings.iconSize) },
                                set: { settingsManager.settings.iconSize = Int($0) }
                            ),
                            in: 32...128,
                            step: 8
                        )
                    }
                }

                // File Display Settings
                Section(header: Text("Files").font(.headline)) {
                    Toggle("Show Hidden Files", isOn: $settingsManager.settings.showHiddenFiles)
                    Toggle("Enable Undo/Redo (Cmd+Z / Cmd+Shift+Z)", isOn: $settingsManager.settings.undoRedoEnabled)
                }

                // Sidebar Visibility
                Section(header: Text("Sidebar").font(.headline)) {
                    Toggle("Show Favorites Section", isOn: $settingsManager.settings.showFavoritesSection)
                    Toggle("Show Recent Section", isOn: $settingsManager.settings.showRecentSection)
                    Toggle("Show Color Tags Section", isOn: $settingsManager.settings.showColorTagsSection)
                    Toggle("Show Google Drive in Favorites", isOn: $settingsManager.settings.showGoogleDriveInFavorites)
                }

                // Appearance Settings
                Section(header: Text("Appearance").font(.headline)) {
                    Picker("Theme:", selection: $settingsManager.settings.theme) {
                        Text("Light").tag(AppSettings.Theme.light)
                        Text("Dark").tag(AppSettings.Theme.dark)
                        Text("System").tag(AppSettings.Theme.system)
                    }
                    .pickerStyle(.radioGroup)
                }

                // Keyboard Shortcuts
                Section(header: Text("Keyboard Shortcuts").font(.headline)) {
                    Toggle("Enable Search (Cmd+F)", isOn: $settingsManager.settings.keyboardShortcuts.searchEnabled)

                    Toggle("Enable Folder Navigation", isOn: $settingsManager.settings.keyboardShortcuts.navigationEnabled)

                    if settingsManager.settings.keyboardShortcuts.navigationEnabled {
                        Picker("Navigation Modifier:", selection: $settingsManager.settings.keyboardShortcuts.navigationModifier) {
                            Text("Control (⌃)").tag(KeyboardShortcuts.KeyModifier.control)
                            Text("Command (⌘)").tag(KeyboardShortcuts.KeyModifier.command)
                            Text("Option (⌥)").tag(KeyboardShortcuts.KeyModifier.option)
                        }
                        .pickerStyle(.radioGroup)
                        .padding(.leading, 20)

                        Text("Use \(settingsManager.settings.keyboardShortcuts.navigationModifier.rawValue)+Arrow keys to navigate folders")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }

                    Toggle("Enable Arrow Keys", isOn: $settingsManager.settings.keyboardShortcuts.arrowKeysEnabled)

                    if settingsManager.settings.keyboardShortcuts.arrowKeysEnabled {
                        Text("Use Arrow keys (without modifiers) to navigate between files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                }

                // Global Hotkey
                Section(header: Text("Global Hotkey").font(.headline)) {
                    Toggle("Enable Global Hotkey", isOn: $settingsManager.settings.globalHotkey.enabled)

                    if settingsManager.settings.globalHotkey.enabled {
                        VStack(alignment: .leading, spacing: 12) {
                            // Current hotkey display
                            HStack {
                                Text("Current Hotkey:")
                                    .font(.subheadline)
                                Text(settingsManager.settings.globalHotkey.displayString)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                            }

                            // Key picker
                            Picker("Key:", selection: $settingsManager.settings.globalHotkey.key) {
                                Text("Space").tag("space")
                                Divider()
                                ForEach(["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"], id: \.self) { key in
                                    Text(key).tag(key.lowercased())
                                }
                                Divider()
                                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { letter in
                                    Text(String(letter)).tag(String(letter).lowercased())
                                }
                            }
                            .pickerStyle(.menu)

                            // Modifier toggles
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Modifiers:")
                                    .font(.subheadline)
                                HStack(spacing: 16) {
                                    ModifierToggle(label: "Command", symbol: "⌘", modifier: .command, modifiers: $settingsManager.settings.globalHotkey.modifiers)
                                    ModifierToggle(label: "Control", symbol: "⌃", modifier: .control, modifiers: $settingsManager.settings.globalHotkey.modifiers)
                                    ModifierToggle(label: "Option", symbol: "⌥", modifier: .option, modifiers: $settingsManager.settings.globalHotkey.modifiers)
                                    ModifierToggle(label: "Shift", symbol: "⇧", modifier: .shift, modifiers: $settingsManager.settings.globalHotkey.modifiers)
                                }
                            }

                            Text("Activates Folder from anywhere on your system")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                }

                // Command-line tool settings
                Section(header: Text("Command-line Tools").font(.headline)) {
                    Picker("Default target:", selection: $settingsManager.settings.defaultTerminal) {
                        ForEach(AppSettings.TerminalApp.supportedCases, id: \.self) { terminal in
                            Text(terminal.rawValue).tag(terminal)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if settingsManager.settings.defaultTerminal == .custom {
                        HStack(spacing: 8) {
                            Text(settingsManager.settings.customTerminalPath?.deletingPathExtension().lastPathComponent ?? "No app selected")
                                .foregroundColor(settingsManager.settings.customTerminalPath == nil ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Button("Choose App…") {
                                chooseCustomCommandLineApp()
                            }
                        }
                        .padding(.leading, 20)
                    }

                    Text("Used by \"Open Command Line Here\". Terminal and iTerm need macOS Automation; Warp, Ghostty, cmux, tmux, Kitty and Alacritty use their native launch path.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }

                // System Settings
                Section(header: Text("System").font(.headline)) {
                    Toggle("Show Menu Bar Icon", isOn: $settingsManager.settings.showMenuBarIcon)

                    Toggle("Launch at Login", isOn: Binding(
                        get: { loginItemService.isEnabled },
                        set: { loginItemService.setEnabled($0) }
                    ))

                    Text("Uses the native macOS Login Items service.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)

                    Divider()

                    Toggle("Enable Tabs", isOn: Binding(
                        get: { settingsManager.settings.tabsEnabled ?? false },
                        set: { settingsManager.settings.tabsEnabled = $0 }
                    ))

                    Text("Tabs are off by default. When enabled, use Command-1 through Command-9 to switch tabs, Command-T to create one and Command-W to close one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)

                    Divider()

                    Toggle("Use Folder as the default app for folders", isOn: Binding(
                        get: { folderDefaultHandlerService.isFolderDefault },
                        set: { shouldUseFolder in
                            if shouldUseFolder {
                                showingMakeFolderDefaultConfirmation = true
                            } else {
                                showingRestoreFolderHandlerConfirmation = true
                            }
                        }
                    ))

                    Text("Folder will open directories, while PDFs, Word files and other documents keep their current default apps. Finder remains responsible for macOS system actions such as “Show in Finder”.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

                PermissionsCenterView()
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer with buttons
            HStack {
                Button("Reset to Defaults") {
                    // A reset must reset the real Login Item as well, not
                    // merely the saved toggle shown in this window.
                    loginItemService.setEnabled(false)
                    settingsManager.reset()
                    loginItemService.refresh()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 640, height: 720)
        .onAppear {
            folderDefaultHandlerService.refresh()
        }
        .alert("Launch at Login", isPresented: Binding(
            get: { loginItemService.errorMessage != nil },
            set: { if !$0 { loginItemService.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { loginItemService.errorMessage = nil }
        } message: {
            Text(loginItemService.errorMessage ?? "Unknown error")
        }
        .alert("Use Folder for folders?", isPresented: $showingMakeFolderDefaultConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Use Folder") {
                folderDefaultHandlerService.makeFolderDefault()
            }
        } message: {
            Text("Folder will become the default app for opening directories. Your document apps will not change.")
        }
        .alert("Restore the previous folder app?", isPresented: $showingRestoreFolderHandlerConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore") {
                folderDefaultHandlerService.restorePreviousHandler()
            }
        } message: {
            Text("Folder will no longer be the default app for opening directories.")
        }
        .alert("Folder Default App", isPresented: Binding(
            get: { folderDefaultHandlerService.errorMessage != nil },
            set: { if !$0 { folderDefaultHandlerService.clearError() } }
        )) {
            Button("OK", role: .cancel) { folderDefaultHandlerService.clearError() }
        } message: {
            Text(folderDefaultHandlerService.errorMessage ?? "Unknown error")
        }
    }

    private func chooseCustomCommandLineApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app Folder should open for “Open Command Line Here”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsManager.settings.customTerminalPath = url
    }
}

// MARK: - Modifier Toggle for Global Hotkey

struct ModifierToggle: View {
    let label: String
    let symbol: String
    let modifier: GlobalHotkey.KeyModifier
    @Binding var modifiers: [GlobalHotkey.KeyModifier]

    private var isEnabled: Bool {
        modifiers.contains(modifier)
    }

    var body: some View {
        Button(action: {
            if isEnabled {
                modifiers.removeAll { $0 == modifier }
            } else {
                modifiers.append(modifier)
            }
        }) {
            HStack(spacing: 4) {
                Text(symbol)
                    .font(.system(size: 14, design: .monospaced))
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isEnabled ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isEnabled ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

}
