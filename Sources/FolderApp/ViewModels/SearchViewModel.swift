//
//  SearchViewModel.swift
//  Folder
//
//  View model for search functionality
//

import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var searchQuery: String = ""
    @Published var searchResults: [FileSystemItem] = []
    @Published var isSearching = false
    @Published var isSearchActive = false

    // Selection state for search results
    @Published var selectedItems: Set<UUID> = []
    @Published var lastSelectedItem: UUID?

    private var searchTask: Task<Void, Never>?
    private let fileSystemService = FileSystemService.shared

    // Debounce timer
    private var debounceTimer: Timer?
    private let debounceDelay: TimeInterval = 0.15  // 150ms

    // MARK: - Search

    func search(in folder: URL, depth: Int = 2) {
        // Cancel previous search
        searchTask?.cancel()
        debounceTimer?.invalidate()

        guard !searchQuery.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        // Debounce the search
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            self.searchTask = Task {
                await self.performSearch(in: folder, depth: depth)
            }
        }
    }

    private func performSearch(in folder: URL, depth: Int) async {
        var results: [FileSystemItem] = []

        // Recursive search with depth limit
        await searchRecursively(in: folder, currentDepth: 0, maxDepth: depth, results: &results)

        // Update results on main thread
        self.searchResults = results.sorted()
        self.isSearching = false
    }

    private func searchRecursively(in folder: URL, currentDepth: Int, maxDepth: Int, results: inout [FileSystemItem]) async {
        // Check if task was cancelled
        if Task.isCancelled {
            return
        }

        // Stop if we've reached max depth
        if currentDepth > maxDepth {
            return
        }

        do {
            let contents = try fileSystemService.contentsOfDirectory(at: folder, showHidden: false)

            for item in contents {
                // Check if task was cancelled
                if Task.isCancelled {
                    return
                }

                // Check if filename matches (case-insensitive substring match)
                if item.name.localizedCaseInsensitiveContains(searchQuery) {
                    results.append(item)
                }

                // Recursively search in subdirectories
                if item.type == .folder {
                    await searchRecursively(in: item.path, currentDepth: currentDepth + 1, maxDepth: maxDepth, results: &results)
                }
            }
        } catch {
            // Silently handle errors (permission denied, etc.)
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        isSearching = false
        isSearchActive = false
        selectedItems = []
        lastSelectedItem = nil
        searchTask?.cancel()
        debounceTimer?.invalidate()
    }

    func activateSearch() {
        isSearchActive = true
    }

    func deactivateSearch() {
        clearSearch()
    }

    // MARK: - Selection Methods

    func toggleSelection(for item: FileSystemItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
        lastSelectedItem = item.id
    }

    func clearSelection() {
        selectedItems = []
        lastSelectedItem = nil
    }

    func selectRange(from startItem: FileSystemItem, to endItem: FileSystemItem) {
        guard let startIndex = searchResults.firstIndex(where: { $0.id == startItem.id }),
              let endIndex = searchResults.firstIndex(where: { $0.id == endItem.id }) else {
            return
        }

        let range = startIndex < endIndex ? startIndex...endIndex : endIndex...startIndex
        for index in range {
            selectedItems.insert(searchResults[index].id)
        }
        lastSelectedItem = endItem.id
    }

    func isSelected(_ item: FileSystemItem) -> Bool {
        selectedItems.contains(item.id)
    }

    // MARK: - Navigation Methods

    func selectNextItem() {
        guard !searchResults.isEmpty else { return }
        if let first = selectedItems.first,
           let idx = searchResults.firstIndex(where: { $0.id == first }) {
            let next = min(idx + 1, searchResults.count - 1)
            selectedItems = [searchResults[next].id]
            lastSelectedItem = searchResults[next].id
        } else {
            selectedItems = [searchResults[0].id]
            lastSelectedItem = searchResults[0].id
        }
    }

    func selectPreviousItem() {
        guard !searchResults.isEmpty else { return }
        if let first = selectedItems.first,
           let idx = searchResults.firstIndex(where: { $0.id == first }) {
            let prev = max(idx - 1, 0)
            selectedItems = [searchResults[prev].id]
            lastSelectedItem = searchResults[prev].id
        } else {
            selectedItems = [searchResults[0].id]
            lastSelectedItem = searchResults[0].id
        }
    }

    func selectItemAbove(columnsPerRow: Int) {
        guard !searchResults.isEmpty else { return }
        if let first = selectedItems.first,
           let idx = searchResults.firstIndex(where: { $0.id == first }) {
            let prev = max(idx - columnsPerRow, 0)
            selectedItems = [searchResults[prev].id]
            lastSelectedItem = searchResults[prev].id
        } else {
            selectedItems = [searchResults[0].id]
            lastSelectedItem = searchResults[0].id
        }
    }

    func selectItemBelow(columnsPerRow: Int) {
        guard !searchResults.isEmpty else { return }
        if let first = selectedItems.first,
           let idx = searchResults.firstIndex(where: { $0.id == first }) {
            let next = min(idx + columnsPerRow, searchResults.count - 1)
            selectedItems = [searchResults[next].id]
            lastSelectedItem = searchResults[next].id
        } else {
            selectedItems = [searchResults[0].id]
            lastSelectedItem = searchResults[0].id
        }
    }

    func selectAll() {
        selectedItems = Set(searchResults.map { $0.id })
    }

    func openSelectedItem(using viewModel: FileExplorerViewModel) {
        guard let firstID = selectedItems.first,
              let item = searchResults.first(where: { $0.id == firstID }) else { return }
        viewModel.openItem(item)
    }

    // MARK: - File Operations

    func deleteSelectedItems() {
        let itemsToDelete = searchResults.filter { selectedItems.contains($0.id) }
        guard !itemsToDelete.isEmpty else { return }

        var sourceURLs: [URL] = []
        var trashURLs: [URL] = []

        for item in itemsToDelete {
            var trashNSURL: NSURL?
            try? FileManager.default.trashItem(at: item.path, resultingItemURL: &trashNSURL)
            sourceURLs.append(item.path)
            if let trashURL = trashNSURL as URL? {
                trashURLs.append(trashURL)
            }
        }

        if sourceURLs.count == trashURLs.count && !sourceURLs.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: .trash, sourceURLs: sourceURLs, destinationURLs: trashURLs
            ))
        }

        // Remove trashed items from search results
        let trashedPaths = Set(sourceURLs)
        searchResults.removeAll { trashedPaths.contains($0.path) }
        selectedItems.removeAll()
        lastSelectedItem = nil
    }
}
