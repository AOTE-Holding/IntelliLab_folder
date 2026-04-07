//
//  SidebarView.swift
//  Folder
//
//  Sidebar with favorites and recent locations
//

import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var sidebarManager: SidebarManager
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var volumeManager = VolumeManager.shared
    @State private var showAllRecent = false

    /// Favorites filtered based on settings
    private var displayedFavorites: [Favorite] {
        if settingsManager.settings.showGoogleDriveInFavorites {
            return sidebarManager.favorites
        }
        return sidebarManager.favorites.filter { !isGoogleDriveFavorite($0) }
    }

    /// Check if a favorite is the root Google Drive entry
    private func isGoogleDriveFavorite(_ favorite: Favorite) -> Bool {
        return favorite.name == "Google Drive"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Favorites Section
            if settingsManager.settings.showFavoritesSection {
                SidebarSection(title: "Favorites") {
                ForEach(displayedFavorites) { favorite in
                    SidebarFavoriteItem(
                        favorite: favorite,
                        isSelected: fileExplorerViewModel.currentPath == favorite.path,
                        sidebarManager: sidebarManager
                    ) {
                        // Resolve symlinks first
                        let resolvedPath = favorite.path.resolvingSymlinksInPath()

                        // Check existence
                        guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
                            return
                        }

                        // Use resourceValues for more reliable directory check
                        do {
                            let resourceValues = try resolvedPath.resourceValues(forKeys: [.isDirectoryKey])
                            if let isDirectory = resourceValues.isDirectory {
                                if isDirectory {
                                    fileExplorerViewModel.navigate(to: resolvedPath)
                                } else {
                                    NSWorkspace.shared.open(resolvedPath)
                                }
                            }
                        } catch {
                            NSWorkspace.shared.open(resolvedPath)
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: favorite.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: FavoriteDropDelegate(
                        favorite: favorite,
                        favorites: sidebarManager.favorites,
                        sidebarManager: sidebarManager
                    ))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDropToFavorites(providers: providers)
            }

                Divider()
                    .padding(.vertical, 8)
            }

            // Devices Section - only show when devices are connected
            if !volumeManager.mountedVolumes.isEmpty {
                SidebarSection(title: "Devices") {
                    ForEach(volumeManager.mountedVolumes) { volume in
                        SidebarDeviceItem(
                            volume: volume,
                            isSelected: fileExplorerViewModel.currentPath == volume.url,
                            volumeManager: volumeManager
                        ) {
                            fileExplorerViewModel.navigate(to: volume.url)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 8)
            }

            // Recent Locations Section
            if settingsManager.settings.showRecentSection {
                SidebarSection(title: "Recent") {
                let displayedRecent = showAllRecent ? sidebarManager.recentLocations : Array(sidebarManager.recentLocations.prefix(5))

                ForEach(displayedRecent, id: \.self) { location in
                    SidebarItem(
                        icon: "clock.fill",
                        title: location.lastPathComponent,
                        isSelected: fileExplorerViewModel.currentPath == location
                    ) {
                        fileExplorerViewModel.navigate(to: location)
                    }
                    .onDrag {
                        NSItemProvider(object: location.path as NSString)
                    }
                    .onDrop(of: [.text], delegate: RecentDropDelegate(
                        location: location,
                        recents: displayedRecent,
                        sidebarManager: sidebarManager
                    ))
                }

                if sidebarManager.recentLocations.count > 5 {
                    Button(action: { showAllRecent.toggle() }) {
                        HStack {
                            Text(showAllRecent ? "Show Less" : "Show More (\(sidebarManager.recentLocations.count - 5))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: showAllRecent ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

                Divider()
                    .padding(.vertical, 8)
            }

            // Color Tags Section - Shows color categories like Finder
            if settingsManager.settings.showColorTagsSection {
                SidebarSection(title: "Tags") {
                    ForEach(ColorTag.TagColor.allCases, id: \.self) { color in
                        let count = sidebarManager.colorTags.filter { $0.value.color == color }.count
                        SidebarTagCategoryItem(
                            color: color,
                            count: count,
                            isSelected: fileExplorerViewModel.tagFilterMode == color
                        ) {
                            if count > 0 {
                                if fileExplorerViewModel.tagFilterMode == color {
                                    fileExplorerViewModel.exitTagFilterMode()
                                } else {
                                    fileExplorerViewModel.showFilesWithTag(color)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(width: 200)
        .background(Color.folderSidebar)
    }

    private func handleDropToFavorites(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                guard let url = object as? URL, error == nil else { return }

                Task { @MainActor in
                    sidebarManager.addFavorite(url, name: url.lastPathComponent, icon: "folder.fill")
                }
            }
        }
        return true
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            content
        }
    }
}

struct SidebarItem: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .folderAccent : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .primary : .primary)
                        .lineLimit(1)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Favorite Item with Color Tag

struct SidebarFavoriteItem: View {
    let favorite: Favorite
    let isSelected: Bool
    @ObservedObject var sidebarManager: SidebarManager
    let action: () -> Void

    var colorTag: ColorTag? {
        sidebarManager.getColorTag(for: favorite.path)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: favorite.icon)
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? .folderAccent : .secondary)
                        .frame(width: 16)

                    // macOS-style color tag dot
                    if let colorTag = colorTag {
                        Circle()
                            .fill(Color(hex: colorTag.color.rawValue))
                            .frame(width: 6, height: 6)
                            .overlay(
                                Circle()
                                    .stroke(Color.folderSidebar, lineWidth: 0.5)
                            )
                            .offset(x: -3, y: -3)
                    }
                }

                Text(favorite.name)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .primary : .primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            // Move Up (disabled if first item)
            Button("Move Up") {
                if let index = sidebarManager.favorites.firstIndex(where: { $0.id == favorite.id }), index > 0 {
                    sidebarManager.reorderFavorites(from: index, to: index - 1)
                }
            }
            .disabled(sidebarManager.favorites.first?.id == favorite.id)

            // Move Down (disabled if last item)
            Button("Move Down") {
                if let index = sidebarManager.favorites.firstIndex(where: { $0.id == favorite.id }), index < sidebarManager.favorites.count - 1 {
                    sidebarManager.reorderFavorites(from: index, to: index + 1)
                }
            }
            .disabled(sidebarManager.favorites.last?.id == favorite.id)

            Divider()

            Menu("Change Icon") {
                ForEach(Array(iconOptions.enumerated()), id: \.offset) { index, iconOption in
                    Button(action: {
                        sidebarManager.updateFavoriteIcon(id: favorite.id, icon: iconOption.icon)
                    }) {
                        HStack {
                            Image(systemName: iconOption.icon)
                            Text(iconOption.name)
                        }
                    }
                }
            }

            Divider()

            Menu("Apply Color Tag") {
                ForEach(ColorTag.TagColor.allCases, id: \.self) { color in
                    Button(action: {
                        sidebarManager.setColorTag(for: favorite.path, tag: ColorTag(color: color, name: color.rawValue))
                    }) {
                        HStack {
                            Circle()
                                .fill(Color(hex: color.rawValue))
                                .frame(width: 10, height: 10)
                            Text(colorName(for: color))
                        }
                    }
                }

                Divider()

                if colorTag != nil {
                    Button("Remove Color Tag") {
                        sidebarManager.setColorTag(for: favorite.path, tag: nil)
                    }
                }
            }

            Divider()

            Button("Remove from Favorites", role: .destructive) {
                sidebarManager.removeFavorite(id: favorite.id)
            }
        }
    }

    private let iconOptions: [(name: String, icon: String)] = [
        ("Folder", "folder.fill"),
        ("Home", "house.fill"),
        ("Desktop", "desktopcomputer"),
        ("Documents", "doc.fill"),
        ("Downloads", "arrow.down.circle.fill"),
        ("Pictures", "photo.fill"),
        ("Music", "music.note"),
        ("Movies", "film.fill"),
        ("Star", "star.fill"),
        ("Heart", "heart.fill"),
        ("Bookmark", "bookmark.fill"),
        ("Tag", "tag.fill")
    ]

    private func colorName(for color: ColorTag.TagColor) -> String {
        switch color {
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

// MARK: - Tag Category Item (Finder-like color categories)

struct SidebarTagCategoryItem: View {
    let color: ColorTag.TagColor
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: color.rawValue))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )

                Text(color.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(count > 0 ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("Right-click to tag")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: - Color Tag Item (Legacy - individual items)

struct SidebarColorTagItem: View {
    let path: URL
    let colorTag: ColorTag
    let isSelected: Bool
    @ObservedObject var sidebarManager: SidebarManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? .folderAccent : .secondary)
                        .frame(width: 16)

                    // macOS-style color tag dot
                    Circle()
                        .fill(Color(hex: colorTag.color.rawValue))
                        .frame(width: 6, height: 6)
                        .overlay(
                            Circle()
                                .stroke(Color.folderSidebar, lineWidth: 0.5)
                        )
                        .offset(x: -3, y: -3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(path.lastPathComponent)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .primary : .primary)
                        .lineLimit(1)

                    Text(path.deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            Button("Open") {
                action()
            }

            Divider()

            Menu("Apply Color Tag") {
                ForEach(ColorTag.TagColor.allCases, id: \.self) { color in
                    Button(action: {
                        sidebarManager.setColorTag(for: path, tag: ColorTag(color: color, name: color.rawValue))
                    }) {
                        HStack {
                            Circle()
                                .fill(Color(hex: color.rawValue))
                                .frame(width: 10, height: 10)
                            Text(colorName(for: color))
                        }
                    }
                }

                Divider()

                Button("Remove Color Tag") {
                    sidebarManager.setColorTag(for: path, tag: nil)
                }
            }
        }
    }

    private func colorName(for color: ColorTag.TagColor) -> String {
        switch color {
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

// MARK: - Drop Delegate for Reordering

struct FavoriteDropDelegate: DropDelegate {
    let favorite: Favorite
    let favorites: [Favorite]
    let sidebarManager: SidebarManager

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = info.itemProviders(for: [.text]).first else { return false }

        draggedID.loadObject(ofClass: NSString.self) { object, error in
            guard let idString = object as? String,
                  let draggedUUID = UUID(uuidString: idString) else { return }

            Task { @MainActor in
                // Get fresh indices from current state
                guard let fromIndex = sidebarManager.favorites.firstIndex(where: { $0.id == draggedUUID }),
                      let toIndex = sidebarManager.favorites.firstIndex(where: { $0.id == favorite.id }),
                      fromIndex != toIndex else { return }

                sidebarManager.reorderFavorites(from: fromIndex, to: toIndex)
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        // Visual feedback only - no mutation
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

struct RecentDropDelegate: DropDelegate {
    let location: URL
    let recents: [URL]
    let sidebarManager: SidebarManager

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedPath = info.itemProviders(for: [.text]).first else { return false }

        draggedPath.loadObject(ofClass: NSString.self) { object, error in
            guard let pathString = object as? String else { return }

            Task { @MainActor in
                // Get fresh indices from current state
                guard let fromIndex = sidebarManager.recentLocations.firstIndex(where: { $0.path == pathString }),
                      let toIndex = sidebarManager.recentLocations.firstIndex(where: { $0 == location }),
                      fromIndex != toIndex else { return }

                sidebarManager.reorderRecents(from: fromIndex, to: toIndex)
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        // Visual feedback only - no mutation
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

// MARK: - Device Item

struct SidebarDeviceItem: View {
    let volume: VolumeInfo
    let isSelected: Bool
    @ObservedObject var volumeManager: VolumeManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 16)

                Text(volume.name)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .primary : .primary)
                    .lineLimit(1)

                Spacer()

                if volume.isEjectable {
                    Button(action: {
                        volumeManager.ejectVolume(volume)
                    }) {
                        Image(systemName: "eject")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Eject \(volume.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
