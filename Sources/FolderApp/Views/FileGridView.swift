//
//  FileGridView.swift
//  Folder
//
//  Grid view for files and folders
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class GridClickTracker {
    var lastClickedItem: UUID?
    var lastClickTime: Date?
}

struct FileGridView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var operationCoordinator = FileOperationCoordinator.shared
    let showDimmed: Bool

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var clickTracker = GridClickTracker()
    @State private var springLoadedItemID: UUID?
    @State private var springLoadGeneration = 0
    @FocusState private var renamingFocusedID: UUID?

    private let spacing: CGFloat = 16
    private let clickPauseInterval: TimeInterval = 0.5 // Time window for click-pause-click
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(viewModel.viewMode.iconSize + 40)), spacing: spacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            SortingToolbar(viewModel: viewModel)

            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(viewModel.items) { item in
                        FileGridItemWithRename(
                            item: item,
                            isSelected: viewModel.isSelected(item),
                            isRenaming: false,
                            clipboardManager: clipboardManager,
                            isDimmed: showDimmed,
                            viewModel: viewModel,
                            onSingleClick: { handleSingleClick(item) },
                            onDoubleClick: { handleDoubleClick(item) },
                            renamingFocusedID: $renamingFocusedID
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.folderAccent.opacity(springLoadedItemID == item.id ? 0.18 : 0))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.folderAccent.opacity(springLoadedItemID == item.id ? 0.85 : 0), lineWidth: 1.5)
                                )
                                .allowsHitTesting(false)
                                .animation(
                                    springLoadedItemID == item.id
                                        ? .easeInOut(duration: 0.38).repeatForever(autoreverses: true)
                                        : .easeOut(duration: 0.12),
                                    value: springLoadedItemID == item.id
                                )
                        }
                        .overlay {
                            Color.clear.multiFileDrag(
                                urls: viewModel.isSelected(item)
                                    ? viewModel.items.filter { viewModel.selectedItems.contains($0.id) }.map { $0.path }
                                    : [item.path],
                                enabled: true,
                                dropDestination: item.type == .folder ? item.path : nil,
                                onDropFiles: { sources, forceCopy in
                                    endSpringLoading(item)
                                    operationCoordinator.drop(sources, into: item.path, forceCopy: forceCopy)
                                },
                                onDragEntered: { beginSpringLoading(item) },
                                onDragExited: { endSpringLoading(item) },
                                onSingleClick: { modifiers in handleSingleClick(item, modifiers: modifiers) },
                                onDoubleClick: { handleDoubleClick(item) }
                            )
                        }
                        .contextMenu {
                            FileContextMenu(item: item, viewModel: viewModel, clipboardManager: clipboardManager)
                        }
                        }
                    }
                    .padding()
                    // A ScrollView sizes its content to the files it contains.
                    // Match the visible height so clicks below the last file
                    // still land in this background and clear the selection.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .overlay {
                                ImmediateBackgroundClickView(action: viewModel.clearSelection)
                            }
                    )
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    dropFilesIntoCurrentFolder(providers)
                }
                .contextMenu {
                    Button("New Folder") {
                        viewModel.createNewFolder(named: "Untitled Folder", autoRename: true)
                    }

                    Divider()

                    Button("Open Command Line Here") {
                        openTerminal(at: viewModel.currentPath)
                    }

                    Divider()

                    Button("Paste") {
                        operationCoordinator.paste(to: viewModel.currentPath)
                    }
                    .disabled(!clipboardManager.hasClipboardContent())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDeleteCommand {
            viewModel.deleteSelectedItems()
        }
    }

    private func dropFilesIntoCurrentFolder(_ providers: [NSItemProvider]) -> Bool {
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
            operationCoordinator.drop(sources, into: viewModel.currentPath, forceCopy: forceCopy)
        }
        return true
    }

    private func beginSpringLoading(_ item: FileSystemItem) {
        guard item.type == .folder else { return }

        springLoadGeneration += 1
        let generation = springLoadGeneration
        withAnimation(.easeInOut(duration: 0.16)) {
            springLoadedItemID = item.id
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard generation == springLoadGeneration,
                  springLoadedItemID == item.id else { return }
            viewModel.navigate(to: item.path)
            springLoadedItemID = nil
        }
    }

    private func endSpringLoading(_ item: FileSystemItem) {
        guard springLoadedItemID == item.id else { return }
        springLoadGeneration += 1
        withAnimation(.easeOut(duration: 0.12)) {
            springLoadedItemID = nil
        }
    }

    private func openTerminal(at path: URL) {
        CommandLineLauncher.shared.open(at: path, settings: settingsManager.settings)
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

    private func handleSingleClick(
        _ item: FileSystemItem,
        modifiers modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
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
            viewModel.selectOnly(item)
            QuickLookManager.shared.selectVisiblePreviewItem(at: item.path)
        }

    }

    private func handleDoubleClick(_ item: FileSystemItem) {
        // Double click: open item
        viewModel.openItem(item)
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

    private var quickLookTransitionImage: NSImage {
        thumbnail ?? iconService.icon(for: item, size: iconSize)
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
            .background(
                QuickLookSourceAnchor(
                    url: item.path,
                    transitionImage: quickLookTransitionImage
                )
            )

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
    var allItems: [FileSystemItem]? = nil
    var selectedItemIDs: Set<UUID>? = nil
    var searchViewModel: SearchViewModel? = nil
    @StateObject private var sidebarManager = SidebarManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var operationCoordinator = FileOperationCoordinator.shared
    @State private var showingRenameAlert = false
    @State private var newName = ""

    private var effectiveItems: [FileSystemItem] { allItems ?? viewModel.items }
    private var effectiveSelectedIDs: Set<UUID> { selectedItemIDs ?? viewModel.selectedItems }
    private var isItemSelected: Bool { effectiveSelectedIDs.contains(item.id) }

    private let imageExtensions = SafeImageRotator.supportedExtensions

    private var isImageFile: Bool {
        item.type == .file && imageExtensions.contains(item.path.pathExtension.lowercased())
    }

    var body: some View {
        Button("Open") {
            viewModel.openItem(item)
        }

        // Show the configured command-line launcher for folders.
        if item.type == .folder {
            Button("Open Command Line Here") {
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
            let items = isItemSelected
                ? effectiveItems.filter { effectiveSelectedIDs.contains($0.id) }
                : [item]
            clipboardManager.copy(items: items)
        }

        Button("Cut") {
            let items = isItemSelected
                ? effectiveItems.filter { effectiveSelectedIDs.contains($0.id) }
                : [item]
            clipboardManager.cut(items: items)
        }

        Divider()

        Button("Duplicate") { duplicateItems() }
        Button("Compress") { compressItems() }

        if isImageFile {
            Menu("Rotate Image") {
                Button("Rotate Left (90°)") { rotateImage(degrees: -90) }
                Button("Rotate Right (90°)") { rotateImage(degrees: 90) }
            }
        }

        Divider()

        Button("Move to Trash", role: .destructive) { moveToTrash() }

        Button("Rename…") {
            newName = item.name
            showingRenameAlert = true
        }

        Divider()

        Button("Add to Favorites") {
            sidebarManager.addFavorite(item.path, name: item.name, icon: item.type == .folder ? "folder.fill" : "doc.fill")
        }
        .background(
            EmptyView()
                .alert("Rename", isPresented: $showingRenameAlert) {
                    TextField("New Name", text: $newName)
                    Button("Rename") {
                        guard !newName.isEmpty else { return }
                        viewModel.renameItem(item, to: newName)
                    }
                    Button("Cancel", role: .cancel) { }
                }
        )
    }

    private func moveToTrash() {
        let items = isItemSelected
            ? effectiveItems.filter { effectiveSelectedIDs.contains($0.id) }
            : [item]
        operationCoordinator.moveToTrash(items.map(\.path))
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
        }
    }

    private func openTerminal(at path: URL) {
        CommandLineLauncher.shared.open(at: path, settings: settingsManager.settings)
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
        let items = isItemSelected ?
            effectiveItems.filter { effectiveSelectedIDs.contains($0.id) } : [item]

        operationCoordinator.duplicate(items.map(\.path))
    }

    private func compressItems() {
        let items = isItemSelected ?
            effectiveItems.filter { effectiveSelectedIDs.contains($0.id) } : [item]

        operationCoordinator.compress(items.map(\.path))
    }

    private func rotateImage(degrees: CGFloat) {
        operationCoordinator.rotateCopy(item.path, quarterTurns: Int((degrees / 90).rounded()))
    }
}
