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
    @Published var errorMessage: String?
    @Published private(set) var searchErrors: [String] = []

    // Selection state for search results
    @Published var selectedItems: Set<UUID> = []
    var lastSelectedItem: UUID?

    private var searchTask: Task<Void, Never>?
    private let fileSystemService = FileSystemService.shared

    private let debounceDelay: TimeInterval = 0.15  // 150ms
    private var searchGeneration = 0

    // MARK: - Search

    func search(in folder: URL, depth: Int = 2) {
        // Cancel previous search
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchQuery

        guard !searchQuery.isEmpty else {
            searchResults = []
            isSearching = false
            errorMessage = nil
            searchErrors = []
            return
        }

        isSearching = true
        errorMessage = nil
        searchErrors = []
        let delay = debounceDelay

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                await self.performSearch(in: folder, query: query, depth: depth, generation: generation)
            } catch {
                return
            }
        }
    }

    private func performSearch(in folder: URL, query: String, depth: Int, generation: Int) async {
        let access = PermissionCenter.shared.beginAccess(to: folder)
        let readableFolder = access?.url ?? folder
        let service = fileSystemService
        let output = await Task.detached(priority: .userInitiated) {
            Self.searchRecursively(
                in: readableFolder,
                query: query,
                currentDepth: 0,
                maxDepth: depth,
                service: service
            )
        }.value
        access?.stop()

        guard generation == searchGeneration, !Task.isCancelled else { return }
        searchResults = output.items.sorted()
        searchErrors = output.errors
        errorMessage = output.errors.first
        isSearching = false
    }

    private nonisolated static func searchRecursively(
        in folder: URL,
        query: String,
        currentDepth: Int,
        maxDepth: Int,
        service: FileSystemService
    ) -> (items: [FileSystemItem], errors: [String]) {
        // Check if task was cancelled
        if Task.isCancelled {
            return ([], [])
        }

        // Stop if we've reached max depth
        if currentDepth > maxDepth {
            return ([], [])
        }

        var results: [FileSystemItem] = []
        var errors: [String] = []
        do {
            let contents = try service.contentsOfDirectory(at: folder, showHidden: false)

            for item in contents {
                // Check if task was cancelled
                if Task.isCancelled {
                    return (results, errors)
                }

                // Check if filename matches (case-insensitive substring match)
                if item.name.localizedCaseInsensitiveContains(query) {
                    results.append(item)
                }

                // Recursively search in subdirectories
                if item.type == .folder {
                    let nested = searchRecursively(
                        in: item.path,
                        query: query,
                        currentDepth: currentDepth + 1,
                        maxDepth: maxDepth,
                        service: service
                    )
                    results.append(contentsOf: nested.items)
                    errors.append(contentsOf: nested.errors.prefix(max(0, 20 - errors.count)))
                }
            }
        } catch {
            errors.append("Could not search \(folder.path): \(error.localizedDescription)")
        }
        return (results, errors)
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        isSearching = false
        isSearchActive = false
        selectedItems = []
        lastSelectedItem = nil
        errorMessage = nil
        searchErrors = []
        searchTask?.cancel()
        searchGeneration += 1
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

    func selectOnly(_ item: FileSystemItem) {
        QuickLookManager.shared.prioritizePreview(for: item)
        if selectedItems == [item.id] {
            lastSelectedItem = item.id
            return
        }

        selectedItems = [item.id]
        lastSelectedItem = item.id
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
        FileOperationCoordinator.shared.moveToTrash(itemsToDelete.map(\.path))
        selectedItems.removeAll()
        lastSelectedItem = nil
    }
}
