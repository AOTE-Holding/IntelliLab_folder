//
//  FileGridView.swift
//  Folder
//
//  Grid view for files and folders
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileGridView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    let showDimmed: Bool

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var lastClickedItem: UUID?
    @State private var lastClickTime: Date?
    @FocusState private var renamingFocusedID: UUID?

    private let spacing: CGFloat = 16
    private let clickPauseInterval: TimeInterval = 0.5 // Time window for click-pause-click
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(viewModel.viewMode.iconSize + 40)), spacing: spacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            SortingToolbar(viewModel: viewModel)

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(viewModel.items) { item in
                        FileGridItemWithRename(
                            item: item,
                            isSelected: viewModel.isSelected(item),
                            isRenaming: viewModel.renamingItem == item.id,
                            clipboardManager: clipboardManager,
                            isDimmed: showDimmed,
                            viewModel: viewModel,
                            onSingleClick: { handleSingleClick(item) },
                            onDoubleClick: { handleDoubleClick(item) },
                            renamingFocusedID: $renamingFocusedID
                        )
                        .overlay {
                            Color.clear
                                .multiFileDrag(
                                    urls: viewModel.isSelected(item)
                                        ? viewModel.items.filter { viewModel.selectedItems.contains($0.id) }.map { $0.path }
                                        : [item.path],
                                    enabled: true,
                                    onSingleClick: { _ in handleSingleClick(item) },
                                    onDoubleClick: { handleDoubleClick(item) }
                                )
                        }
                        .onDrag {
                            NSItemProvider(object: item.path as NSURL)
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers: providers, destination: item)
                        }
                        .contextMenu {
                            FileContextMenu(item: item, viewModel: viewModel, clipboardManager: clipboardManager)
                        }
                    }
                }
                .padding()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.clearSelection()
                            if viewModel.renamingItem != nil {
                                renamingFocusedID = nil
                                viewModel.commitRename()
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button("New Folder") {
                    viewModel.createNewFolder(named: "Untitled Folder", autoRename: true)
                }

                Divider()

                Button("Open Terminal Here") {
                    openTerminal(at: viewModel.currentPath)
                }

                Divider()

                Button("Paste") {
                    Task {
                        _ = try? await clipboardManager.paste(to: viewModel.currentPath)
                        viewModel.refresh()
                    }
                }
                .disabled(!clipboardManager.hasClipboardContent())
            }
        }
        .onDeleteCommand {
            viewModel.deleteSelectedItems()
        }
    }

    private func openTerminal(at path: URL) {
        // Check for custom terminal path first
        if let customTerminalPath = settingsManager.settings.customTerminalPath {
            openCustomTerminal(customTerminalPath, at: path)
            return
        }

        let terminal = settingsManager.settings.defaultTerminal

        switch terminal {
        case .terminal, .iterm2:
            // Use AppleScript for Terminal.app and iTerm2
            let appName = terminal == .terminal ? "Terminal" : "iTerm"
            let script = """
                tell application "\(appName)"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }

        case .warp:
            // Warp uses URL scheme
            if let url = URL(string: "warp://action/new_tab?path=\(path.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path.path)") {
                NSWorkspace.shared.open(url)
            }

        case .kitty:
            // Launch kitty with --directory argument
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitty")
            process.arguments = ["--directory", path.path]
            try? process.run()

        case .alacritty:
            // Launch alacritty with --working-directory argument
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Alacritty.app/Contents/MacOS/alacritty")
            process.arguments = ["--working-directory", path.path]
            try? process.run()
        }
    }

    private func openCustomTerminal(_ terminalURL: URL, at path: URL) {
        // Use AppleScript for Terminal.app specifically
        if terminalURL.path.contains("Terminal.app") {
            let script = """
                tell application "Terminal"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else if terminalURL.path.contains("iTerm") {
            let script = """
                tell application "iTerm"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else {
            // For other terminals, try opening with the path
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([path], withApplicationAt: terminalURL, configuration: config)
        }
    }

    private func handleSingleClick(_ item: FileSystemItem) {
        let modifierFlags = NSEvent.modifierFlags
        let now = Date()

        // Check for Finder-style click-pause-click rename pattern
        if !modifierFlags.contains(.shift) && !modifierFlags.contains(.command),
           lastClickedItem == item.id,
           let lastTime = lastClickTime,
           now.timeIntervalSince(lastTime) >= clickPauseInterval && now.timeIntervalSince(lastTime) <= 2.0,
           viewModel.isSelected(item) {
            // Second click on same item after pause - enter rename mode
            viewModel.startRenaming(item)
            renamingFocusedID = item.id
            lastClickedItem = nil
            lastClickTime = nil
            return
        }

        // Dismiss any active rename mode when clicking a different item
        if viewModel.renamingItem != nil && viewModel.renamingItem != item.id {
            renamingFocusedID = nil
            viewModel.commitRename()
        }

        // Handle selection
        if modifierFlags.contains(.shift) {
            // Shift+Click: range selection
            if let lastSelected = viewModel.lastSelectedItem,
               let lastItem = viewModel.items.first(where: { $0.id == lastSelected }) {
                viewModel.selectRange(from: lastItem, to: item)
            } else {
                viewModel.toggleSelection(for: item)
            }
        } else if modifierFlags.contains(.command) {
            // Cmd+Click: toggle selection (add/remove from selection)
            viewModel.toggleSelection(for: item)
        } else {
            // Regular click: select only this item
            viewModel.clearSelection()
            viewModel.toggleSelection(for: item)
        }

        // Track click for rename detection
        lastClickedItem = item.id
        lastClickTime = now
    }

    private func handleDoubleClick(_ item: FileSystemItem) {
        // Double click: open item
        viewModel.openItem(item)
    }

    private func handleDrop(providers: [NSItemProvider], destination: FileSystemItem) -> Bool {
        guard destination.type == .folder else { return false }

        viewModel.isProcessing = true

        let group = DispatchGroup()
        let lock = NSLock()
        var allSourceURLs: [URL] = []
        var allDestURLs: [URL] = []

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                defer { group.leave() }
                guard let url = object as? URL, error == nil else { return }

                let destinationURL = destination.path.appendingPathComponent(url.lastPathComponent)
                guard url != destinationURL else { return }
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return }

                do {
                    try FileManager.default.moveItem(at: url, to: destinationURL)
                    lock.lock()
                    allSourceURLs.append(url)
                    allDestURLs.append(destinationURL)
                    lock.unlock()
                } catch {}
            }
        }

        group.notify(queue: .main) { [weak viewModel] in
            if !allSourceURLs.isEmpty {
                ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                    type: .move, sourceURLs: allSourceURLs, destinationURLs: allDestURLs
                ))
            }
            viewModel?.isProcessing = false
            viewModel?.refresh()
        }

        return true
    }

}

// MARK: - File Grid Item with Rename Support

struct FileGridItemWithRename: View {
    let item: FileSystemItem
    let isSelected: Bool
    let isRenaming: Bool
    let clipboardManager: ClipboardManager
    let isDimmed: Bool
    @ObservedObject var viewModel: FileExplorerViewModel
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    @FocusState.Binding var renamingFocusedID: UUID?
    @StateObject private var iconService = IconService.shared
    @StateObject private var thumbnailService = ThumbnailService.shared
    @State private var thumbnail: NSImage?

    var body: some View {
        if isRenaming {
            // Rename mode
            VStack(spacing: 8) {
                // Use thumbnail if available, otherwise use icon
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: CGFloat(viewModel.viewMode.iconSize), height: CGFloat(viewModel.viewMode.iconSize))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        iconService.swiftUIIcon(for: item, size: CGFloat(viewModel.viewMode.iconSize))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: CGFloat(viewModel.viewMode.iconSize), height: CGFloat(viewModel.viewMode.iconSize))
                    }
                }
                .opacity(isDimmed && clipboardManager.clipboardItems.contains(where: { $0.id == item.id }) ? 0.5 : 1.0)

                TextField("", text: $viewModel.renameText, onCommit: {
                    viewModel.commitRename()
                })
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .frame(width: CGFloat(viewModel.viewMode.iconSize + 40))
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
                .focused($renamingFocusedID, equals: item.id)
                .onExitCommand {
                    viewModel.cancelRename()
                    renamingFocusedID = nil
                }
                .onAppear {
                    renamingFocusedID = item.id
                }
            }
            .padding(8)
            .background(isSelected ? Color.folderAccent.opacity(0.2) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.folderAccent, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(Rectangle())
            .frame(width: CGFloat(viewModel.viewMode.iconSize + 40) + 16)
            .transaction { $0.animation = nil }
            .task {
                // Load thumbnail when entering rename mode
                if thumbnailService.supportsThumbnail(for: item.path.path) {
                    thumbnail = await thumbnailService.getThumbnail(for: item.path.path, size: CGSize(width: 128, height: 128))
                }
            }
        } else {
            // Normal display mode
            FileGridItem(item: item, isSelected: isSelected, clipboardManager: clipboardManager, isDimmed: isDimmed, iconSize: CGFloat(viewModel.viewMode.iconSize))
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
                .onTapGesture {
                    onSingleClick()
                }
        }
    }
}

struct FileGridItem: View {
    let item: FileSystemItem
    let isSelected: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    let isDimmed: Bool
    let iconSize: CGFloat
    @StateObject private var iconService = IconService.shared
    @StateObject private var sidebarManager = SidebarManager.shared
    @StateObject private var thumbnailService = ThumbnailService.shared
    @State private var thumbnail: NSImage?

    private var isCut: Bool {
        clipboardManager.clipboardAction == .cut &&
        clipboardManager.clipboardItems.contains(where: { $0.path == item.path })
    }

    private var colorTag: ColorTag? {
        sidebarManager.getColorTag(for: item.path)
    }

    private var opacity: Double {
        if isDimmed {
            return 0.3
        } else if isCut {
            return 0.5
        } else {
            return 1.0
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Icon or Thumbnail
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = thumbnail {
                    // Show thumbnail preview
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    // Show regular icon
                    iconService.swiftUIIcon(for: item, size: iconSize)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSize, height: iconSize)
                }

                // Symlink badge
                if item.isSymlink {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 16))
                        .foregroundColor(.folderAccent)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(Circle())
                }

                // Color tag badge
                if let colorTag = colorTag {
                    Circle()
                        .fill(Color(hex: colorTag.color.rawValue))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        )
                        .offset(x: 4, y: -4)
                }
            }

            // Name
            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: iconSize + 40)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.folderAccent : Color.clear, lineWidth: 2)
        )
        .opacity(opacity)
        .contentShape(Rectangle())
        .transaction { $0.animation = nil }
        .task {
            // Load thumbnail for images and PDFs
            if thumbnailService.supportsThumbnail(for: item.path.path) {
                thumbnail = await thumbnailService.getThumbnail(for: item.path.path, size: CGSize(width: 128, height: 128))
            }
        }
    }
}

// MARK: - File Context Menu

struct FileContextMenu: View {
    let item: FileSystemItem
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var clipboardManager: ClipboardManager
    @StateObject private var sidebarManager = SidebarManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var showingRenameAlert = false
    @State private var newName = ""

    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]

    private var isImageFile: Bool {
        item.type == .file && imageExtensions.contains(item.path.pathExtension.lowercased())
    }

    var body: some View {
        Button("Open") {
            viewModel.openItem(item)
        }

        // Show "Open Terminal Here" for folders
        if item.type == .folder {
            Button("Open Terminal Here") {
                openTerminal(at: item.path)
            }
        }

        // Only show "Open With" for files (not folders)
        if item.type == .file {
            Menu("Open With") {
                if let contentType = try? item.path.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    let apps = NSWorkspace.shared.urlsForApplications(toOpen: contentType)
                    let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: contentType)

                    ForEach(Array(apps.enumerated()), id: \.offset) { index, appURL in
                        Button(action: {
                            openWith(appURL: appURL)
                        }) {
                            HStack {
                                // App icon
                                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)

                                // App name
                                let appName = FileManager.default.displayName(atPath: appURL.path)
                                    .replacingOccurrences(of: ".app", with: "")
                                Text(appName)

                                // Mark default app
                                if appURL == defaultAppURL {
                                    Text("(default)")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }

                    if !apps.isEmpty {
                        Divider()
                    }

                    // "Other..." option to choose from file picker
                    Button("Other...") {
                        let panel = NSOpenPanel()
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.allowedContentTypes = [.application]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false

                        if panel.runModal() == .OK, let appURL = panel.url {
                            openWith(appURL: appURL)
                        }
                    }
                }
            }

            Button("Always Open With...") {
                showAlwaysOpenWith()
            }
        }

        Divider()

        Button("Copy") {
            // Copy all selected items if item is in selection, otherwise just this item
            let itemsToCopy = viewModel.isSelected(item) ?
                viewModel.items.filter { viewModel.selectedItems.contains($0.id) } :
                [item]
            clipboardManager.copy(items: itemsToCopy)
        }

        Button("Cut") {
            // Cut all selected items if item is in selection, otherwise just this item
            let itemsToCut = viewModel.isSelected(item) ?
                viewModel.items.filter { viewModel.selectedItems.contains($0.id) } :
                [item]
            clipboardManager.cut(items: itemsToCut)
        }

        Divider()

        Button("Duplicate") {
            duplicateItems()
        }

        Button("Compress") {
            compressItems()
        }

        if isImageFile {
            Menu("Rotate Image") {
                Button("Rotate Left (90°)") {
                    rotateImage(degrees: -90)
                }
                Button("Rotate Right (90°)") {
                    rotateImage(degrees: 90)
                }
            }
        }

        Divider()

        Button("Move to Trash") {
            moveToTrash()
        }

        Button("Rename...") {
            newName = item.name
            showingRenameAlert = true
        }

        Divider()

        Button("Add to Favorites") {
            sidebarManager.addFavorite(item.path, name: item.name, icon: item.type == .folder ? "folder.fill" : "doc.fill")
        }

        Menu("Apply Color Tag") {
            ForEach(ColorTag.TagColor.allCases, id: \.self) { color in
                Button(action: {
                    sidebarManager.setColorTag(for: item.path, tag: ColorTag(color: color, name: color.rawValue))
                }) {
                    HStack {
                        Circle()
                            .fill(Color(hex: color.rawValue))
                            .frame(width: 12, height: 12)
                        Text(colorName(for: color))
                    }
                }
            }

            Divider()

            Button("Remove Color Tag") {
                sidebarManager.setColorTag(for: item.path, tag: nil)
            }
        }
        .background(
            EmptyView()
                .alert("Rename", isPresented: $showingRenameAlert) {
                    TextField("New Name", text: $newName)
                    Button("Rename") {
                        if !newName.isEmpty {
                            viewModel.renameItem(item, to: newName)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
        )
    }

    private func moveToTrash() {
        let itemsToTrash = viewModel.isSelected(item) ?
            viewModel.items.filter { viewModel.selectedItems.contains($0.id) } :
            [item]

        var sourceURLs: [URL] = []
        var trashURLs: [URL] = []

        for trashItem in itemsToTrash {
            var trashNSURL: NSURL?
            try? FileManager.default.trashItem(at: trashItem.path, resultingItemURL: &trashNSURL)
            sourceURLs.append(trashItem.path)
            if let trashURL = trashNSURL as URL? {
                trashURLs.append(trashURL)
            }
        }

        if sourceURLs.count == trashURLs.count && !sourceURLs.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: .trash, sourceURLs: sourceURLs, destinationURLs: trashURLs
            ))
        }

        viewModel.selectedItems.removeAll()
        viewModel.refresh()
    }

    private func openWith(appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([item.path], withApplicationAt: appURL, configuration: configuration)
    }

    private func showAlwaysOpenWith() {
        // Open Finder's Get Info panel where user can change default app
        let script = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(item.path.path)" as alias)
            end tell
            """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
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
        case .pink: return "Pink"
        case .gray: return "Gray"
        }
    }

    private func openTerminal(at path: URL) {
        // Check for custom terminal path first
        if let customTerminalPath = settingsManager.settings.customTerminalPath {
            openCustomTerminal(customTerminalPath, at: path)
            return
        }

        let terminal = settingsManager.settings.defaultTerminal

        switch terminal {
        case .terminal, .iterm2:
            // Use AppleScript for Terminal.app and iTerm2
            let appName = terminal == .terminal ? "Terminal" : "iTerm"
            let script = """
                tell application "\(appName)"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }

        case .warp:
            // Warp uses URL scheme
            if let url = URL(string: "warp://action/new_tab?path=\(path.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path.path)") {
                NSWorkspace.shared.open(url)
            }

        case .kitty:
            // Launch kitty with --directory argument
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitty")
            process.arguments = ["--directory", path.path]
            try? process.run()

        case .alacritty:
            // Launch alacritty with --working-directory argument
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Alacritty.app/Contents/MacOS/alacritty")
            process.arguments = ["--working-directory", path.path]
            try? process.run()
        }
    }

    private func openCustomTerminal(_ terminalURL: URL, at path: URL) {
        // Use AppleScript for Terminal.app specifically
        if terminalURL.path.contains("Terminal.app") {
            let script = """
                tell application "Terminal"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else if terminalURL.path.contains("iTerm") {
            let script = """
                tell application "iTerm"
                    activate
                    do script "cd '\(path.path)'"
                end tell
                """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        } else {
            // For other terminals, try opening with the path
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([path], withApplicationAt: terminalURL, configuration: config)
        }
    }

    private func duplicateItems() {
        let items = viewModel.isSelected(item) ?
            viewModel.items.filter { viewModel.selectedItems.contains($0.id) } : [item]

        for duplicateItem in items {
            _ = try? FileSystemService.shared.duplicateItem(at: duplicateItem.path)
        }
        viewModel.refresh()
    }

    private func compressItems() {
        let items = viewModel.isSelected(item) ?
            viewModel.items.filter { viewModel.selectedItems.contains($0.id) } : [item]

        _ = try? FileSystemService.shared.compressItems(at: items.map { $0.path })
        viewModel.refresh()
    }

    private func rotateImage(degrees: CGFloat) {
        try? FileSystemService.shared.rotateImage(at: item.path, degrees: degrees)
        ThumbnailService.shared.clearCache()
        viewModel.refresh()
    }
}
