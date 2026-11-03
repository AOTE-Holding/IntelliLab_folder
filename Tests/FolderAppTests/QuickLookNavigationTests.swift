import Testing
import Foundation
import ImageIO
import AppKit
@testable import FolderApp

@Test func quickLookScrollMovesWithinThePreviewListWithoutWrapping() {
    #expect(QuickLookManager.previewIndex(after: 0, itemCount: 3, direction: 1) == 1)
    #expect(QuickLookManager.previewIndex(after: 2, itemCount: 3, direction: -1) == 1)
    #expect(QuickLookManager.previewIndex(after: 2, itemCount: 3, direction: 1) == nil)
    #expect(QuickLookManager.previewIndex(after: 0, itemCount: 3, direction: -1) == nil)
    #expect(QuickLookManager.previewIndex(after: 0, itemCount: 0, direction: 1) == nil)
}

@Test func folderQuickLookCreatesANativeExtensionPayload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderQuickLookTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("Projects & Notes", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("A Folder"), withIntermediateDirectories: true)
    try Data("preview".utf8).write(to: folder.appendingPathComponent("<draft>.txt"))

    let listing = try FolderQuickLookPreview.folderEntries(at: folder)
    #expect(listing.entries.map(\.name) == ["A Folder", "<draft>.txt"])
    #expect(listing.entries.first?.isDirectory == true)

    let document = try FolderQuickLookPreview.createDocument(
        for: folder,
        in: root.appendingPathComponent("Preview", isDirectory: true)
    )
    #expect(document.pathExtension == FolderQuickLookPreview.filenameExtension)
    let payload = try FolderQuickLookPreview.decodeDocument(at: document)
    #expect(payload.folderName == "Projects & Notes")
    #expect(payload.entries.map(\.name) == ["A Folder", "<draft>.txt"])
    #expect(payload.errorMessage == nil)

}

@Test func quickLookCreatesReadablePayloadForUTF8SourceFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderQuickLookTextTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("app.ts")
    try Data("export const answer: number = 42;\n".utf8).write(to: source)

    let document = try #require(FolderQuickLookPreview.createTextDocument(
        for: source,
        in: root.appendingPathComponent("Preview", isDirectory: true)
    ))
    let payload = try FolderQuickLookPreview.decodeDocument(at: document)
    #expect(payload.previewKind == "text")
    #expect(payload.textLanguage == "TypeScript")
    #expect(payload.textContent == "export const answer: number = 42;\n")

    let html = root.appendingPathComponent("index.html")
    try Data("<h1>Rendered by Quick Look</h1>".utf8).write(to: html)
    #expect(FolderQuickLookPreview.createTextDocument(
        for: html,
        in: root.appendingPathComponent("Preview", isDirectory: true)
    ) == nil)
}

@Test func svgUsesRenderedImagePreviewInsteadOfSourceText() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderSVGPreviewTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("shape.SVG")
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\" fill=\"red\"/></svg>"
    try Data(svg.utf8).write(to: source)

    #expect(ImagePreviewSupport.isImage(source))
    #expect(ImagePreviewSupport.isImage(root.appendingPathComponent("photo.png")))
    #expect(!ImagePreviewSupport.isImage(root.appendingPathComponent("notes.txt")))
    #expect(FolderQuickLookPreview.createTextDocument(for: source, in: root) == nil)

    let preview = try #require(ImagePreviewSupport.createSVGPreview(for: source, in: root))
    #expect(preview.pathExtension == "png")
    let image = try #require(CGImageSourceCreateWithURL(preview as CFURL, nil))
    #expect(CGImageSourceGetCount(image) == 1)
    let rendered = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
    #expect(rendered.width == 650)
    #expect(rendered.height == 325)

    let broken = root.appendingPathComponent("broken.svg")
    try Data("<svg><not-closed>".utf8).write(to: broken)
    let errorPreview = try #require(ImagePreviewSupport.createSVGPreview(for: broken, in: root))
    #expect(try String(contentsOf: errorPreview, encoding: .utf8).contains("SVG image is invalid"))
}

@MainActor @Test func largeSVGTransitionThumbnailFitsTheFileTile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderSVGThumbnailTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("large.svg")
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"512\"><rect width=\"1024\" height=\"512\" fill=\"red\"/></svg>"
    try Data(svg.utf8).write(to: source)

    let thumbnail = try #require(await ThumbnailService.shared.getThumbnail(
        for: source.path,
        size: CGSize(width: 128, height: 128)
    ))
    #expect(thumbnail.size.width == 256)
    #expect(thumbnail.size.height == 128)
    #expect(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
}

@Test func quickLookPreparesFolderContentsBeforeThePanelIsVisible() {
    #expect(QuickLookManager.eagerFolderEnumerationCount(itemCount: 0) == 0)
    #expect(QuickLookManager.eagerFolderEnumerationCount(itemCount: 1_000) == 1_000)
}

@Test func nativeFileClicksSelectImmediatelyAndOpenOnlyOnSecondRelease() {
    #expect(DraggableView.action(forMouseDownClickCount: 1) == .select)
    #expect(DraggableView.action(forMouseUpClickCount: 1) == .none)
    #expect(DraggableView.action(forMouseDownClickCount: 2) == .none)
    #expect(DraggableView.action(forMouseUpClickCount: 2) == .open)
}

@Test func quickLookArrowKeysAdvanceExactlyOneItem() {
    #expect(QuickLookManager.navigationDirection(forKeyCode: 123) == -1)
    #expect(QuickLookManager.navigationDirection(forKeyCode: 126) == -1)
    #expect(QuickLookManager.navigationDirection(forKeyCode: 124) == 1)
    #expect(QuickLookManager.navigationDirection(forKeyCode: 125) == 1)
    #expect(QuickLookManager.navigationDirection(forKeyCode: 49) == nil)

    let direction = QuickLookManager.navigationDirection(forKeyCode: 124)
    #expect(QuickLookManager.previewIndex(after: 1, itemCount: 4, direction: direction ?? 0) == 2)

    #expect(QuickLookManager.browserTargetIndex(
        current: 5, itemCount: 12, keyCode: 123, columnsPerRow: 4, isGrid: true
    ) == 4)
    #expect(QuickLookManager.browserTargetIndex(
        current: 5, itemCount: 12, keyCode: 124, columnsPerRow: 4, isGrid: true
    ) == 6)
    #expect(QuickLookManager.browserTargetIndex(
        current: 5, itemCount: 12, keyCode: 126, columnsPerRow: 4, isGrid: true
    ) == 1)
    #expect(QuickLookManager.browserTargetIndex(
        current: 5, itemCount: 12, keyCode: 125, columnsPerRow: 4, isGrid: true
    ) == 9)
    #expect(QuickLookManager.browserTargetIndex(
        current: 5, itemCount: 12, keyCode: 126, columnsPerRow: 4, isGrid: false
    ) == 4)
}

@Test func quickLookStartsAtTheActivelySelectedItem() {
    let folderID = UUID()
    let fileID = UUID()
    let otherID = UUID()

    #expect(QuickLookManager.startingPreviewIndex(
        itemIDs: [folderID, fileID, otherID],
        selectedIDs: [fileID],
        activeID: fileID
    ) == 1)
    #expect(QuickLookManager.startingPreviewIndex(
        itemIDs: [folderID, fileID, otherID],
        selectedIDs: [folderID, fileID],
        activeID: fileID
    ) == 1)
    #expect(QuickLookManager.clampedPreviewIndex(99, itemCount: 3) == 2)
}
