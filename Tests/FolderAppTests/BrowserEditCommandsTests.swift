import AppKit
import Combine
import Testing
@testable import FolderApp

@Suite(.serialized) @MainActor struct BrowserActionTests {

    @Test @MainActor func editMenuTargetsBrowserCommandsAndIncludesUndoRedo() {
        let delegate = AppDelegate()
        let menu = delegate.buildMenu()
        let edit = menu.items.compactMap(\.submenu).first { $0.title == "Edit" }

        #expect(edit?.item(withTitle: "Undo")?.action == #selector(AppDelegate.editUndo(_:)))
        #expect(edit?.item(withTitle: "Redo")?.action == #selector(AppDelegate.editRedo(_:)))
        #expect(edit?.item(withTitle: "Redo")?.keyEquivalentModifierMask == [.command, .shift])
        #expect(edit?.item(withTitle: "Cut")?.action == #selector(AppDelegate.editCut(_:)))
        #expect(edit?.item(withTitle: "Copy")?.action == #selector(AppDelegate.editCopy(_:)))
        #expect(edit?.item(withTitle: "Paste")?.action == #selector(AppDelegate.editPaste(_:)))
        #expect(edit?.item(withTitle: "Select All")?.action == #selector(AppDelegate.editSelectAll(_:)))
        #expect(edit?.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === delegate } == true)
    }

    @Test func settingsMenuKeepsLastOpenedTabAndHasNoSeparatePermissionsEntry() {
        let delegate = AppDelegate()
        let appMenu = delegate.buildMenu().items.first?.submenu
        #expect(appMenu?.item(withTitle: "Settings...")?.action == #selector(AppDelegate.showSettings))
        #expect(appMenu?.item(withTitle: "Permissions...") == nil)

        let suite = "SettingsNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)
        #expect(navigation.selectedTab == .general)
        navigation.selectedTab = .permissions
        #expect(SettingsNavigation(defaults: defaults).selectedTab == .permissions)
    }

