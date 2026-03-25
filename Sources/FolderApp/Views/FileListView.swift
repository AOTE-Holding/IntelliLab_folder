//
//  FileListView.swift
//  Folder
//
//  List view for files and folders
//

import SwiftUI
import AppKit

struct FileListView: View {
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
    @State private var scrollPosition: UUID?

    private let clickPauseInterval: TimeInterval = 0.5

    var body: some View {
        VStack(spacing: 0) {
            SortingToolbar(viewModel: viewModel)

            List(viewModel.items) { item in
                FileListRowWithRename(
                    item: item,
                    isSelected: viewModel.isSelected(item),
                    isRenaming: viewModel.renamingItem == item.id,
                    clipboardManager: clipboardManager,
                    fileExplorerViewModel: viewModel,
                    isDimmed: showDimmed,
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
                            enabled: true
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
            .listStyle(.plain)
            .focusable(true)
            .scrollContentBackground(.hidden)  // Hide default List background
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Clear selection when clicking empty space
                        viewModel.clearSelection()
                        // Save scroll position before dismissing
                        if let currentRenaming = viewModel.renamingItem {
                            scrollPosition = currentRenaming
                        }
                        // Dismiss rename mode when clicking empty space
                        renamingFocusedID = nil
                        viewModel.commitRename()
                    }
            )
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
        // Only allow drops on folders
        guard destination.type == .folder else { return false }

        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { [weak viewModel] object, error in
                guard let url = object as? URL, error == nil else {
                    return
                }

                let destinationURL = destination.path.appendingPathComponent(url.lastPathComponent)

                // Don't move if source and destination are the same
                guard url != destinationURL else { return }

                // Check if destination already exists
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return }

                try? FileManager.default.moveItem(at: url, to: destinationURL)
                Task { @MainActor in
                    viewModel?.refresh()
                }
            }
        }

        return true
    }

}

// MARK: - File List Row with Rename Support

struct FileListRowWithRename: View {
    let item: FileSystemItem
    let isSelected: Bool
    let isRenaming: Bool
    let clipboardManager: ClipboardManager
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    let isDimmed: Bool
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    @FocusState.Binding var renamingFocusedID: UUID?
    @StateObject private var iconService = IconService.shared
    @StateObject private var sidebarManager = SidebarManager.shared
    @StateObject private var thumbnailService = ThumbnailService.shared
    @State private var thumbnail: NSImage?

    var body: some View {
        if isRenaming {
            // Rename mode
            HStack(spacing: 12) {
                // Icon or Thumbnail
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    } else {
                        iconService.swiftUIIcon(for: item, size: 20)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    }
                }

                // Rename TextField
                TextField("", text: $fileExplorerViewModel.renameText, onCommit: {
                    fileExplorerViewModel.commitRename()
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
                .focused($renamingFocusedID, equals: item.id)
                .onExitCommand {
                    fileExplorerViewModel.cancelRename()
                    renamingFocusedID = nil
                }
                .onAppear {
                    renamingFocusedID = item.id
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.folderAccent.opacity(0.1))
            .cornerRadius(4)
            .transaction { $0.animation = nil }
            .task {
                // Load thumbnail when entering rename mode
                if thumbnailService.supportsThumbnail(for: item.path.path) {
                    thumbnail = await thumbnailService.getThumbnail(for: item.path.path, size: CGSize(width: 40, height: 40))
                }
            }
        } else {
            // Normal display mode
            FileListRow(
                item: item,
                isSelected: isSelected,
                clipboardManager: clipboardManager,
                fileExplorerViewModel: fileExplorerViewModel,
                isDimmed: isDimmed
            )
            .onTapGesture(count: 2) {
                onDoubleClick()
            }
            .onTapGesture {
                onSingleClick()
            }
        }
    }
}

struct FileListRow: View {
    let item: FileSystemItem
    let isSelected: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    let isDimmed: Bool
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
        HStack(spacing: 12) {
            // Icon or Thumbnail
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = thumbnail {
                    // Show thumbnail preview
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    // Show regular icon
                    iconService.swiftUIIcon(for: item, size: 20)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                }

                // Symlink badge
                if item.isSymlink {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8))
                        .foregroundColor(.folderAccent)
                }

                // Color tag badge
                if let colorTag = colorTag {
                    Circle()
                        .fill(Color(hex: colorTag.color.rawValue))
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                }
            }

            // Name
            Text(item.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Modified date
            Text(item.modifiedAt, style: .date)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)

            // Size
            if item.type == .file {
                Text(formatFileSize(item.size))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else if item.type == .folder {
                // Show folder size if calculated
                if let folderSize = fileExplorerViewModel.folderSizes[item.path] {
                    Text(formatFileSize(folderSize))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                } else {
                    Text("...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            } else {
                Text("--")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.folderAccent.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())  // Make entire row clickable
        .opacity(opacity)
        .transaction { $0.animation = nil }
        .task {
            // Load thumbnail for images and PDFs
            if thumbnailService.supportsThumbnail(for: item.path.path) {
                thumbnail = await thumbnailService.getThumbnail(for: item.path.path, size: CGSize(width: 40, height: 40))
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
