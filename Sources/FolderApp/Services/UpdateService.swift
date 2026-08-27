import Foundation
import AppKit
import Sparkle

/// Sparkle owns download verification, installation, rollback and relaunch.
/// Folder never deletes or replaces its own bundle directly.
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController?

    private override init() {
        if Self.hasProductionUpdateConfiguration {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            // Local development bundles intentionally contain placeholder
            // Sparkle values. Do not start Sparkle or show a misleading
            // "Unable to Check for Updates" alert for those builds.
            controller = nil
        }
        super.init()
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates Are Disabled in This Development Build"
            alert.informativeText = "Install a signed production release to use automatic updates."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    func checkInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }

    private static var hasProductionUpdateConfiguration: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        let feedString = info["SUFeedURL"] as? String ?? ""
        guard let feedURL = URL(string: feedString) else { return false }
        return !publicKey.isEmpty
            && !publicKey.hasPrefix("DEVELOPMENT_")
            && feedURL.host != "invalid.example"
    }
}