    @Test @MainActor func browserEditCommandsUseVisibleSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserEditCommandsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("alpha.txt"))

        let commands = BrowserEditCommands()
        let browser = FileExplorerViewModel(initialPath: root)
        let search = SearchViewModel()
        // The initializer starts its own load, which supersedes this one.
        // Wait for whichever read publishes the directory first.
        await browser.loadContents()
        let loadDeadline = Date().addingTimeInterval(3)
        while browser.items.isEmpty && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        commands.activate(browser: browser, search: search)

        #expect(!commands.canPerform(.copy))
        #expect(commands.canPerform(.selectAll))
        commands.perform(.selectAll)
        #expect(browser.selectedItems.count == 1)
        #expect(commands.canPerform(.copy))

        search.isSearchActive = true
        search.searchQuery = "missing"
        search.searchResults = []
        #expect(!commands.canPerform(.copy))
        #expect(!commands.canPerform(.selectAll))

        commands.deactivate(browser: browser)
        #expect(!commands.canPerform(.copy))
    }

    @Test @MainActor func undoRedoAvailabilityFollowsFileHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserEditHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("before.txt")
        let destination = root.appendingPathComponent("after.txt")
        try Data("content".utf8).write(to: destination)

        let previousSetting = SettingsManager.shared.settings.undoRedoEnabled
        SettingsManager.shared.settings.undoRedoEnabled = true
        defer { SettingsManager.shared.settings.undoRedoEnabled = previousSetting }

        let history = ActionHistoryManager()
        let commands = BrowserEditCommands(history: history)
        let browser = FileExplorerViewModel(initialPath: root)
        let search = SearchViewModel()
        commands.activate(browser: browser, search: search)

        #expect(!commands.canPerform(.undo))
        #expect(!commands.canPerform(.redo))
        history.record(.init(type: .move, sourceURLs: [source], destinationURLs: [destination]))
        #expect(commands.canPerform(.undo))
        commands.perform(.undo)
        #expect(!commands.canPerform(.undo))
        try await waitForHistoryOperation(history)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(commands.canPerform(.redo))

        commands.perform(.redo)
        try await waitForHistoryOperation(history)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(commands.canPerform(.undo))
        #expect(!commands.canPerform(.redo))
    }

    @Test func newFolderActionCreatesUniqueFolderAndStartsRename() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFolderActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Untitled Folder", isDirectory: true),
            withIntermediateDirectories: false
        )

        let model = FileExplorerViewModel(initialPath: root)
        await model.loadContents()
        model.createNewFolder(named: "Untitled Folder", autoRename: true)

        let deadline = Date().addingTimeInterval(3)
        while model.renamingItem == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let newFolder = try #require(model.items.first { $0.name == "Untitled Folder (2)" })
        #expect(FileManager.default.fileExists(atPath: newFolder.path.path))
        #expect(model.renamingItem == newFolder.id)
        #expect(model.renameText == "Untitled Folder (2)")
    }

    @Test func inlineRenameUpdatesSelectionAndReportsInvalidName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InlineRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content".utf8).write(to: root.appendingPathComponent("before.txt"))

        let model = FileExplorerViewModel(initialPath: root)
        await model.loadContents()
        let loadDeadline = Date().addingTimeInterval(3)
        while model.items.first(where: { $0.name == "before.txt" }) == nil && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let original = try #require(model.items.first { $0.name == "before.txt" })
        model.startRenaming(original)
        #expect(model.renamingItem == original.id)
        model.renameText = "after.txt"
        model.commitRename()

        let coordinator = FileOperationCoordinator.shared
        let deadline = Date().addingTimeInterval(3)
        while (model.items.first(where: { $0.name == "after.txt" }) == nil ||
               model.selectedItems.isEmpty) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let renamed = try #require(model.items.first { $0.name == "after.txt" })
        #expect(model.selectedItems.contains(renamed.id))

        model.startRenaming(renamed)
        model.renameText = ""
        model.commitRename()
        while coordinator.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(coordinator.presentedReport?.report.failed.count == 1)
    }

    @Test func navigationWithoutSelectionOpensFirstFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("First Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = FileExplorerViewModel(initialPath: root)
        await model.loadContents()
        let loadDeadline = Date().addingTimeInterval(3)
        while model.items.first(where: { $0.type == .folder }) == nil && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        model.navigateIntoSelectedFolder()
        #expect(model.currentPath.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }

    @Test func explicitRefreshPublishesCompletionEvenForEmptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefreshFeedbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileExplorerViewModel(initialPath: root)
        await model.loadContents()
        model.refresh()
        #expect(model.isRefreshing)
        let deadline = Date().addingTimeInterval(3)
        while model.isRefreshing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!model.isRefreshing)
        #expect(model.lastRefreshDate != nil)
    }

    @Test func coordinatorPublishesProgressWithoutSuccessDialog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["one.txt", "two.txt"].map { root.appendingPathComponent($0) }
        for source in sources { try Data("content".utf8).write(to: source) }

        let coordinator = FileOperationCoordinator(service: FileOperationService())
        var updates: [FileOperationProgress] = []
        let observation = coordinator.$progress.compactMap { $0 }.sink { updates.append($0) }
        defer { observation.cancel() }

        coordinator.duplicate(sources)
        let deadline = Date().addingTimeInterval(3)
        while coordinator.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(!coordinator.isProcessing)
        #expect(updates.contains { $0.total == 2 && $0.currentItem != nil })
        #expect(coordinator.presentedReport == nil)
    }

    @Test func coordinatorCancellationDoesNotShowASuccessDialog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["one.txt", "two.txt"].map { root.appendingPathComponent($0) }
        for source in sources { try Data("content".utf8).write(to: source) }

        let coordinator = FileOperationCoordinator(service: FileOperationService())
        coordinator.duplicate(sources)
        coordinator.cancel()
        #expect(coordinator.isCancellationRequested)

        let deadline = Date().addingTimeInterval(3)
        while coordinator.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(!coordinator.isProcessing)
        #expect(!coordinator.isCancellationRequested)
        #expect(coordinator.presentedReport == nil)
    }

    @MainActor private func waitForHistoryOperation(_ history: ActionHistoryManager) async throws {
        let deadline = Date().addingTimeInterval(3)
        while history.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!history.isProcessing)
    }
}
