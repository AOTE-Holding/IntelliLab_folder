import Foundation
import AppKit

@MainActor
class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var downloadURL: URL?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0

    private let repoOwner = "intellilab-dev"
    private let repoName = "folder-app"
    private let lastCheckKey = "UpdateService.lastCheckDate"

    private override init() {
        super.init()
    }

    // MARK: - Check for Updates

    func checkForUpdates(silent: Bool = true) async {
        // In silent mode, skip if checked within the last 60 minutes
        if silent, let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 3600 {
            return
        }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return }

            // Rate limited or other error
            if httpResponse.statusCode != 200 {
                if !silent {
                    showError("Could not check for updates (HTTP \(httpResponse.statusCode)).")
                }
                return
            }

            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent { showError("Could not parse release information.") }
                return
            }

            let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let notes = json["body"] as? String ?? ""

            // Find the zip asset
            var assetURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".zip"),
                       let urlStr = asset["browser_download_url"] as? String {
                        assetURL = URL(string: urlStr)
                        break
                    }
                }
            }

            if isNewerVersion(latest: latest, current: appVersion) {
                self.updateAvailable = true
                self.latestVersion = latest
                self.releaseNotes = notes
                self.downloadURL = assetURL
            } else {
                self.updateAvailable = false
            }
        } catch {
            if !silent {
                showError("Failed to check for updates: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Download and Install

    func downloadAndInstall() async {
        guard let downloadURL = downloadURL else {
            showError("No download URL available for this release.")
            return
        }

        isDownloading = true
        downloadProgress = 0

        let supportDir = appSupportDirectory()

        do {
            let zipPath = supportDir.appendingPathComponent("Folder-update.zip")
            let extractDir = supportDir.appendingPathComponent("update-extract")

            // Clean previous downloads
            try? FileManager.default.removeItem(at: zipPath)
            try? FileManager.default.removeItem(at: extractDir)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // Download the zip
            let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                isDownloading = false
                showError("Download failed.")
                return
            }

            // Move to our location
            try FileManager.default.moveItem(at: tempURL, to: zipPath)

            downloadProgress = 0.5

            // Extract with ditto
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", zipPath.path, extractDir.path]
            try ditto.run()
            ditto.waitUntilExit()

            guard ditto.terminationStatus == 0 else {
                isDownloading = false
                showError("Failed to extract update.")
                return
            }

            downloadProgress = 0.8

            // Find the .app in extracted contents
            let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                isDownloading = false
                showError("No app bundle found in the download.")
                return
            }

            downloadProgress = 1.0

            // Replace and relaunch
            replaceAndRelaunch(with: newApp)

        } catch {
            isDownloading = false
            showError("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Replace and Relaunch

    private func replaceAndRelaunch(with newAppURL: URL) {
        let installPath = "/Applications/Folder.app"
        let scriptDir = appSupportDirectory()
        let scriptPath = scriptDir.appendingPathComponent("update.sh")

        let script = """
        #!/bin/bash
        sleep 1
        rm -rf "\(installPath)"
        cp -R "\(newAppURL.path)" "\(installPath)"
        xattr -cr "\(installPath)"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(installPath)"
        open "\(installPath)"
        rm -f "\(scriptPath.path)"
        """

        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath.path]
            // Detach so it survives app termination
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            // Quit the app so the script can replace it
            NSApplication.shared.terminate(nil)
        } catch {
            isDownloading = false
            showError("Failed to start update process: \(error.localizedDescription)")
        }
    }

    // MARK: - Version Comparison

    private func isNewerVersion(latest: String, current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    // MARK: - Helpers

    private func appSupportDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.folder.app/updates")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
