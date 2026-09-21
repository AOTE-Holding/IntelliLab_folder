import Foundation
import Testing
@testable import FolderApp

@Test @MainActor func ejectFailureIsVisibleAndSuccessfulRetryClearsIt() {
    let volume = VolumeInfo(
        url: URL(fileURLWithPath: "/Volumes/Test Drive", isDirectory: true),
        name: "Test Drive",
        isRemovable: true,
        isEjectable: true,
        isLocal: true
    )
    var attemptedURLs: [URL] = []
    var shouldFail = true
    let manager = VolumeManager(ejectDevice: { url in
        attemptedURLs.append(url)
        if shouldFail {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "The disk is in use."]
            )
        }
    }, observesWorkspace: false)

    manager.ejectVolume(volume)
    #expect(attemptedURLs == [volume.url])
    #expect(manager.lastEjectError?.contains("Test Drive") == true)
    #expect(manager.lastEjectError?.contains("The disk is in use.") == true)

    shouldFail = false
    manager.ejectVolume(volume)
    #expect(manager.lastEjectError == nil)

    shouldFail = true
    manager.ejectVolume(volume)
    #expect(attemptedURLs == [volume.url, volume.url, volume.url])
    manager.clearEjectError()
    #expect(manager.lastEjectError == nil)
}
