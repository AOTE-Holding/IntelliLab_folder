import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()

    @Published private(set) var isEnabled = false
    @Published var errorMessage: String?

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
        // The visible toggle is backed by the native Login Items service.
        // Keep the persisted preference an accurate reflection of that source
        // of truth after relaunches and external System Settings changes.
        if SettingsManager.shared.settings.launchAtLogin != isEnabled {
            SettingsManager.shared.settings.launchAtLogin = isEnabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            SettingsManager.shared.settings.launchAtLogin = isEnabled
        } catch {
            refresh()
            SettingsManager.shared.settings.launchAtLogin = isEnabled
            errorMessage = "Launch at Login could not be changed: \(error.localizedDescription)"
        }
    }
}
