import Foundation
import CoreServices
import Testing
@testable import FolderApp

@MainActor
private final class InMemoryFolderHandlerRegistry: FolderHandlerRegistry {
    var currentHandler: String?
    var registrationStatus: OSStatus = noErr
    var setStatus: OSStatus = noErr
    private(set) var registeredURLs: [URL] = []
    private(set) var requestedHandlers: [String] = []

    init(currentHandler: String?) {
        self.currentHandler = currentHandler
    }

    func registerApplication(at url: URL) -> OSStatus {
        registeredURLs.append(url)
        return registrationStatus
    }

    func defaultHandlerBundleIdentifier() -> String? {
        currentHandler
    }

    func setDefaultHandler(bundleIdentifier: String) -> OSStatus {
        requestedHandlers.append(bundleIdentifier)
        if setStatus == noErr {
            currentHandler = bundleIdentifier
        }
        return setStatus
    }
}

@Test @MainActor func folderDefaultHandlerSavesAndRestoresThePreviousApp() throws {
    let suiteName = "FolderDefaultHandlerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = InMemoryFolderHandlerRegistry(currentHandler: "com.apple.finder")
    let bundleIdentifier = "com.intellilab.folder.tests"
    let bundleURL = URL(fileURLWithPath: "/Applications/FolderTests.app", isDirectory: true)
    let service = FolderDefaultHandlerService(
        registry: registry,
        defaults: defaults,
        bundleIdentifier: bundleIdentifier,
        bundleURL: bundleURL
    )

    service.makeFolderDefault()

    #expect(registry.registeredURLs == [bundleURL])
    #expect(registry.requestedHandlers == [bundleIdentifier])
    #expect(service.isFolderDefault)

    service.restorePreviousHandler()

    #expect(registry.requestedHandlers == [bundleIdentifier, "com.apple.finder"])
    #expect(!service.isFolderDefault)
}

@Test @MainActor func folderDefaultHandlerKeepsTheCurrentAppWhenRegistrationFails() throws {
    let suiteName = "FolderDefaultHandlerFailureTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = InMemoryFolderHandlerRegistry(currentHandler: "com.apple.finder")
    registry.registrationStatus = -1
    let service = FolderDefaultHandlerService(
        registry: registry,
        defaults: defaults,
        bundleIdentifier: "com.intellilab.folder.tests",
        bundleURL: URL(fileURLWithPath: "/Applications/FolderTests.app", isDirectory: true)
    )

    service.makeFolderDefault()

    #expect(registry.requestedHandlers.isEmpty)
    #expect(!service.isFolderDefault)
    #expect(service.errorMessage != nil)
}
