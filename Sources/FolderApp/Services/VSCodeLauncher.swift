//
//  VSCodeLauncher.swift
//  Folder
//

import AppKit

@MainActor
enum VSCodeLauncher {
    static func open(_ directory: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            showError("Visual Studio Code is not installed.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                showError("Could not open Visual Studio Code: \(error.localizedDescription)")
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Open VS Code Here"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
