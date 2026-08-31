//
//  FileListView.swift
//  Folder
//
//  List view for files and folders
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class ListClickTracker {
    var lastClickedItem: UUID?
    var lastClickTime: Date?
}

struct FileListView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var operationCoordinator = FileOperationCoordinator.shared
    let showDimmed: Bool

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var clickTracker = ListClickTracker()
    @FocusState private var renamingFocusedID: UUID?
    @State private var scrollPosition: UUID?
    @State private var springLoadedItemID: UUID?
    @State private var springLoadGeneration = 0
    @State private var tagDropTargetID: UUID?

    private let clickPauseInterval: TimeInterval = 0.5

    var body: some View {
        VStack(spacing: 0) {
            SortingToolbar(viewModel: viewModel)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                        row(for: item)
                        }
                    }
                    .padding(.horizontal)
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
                // Die Auswahl bleibt sichtbar — siehe die gleichlautende Stelle
                // in FileGridView.
                .onChange(of: viewModel.selectedItems) { auswahl in
                    guard auswahl.count == 1, let ziel = auswahl.first else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(ziel)
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDeleteCommand {
            viewModel.deleteSelectedItems()
        }
    }

    /// Eine Zeile mit allem, was daran hängt.
    ///
    /// Ausgelagert, weil der Compiler den Ausdruck im `body` sonst nicht mehr in
    /// vertretbarer Zeit prüfen kann — jeder Modifikator vergrössert den Typ.
    @ViewBuilder
    private func row(for item: FileSystemItem) -> some View {
            FileListRowWithRename(
                item: item,
                isSelected: viewModel.isSelected(item),
                isRenaming: false,
                clipboardManager: clipboardManager,
                fileExplorerViewModel: viewModel,
                isDimmed: showDimmed,
                onSingleClick: { handleSingleClick(item) },
                onDoubleClick: { handleDoubleClick(item) },
                renamingFocusedID: $renamingFocusedID
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.folderAccent.opacity(springLoadedItemID == item.id ? 0.18 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
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
                    onDoubleClick: { handleDoubleClick(item) },
                    onColorTagDrop: { farbe in
                        viewModel.applyColorTag(farbe, to: tagDropTargets(for: item))
                    },
                    onColorTagHover: { aktiv in
                        if aktiv {
                            tagDropTargetID = item.id
                        } else if tagDropTargetID == item.id {
                            tagDropTargetID = nil
                        }
                    }
                )
            }
            .contextMenu {
                FileContextMenu(item: item, viewModel: viewModel, clipboardManager: clipboardManager)
            }
            // Eine Farbe aus der Sidebar hierher fallen lassen markiert
            // die Zeile. Der Rahmen zeigt vorher, welche Zeile trifft.
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        Color.folderAccent.opacity(tagDropTargetID == item.id ? 0.9 : 0),
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            }
    }

    /// Worauf ein fallengelassener Tag wirkt: auf die ganze Auswahl, wenn die
    /// getroffene Zeile dazugehört, sonst nur auf diese eine. Wie in Finder.
    private func tagDropTargets(for item: FileSystemItem) -> [FileSystemItem] {
        guard viewModel.selectedItems.contains(item.id) else { return [item] }
        return viewModel.items.filter { viewModel.selectedItems.contains($0.id) }
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
    @State private var icon: NSImage?

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
                        Image(nsImage: icon ?? iconService.icon(for: item, size: 20))
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
                // Das echte Symbol kommt abseits des Hauptthreads nach — im
                // Bildaufbau darf es nie geholt werden.
                if let geladen = await iconService.loadIcon(for: item, size: 20) {
                    icon = geladen
                }

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
    @State private var icon: NSImage?

    private var isCut: Bool {
        clipboardManager.clipboardAction == .cut &&
        clipboardManager.clipboardItems.contains(where: { $0.path == item.path })
    }

    /// Kommt aus dem Einlesen des Ordners. Pro Kachel auf die Platte zu gehen
    /// wuerde bei tausend Dateien tausend Zugriffe je Bildaufbau kosten.
    private var colorTag: ColorTag? {
        item.colorTag.map { ColorTag(color: $0, name: $0.displayName) }
    }

    private var quickLookTransitionImage: NSImage {
        thumbnail ?? icon ?? iconService.icon(for: item, size: 20)
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
                    Image(nsImage: icon ?? iconService.icon(for: item, size: 20))
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
            .background(
                QuickLookSourceAnchor(
                    url: item.path,
                    transitionImage: quickLookTransitionImage
                )
            )

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
            // Das echte Symbol kommt abseits des Hauptthreads nach — im
            // Bildaufbau darf es nie geholt werden.
            if let geladen = await iconService.loadIcon(for: item, size: 20) {
                icon = geladen
            }

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
