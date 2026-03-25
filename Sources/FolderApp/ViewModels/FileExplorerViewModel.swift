//
//  FileExplorerViewModel.swift
//  Folder
//
//  Main view model for file exploration and navigation
//

import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
class FileExplorerViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var currentPath: URL
    @Published var items: [FileSystemItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var viewMode: ViewMode = .default
    @Published var selectedItemID: UUID? // Single selection for performance
    @Published var selectedItems: Set<UUID> = [] // Multi-selection support
    @Published var lastSelectedItem: UUID? // Track last selected item for range selection
    @Published var folderSizes: [URL: Int64] = [:] // Cache folder sizes
    @Published var renamingItem: UUID? // Track which item is being renamed
    @Published var renameText: String = "" // Current text in rename field

    // Tag filter mode (Finder-like color tag view)
    @Published var tagFilterMode: ColorTag.TagColor? = nil
    @Published var tagFilteredItems: [FileSystemItem] = []

    // Navigation history
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var navigationHistory: [URL] = []
    private var currentHistoryIndex = -1

    // Services
    private let fileSystemService = FileSystemService.shared
    private let settingsManager = SettingsManager.shared
    private let fileWatcher = FileSystemWatcher()

    // Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(initialPath: URL? = nil) {
        // Start at home directory or last opened folder
        if let path = initialPath {
            // Validate it's a directory
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                self.currentPath = path
            } else {
                // If file path provided, use parent directory
                self.currentPath = path.deletingLastPathComponent()
            }
        } else if let path = settingsManager.settings.lastOpenedFolder {
            self.currentPath = path
        } else {
            self.currentPath = fileSystemService.homeDirectory()
        }

        // Subscribe to file system changes
        setupFileWatcher()

        // Load initial contents
        Task {
            await loadContents()
        }
    }

    // MARK: - File System Watching

    private func setupFileWatcher() {
        fileWatcher.$didDetectChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] didChange in
                guard let self = self, didChange else { return }

                // Auto-refresh when changes detected
                Task {
                    await self.loadContents()
                }

                // Reset the flag
                self.fileWatcher.resetChangeFlag()
            }
            .store(in: &cancellables)
    }

    // MARK: - Directory Loading

    func loadContents() async {
        isLoading = true
        errorMessage = nil

        // Validate path is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: currentPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            self.errorMessage = "Invalid path: Not a directory"
            self.items = []
            self.isLoading = false
            return
        }

        do {
            let showHidden = settingsManager.settings.showHiddenFiles
            let contents = try fileSystemService.contentsOfDirectory(at: currentPath, showHidden: showHidden)

            // Capture previously selected paths BEFORE replacing items
            // (UUIDs change on every reload, so path is the only stable identity)
            let previouslySelectedPaths = Set(
                self.items
                    .filter { selectedItems.contains($0.id) }
                    .map { $0.path }
            )

            // Also capture the last-selected item's path for shift+click range selection
            let previousLastSelectedPath: URL? = {
                guard let lastID = lastSelectedItem else { return nil }
                return self.items.first(where: { $0.id == lastID })?.path
            }()

            // Sort based on current view mode
            self.items = sortItems(contents)
            self.isLoading = false

            // Save as last opened folder
            settingsManager.settings.lastOpenedFolder = currentPath

            // Restore selection by matching on path
            if !previouslySelectedPaths.isEmpty {
                let restoredIDs = Set(
                    self.items
                        .filter { previouslySelectedPaths.contains($0.path) }
                        .map { $0.id }
                )
                selectedItems = restoredIDs
                selectedItemID = restoredIDs.first

                // Restore lastSelectedItem for shift+click range selection
                if let lastPath = previousLastSelectedPath {
                    lastSelectedItem = self.items.first(where: { $0.path == lastPath })?.id
                }
            } else if selectedItems.isEmpty && !items.isEmpty {
                // Only auto-select first item on fresh navigation (no prior selection)
                selectedItems = [items[0].id]
                selectedItemID = items[0].id
                lastSelectedItem = items[0].id
            }

            // Calculate folder sizes in background
            Task.detached(priority: .background) { [weak self] in
                await self?.calculateFolderSizes(for: contents.filter { $0.type == .folder })
            }

            // Start watching the current directory for changes
            fileWatcher.startWatching(url: currentPath)
        } catch {
            self.errorMessage = "Failed to load directory: \(error.localizedDescription)"
            self.items = []
            self.isLoading = false

            // Stop watching on error
            fileWatcher.stopWatching()
        }
    }

    private func calculateFolderSizes(for folders: [FileSystemItem]) async {
        for folder in folders {
            // Skip if already calculated
            if folderSizes[folder.path] != nil {
                continue
            }

            do {
                let size = try await fileSystemService.calculateFolderSize(at: folder.path)
                await MainActor.run {
                    self.folderSizes[folder.path] = size
                }
            } catch {
                // Silently fail for inaccessible folders
            }
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        // Exit tag filter mode when navigating to any folder
        if tagFilterMode != nil {
            exitTagFilterMode()
        }

        guard fileSystemService.pathExists(url) else {
            errorMessage = "Path does not exist: \(url.path)"
            return
        }

        // Add to history
        if currentHistoryIndex < navigationHistory.count - 1 {
            // Remove forward history when navigating to new location
            navigationHistory.removeSubrange((currentHistoryIndex + 1)...)
        }

        navigationHistory.append(currentPath)
        currentHistoryIndex = navigationHistory.count - 1

        // Update navigation state
        updateNavigationState()

        // Navigate
        currentPath = url
        selectedItems.removeAll()

        Task {
            await loadContents()
        }
    }

    func navigateToParent() {
        guard let parent = fileSystemService.parentDirectory(of: currentPath) else {
            return
        }
        navigate(to: parent)
    }

    func navigateBack() {
        guard canGoBack, currentHistoryIndex > 0 else { return }

        currentHistoryIndex -= 1
        currentPath = navigationHistory[currentHistoryIndex]
        selectedItems.removeAll()

        Task {
            await loadContents()
        }

        updateNavigationState()
    }

    func navigateForward() {
        guard canGoForward, currentHistoryIndex < navigationHistory.count - 1 else { return }

        currentHistoryIndex += 1
        currentPath = navigationHistory[currentHistoryIndex]
        selectedItems.removeAll()

        Task {
            await loadContents()
        }

        updateNavigationState()
    }

    private func updateNavigationState() {
        canGoBack = currentHistoryIndex > 0
        canGoForward = currentHistoryIndex < navigationHistory.count - 1
    }

    // MARK: - Item Selection

    func toggleSelection(for item: FileSystemItem) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
                if selectedItemID == item.id {
                    selectedItemID = nil
                }
            } else {
                selectedItems.insert(item.id)
                selectedItemID = item.id
            }
            lastSelectedItem = item.id
        }
    }

    func selectAll() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedItems = Set(items.map { $0.id })
            selectedItemID = items.first?.id
        }
    }

    func clearSelection() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedItems.removeAll()
            selectedItemID = nil
        }
    }

    func isSelected(_ item: FileSystemItem) -> Bool {
        return selectedItems.contains(item.id)
    }

    func selectRange(from startItem: FileSystemItem, to endItem: FileSystemItem) {
        guard let startIndex = items.firstIndex(where: { $0.id == startItem.id }),
              let endIndex = items.firstIndex(where: { $0.id == endItem.id }) else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            let range = startIndex <= endIndex ? startIndex...endIndex : endIndex...startIndex
            for index in range {
                selectedItems.insert(items[index].id)
            }
            selectedItemID = endItem.id
            lastSelectedItem = endItem.id
        }
    }

    // MARK: - Item Actions

    func openItem(_ item: FileSystemItem, openInNewWindow: Bool = false) {
        if item.type == .folder {
            // Always navigate in current window
            navigate(to: item.path)
        } else {
            // Open file with default application
            NSWorkspace.shared.open(item.path)
        }
    }

    // MARK: - View Mode

    func toggleViewMode() {
        viewMode.mode = viewMode.mode == .iconGrid ? .list : .iconGrid
    }

    func setViewMode(_ mode: ViewMode.DisplayMode) {
        viewMode.mode = mode
    }

    func setSortOption(_ sortBy: ViewMode.SortOption) {
        viewMode.sortBy = sortBy
        items = sortItems(items)
    }

    func toggleSortOrder() {
        viewMode.sortOrder = viewMode.sortOrder == .ascending ? .descending : .ascending
        items = sortItems(items)
    }

    // MARK: - Sorting

    private func sortItems(_ items: [FileSystemItem]) -> [FileSystemItem] {
        var sorted = items

        // Sort by selected option
        switch viewMode.sortBy {
        case .name:
            sorted.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateModified:
            sorted.sort { $0.modifiedAt < $1.modifiedAt }
        case .size:
            sorted.sort { $0.size < $1.size }
        case .type:
            sorted.sort { $0.type.rawValue < $1.type.rawValue }
        }

        // Apply sort order
        if viewMode.sortOrder == .descending {
            sorted.reverse()
        }

        return sorted
    }

    // MARK: - Refresh

    func refresh() {
        Task {
            await loadContents()
        }
    }

    // MARK: - Keyboard Navigation

    func selectNextItem() {
        guard !items.isEmpty else { return }

        if let firstSelected = selectedItems.first,
           let currentIndex = items.firstIndex(where: { $0.id == firstSelected }) {
            let nextIndex = min(currentIndex + 1, items.count - 1)
            clearSelection()
            selectedItems.insert(items[nextIndex].id)
        } else {
            // No selection, select first item
            selectedItems.insert(items[0].id)
        }
    }

    func selectPreviousItem() {
        guard !items.isEmpty else { return }

        if let firstSelected = selectedItems.first,
           let currentIndex = items.firstIndex(where: { $0.id == firstSelected }) {
            let prevIndex = max(currentIndex - 1, 0)
            clearSelection()
            selectedItems.insert(items[prevIndex].id)
        } else {
            // No selection, select first item
            selectedItems.insert(items[0].id)
        }
    }

    func selectItemBelow(columnsPerRow: Int) {
        guard !items.isEmpty else { return }

        if let firstSelected = selectedItems.first,
           let currentIndex = items.firstIndex(where: { $0.id == firstSelected }) {
            let nextIndex = min(currentIndex + columnsPerRow, items.count - 1)
            clearSelection()
            selectedItems.insert(items[nextIndex].id)
        } else {
            // No selection, select first item
            selectedItems.insert(items[0].id)
        }
    }

    func selectItemAbove(columnsPerRow: Int) {
        guard !items.isEmpty else { return }

        if let firstSelected = selectedItems.first,
           let currentIndex = items.firstIndex(where: { $0.id == firstSelected }) {
            let prevIndex = max(currentIndex - columnsPerRow, 0)
            clearSelection()
            selectedItems.insert(items[prevIndex].id)
        } else {
            // No selection, select first item
            selectedItems.insert(items[0].id)
        }
    }

    func openSelectedItem() {
        guard let firstSelected = selectedItems.first,
              let item = items.first(where: { $0.id == firstSelected }) else {
            return
        }
        openItem(item)
    }

    func navigateIntoSelectedFolder() {
        guard let firstSelected = selectedItems.first,
              let item = items.first(where: { $0.id == firstSelected }) else {
            // No selection, navigate into first folder
            if let firstFolder = items.first(where: { $0.type == .folder }) {
                navigate(to: firstFolder.path)
            }
            return
        }

        if item.type == .folder {
            navigate(to: item.path)
        }
    }

    // MARK: - File Operations

    func createNewFolder(named name: String, autoRename: Bool = false) {
        // Start accessing the directory with security-scoped resource
        let accessing = currentPath.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                currentPath.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try fileSystemService.createFolder(at: currentPath, named: name)

            if autoRename {
                // Refresh to get the new folder, then start renaming it
                Task {
                    await loadContents()
                    // Find the newly created folder
                    if let newFolder = items.first(where: { $0.name == name && $0.type == .folder }) {
                        startRenaming(newFolder)
                    }
                }
            } else {
                refresh()
            }
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }

    func renameItem(_ item: FileSystemItem, to newName: String) {
        let newPath = item.path.deletingLastPathComponent().appendingPathComponent(newName)

        do {
            try FileManager.default.moveItem(at: item.path, to: newPath)
            refresh()
        } catch {
            errorMessage = "Failed to rename item: \(error.localizedDescription)"
        }
    }

    func startRenaming(_ item: FileSystemItem) {
        renamingItem = item.id
        renameText = item.name
    }

    func commitRename() {
        guard let itemId = renamingItem,
              let item = items.first(where: { $0.id == itemId }),
              !renameText.isEmpty,
              renameText != item.name else {
            cancelRename()
            return
        }

        renameItem(item, to: renameText)
        cancelRename()
    }

    func cancelRename() {
        renamingItem = nil
        renameText = ""
    }

    func deleteSelectedItems() {
        let selectedItemsList = items.filter { selectedItems.contains($0.id) }

        guard !selectedItemsList.isEmpty else { return }

        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Move to Trash"

        let itemCount = selectedItemsList.count
        if itemCount == 1 {
            alert.informativeText = "Are you sure you want to move \"\(selectedItemsList[0].name)\" to the trash?"
        } else {
            alert.informativeText = "Are you sure you want to move \(itemCount) items to the trash?"
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")

        // Set default button to "No" for safety
        alert.buttons[1].keyEquivalent = "\r"  // Enter key confirms "No"
        alert.buttons[0].keyEquivalent = ""     // Remove default from "Yes"

        let response = alert.runModal()

        // Only delete if user clicked "Yes" (first button)
        guard response == .alertFirstButtonReturn else {
            return
        }

        var sourceURLs: [URL] = []
        var trashURLs: [URL] = []

        for item in selectedItemsList {
            do {
                var trashNSURL: NSURL?
                try FileManager.default.trashItem(at: item.path, resultingItemURL: &trashNSURL)
                sourceURLs.append(item.path)
                trashURLs.append(trashNSURL as URL? ?? item.path)
            } catch {
                errorMessage = "Failed to delete item: \(error.localizedDescription)"
            }
        }

        if !sourceURLs.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: .trash, sourceURLs: sourceURLs, destinationURLs: trashURLs
            ))
        }

        selectedItems.removeAll()
        refresh()
    }

    // MARK: - Tag Filter Mode

    func showFilesWithTag(_ color: ColorTag.TagColor) {
        let sidebarManager = SidebarManager.shared
        tagFilterMode = color

        // Get all URLs with this color from sidebarManager.colorTags
        let taggedURLs = sidebarManager.colorTags
            .filter { $0.value.color == color }
            .map { $0.key }

        // Create FileSystemItems for those URLs
        tagFilteredItems = taggedURLs.compactMap { url in
            // Check if file/folder still exists
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            do {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let modifiedAt = resourceValues.contentModificationDate ?? Date()
                let size = Int64(resourceValues.fileSize ?? 0)
                let isSymlink = resourceValues.isSymbolicLink ?? false

                return FileSystemItem(
                    path: url,
                    name: url.lastPathComponent,
                    type: isDirectory ? .folder : .file,
                    size: size,
                    modifiedAt: modifiedAt,
                    isSymlink: isSymlink
                )
            } catch {
                return nil
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Clear selection
        selectedItems.removeAll()
        selectedItemID = nil
    }

    func exitTagFilterMode() {
        tagFilterMode = nil
        tagFilteredItems = []
        selectedItems.removeAll()
        selectedItemID = nil
    }

    // MARK: - Deinitialization

    deinit {
        fileWatcher.stopWatching()
    }
}
