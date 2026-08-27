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
    @State private var favoritesExpanded = true
    @State private var devicesExpanded = true
    @State private var recentExpanded = true
    @State private var tagsExpanded = true
    @State private var favoriteReorderTargetID: UUID?
    @State private var favoriteInsertionTarget: FavoriteInsertionTarget?
    @State private var favoriteDropFrames: [UUID: CGRect] = [:]

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

    /// Finder keeps the most specific matching sidebar location highlighted
    /// while browsing inside it. Canonicalize URLs first because security
    /// scoped/bookmarked paths may use a different URL spelling for the same
    /// directory.
    private var activeFavoriteID: UUID? {
        let currentComponents = fileExplorerViewModel.currentPath
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents

        return displayedFavorites
            .filter { favorite in
                let favoriteComponents = favorite.path
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .pathComponents
                return currentComponents.starts(with: favoriteComponents)
            }
            .max { lhs, rhs in
                lhs.path.standardizedFileURL.pathComponents.count
                    < rhs.path.standardizedFileURL.pathComponents.count
            }?
            .id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            favoritesSection

            // Devices Section - only show when devices are connected
            if !volumeManager.mountedVolumes.isEmpty {
                SidebarSection(title: "Devices", isExpanded: $devicesExpanded) {
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
                    .overlay(Color.folderStroke.opacity(0.65))
                    .padding(.vertical, 8)
            }

            // Recent Locations Section
            if settingsManager.settings.showRecentSection {
                SidebarSection(title: "Recent", isExpanded: $recentExpanded) {
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
                    .overlay(Color.folderStroke.opacity(0.65))
                    .padding(.vertical, 8)
            }

            // Color Tags Section - Shows color categories like Finder
            if settingsManager.settings.showColorTagsSection {
                SidebarSection(title: "Tags", isExpanded: $tagsExpanded) {
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
        // The split view owns the width. Filling that width keeps the sidebar
        // background continuous while labels naturally truncate like Finder.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.folderSidebar)
        .coordinateSpace(name: "sidebarFavoriteDropArea")
        .onPreferenceChange(FavoriteFramePreferenceKey.self) { favoriteDropFrames = $0 }
        .animation(.easeOut(duration: 0.12), value: favoriteInsertionTarget)
        .onDrop(of: [.fileURL], delegate: SidebarFavoritesDropDelegate(
            favorites: displayedFavorites,
            favoriteFrames: favoriteDropFrames,
            sidebarManager: sidebarManager,
            insertionTarget: $favoriteInsertionTarget
        ))
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if settingsManager.settings.showFavoritesSection {
            SidebarSection(title: "Favorites", isExpanded: $favoritesExpanded) {
                VStack(spacing: 2) {
                    ForEach(displayedFavorites) { favorite in
                        favoriteRow(for: favorite)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .overlay(Color.folderStroke.opacity(0.65))
                .padding(.vertical, 8)
        }
    }

    private func favoriteRow(for favorite: Favorite) -> some View {
        SidebarFavoriteItem(
            favorite: favorite,
            isSelected: activeFavoriteID == favorite.id,
            isReorderTarget: favoriteReorderTargetID == favorite.id,
            insertionEdge: favoriteInsertionTarget?.favoriteID == favorite.id
                ? favoriteInsertionTarget?.edge
                : nil,
            sidebarManager: sidebarManager,
            action: { openFavorite(favorite) },
            onFolderDragEdgeChanged: { updateFavoriteInsertionTarget(for: favorite, edge: $0) },
            onFolderDrop: { insertFolders($0, nextTo: favorite, edge: $1) }
        )
        .onDrag {
            NSItemProvider(object: favorite.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: FavoriteDropDelegate(
            favorite: favorite,
            favorites: sidebarManager.favorites,
            sidebarManager: sidebarManager,
            reorderTargetID: $favoriteReorderTargetID
        ))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FavoriteFramePreferenceKey.self,
                    value: [favorite.id: proxy.frame(in: .named("sidebarFavoriteDropArea"))]
                )
            }
        }
    }

    private func openFavorite(_ favorite: Favorite) {
        let resolvedPath = favorite.path.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolvedPath.path) else { return }

        if (try? resolvedPath.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            fileExplorerViewModel.navigate(to: resolvedPath)
        } else {
            NSWorkspace.shared.open(resolvedPath)
        }
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func updateFavoriteInsertionTarget(for favorite: Favorite, edge: FavoriteInsertionEdge?) {
        favoriteInsertionTarget = edge.map {
            FavoriteInsertionTarget(favoriteID: favorite.id, edge: $0)
        }
    }

    private func insertFolders(_ urls: [URL], nextTo favorite: Favorite, edge: FavoriteInsertionEdge) {
        guard let targetIndex = sidebarManager.favorites.firstIndex(where: { $0.id == favorite.id }) else {
            return
        }
        for (offset, url) in urls.enumerated() where Self.isDirectory(url) {
            sidebarManager.addFavorite(
                url,
                name: url.lastPathComponent,
                icon: "folder.fill",
                at: targetIndex + (edge == .after ? 1 : 0) + offset
            )
        }
        favoriteInsertionTarget = nil
    }

}

private struct FavoriteFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.8))
                        .frame(width: 12, height: 12)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
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
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
            .padding(.vertical, 7)
            .background(isSelected ? Color.folderAccent.opacity(0.16) : Color.clear)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.folderAccent)
                    .frame(width: 3, height: 18)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.leading, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Favorite Item with Color Tag

struct SidebarFavoriteItem: View {
    let favorite: Favorite
    let isSelected: Bool
    let isReorderTarget: Bool
    let insertionEdge: FavoriteInsertionEdge?
    @ObservedObject var sidebarManager: SidebarManager
    let action: () -> Void
    let onFolderDragEdgeChanged: (FavoriteInsertionEdge?) -> Void
    let onFolderDrop: ([URL], FavoriteInsertionEdge) -> Void

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
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.folderAccent.opacity(0.16) : Color.clear
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.folderAccent)
                    .frame(width: 3, height: 18)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.leading, 4)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.folderAccent)
                    .frame(height: 2)
                    .padding(.horizontal, 9)
                    .opacity(isReorderTarget || insertionEdge == .before ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.folderAccent)
                    .frame(height: 2)
                    .padding(.horizontal, 9)
                    .opacity(insertionEdge == .after ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .overlay {
            NativeFavoriteDropTarget(
                onOpen: action,
                onHoverEdgeChanged: onFolderDragEdgeChanged,
                onDrop: onFolderDrop
            )
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
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

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

enum FavoriteInsertionEdge: Equatable {
    case before
    case after
}

struct FavoriteInsertionTarget: Equatable {
    let favoriteID: UUID
    let edge: FavoriteInsertionEdge
}

/// Native AppKit destination placed above each Favorite row. File drags in
/// this app originate from `NSDraggingSession`; registering the row itself is
/// what makes its visible surface, rather than only the surrounding SwiftUI
/// whitespace, accept a drop.
private struct NativeFavoriteDropTarget: NSViewRepresentable {
    let onOpen: () -> Void
    let onHoverEdgeChanged: (FavoriteInsertionEdge?) -> Void
    let onDrop: ([URL], FavoriteInsertionEdge) -> Void

    func makeNSView(context: Context) -> FavoriteDropView {
        let view = FavoriteDropView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FavoriteDropView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FavoriteDropView) {
        view.onOpen = onOpen
        view.onHoverEdgeChanged = onHoverEdgeChanged
        view.onDrop = onDrop
    }

    final class FavoriteDropView: NSView {
        var onOpen: () -> Void = {}
        var onHoverEdgeChanged: (FavoriteInsertionEdge?) -> Void = { _ in }
        var onDrop: ([URL], FavoriteInsertionEdge) -> Void = { _, _ in }
        private var isHovering = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // This view sits above SwiftUI's Button to receive native file drags.
        // Handle the ordinary click here as well; otherwise the overlay would
        // swallow it before the Favorite button can navigate.
        override func mouseDown(with event: NSEvent) {
            onOpen()
        }

        // Let the original SwiftUI Button receive right-clicks so its full
        // Finder-style context menu (icon, tag, move, remove) remains intact.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent,
               event.type == .rightMouseDown || event.type == .rightMouseUp {
                return nil
            }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !folderURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
            isHovering = true
            onHoverEdgeChanged(edge(for: sender))
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !folderURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
            onHoverEdgeChanged(edge(for: sender))
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            finishHover()
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !folderURLs(from: sender.draggingPasteboard).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = folderURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            let insertionEdge = edge(for: sender)
            finishHover()
            onDrop(urls, insertionEdge)
            return true
        }

        private func edge(for draggingInfo: NSDraggingInfo) -> FavoriteInsertionEdge {
            let point = convert(draggingInfo.draggingLocation, from: nil)
            return point.y >= bounds.midY ? .before : .after
        }

        private func finishHover() {
            guard isHovering else { return }
            isHovering = false
            onHoverEdgeChanged(nil)
        }

        private func folderURLs(from pasteboard: NSPasteboard) -> [URL] {
            let urls: [URL]
            if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !objects.isEmpty {
                urls = objects
            } else if let paths = pasteboard.propertyList(
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ) as? [String] {
                urls = paths.map(URL.init(fileURLWithPath:))
            } else {
                return []
            }

            return urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
    }
}

/// Turns the complete Favorites section into one continuous destination.
/// The marker is calculated from the actual rendered rows, so a folder can be
/// released immediately anywhere over Favorites instead of requiring a gap.
struct SidebarFavoritesDropDelegate: DropDelegate {
    let favorites: [Favorite]
    let favoriteFrames: [UUID: CGRect]
    let sidebarManager: SidebarManager
    @Binding var insertionTarget: FavoriteInsertionTarget?

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.fileURL]).first,
              let target = target(for: info) else { return false }

        provider.loadObject(ofClass: NSURL.self) { object, error in
            guard let url = object as? URL,
                  error == nil,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return
            }

            Task { @MainActor in
                guard let targetIndex = sidebarManager.favorites.firstIndex(where: { $0.id == target.favoriteID }) else {
                    return
                }
                let insertionIndex = targetIndex + (target.edge == .after ? 1 : 0)
                sidebarManager.addFavorite(
                    url,
                    name: url.lastPathComponent,
                    icon: "folder.fill",
                    at: insertionIndex
                )
                insertionTarget = nil
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        insertionTarget = target(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionTarget = target(for: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        insertionTarget = nil
    }

    private func target(for info: DropInfo) -> FavoriteInsertionTarget? {
        let renderedFavorites = favorites.compactMap { favorite in
            favoriteFrames[favorite.id].map { (favorite, $0) }
        }.sorted { $0.1.minY < $1.1.minY }

        guard let first = renderedFavorites.first,
              let last = renderedFavorites.last,
              info.location.y >= first.1.minY - 18,
              info.location.y <= last.1.maxY + 18 else {
            return nil
        }

        let candidates = renderedFavorites.flatMap { favorite, frame in
            [
                (FavoriteInsertionTarget(favoriteID: favorite.id, edge: .before), frame.minY),
                (FavoriteInsertionTarget(favoriteID: favorite.id, edge: .after), frame.maxY)
            ]
        }

        return candidates.min { lhs, rhs in
            abs(lhs.1 - info.location.y) < abs(rhs.1 - info.location.y)
        }?.0
    }
}

struct FavoriteDropDelegate: DropDelegate {
    let favorite: Favorite
    let favorites: [Favorite]
    let sidebarManager: SidebarManager
    @Binding var reorderTargetID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        defer {
            Task { @MainActor in
                if reorderTargetID == favorite.id {
                    reorderTargetID = nil
                }
            }
        }
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
        reorderTargetID = favorite.id
    }

    func dropExited(info: DropInfo) {
        if reorderTargetID == favorite.id {
            reorderTargetID = nil
        }
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
    @StateObject private var operationCoordinator = FileOperationCoordinator.shared
    @State private var isDragHovered = false
    @State private var dragHoverGeneration = 0
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 16)

                Text(volume.name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "eject")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .background(
            (isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                .overlay(Color.folderAccent.opacity(isDragHovered ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .animation(
            isDragHovered
                ? .easeInOut(duration: 0.38).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.12),
            value: isDragHovered
        )
        .overlay {
            NativeDeviceDropTarget(
                destination: volume.url,
                onOpen: action,
                onEject: { volumeManager.ejectVolume(volume) },
                onEntered: beginSpringLoading,
                onExited: endSpringLoading,
                onDrop: { sources, forceCopy in
                    endSpringLoading()
                    operationCoordinator.drop(sources, into: volume.url, forceCopy: forceCopy)
                }
            )
        }
        .help("Open \(volume.name) · Eject button on the right")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(volume.name), external drive")
        .accessibilityHint("Click to open. Click the eject icon to eject. You can drop files here.")
    }

    private func beginSpringLoading() {
        dragHoverGeneration += 1
        let generation = dragHoverGeneration
        withAnimation(.easeInOut(duration: 0.16)) {
            isDragHovered = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard generation == dragHoverGeneration, isDragHovered else { return }
            action()
            isDragHovered = false
        }
    }

    private func endSpringLoading() {
        dragHoverGeneration += 1
        withAnimation(.easeOut(duration: 0.12)) {
            isDragHovered = false
        }
    }
}

/// Uses AppKit's dragging pasteboard for sidebar volumes. SwiftUI's
/// `DropDelegate` can show hover feedback for an AppKit drag session but may
/// lose the file URL providers after spring-loading navigates the browser.
/// Keeping the destination in AppKit makes the final drop use the exact same
/// payload path as folders in the grid and list.
private struct NativeDeviceDropTarget: NSViewRepresentable {
    let destination: URL
    let onOpen: () -> Void
    let onEject: () -> Void
    let onEntered: () -> Void
    let onExited: () -> Void
    let onDrop: ([URL], Bool) -> Void

    func makeNSView(context: Context) -> DeviceDropView {
        let view = DeviceDropView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: DeviceDropView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: DeviceDropView) {
        view.destination = destination
        view.onOpen = onOpen
        view.onEject = onEject
        view.onEntered = onEntered
        view.onExited = onExited
        view.onDrop = onDrop
    }

    final class DeviceDropView: NSView {
        var destination: URL?
        var onOpen: () -> Void = {}
        var onEject: () -> Void = {}
        var onEntered: () -> Void = {}
        var onExited: () -> Void = {}
        var onDrop: ([URL], Bool) -> Void = { _, _ in }
        private var isHovering = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if point.x >= bounds.maxX - 32 {
                onEject()
            } else {
                onOpen()
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination else { return [] }
            let operation = FileDropValidation.operation(
                for: droppedURLs(from: sender.draggingPasteboard),
                into: destination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            )
            guard operation != [] else { return [] }
            if !isHovering {
                isHovering = true
                onEntered()
            }
            return operation
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination else { return [] }
            return FileDropValidation.operation(
                for: droppedURLs(from: sender.draggingPasteboard),
                into: destination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            )
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            finishHover()
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let destination else { return false }
            return FileDropValidation.operation(
                for: droppedURLs(from: sender.draggingPasteboard),
                into: destination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            ) != []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = droppedURLs(from: sender.draggingPasteboard)
            guard let destination,
                  FileDropValidation.operation(
                    for: urls,
                    into: destination,
                    forceCopy: NSEvent.modifierFlags.contains(.option)
                  ) != [] else { return false }
            finishHover()
            onDrop(urls, NSEvent.modifierFlags.contains(.option))
            return true
        }

        private func finishHover() {
            guard isHovering else { return }
            isHovering = false
            onExited()
        }

        private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
            if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !objects.isEmpty {
                return objects
            }

            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            if let paths = pasteboard.propertyList(forType: filenames) as? [String] {
                return paths.map(URL.init(fileURLWithPath:))
            }

            return []
        }
    }
}

private struct FileDestinationDropDelegate: DropDelegate {
    let destination: URL
    let onEntered: () -> Void
    let onExited: () -> Void
    let onDrop: ([URL], Bool) -> Void

    func dropEntered(info: DropInfo) {
        onEntered()
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        FileDropValidation.canWrite(to: destination)
            ? DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
            : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let accumulator = LockedURLAccumulator()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                defer { group.leave() }
                guard let url = object as? URL, error == nil else { return }
                accumulator.append(url)
            }
        }

        let forceCopy = NSEvent.modifierFlags.contains(.option)
        group.notify(queue: .main) {
            let sources = accumulator.snapshot()
            guard !sources.isEmpty else { return }
            onDrop(sources, forceCopy)
        }
        return true
    }
}
