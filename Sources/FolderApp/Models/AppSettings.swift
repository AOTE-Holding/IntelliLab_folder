//
//  AppSettings.swift
//  Folder
//
//  Global app preferences and settings
//

import Foundation

struct AppSettings: Codable {
    var defaultViewMode: DisplayMode
    var showHiddenFiles: Bool
    var autoSaveSearchHistory: Bool
    var lastOpenedFolder: URL?
    var theme: Theme
    var iconSize: Int  // 32-128px
    var keyboardShortcuts: KeyboardShortcuts
    var globalHotkey: GlobalHotkey
    var launchAtLogin: Bool
    var showMenuBarIcon: Bool

    // Sidebar visibility
    var showSidebar: Bool
    var showFavoritesSection: Bool
    var showRecentSection: Bool
    var showColorTagsSection: Bool
    var showGoogleDriveInFavorites: Bool

    // Undo/Redo
    var undoRedoEnabled: Bool

    // Terminal settings
    var defaultTerminal: TerminalApp
    var customTerminalPath: URL?  // nil means use defaultTerminal enum

    // Helper to get terminal name for display
    var terminalAppName: String {
        if let customPath = customTerminalPath {
            return customPath.deletingPathExtension().lastPathComponent
        }
        return defaultTerminal.rawValue
    }

    enum DisplayMode: String, Codable {
        case iconGrid
        case list
    }

    enum Theme: String, Codable {
        case light
        case dark
        case system
    }

    enum TerminalApp: String, Codable, CaseIterable {
        case terminal = "Terminal"
        case iterm2 = "iTerm"
        case warp = "Warp"
        case kitty = "kitty"
        case alacritty = "Alacritty"

        var bundleIdentifier: String {
            switch self {
            case .terminal: return "com.apple.Terminal"
            case .iterm2: return "com.googlecode.iterm2"
            case .warp: return "dev.warp.Warp-Stable"
            case .kitty: return "net.kovidgoyal.kitty"
            case .alacritty: return "org.alacritty"
            }
        }
    }

    // Default settings
    static let `default` = AppSettings(
        defaultViewMode: .iconGrid,
        showHiddenFiles: false,
        autoSaveSearchHistory: false,
        lastOpenedFolder: FileManager.default.homeDirectoryForCurrentUser,
        theme: .system,
        iconSize: 64,
        keyboardShortcuts: KeyboardShortcuts(),
        globalHotkey: GlobalHotkey(),
        launchAtLogin: false,
        showMenuBarIcon: true,
        showSidebar: true,
        showFavoritesSection: true,
        showRecentSection: true,
        showColorTagsSection: true,
        showGoogleDriveInFavorites: true,
        undoRedoEnabled: true,
        defaultTerminal: .terminal,
        customTerminalPath: nil
    )
}

struct KeyboardShortcuts: Codable {
    var searchEnabled: Bool
    var navigationEnabled: Bool
    var arrowKeysEnabled: Bool

    // Modifier keys
    var searchModifier: KeyModifier
    var navigationModifier: KeyModifier

    enum KeyModifier: String, Codable {
        case command = "⌘"
        case control = "⌃"
        case option = "⌥"
        case shift = "⇧"
        case none = ""

        var displayName: String {
            switch self {
            case .command: return "Command (⌘)"
            case .control: return "Control (⌃)"
            case .option: return "Option (⌥)"
            case .shift: return "Shift (⇧)"
            case .none: return "None"
            }
        }
    }

    init(
        searchEnabled: Bool = true,
        navigationEnabled: Bool = true,
        arrowKeysEnabled: Bool = true,
        searchModifier: KeyModifier = .command,
        navigationModifier: KeyModifier = .control
    ) {
        self.searchEnabled = searchEnabled
        self.navigationEnabled = navigationEnabled
        self.arrowKeysEnabled = arrowKeysEnabled
        self.searchModifier = searchModifier
        self.navigationModifier = navigationModifier
    }
}

struct GlobalHotkey: Codable {
    var enabled: Bool
    var key: String
    var modifiers: [KeyModifier]

    enum KeyModifier: String, Codable, CaseIterable {
        case command = "⌘"
        case control = "⌃"
        case option = "⌥"
        case shift = "⇧"

        var displayName: String {
            switch self {
            case .command: return "Command (⌘)"
            case .control: return "Control (⌃)"
            case .option: return "Option (⌥)"
            case .shift: return "Shift (⇧)"
            }
        }
    }

    init(
        enabled: Bool = true,
        key: String = "space",
        modifiers: [KeyModifier] = [.command, .shift]
    ) {
        self.enabled = enabled
        self.key = key
        self.modifiers = modifiers
    }

    var displayString: String {
        let modifierString = modifiers.map { $0.rawValue }.joined()
        return "\(modifierString)\(key.uppercased())"
    }
}

// MARK: - Settings Manager
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "com.folder.settings"

    private init() {
        // Load settings from UserDefaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    func reset() {
        settings = .default
    }
}
