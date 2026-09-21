import AppKit
import Foundation

/// Lightweight updater backed directly by GitHub Releases.
/// It deliberately does not depend on Sparkle or an appcast.
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    enum CheckResult: Equatable {
        case upToDate
        case installable(version: String, notes: String, downloadURL: URL)
        case missingAsset(version: String)
        case failed(message: String)
        case skipped
    }

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion = ""
    @Published private(set) var releaseNotes = ""
    @Published private(set) var isDownloading = false

    private let apiURL = URL(string: "https://api.github.com/repos/AOTE-Holding/IntelliLab_folder/releases/latest")!
    private let lastCheckKey = "UpdateService.lastCheckDate"
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private var downloadURL: URL?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.defaults = defaults
        self.now = now
        super.init()
    }

    func checkInBackground() {
        Task {
            switch await check(silent: true) {
            case .installable:
                showUpdateAlert()
            case .missingAsset(let version):
                showMissingAssetAlert(version: version)
            case .upToDate, .failed, .skipped:
                break
            }
        }
    }

    func checkForUpdates() {
        Task {
            switch await check(silent: false) {
            case .installable:
                showUpdateAlert()
            case .upToDate:
                showUpToDateAlert()
            case .missingAsset(let version):
                showMissingAssetAlert(version: version)
            case .failed(let message):
                showError(message)
            case .skipped:
                break
            }
        }
    }

    func check(silent: Bool) async -> CheckResult {
        if silent,
           let lastCheck = defaults.object(forKey: lastCheckKey) as? Date,
           now().timeIntervalSince(lastCheck) < 60 * 60 {
            return .skipped
        }

        updateAvailable = false
        downloadURL = nil
        // A failed request is still a completed attempt. Throttle background
        // checks after HTTP, network, and decoding failures as well.
        defer { defaults.set(now(), forKey: lastCheckKey) }

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Folder Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                return .failed(message: "Could not check GitHub for updates. Please try again later.")
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let result = Self.assess(release, currentVersion: currentVersion)
            switch result {
            case .installable(let version, let notes, let archiveURL):
                latestVersion = version
                releaseNotes = notes
                downloadURL = archiveURL
                updateAvailable = true
            case .missingAsset(let version):
                latestVersion = version
                releaseNotes = release.body ?? ""
            case .upToDate, .failed, .skipped:
                break
            }
            return result
        } catch {
            return .failed(message: "Failed to check for updates: \(error.localizedDescription)")
        }
    }

    static func assess(_ release: GitHubRelease, currentVersion: String) -> CheckResult {
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewerVersion(version, than: currentVersion) else { return .upToDate }
        guard let archive = release.assets.first(where: { $0.name == "Folder.app.zip" }) else {
            return .missingAsset(version: version)
        }
        return .installable(version: version, notes: release.body ?? "", downloadURL: archive.downloadURL)
    }

    private func showUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Folder \(latestVersion) is available (you have \(currentVersion)).\n\n\(releaseNotes)"
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndInstall() }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Folder \(currentVersion) is the latest version."
        alert.runModal()
    }

    private func showMissingAssetAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Not Installable"
        alert.informativeText = "Folder \(version) is newer, but this release does not include Folder.app.zip. It cannot be installed from Folder."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func downloadAndInstall() async {
        guard let downloadURL else {
            showError("No Folder.app.zip download is attached to this release.")
            return
        }

        isDownloading = true
        defer { isDownloading = false }

        let fileManager = FileManager.default
        let updateDirectory = appSupportDirectory()
        let archiveURL = updateDirectory.appendingPathComponent("Folder-update.zip")
        let extractedURL = updateDirectory.appendingPathComponent("update-extract", isDirectory: true)

        do {
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: extractedURL)
            try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)

            let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                showError("The update download failed.")
                return
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)

            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", archiveURL.path, extractedURL.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                showError("The update could not be unpacked.")
                return
            }

            let contents = try fileManager.contentsOfDirectory(at: extractedURL, includingPropertiesForKeys: nil)
            guard let newAppURL = contents.first(where: { $0.lastPathComponent == "Folder.app" }) else {
                showError("The download does not contain Folder.app.")
                return
            }
            replaceAndRelaunch(with: newAppURL)
        } catch {
            showError("Update failed: \(error.localizedDescription)")
        }
    }

    private func replaceAndRelaunch(with newAppURL: URL) {
        let fileManager = FileManager.default
        let installURL = Bundle.main.bundleURL
        let scriptURL = appSupportDirectory().appendingPathComponent("install-update.sh")
        let backupURL = installURL.deletingLastPathComponent().appendingPathComponent(".Folder.previous.app")

        let script = Self.installerScript

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let process = Process()
            if fileManager.isWritableFile(atPath: installURL.deletingLastPathComponent().path) {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [scriptURL.path, newAppURL.path, installURL.path, backupURL.path]
            } else {
                let command = "/bin/bash \(shellQuote(scriptURL.path)) \(shellQuote(newAppURL.path)) \(shellQuote(installURL.path)) \(shellQuote(backupURL.path))"
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "do shell script \(appleScriptQuote(command)) with administrator privileges"]
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            showError("Failed to start the update installer: \(error.localizedDescription)")
        }
    }

    static let installerScript = """
        #!/bin/bash
        set -eu
        source_app="$1"
        target_app="$2"
        backup_app="$3"
        script_path="$0"
        sleep 1
        rm -rf "$backup_app"
        if [ -d "$target_app" ]; then mv "$target_app" "$backup_app"; fi
        if ditto "$source_app" "$target_app"; then
          xattr -cr "$target_app" || true
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app" || true
          rm -rf "$backup_app"
          open "$target_app"
        else
          # ditto can leave a partial target. Remove it before mv so the
          # backup returns to its original path rather than nesting inside it.
          if [ -e "$target_app" ]; then rm -rf "$target_app"; fi
          if [ -d "$backup_app" ]; then
            mv "$backup_app" "$target_app"
            if [ ! -d "$target_app" ] || [ -e "$backup_app" ]; then
              echo "Update rollback did not restore the previous app" >&2
              exit 1
            fi
          fi
          exit 1
        fi
        rm -f "$script_path"
        """

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    private func appSupportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("com.intellilab.folder/updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}
