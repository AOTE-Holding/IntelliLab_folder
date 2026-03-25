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

    var body: some View {
        VStack(spacing: 20) {
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
            .padding(.bottom, 10)

            Divider()

            // Settings Form
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

                // Terminal Settings
                Section(header: Text("Terminal").font(.headline)) {
                    HStack {
                        Text("Default Terminal:")
                        Spacer()
                        Text(settingsManager.settings.terminalAppName)
                            .foregroundColor(.secondary)
                        Button("Choose...") {
                            selectTerminalApp()
                        }
                        if settingsManager.settings.customTerminalPath != nil {
                            Button("Reset") {
                                settingsManager.settings.customTerminalPath = nil
                            }
                        }
                    }

                    if settingsManager.settings.customTerminalPath == nil {
                        Picker("Preset Terminals:", selection: $settingsManager.settings.defaultTerminal) {
                            ForEach(AppSettings.TerminalApp.allCases, id: \.self) { terminal in
                                Text(terminal.rawValue).tag(terminal)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }

                    Text("Terminal app used for \"Open Terminal Here\" context menu option")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }

                // System Settings
                Section(header: Text("System").font(.headline)) {
                    Toggle("Show Menu Bar Icon", isOn: $settingsManager.settings.showMenuBarIcon)

                    Toggle("Launch at Login", isOn: $settingsManager.settings.launchAtLogin)

                    Text("Add Folder to Login Items in System Preferences > Users & Groups to launch at login")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer with buttons
            HStack {
                Button("Reset to Defaults") {
                    settingsManager.reset()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 550, height: 700)
    }

    private func selectTerminalApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Select Terminal Application"
        panel.message = "Choose a terminal application to use for \"Open Terminal Here\""

        if panel.runModal() == .OK, let url = panel.url {
            settingsManager.settings.customTerminalPath = url
        }
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
