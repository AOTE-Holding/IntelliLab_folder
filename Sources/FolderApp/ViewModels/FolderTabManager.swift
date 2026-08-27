import Foundation
import Combine

@MainActor
final class FolderTab: ObservableObject, Identifiable {
    let id = UUID()
    let viewModel: FileExplorerViewModel
    let searchViewModel: SearchViewModel
    private var viewModelChange: AnyCancellable?

    init(initialPath: URL? = nil) {
        viewModel = FileExplorerViewModel(initialPath: initialPath)
        searchViewModel = SearchViewModel()
        viewModelChange = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

@MainActor
final class FolderTabManager: ObservableObject {
    @Published private(set) var tabs: [FolderTab]
    @Published var selectedTabID: UUID

    init(initialPath: URL? = nil) {
        let initialTab = FolderTab(initialPath: initialPath)
        tabs = [initialTab]
        selectedTabID = initialTab.id
    }

    var selectedTab: FolderTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    @discardableResult
    func selectTab(number: Int) -> Bool {
        let index = number - 1
        guard tabs.indices.contains(index) else { return false }
        selectedTabID = tabs[index].id
        return true
    }

    func createTab(at path: URL? = nil, select: Bool = true) {
        let tab = FolderTab(initialPath: path ?? selectedTab?.viewModel.currentPath)
        tabs.append(tab)
        if select {
            selectedTabID = tab.id
        }
    }

    /// Uses the active tab for the first directory and creates one tab for
    /// every further directory supplied in the same macOS open event.
    func openFolders(_ urls: [URL]) {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            let normalized = url.standardizedFileURL
            if !result.contains(where: { $0.standardizedFileURL == normalized }) {
                result.append(normalized)
            }
        }
        guard let firstURL = uniqueURLs.first else { return }

        if let tab = selectedTab {
            tab.viewModel.navigate(to: firstURL)
        } else {
            createTab(at: firstURL)
        }

        for url in uniqueURLs.dropFirst() {
            createTab(at: url, select: false)
        }
    }

    /// Returns true only when the caller should close its containing window.
    func closeSelectedTab() -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return false }
        guard tabs.count > 1 else { return true }

        tabs.remove(at: index)
        selectedTabID = tabs[max(0, index - 1)].id
        return false
    }
}

extension Notification.Name {
    static let openFolders = Notification.Name("OpenFolders")
    static let createFolderTab = Notification.Name("CreateFolderTab")
    static let closeFolderTab = Notification.Name("CloseFolderTab")
}
