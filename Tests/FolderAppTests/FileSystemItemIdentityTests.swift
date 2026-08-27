import Foundation
import Testing
@testable import FolderApp

@Test func watcherRefreshCanPreserveVisibleItemIdentity() {
    let stableID = UUID()
    let refreshed = FileSystemItem(
        path: URL(fileURLWithPath: "/tmp/example.txt"),
        name: "example.txt",
        type: .file,
        size: 42
    )

    let stabilized = refreshed.preservingIdentity(stableID)

    #expect(stabilized.id == stableID)
    #expect(stabilized.path == refreshed.path)
    #expect(stabilized.size == 42)
}
