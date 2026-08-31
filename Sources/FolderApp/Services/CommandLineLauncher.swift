//
//  CommandLineLauncher.swift
//  Folder
//
//  One launch path for “Open Command Line Here”. Apple Events are used only
//  where a terminal exposes that public interface; other targets use their
//  native URL scheme or documented command-line entry point.
//

import AppKit
import Foundation

@MainActor
final class CommandLineLauncher {
    static let shared = CommandLineLauncher()

    private let fileManager = FileManager.default

    private init() {}

    func open(at directory: URL, settings: AppSettings) {
        let target = settings.defaultTerminal

        if target == .custom {
            openCustomApplication(settings.customTerminalPath, at: directory)
            return
        }

        switch target {
        case .terminal:
            openAppleScriptTerminal(.terminal, command: changeDirectoryCommand(for: directory))
        case .iterm2:
            openAppleScriptTerminal(.iTerm, command: changeDirectoryCommand(for: directory))
        case .warp:
            openWarp(at: directory)
        case .ghostty:
            // Ghostty lässt sich auf macOS NICHT über sein CLI-Programm starten
            // — das sagt sein eigenes `--help`. Der Aufruf beendet sich dort mit
            // Erfolg und tut nichts; lief Ghostty schon, kam nur ein Fenster im
            // zuletzt benutzten Ordner nach vorne. Genau so sah der Fehler aus.
            //
            // Eine Prüfung des Rückgabewerts hätte das nicht gefangen: der
            // Aufruf meldet 0. Der dokumentierte Weg ist, der App den Ordner zu
            // übergeben — nachgemessen, das Fenster startet darin.
            openDirectory(
                directory,
                withApplicationNamed: "Ghostty",
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        case .cmux:
            openCMux(at: directory)
        case .tmux:
            let command = "cd -- \(shellQuoted(directory.path)); exec tmux new-session -A -s Folder"
            openAppleScriptTerminal(.terminal, command: command)
        case .kitty:
            launchBundledApplication(
                bundleIdentifier: "net.kovidgoyal.kitty",
                appName: "kitty",
                executableName: "kitty",
                arguments: ["--directory", directory.path],
                at: directory
            )
        case .alacritty:
            launchBundledApplication(
                bundleIdentifier: "org.alacritty",
                appName: "Alacritty",
                executableName: "alacritty",
                arguments: ["--working-directory", directory.path],
                at: directory
            )
        case .custom:
            break
        }
    }

    private func openAppleScriptTerminal(_ target: TerminalAutomationTarget, command: String) {
        guard PermissionCenter.shared.isAutomationTargetInstalled(target) else {
            report("\(target.title) is not installed. Choose another command-line target in Settings.")
            return
        }

        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application id "\(target.bundleIdentifier)"
                activate
                do script "\(escapedCommand)"
            end tell
            """
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil, error == nil else {
            report("Folder could not open \(target.title). Allow Automation in System Settings, then try again.")
            return
        }
    }

    private func openWarp(at directory: URL) {
        guard let encodedPath = directory.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "warp://action/new_tab?path=\(encodedPath)") else {
            report("Folder could not prepare the Warp path.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openCMux(at directory: URL) {
        // cmux exposes a public CLI specifically for creating a workspace at a
        // working directory. Prefer it; opening the app is a graceful fallback.
        if launchFirstAvailableCommand(named: "cmux", arguments: ["new-workspace", "--cwd", directory.path]) {
            return
        }

        guard let appURL = applicationURL(bundleIdentifier: "com.manaflow.cmux", appName: "cmux") else {
            report("cmux is not installed. Install its CLI or choose another command-line target in Settings.")
            return
        }
        openDirectory(directory, with: appURL)
    }

    private func launchBundledApplication(
        bundleIdentifier: String,
        appName: String,
        executableName: String,
        arguments: [String],
        at directory: URL
    ) {
        guard let appURL = applicationURL(bundleIdentifier: bundleIdentifier, appName: appName) else {
            report("\(appName) is not installed. Choose another command-line target in Settings.")
            return
        }

        let executable = Bundle(url: appURL)?.executableURL
            ?? appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard fileManager.isExecutableFile(atPath: executable.path), run(executable, arguments: arguments) else {
            openDirectory(directory, with: appURL)
            return
        }
    }

    private func openCustomApplication(_ applicationURL: URL?, at directory: URL) {
        guard let applicationURL else {
            report("Choose an app in Settings → Command-line Tools before using Other App.")
            return
        }
        openDirectory(directory, with: applicationURL)
    }

    /// Übergibt der App den Ordner — das Gegenstück zu `open -a App <Ordner>`.
    private func openDirectory(
        _ directory: URL,
        withApplicationNamed appName: String,
        bundleIdentifier: String
    ) {
        guard let appURL = applicationURL(bundleIdentifier: bundleIdentifier, appName: appName) else {
            report("\(appName) is not installed. Choose another command-line target in Settings.")
            return
        }
        openDirectory(directory, with: appURL)
    }

    private func openDirectory(_ directory: URL, with applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: applicationURL, configuration: configuration)
    }

    private func applicationURL(bundleIdentifier: String, appName: String) -> URL? {
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return application
        }
        let applicationPath = "/Applications/\(appName).app"
        return fileManager.fileExists(atPath: applicationPath) ? URL(fileURLWithPath: applicationPath) : nil
    }

    private func launchFirstAvailableCommand(named name: String, arguments: [String]) -> Bool {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)").path,
            "/usr/bin/\(name)"
        ]
        guard let executablePath = paths.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return false
        }
        return run(URL(fileURLWithPath: executablePath), arguments: arguments)
    }

    private func run(_ executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func changeDirectoryCommand(for directory: URL) -> String {
        "cd -- \(shellQuoted(directory.path))"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private func report(_ message: String) {
        PermissionCenter.shared.lastError = message
    }
}
