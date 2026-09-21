import AppKit

enum BrowserEditCommand {
    case cut
    case copy
    case paste
    case selectAll
    case undo
    case redo
}

/// The browser currently visible in the main window owns file edit commands.
/// Menu items and local shortcuts both use this context.
@MainActor
final class BrowserEditCommands {
    static let shared = BrowserEditCommands()

    private weak var browser: FileExplorerViewModel?
    private weak var search: SearchViewModel?
    private let clipboard: ClipboardManager
    private let operations: FileOperationCoordinator
    private let history: ActionHistoryManager

    init(
        clipboard: ClipboardManager? = nil,
        operations: FileOperationCoordinator? = nil,
        history: ActionHistoryManager? = nil
    ) {
        self.clipboard = clipboard ?? .shared
        self.operations = operations ?? .shared
        self.history = history ?? .shared
    }

    func activate(browser: FileExplorerViewModel, search: SearchViewModel) {
        self.browser = browser
        self.search = search
    }

    func deactivate(browser: FileExplorerViewModel) {
        guard self.browser === browser else { return }
        self.browser = nil
        search = nil
    }

    func canPerform(_ command: BrowserEditCommand) -> Bool {
        guard let browser, let search else { return false }
        switch command {
        case .copy:
            return !selectedFiles(browser: browser, search: search).isEmpty
        case .cut:
            return FileOperationPolicy.isEnabled && !selectedFiles(browser: browser, search: search).isEmpty
        case .paste:
            return FileOperationPolicy.isEnabled && !operations.isProcessing
                && clipboard.hasClipboardContent() && FileDropValidation.canWrite(to: browser.currentPath)
        case .selectAll:
            return !visibleFiles(browser: browser, search: search).isEmpty
        case .undo:
            return FileOperationPolicy.isEnabled && history.canUndo && !history.isProcessing
                && !operations.isProcessing && SettingsManager.shared.settings.undoRedoEnabled
        case .redo:
            return FileOperationPolicy.isEnabled && history.canRedo && !history.isProcessing
                && !operations.isProcessing && SettingsManager.shared.settings.undoRedoEnabled
        }
    }

    func perform(_ command: BrowserEditCommand) {
        guard canPerform(command), let browser, let search else { return }
        switch command {
        case .copy:
            clipboard.copy(items: selectedFiles(browser: browser, search: search))
        case .cut:
            clipboard.cut(items: selectedFiles(browser: browser, search: search))
        case .paste:
            operations.paste(to: browser.currentPath)
        case .selectAll:
            if browser.tagFilterMode != nil {
                browser.selectedItems = Set(browser.tagFilteredItems.map(\.id))
                browser.selectedItemID = browser.tagFilteredItems.first?.id
            } else if search.isSearchActive && !search.searchQuery.isEmpty {
                search.selectAll()
            } else {
                browser.selectAll()
            }
        case .undo:
            history.undo()
        case .redo:
            history.redo()
        }
    }

    private func visibleFiles(browser: FileExplorerViewModel, search: SearchViewModel) -> [FileSystemItem] {
        if browser.tagFilterMode != nil { return browser.tagFilteredItems }
        if search.isSearchActive && !search.searchQuery.isEmpty { return search.searchResults }
        return browser.items
    }

    private func selectedFiles(browser: FileExplorerViewModel, search: SearchViewModel) -> [FileSystemItem] {
        if browser.tagFilterMode != nil {
            return browser.tagFilteredItems.filter { browser.selectedItems.contains($0.id) }
        }
        if search.isSearchActive && !search.searchQuery.isEmpty {
            return search.searchResults.filter { search.selectedItems.contains($0.id) }
        }
        return browser.items.filter { browser.selectedItems.contains($0.id) }
    }
}
