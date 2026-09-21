//
//  SettingsNavigation.swift
//  Folder
//
//  Welcher Bereich der Einstellungen gezeigt wird.
//

import Foundation

/// Merkt sich den zuletzt geöffneten Settings-Tab auch über App-Neustarts.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    static let lastTabKey = "settings.lastOpenedTab"

    enum Tab: String, Hashable {
        case general
        case permissions
    }

    @Published var selectedTab: Tab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Self.lastTabKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = ConfigStore.shared) {
        self.defaults = defaults
        selectedTab = Tab(rawValue: defaults.string(forKey: Self.lastTabKey) ?? "") ?? .general
    }
}
