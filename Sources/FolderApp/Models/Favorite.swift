//
//  Favorite.swift
//  Folder
//
//  Model for favorite/bookmarked locations
//

import Foundation

struct Favorite: Identifiable, Codable, Equatable {
    let id: UUID
    let path: URL
    let name: String
    let icon: String
    let order: Int

    init(id: UUID = UUID(), path: URL, name: String, icon: String = "folder.fill", order: Int = 0) {
        self.id = id
        self.path = path
        self.name = name
        self.icon = icon
        self.order = order
    }
}

struct ColorTag: Codable, Equatable, Hashable {
    let color: TagColor
    let name: String

    enum TagColor: String, Codable, CaseIterable {
        case red = "#FF3B30"
        case orange = "#FF9500"
        case yellow = "#FFCC00"
        case green = "#34C759"
        case teal = "#009880"
        case blue = "#007AFF"
        case purple = "#AF52DE"

        var displayName: String {
            switch self {
            case .red: return "Red"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .teal: return "Teal"
            case .blue: return "Blue"
            case .purple: return "Purple"
            }
        }
    }
}

@MainActor
class SidebarManager: ObservableObject {
    static let shared = SidebarManager()

    @Published var favorites: [Favorite] = []
    @Published var recentLocations: [URL] = []
    @Published var colorTags: [URL: ColorTag] = [:] // path -> tag mapping

    private let favoritesKey = "favorites"
    private let recentLocationsKey = "recentLocations"
    private let colorTagsKey = "colorTags"
    private let maxRecentLocations = 10

    private init() {
        loadFavorites()
        loadRecentLocations()
        loadColorTags()

        // Add default favorites if empty
        if favorites.isEmpty {
            addDefaultFavorites()
        } else {
            // Check and add Google Drive if it exists but isn't in favorites
            addGoogleDriveIfMissing()
        }
    }

    // MARK: - Favorites

    func addFavorite(
        _ path: URL,
        name: String? = nil,
        icon: String = "folder.fill",
        at index: Int? = nil
    ) {
        let standardizedPath = path.standardizedFileURL
        guard !favorites.contains(where: { $0.path.standardizedFileURL == standardizedPath }) else {
            return
        }
        let favoriteName = name ?? path.lastPathComponent
        let favorite = Favorite(
            path: path,
            name: favoriteName,
            icon: icon,
            order: 0
        )
        let insertionIndex = min(max(index ?? favorites.count, 0), favorites.count)
        favorites.insert(favorite, at: insertionIndex)
        normalizeFavoriteOrder()
        saveFavorites()
    }

    func removeFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    func reorderFavorites(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < favorites.count,
              to >= 0, to < favorites.count else { return }

        let item = favorites.remove(at: from)
        favorites.insert(item, at: to)

        // Recreate favorites with updated order values
        normalizeFavoriteOrder()

        saveFavorites()
    }

    func updateFavoriteIcon(id: UUID, icon: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let favorite = favorites[index]
        favorites[index] = Favorite(id: favorite.id, path: favorite.path, name: favorite.name, icon: icon, order: favorite.order)
        saveFavorites()
    }

    func isFavorite(_ path: URL) -> Bool {
        return favorites.contains { $0.path == path }
    }

    private func normalizeFavoriteOrder() {
        favorites = favorites.enumerated().map { index, favorite in
            Favorite(id: favorite.id, path: favorite.path, name: favorite.name, icon: favorite.icon, order: index)
        }
    }

    // MARK: - Recent Locations

    func addRecentLocation(_ path: URL) {
        // Remove if already exists
        recentLocations.removeAll { $0 == path }

        // Add to beginning
        recentLocations.insert(path, at: 0)

        // Limit to max
        if recentLocations.count > maxRecentLocations {
            recentLocations = Array(recentLocations.prefix(maxRecentLocations))
        }

        saveRecentLocations()
    }

    func reorderRecents(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < recentLocations.count,
              to >= 0, to < recentLocations.count else { return }

        let item = recentLocations.remove(at: from)
        recentLocations.insert(item, at: to)

        saveRecentLocations()
    }

    // MARK: - Color Tags

    func setColorTag(for path: URL, tag: ColorTag?) {
        if let tag = tag {
            colorTags[path] = tag
        } else {
            colorTags.removeValue(forKey: path)
        }
        saveColorTags()
    }

    func getColorTag(for path: URL) -> ColorTag? {
        return colorTags[path]
    }

    // MARK: - Persistence

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
            return
        }
        favorites = decoded
    }

    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(encoded, forKey: favoritesKey)
        }
    }

    private func loadRecentLocations() {
        guard let data = UserDefaults.standard.data(forKey: recentLocationsKey),
              let decoded = try? JSONDecoder().decode([URL].self, from: data) else {
            return
        }
        recentLocations = decoded
    }

    private func saveRecentLocations() {
        if let encoded = try? JSONEncoder().encode(recentLocations) {
            UserDefaults.standard.set(encoded, forKey: recentLocationsKey)
        }
    }

    private func loadColorTags() {
        guard let data = UserDefaults.standard.data(forKey: colorTagsKey),
              let decoded = try? JSONDecoder().decode([URL: ColorTag].self, from: data) else {
            return
        }
        colorTags = decoded
    }

    private func saveColorTags() {
        if let encoded = try? JSONEncoder().encode(colorTags) {
            UserDefaults.standard.set(encoded, forKey: colorTagsKey)
        }
    }

    private func addGoogleDriveIfMissing() {
        guard !favorites.contains(where: { $0.name == "Google Drive" }) else { return }
        Task { [weak self] in
            let driveURL = await Task.detached(priority: .utility) {
                Self.discoverGoogleDrive()
            }.value
            guard let self,
                  let driveURL,
                  !favorites.contains(where: { $0.name == "Google Drive" }) else { return }
            addFavorite(driveURL, name: "Google Drive", icon: "cloud.fill")
        }
    }

    nonisolated private static func discoverGoogleDrive() -> URL? {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let cloudStorageURL = homeURL.appendingPathComponent("Library/CloudStorage")
        if let contents = try? fileManager.contentsOfDirectory(
            at: cloudStorageURL,
            includingPropertiesForKeys: nil
        ), let googleDriveFolder = contents.first(where: { $0.lastPathComponent.starts(with: "GoogleDrive-") }) {
            let myDriveURL = googleDriveFolder.appendingPathComponent("My Drive")
            if fileManager.fileExists(atPath: myDriveURL.path) {
                return myDriveURL
            }
        }

        let legacyGoogleDriveURL = homeURL.appendingPathComponent("Google Drive")
        return fileManager.fileExists(atPath: legacyGoogleDriveURL.path) ? legacyGoogleDriveURL : nil
    }

    private func addDefaultFavorites() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser

        // Home
        addFavorite(homeURL, name: "Home", icon: "house.fill")

        // Desktop
        let desktopURL = homeURL.appendingPathComponent("Desktop")
        addFavorite(desktopURL, name: "Desktop", icon: "desktopcomputer")

        // Documents
        let documentsURL = homeURL.appendingPathComponent("Documents")
        addFavorite(documentsURL, name: "Documents", icon: "doc.fill")

        // Downloads
        let downloadsURL = homeURL.appendingPathComponent("Downloads")
        addFavorite(downloadsURL, name: "Downloads", icon: "arrow.down.circle.fill")
        addGoogleDriveIfMissing()
    }
}
