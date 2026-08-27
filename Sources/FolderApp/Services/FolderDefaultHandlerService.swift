import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Owns Folder's optional Launch Services association for directories.
///
/// The association is always explicit: Folder never claims it during launch
/// and keeps the user's previous handler so it can be restored later.
@MainActor
final class FolderDefaultHandlerService: ObservableObject {
    static let shared = FolderDefaultHandlerService()

    @Published private(set) var isFolderDefault = false
    @Published private(set) var errorMessage: String?

    private let registry: any FolderHandlerRegistry
    private let defaults: UserDefaults
    private let bundleIdentifier: String?
    private let bundleURL: URL
    private let previousHandlerKey = "com.intellilab.folder.previous-folder-handler"

    private init() {
        registry = SystemFolderHandlerRegistry()
        defaults = .standard
        bundleIdentifier = Bundle.main.bundleIdentifier
        bundleURL = Bundle.main.bundleURL
        refresh()
    }

    init(
        registry: any FolderHandlerRegistry,
        defaults: UserDefaults,
        bundleIdentifier: String?,
        bundleURL: URL
    ) {
        self.registry = registry
        self.defaults = defaults
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        refresh()
    }

    func refresh() {
        guard let bundleIdentifier else {
            isFolderDefault = false
            return
        }
        isFolderDefault = registry.defaultHandlerBundleIdentifier() == bundleIdentifier
    }

    func clearError() {
        errorMessage = nil
    }

    func makeFolderDefault() {
        guard let bundleIdentifier else {
            errorMessage = "Folder has no bundle identifier and cannot become the default app."
            return
        }

        let currentHandler = registry.defaultHandlerBundleIdentifier()
        if currentHandler != bundleIdentifier,
           defaults.string(forKey: previousHandlerKey) == nil,
           let currentHandler {
            defaults.set(currentHandler, forKey: previousHandlerKey)
        }

        let registrationStatus = registry.registerApplication(at: bundleURL)
        guard registrationStatus == noErr else {
            errorMessage = "Folder could not be registered with macOS (error \(registrationStatus))."
            refresh()
            return
        }

        let status = registry.setDefaultHandler(bundleIdentifier: bundleIdentifier)
        guard status == noErr else {
            errorMessage = "macOS could not set Folder as the default app for folders (error \(status))."
            refresh()
            return
        }

        errorMessage = nil
        refresh()
    }

    func restorePreviousHandler() {
        guard let bundleIdentifier else { return }
        guard registry.defaultHandlerBundleIdentifier() == bundleIdentifier else {
            refresh()
            return
        }

        let previousHandler = defaults.string(forKey: previousHandlerKey) ?? "com.apple.finder"
        let status = registry.setDefaultHandler(bundleIdentifier: previousHandler)
        guard status == noErr else {
            errorMessage = "macOS could not restore the previous folder app (error \(status))."
            refresh()
            return
        }

        defaults.removeObject(forKey: previousHandlerKey)
        errorMessage = nil
        refresh()
    }
}

/// Isolates the deprecated Launch Services setter behind one small adapter.
/// Apple has not supplied a replacement API for changing this user preference.
@MainActor
protocol FolderHandlerRegistry {
    func registerApplication(at url: URL) -> OSStatus
    func defaultHandlerBundleIdentifier() -> String?
    func setDefaultHandler(bundleIdentifier: String) -> OSStatus
}

struct SystemFolderHandlerRegistry: FolderHandlerRegistry {
    private let folderContentType = UTType.folder.identifier as CFString

    func registerApplication(at url: URL) -> OSStatus {
        LSRegisterURL(url as CFURL, true)
    }

    func defaultHandlerBundleIdentifier() -> String? {
        guard let handler = LSCopyDefaultRoleHandlerForContentType(folderContentType, .viewer) else {
            return nil
        }
        let handlerIdentifier: CFString = handler.takeRetainedValue()
        return handlerIdentifier as String
    }

    func setDefaultHandler(bundleIdentifier: String) -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(
            folderContentType,
            .viewer,
            bundleIdentifier as CFString
        )
    }
}
