import Foundation
import Testing
@testable import FolderApp

@Test func tabsAreDisabledByDefault() {
    #expect(AppSettings.default.tabsEnabled == false)
}

@Test @MainActor func externalFoldersUseTheActiveTabThenCreateAdditionalTabs() {
    let first = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderTabTests-\(UUID().uuidString)", isDirectory: true)
    let second = first.appendingPathComponent("Second", isDirectory: true)
    try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: first) }

    let manager = FolderTabManager(initialPath: first)
    let originalTabID = manager.selectedTabID
    manager.openFolders([first, second])

    #expect(manager.tabs.count == 2)
    #expect(manager.selectedTabID == originalTabID)
    #expect(manager.tabs[0].viewModel.currentPath.standardizedFileURL == first.standardizedFileURL)
    #expect(manager.tabs[1].viewModel.currentPath.standardizedFileURL == second.standardizedFileURL)
}

@Test @MainActor func closingTheLastTabRequestsWindowClosure() {
    let manager = FolderTabManager(initialPath: FileManager.default.temporaryDirectory)
    #expect(manager.closeSelectedTab())

    manager.createTab()
    #expect(!manager.closeSelectedTab())
    #expect(manager.tabs.count == 1)
}

@Test @MainActor func numberedTabSelectionUsesOneBasedIndices() {
    let manager = FolderTabManager(initialPath: FileManager.default.temporaryDirectory)
    manager.createTab()
    let secondTabID = manager.selectedTabID

    #expect(manager.selectTab(number: 1))
    #expect(manager.selectedTabID != secondTabID)
    #expect(manager.selectTab(number: 2))
    #expect(manager.selectedTabID == secondTabID)
    #expect(!manager.selectTab(number: 3))
}
