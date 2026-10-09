import Foundation
import Testing
@testable import FolderApp

@Suite(.serialized) @MainActor struct FileOperationRevealTests {
    @Test func failedOperationShowsAndSelectsTheOriginal() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("affected.txt")
        try Data("original".utf8).write(to: source)

        let browser = FileExplorerViewModel(initialPath: destinationDirectory)
        await browser.showInFolder(
            result(source: source, destination: destinationDirectory.appendingPathComponent("affected.txt"), outcome: .failed),
            operation: .copy
        )
        await waitForSelection(in: browser)

        #expect(browser.currentPath.standardizedFileURL == sourceDirectory.standardizedFileURL)
        let selected = browser.items.first { browser.selectedItems.contains($0.id) }
        #expect(selected?.path.standardizedFileURL == source.standardizedFileURL)
    }

    @Test func successfulRowShowsAndSelectsTheDestination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let destination = destinationDirectory.appendingPathComponent("copied.txt")
        try Data("copy".utf8).write(to: destination)

        let browser = FileExplorerViewModel(initialPath: root)
        await browser.showInFolder(
            result(source: root.appendingPathComponent("missing-original.txt"), destination: destination, outcome: .succeeded),
            operation: .copy
        )
        await waitForSelection(in: browser)

        #expect(browser.currentPath.standardizedFileURL == destinationDirectory.standardizedFileURL)
        let selected = browser.items.first { browser.selectedItems.contains($0.id) }
        #expect(selected?.path.standardizedFileURL == destination.standardizedFileURL)
    }

    @Test func missingItemFallsBackToExistingDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileExplorerViewModel(initialPath: FileManager.default.homeDirectoryForCurrentUser)
        let missing = root.appendingPathComponent("gone", isDirectory: true)
            .appendingPathComponent("missing.txt")

        await browser.showInFolder(result(source: missing, outcome: .failed), operation: .move)

        #expect(browser.currentPath.standardizedFileURL == root.standardizedFileURL)
        #expect(browser.selectedItems.isEmpty)
    }

    @Test func failedFolderCreationOpensItsParentDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileExplorerViewModel(initialPath: FileManager.default.homeDirectoryForCurrentUser)

        await browser.showInFolder(
            result(source: root, destination: root.appendingPathComponent("not-created"), outcome: .failed),
            operation: .createFolder
        )

        #expect(browser.currentPath.standardizedFileURL == root.standardizedFileURL)
        #expect(browser.selectedItems.isEmpty)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOperationRevealTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitForSelection(in browser: FileExplorerViewModel) async {
        let deadline = Date().addingTimeInterval(3)
        while browser.selectedItems.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func result(
        source: URL,
        destination: URL? = nil,
        outcome: FileOperationOutcome
    ) -> FileOperationItemResult {
        FileOperationItemResult(
            source: source,
            destination: destination,
            outcome: outcome,
            message: nil,
            replacedItemInTrash: nil
        )
    }
}
