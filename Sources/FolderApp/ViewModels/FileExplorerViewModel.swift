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
    /// True only when the last directory read failed because macOS denied
    /// access. Other failures (an ejected drive, offline share, etc.) must
    /// not turn into another permission prompt.
    @Published private(set) var requiresPermission = false
    @Published var viewMode: ViewMode = .default
    var selectedItemID: UUID? // Derived selection detail; selectedItems drives UI
    @Published var selectedItems: Set<UUID> = [] // Multi-selection support
    var lastSelectedItem: UUID? // Interaction anchor; does not drive rendering
    @Published var folderSizes: [URL: Int64] = [:] // Cache folder sizes
    @Published var renamingItem: UUID? // Track which item is being renamed
    @Published var renameText: String = "" // Current text in rename field
    @Published var isProcessing = false // Background file operation in progress

    // Tag filter mode (Finder-like color tag view)
    @Published var tagFilterMode: ColorTag.TagColor? = nil
    @Published var tagFilteredItems: [FileSystemItem] = []

    // Navigation history
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var navigationHistory: NavigationHistory

    // Services
    private let fileSystemService = FileSystemService.shared
    private let settingsManager = SettingsManager.shared
    private let fileWatcher = FileSystemWatcher()
    private var loadGeneration = 0

    // Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(initialPath: URL? = nil) {
        let startingPath: URL

        // Start at home directory or last opened folder
        if let path = initialPath {
            // Validation happens with the directory read on the worker. A
            // synchronous metadata probe here stalls window construction on
            // cloud, network and sleeping external volumes.
            startingPath = path
        } else if let path = settingsManager.settings.lastOpenedFolder {
            startingPath = path
        } else {
            startingPath = fileSystemService.homeDirectory()
        }

        self.currentPath = startingPath
        self.navigationHistory = NavigationHistory(initialURL: startingPath)
        self.viewMode.mode = settingsManager.settings.defaultViewMode == .iconGrid ? .iconGrid : .list
        self.viewMode.iconSize = settingsManager.settings.iconSize
        updateNavigationState()

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
                    await self.loadContents(showLoadingIndicator: false)
                }

                // Reset the flag
                self.fileWatcher.resetChangeFlag()
            }
            .store(in: &cancellables)
    }

    // MARK: - Directory Loading

    func loadContents(showLoadingIndicator: Bool = true) async {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPath = currentPath
        if showLoadingIndicator {
            isLoading = true
        }
        errorMessage = nil
        requiresPermission = false

        do {
            // Resolve any stored security-scoped bookmark for the current
            // folder and start/stop access around the directory read.
            let access = PermissionCenter.shared.beginAccess(to: requestedPath)
            defer { access?.stop() }
            let readablePath = access?.url ?? requestedPath
            let showHidden = settingsManager.settings.showHiddenFiles
            let service = fileSystemService
            let contents = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try service.contentsOfDirectory(at: readablePath, showHidden: showHidden)
            }.value
            guard generation == loadGeneration, requestedPath == currentPath else { return }

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

            // Preserve identity for unchanged paths. FileSystemItem's normal
            // initializer creates a UUID, which made every watcher refresh
            // look like a completely new directory to SwiftUI.
            let existingIDs = Dictionary(
                uniqueKeysWithValues: self.items.map { ($0.path.standardizedFileURL, $0.id) }
            )
            let identityStableContents = contents.map { item in
                guard let stableID = existingIDs[item.path.standardizedFileURL] else { return item }
                return item.preservingIdentity(stableID)
            }

            // Sort based on current view mode and publish only a real change.
            let sortedContents = sortItems(identityStableContents)
            if self.items != sortedContents {
                self.items = sortedContents
            }
            self.isLoading = false
            self.requiresPermission = false

            // Save as last opened folder
            if settingsManager.settings.lastOpenedFolder != currentPath {
                settingsManager.settings.lastOpenedFolder = currentPath
            }

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
            }

            // Start watching the current directory for changes
            fileWatcher.startWatching(url: requestedPath)
            QuickLookManager.shared.prewarmPreviewCache(for: self.items, in: requestedPath)
        } catch {
            guard generation == loadGeneration else { return }
            self.errorMessage = "Failed to load directory: \(error.localizedDescription)"
            self.requiresPermission = Self.isPermissionDenied(error)
            self.items = []
            self.isLoading = false

            // Stop watching on error
            fileWatcher.stopWatching()
        }
    }

    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }

    /// Folder sizes are intentionally opt-in. Recursively sizing every visible
    /// directory made opening Home, cloud folders and removable drives stall.
    func calculateFolderSize(for folder: FileSystemItem) {
        guard folder.type == .folder, folderSizes[folder.path] == nil else { return }
        let path = folder.path
        Task { [weak self] in
            do {
                let size = try await self?.fileSystemService.calculateFolderSize(at: path)
                guard let self, let size else { return }
                self.folderSizes[path] = size
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = "Could not calculate the size of \(folder.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        guard url.standardizedFileURL != currentPath.standardizedFileURL else { return }

        // Exit tag filter mode when navigating to any folder
        if tagFilterMode != nil {
            exitTagFilterMode()
        }

        navigationHistory.navigate(to: url)

        // Update navigation state
        updateNavigationState()

        prepareForNavigation(to: url)

        Task {
            await loadContents(showLoadingIndicator: false)
        }
    }

    func navigateToParent() {
        guard let parent = fileSystemService.parentDirectory(of: currentPath) else {
            return
        }
        navigate(to: parent)
    }

    func navigateBack() {
        guard let destination = navigationHistory.goBack() else { return }
        prepareForNavigation(to: destination)

        Task {
            await loadContents(showLoadingIndicator: false)
        }

        updateNavigationState()
    }

    func navigateForward() {
        guard let destination = navigationHistory.goForward() else { return }
        prepareForNavigation(to: destination)

        Task {
            await loadContents(showLoadingIndicator: false)
        }

        updateNavigationState()
    }

    /// A mounted volume can disappear while Folder is displaying a folder on
    /// it. Go back to the last location outside that volume instead of leaving
    /// a stale, non-existent directory as the current view.
    func navigateAwayFromUnmountedVolume(_ volumeRoot: URL) {
        let normalizedRoot = volumeRoot.standardizedFileURL.path
        let current = currentPath.standardizedFileURL.path
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"

        guard current == normalizedRoot || current.hasPrefix(rootPrefix) else { return }

        let fallback = navigationHistory.lastLocationOutsideVolume(volumeRoot)
            ?? fileSystemService.homeDirectory()
        navigate(to: fallback)
    }

    private func updateNavigationState() {
        canGoBack = navigationHistory.canGoBack
        canGoForward = navigationHistory.canGoForward
    }

    /// Makes path changes visually atomic: the old directory is removed and
    /// any in-flight load invalidated before SwiftUI can render the new path.
    private func prepareForNavigation(to url: URL) {
        loadGeneration += 1
        isLoading = true
        errorMessage = nil
        requiresPermission = false
        items = []
        selectedItems.removeAll()
        selectedItemID = nil
        lastSelectedItem = nil
        currentPath = url
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

    func selectOnly(_ item: FileSystemItem) {
        QuickLookManager.shared.prioritizePreview(for: item)
        if selectedItems == [item.id] {
            selectedItemID = item.id
            lastSelectedItem = item.id
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedItems = [item.id]
            selectedItemID = item.id
            lastSelectedItem = item.id
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

        if let currentID = selectedItemID ?? lastSelectedItem,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = min(currentIndex + 1, items.count - 1)
            selectOnly(items[nextIndex])
        } else {
            // No selection, select first item
            selectOnly(items[0])
        }
    }

    func selectPreviousItem() {
        guard !items.isEmpty else { return }

        if let currentID = selectedItemID ?? lastSelectedItem,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }) {
            let prevIndex = max(currentIndex - 1, 0)
            selectOnly(items[prevIndex])
        } else {
            // No selection, select first item
            selectOnly(items[0])
        }
    }

    func selectItemBelow(columnsPerRow: Int) {
        guard !items.isEmpty else { return }

        if let currentID = selectedItemID ?? lastSelectedItem,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = min(currentIndex + columnsPerRow, items.count - 1)
            selectOnly(items[nextIndex])
        } else {
            // No selection, select first item
            selectOnly(items[0])
        }
    }

    func selectItemAbove(columnsPerRow: Int) {
        guard !items.isEmpty else { return }

        if let currentID = selectedItemID ?? lastSelectedItem,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }) {
            let prevIndex = max(currentIndex - columnsPerRow, 0)
            selectOnly(items[prevIndex])
        } else {
            // No selection, select first item
            selectOnly(items[0])
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
        FileOperationCoordinator.shared.createFolder(in: currentPath, named: name) { [weak self] newURL in
            guard autoRename, let self, let newURL else { return }
            Task {
                await self.loadContents()
                if let newFolder = self.items.first(where: { $0.path.standardizedFileURL == newURL.standardizedFileURL }) {
                    self.startRenaming(newFolder)
                }
            }
        }
    }

    func renameItem(_ item: FileSystemItem, to newName: String) {
        FileOperationCoordinator.shared.rename(item.path, to: newName)
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

        FileOperationCoordinator.shared.moveToTrash(selectedItemsList.map(\.path))
        selectedItems.removeAll()
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
