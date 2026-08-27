import Foundation
import Testing
@testable import FolderApp

@Test @MainActor func folderCutRemainsMoveWhilePasteboardIsOwned() {
    let url = URL(fileURLWithPath: "/a")
    #expect(ClipboardManager.effectiveAction(
        requestedAction: .cut,
        currentChangeCount: 4,
        ownedChangeCount: 4,
        currentURLs: [url],
        ownedURLs: [url]
    ) == .cut)
}

@Test @MainActor func finderCopyAfterFolderCutBecomesCopy() {
    #expect(ClipboardManager.effectiveAction(
        requestedAction: .cut,
        currentChangeCount: 5,
        ownedChangeCount: 4,
        currentURLs: [URL(fileURLWithPath: "/finder-copy")],
        ownedURLs: [URL(fileURLWithPath: "/folder-cut")]
    ) == .copy)
}
