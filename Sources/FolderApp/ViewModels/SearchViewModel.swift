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

    /// Die Suche ist geparkt: Der Nutzer hat einen Treffer geöffnet und schaut
    /// gerade in einen Ordner. Begriff und Trefferliste bleiben stehen, bis er
    /// zurückkommt.
    @Published private(set) var isParked = false

    /// Der Ordner, in dem gesucht wurde. Kehrt der Nutzer hierher zurück, ist
    /// die Trefferliste wieder da.
    private(set) var searchRoot: URL?

    // Selection state for search results
    @Published var selectedItems: Set<UUID> = []
    var lastSelectedItem: UUID?

    private var searchTask: Task<Void, Never>?
    private let fileSystemService = FileSystemService.shared

    /// Wartezeit, bevor getippte Zeichen eine Suche auslösen.
    ///
    /// Kurz genug, dass es nicht als Verzögerung auffällt, lang genug, dass
    /// schnelles Tippen nicht jede Zwischenstufe durchsucht.
    private let debounceDelay: TimeInterval = 0.08
    private var searchGeneration = 0

    // MARK: - Search

    func search(in folder: URL, depth: Int = 2) {
        searchRoot = folder
        isParked = false

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

    /// Sucht in Stufen und zeigt jede Stufe sofort an.
    ///
    /// Der aktuelle Ordner allein ist in etwa zwei Millisekunden durchsucht, die
    /// zweite Ebene braucht rund fünfzig, die dritte über hundert — gemessen im
    /// Benutzerordner. Wer auf das Gesamtergebnis wartet, sieht deshalb erst nach
    /// einer spürbaren Pause etwas, obwohl die naheliegenden Treffer längst
    /// feststehen.
    ///
    /// Jede Stufe umfasst die vorige, die Liste wächst also nur — nichts
    /// verschwindet wieder, und die Reihenfolge bleibt.
    private func performSearch(in folder: URL, query: String, depth: Int, generation: Int) async {
        let access = PermissionCenter.shared.beginAccess(to: folder)
        let readableFolder = access?.url ?? folder
        let service = fileSystemService

        for stufe in 0...max(depth, 0) {
            let output = await Task.detached(priority: .userInitiated) {
                Self.searchRecursively(
                    in: readableFolder,
                    query: query,
                    currentDepth: 0,
                    maxDepth: stufe,
                    service: service
                )
            }.value

            guard generation == searchGeneration, !Task.isCancelled else {
                access?.stop()
                return
            }

            searchResults = output.items.sorted()
            searchErrors = output.errors
            errorMessage = output.errors.first
        }

        access?.stop()
        guard generation == searchGeneration else { return }
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

                // In Ordner hinein — aber nicht in Pakete. Eine Fotomediathek
                // ist ein Dokument, kein Ordner voller Dateien; Finder geht dort
                // ebenfalls nicht hinein.
                if item.type == .folder, !item.isPackage {
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
        isParked = false
        searchRoot = nil
    }

    // MARK: - Parken

    /// Legt die Suche beiseite, statt sie wegzuwerfen.
    ///
    /// Wer aus der Trefferliste einen Ordner öffnet, will ihn ansehen — nicht
    /// die Suche verlieren. Vorher wurde an dieser Stelle alles gelöscht, und
    /// selbst Zurück brachte die Treffer nicht wieder: man musste den Begriff
    /// neu tippen. Genau dafür sucht man aber.
    func park() {
        guard isSearchActive, !searchResults.isEmpty else { return }
        isSearchActive = false
        isParked = true
        selectedItems = []
        lastSelectedItem = nil
    }

    /// Holt die geparkte Suche zurück, sobald der Nutzer wieder in dem Ordner
    /// steht, in dem er gesucht hat.
    @discardableResult
    func resumeIfParked(at path: URL) -> Bool {
        guard isParked,
              let searchRoot,
              searchRoot.standardizedFileURL == path.standardizedFileURL
        else { return false }

        isParked = false
        isSearchActive = true
        return true
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

    /// Liest die Farb-Tags der Treffer neu ein.
    ///
    /// Die Treffer tragen ihren Tag aus dem Moment der Suche. Wer aus der
    /// Trefferliste heraus einen Tag setzt, soll den Punkt sofort sehen und
    /// nicht erst nach einer neuen Suche.
    func refreshTagsIfNeeded() {
        guard !searchResults.isEmpty else { return }
        searchResults = searchResults.map { treffer in
            var aktualisiert = treffer
            aktualisiert.colorTag = FinderTagService.colorTag(for: treffer.path)
            return aktualisiert
        }
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

    // Senkrecht heisst senkrecht: eine Zeile, gleiche Spalte. Fehlt die Zeile,
    // bleibt die Auswahl stehen, statt in die Ecke zu springen — siehe die
    // gleichlautende Stelle in FileExplorerViewModel.

    func selectItemAbove(columnsPerRow: Int) {
        moveSelectionVertically(by: -max(columnsPerRow, 1))
    }

    func selectItemBelow(columnsPerRow: Int) {
        moveSelectionVertically(by: max(columnsPerRow, 1))
    }

    private func moveSelectionVertically(by offset: Int) {
        guard !searchResults.isEmpty else { return }

        guard let first = selectedItems.first,
              let idx = searchResults.firstIndex(where: { $0.id == first }) else {
            selectedItems = [searchResults[0].id]
            lastSelectedItem = searchResults[0].id
            return
        }

        let target = idx + offset
        guard searchResults.indices.contains(target) else { return }
        selectedItems = [searchResults[target].id]
        lastSelectedItem = searchResults[target].id
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
