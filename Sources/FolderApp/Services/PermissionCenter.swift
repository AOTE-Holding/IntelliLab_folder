//
//  PermissionCenter.swift
//  Folder
//
//  Central model for folder & permission access:
//   - Standard folders (Desktop, Documents, Downloads)
//   - User-selected folders (stored as security-scoped bookmarks)
//   - External / network volumes
//   - Full Disk Access
//   - Terminal / iTerm automation
//
//  Production builds are sandboxed. Security-scoped bookmarks are therefore
//  the authority for every user-selected root and all of its descendants.
//

import Foundation
import AppKit
import SwiftUI
import Combine
import Darwin
import OSLog

private let permissionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.intellilab.folder",
    category: "Permissions"
)

private struct StandardFolderProbe: Sendable {
    let id: String
    let title: String
    let url: URL
    let bookmarkData: Data?
}

// MARK: - Status

enum AccessStatus: Equatable, Sendable {
    case allowed
    case denied
    case notRequested
    case stale   // bookmark exists but no longer resolves

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .notRequested: return "Not Requested"
        case .stale: return "Needs Re-authorization"
        }
    }

    var symbolName: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notRequested: return "circle.dashed"
        case .stale: return "clock.badge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        case .notRequested: return .secondary
        case .stale: return .orange
        }
    }
}

enum TerminalAutomationTarget: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        }
    }
}

// MARK: - Models

/// A folder the user granted access to. Keeps a security-scoped bookmark
/// when supported so access survives relaunch (raw URL as fallback).
struct BookmarkedFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: URL
    var bookmarkData: Data?

    init(id: UUID = UUID(), name: String, url: URL, bookmarkData: Data? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.bookmarkData = bookmarkData
    }
}

/// Live status for one of the macOS-standard protected folders.
struct StandardFolderAccess: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var url: URL
    var status: AccessStatus

    var symbolName: String {
        switch id {
        case "desktop": return "desktopcomputer"
        case "documents": return "doc.fill"
        case "downloads": return "arrow.down.circle.fill"
        default: return "folder"
        }
    }
}

/// A snapshot of access for an external or network volume.
struct VolumeAccess: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var name: String
    var isNetwork: Bool
    var status: AccessStatus

    var symbolName: String { isNetwork ? "network" : "externaldrive.fill" }
}

// MARK: - Active access token

/// Result of granting access to a URL via a stored bookmark. Call `stop()`
/// once the file-system work is finished.
struct ActiveAccess: Sendable {
    let url: URL
    let started: Bool

    func stop() {
        if started {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

// MARK: - Permission Center

@MainActor
class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    // Published state (drives the Permissions Center UI)
    @Published private(set) var standardFolderAccess: [StandardFolderAccess] = []
    @Published private(set) var userFolders: [BookmarkedFolder] = []
    @Published private(set) var volumeAccess: [VolumeAccess] = []
    @Published private(set) var hasFullDiskAccess = false
    @Published private(set) var terminalAutomationStatus: AccessStatus = .notRequested
    @Published private(set) var iTermAutomationStatus: AccessStatus = .notRequested
    @Published private(set) var hasSeenOnboarding = false
    @Published private(set) var onboardingStep = 0
    @Published private(set) var fullDiskAccessSettingsOpened = false
    @Published var lastError: String?

    private let fileManager = FileManager.default
    private let defaults: UserDefaults = ConfigStore.shared

    // Persistence keys
    private let userFoldersKey = "permissionCenter.userFolders"
    private let standardBookmarksKey = "permissionCenter.standardFolderBookmarks"
    private let onboardingSeenKey = "permissionCenter.onboardingSeen"
    private let onboardingStepKey = "permissionCenter.onboardingStep"
    private let fullDiskAccessConfirmedKey = "permissionCenter.fullDiskAccessConfirmed"
    private let fullDiskAccessSettingsOpenedKey = "permissionCenter.fullDiskAccessSettingsOpened"
    private let terminalRequestedKey = "permissionCenter.terminalAutomationRequested"
    private let iTermRequestedKey = "permissionCenter.iTermAutomationRequested"
    private var folderStatusGeneration = 0
    private var fullDiskAccessGeneration = 0
    private var terminalStatusGeneration = 0

    private let volumeManager = VolumeManager.shared

    private init() {
        loadPersistedState()
        hasSeenOnboarding = defaults.bool(forKey: onboardingSeenKey)
        onboardingStep = Self.normalizedOnboardingStep(defaults.integer(forKey: onboardingStepKey))
        hasFullDiskAccess = false
        fullDiskAccessSettingsOpened = defaults.bool(forKey: fullDiskAccessSettingsOpenedKey)

        // Keep volumes live
        reloadVolumes()
        monitorVolumes()

        refreshFolderStatus()
        detectFullDiskAccess()
        refreshTerminalStatuses()
    }

    // MARK: - Standard folders

    /// The macOS protected standard folders we offer in onboarding.
    private func standardFolderList() -> [(id: String, title: String, url: URL)] {
        // In a sandbox, `homeDirectoryForCurrentUser` points at the app
        // container. Desktop and Downloads happen to be container symlinks,
        // but Documents can be a distinct container directory. Ask for the
        // login user's real home so every picker validates the same root the
        // user sees in Finder.
        let home = Self.loginUserHomeDirectory(
            fileManager: fileManager,
            userName: NSUserName()
        )
        return [
            ("desktop", "Desktop", home.appendingPathComponent("Desktop")),
            ("documents", "Documents", home.appendingPathComponent("Documents")),
            ("downloads", "Downloads", home.appendingPathComponent("Downloads"))
        ]
    }

    nonisolated static func loginUserHomeDirectory(
        fileManager: FileManager,
        userName: String
    ) -> URL {
        // Foundation's current-user directory APIs are intentionally
        // container-relative in an App Sandbox. The POSIX account record is
        // the source of truth for the login user's Finder-visible home.
        var passwordEntry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedSize = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            getpwuid_r(
                getuid(),
                &passwordEntry,
                bufferPointer.baseAddress,
                bufferPointer.count,
                &result
            )
        }

        if status == 0, result != nil, let homePointer = passwordEntry.pw_dir {
            return URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
        }

        return fileManager.homeDirectory(forUser: userName)
            ?? fileManager.homeDirectoryForCurrentUser
    }

    func refreshFolderStatus() {
        let bookmarks = loadStandardBookmarks()
        let fullDiskAccessGranted = hasFullDiskAccess
        let probes = standardFolderList().map { entry in
            StandardFolderProbe(
                id: entry.id,
                title: entry.title,
                url: entry.url,
                bookmarkData: bookmarks[entry.id]
            )
        }
        // Publish the persisted state immediately. Validation follows on a
        // utility worker so a slow or disconnected location cannot stall UI.
        standardFolderAccess = probes.map { probe in
            StandardFolderAccess(
                id: probe.id,
                title: probe.title,
                url: probe.url,
                status: fullDiskAccessGranted || probe.bookmarkData != nil ? .allowed : .notRequested
            )
        }

        folderStatusGeneration += 1
        let generation = folderStatusGeneration
        Task { [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                probes.map { Self.probeStandardFolder($0, fullDiskAccessGranted: fullDiskAccessGranted) }
            }.value
            guard let self, generation == folderStatusGeneration else { return }
            standardFolderAccess = statuses
        }
    }

    nonisolated private static func probeStandardFolder(
        _ probe: StandardFolderProbe,
        fullDiskAccessGranted: Bool
    ) -> StandardFolderAccess {
        // Full Disk Access is an explicit macOS grant. Do not ask the user to
        // select Desktop/Documents/Downloads again when it already makes the
        // standard root directly usable.
        if fullDiskAccessGranted {
            return StandardFolderAccess(
                id: probe.id,
                title: probe.title,
                url: probe.url,
                status: .allowed
            )
        }

        guard let bookmarkData = probe.bookmarkData else {
            return StandardFolderAccess(
                id: probe.id,
                title: probe.title,
                url: probe.url,
                status: .notRequested
            )
        }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            return StandardFolderAccess(
                id: probe.id,
                title: probe.title,
                url: probe.url,
                status: .stale
            )
        }

        let started = resolved.startAccessingSecurityScopedResource()
        let readable = FileManager.default.isReadableFile(atPath: resolved.path)
        if started { resolved.stopAccessingSecurityScopedResource() }
        return StandardFolderAccess(
            id: probe.id,
            title: probe.title,
            url: probe.url,
            status: readable ? .allowed : .denied
        )
    }

    /// Prompt the user to grant access to a standard folder (creates a bookmark).
    func grantStandardFolder(_ entry: StandardFolderAccess) {
        let panel = NSOpenPanel()
        // Start one level above the requested root. If the panel opens *inside*
        // Desktop/Documents/Downloads, macOS can only return one of its
        // children, so the exact-root validation below necessarily fails.
        panel.directoryURL = entry.url.deletingLastPathComponent()
        panel.nameFieldStringValue = entry.url.lastPathComponent
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Allow"
        panel.message = "Allow Folder access to “\(entry.title)”?"

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        guard Self.urlsReferToSameDirectory(chosen, entry.url, fileManager: fileManager) else {
            permissionLogger.error(
                "Standard-folder mismatch for \(entry.id, privacy: .public): selected=\(chosen.path, privacy: .public) expected=\(entry.url.path, privacy: .public)"
            )
            lastError = "Please select the \(entry.title) folder itself so Folder can store the correct access scope."
            return
        }

        guard let data = bookmark(for: chosen) else { return }

        var bookmarks = loadStandardBookmarks()
        bookmarks[entry.id] = data
        saveStandardBookmarks(bookmarks)
        refreshFolderStatus()
    }

    // MARK: - User-selected folders

    /// Present a folder picker and grant access to every chosen folder.
    /// Multiple folders can be selected at once.
    func pickAndGrantFolders(message: String = "Choose folders to grant Folder access to.",
                             prompt: String = "Allow") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.prompt = prompt

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addUserFolder(url: url)
        }
    }

    func addUserFolder() {
        pickAndGrantFolders()
    }

    /// Requests a bookmark for the folder currently shown in Folder's error
    /// state. The picker opens one level above the target so macOS can return
    /// the target itself (including a mounted-volume root).
    @discardableResult
    func requestAccess(to folder: URL) -> Bool {
        // Do not show Folder's picker when macOS has already granted direct
        // access (for example through Files & Folders or a mounted-volume
        // approval). The walkthrough remains the one-time permission setup;
        // this recovery picker is only for a real access denial.
        if hasUsableAccess(to: folder) {
            refreshFolderStatus()
            reloadVolumes()
            return true
        }

        let panel = NSOpenPanel()
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.nameFieldStringValue = folder.lastPathComponent
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Give Access"
        panel.message = "Choose “\(folder.lastPathComponent)” or a parent folder to allow Folder access."

        guard panel.runModal() == .OK, let chosen = panel.url,
              let bookmarkData = bookmark(for: chosen) else { return false }

        if let index = userFolders.firstIndex(where: {
            $0.url.standardizedFileURL == chosen.standardizedFileURL
        }) {
            // Selecting a known root renews its bookmark instead of making
            // the user remove it before they can recover access.
            userFolders[index].name = chosen.lastPathComponent
            userFolders[index].url = chosen
            userFolders[index].bookmarkData = bookmarkData
            saveUserFolders()
        } else {
            userFolders.append(BookmarkedFolder(
                name: chosen.lastPathComponent,
                url: chosen,
                bookmarkData: bookmarkData
            ))
            saveUserFolders()
        }

        refreshFolderStatus()
        reloadVolumes()
        return true
    }

    @discardableResult
    func addUserFolder(url: URL) -> Bool {
        guard let bookmarkData = bookmark(for: url) else { return false }
        if let index = userFolders.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            userFolders[index].name = url.lastPathComponent
            userFolders[index].url = url
            userFolders[index].bookmarkData = bookmarkData
        } else {
            userFolders.append(BookmarkedFolder(
                name: url.lastPathComponent,
                url: url,
                bookmarkData: bookmarkData
            ))
        }
        saveUserFolders()
        return true
    }

    func removeUserFolder(_ folder: BookmarkedFolder) {
        // Stop any active access and release the bookmark
        if let data = folder.bookmarkData, let resolved = resolve(url: folder.url, bookmarkData: data) {
            resolved.stopAccessingSecurityScopedResource()
        }
        userFolders.removeAll { $0.id == folder.id }
        saveUserFolders()
    }

    func reauthorize(_ folder: BookmarkedFolder) {
        let panel = NSOpenPanel()
        panel.directoryURL = folder.url.deletingLastPathComponent()
        panel.nameFieldStringValue = folder.url.lastPathComponent
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Re-authorize"
        panel.message = "Choose the folder again to renew Folder's access."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = bookmark(for: url),
              let index = userFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        userFolders[index].name = url.lastPathComponent
        userFolders[index].url = url
        userFolders[index].bookmarkData = data
        saveUserFolders()
    }

    func status(for folder: BookmarkedFolder) -> AccessStatus {
        if let data = folder.bookmarkData {
            return resolve(url: folder.url, bookmarkData: data) != nil ? .allowed : .stale
        }
        return .stale
    }

    // MARK: - Volumes

    private func monitorVolumes() {
        volumeManager.$mountedVolumes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.reloadVolumes()
                }
            }
            .store(in: &volumeCancellables)
    }

    private var volumeCancellables = Set<AnyCancellable>()

    func reloadVolumes() {
        volumeAccess = volumeManager.mountedVolumes.map { volume in
            let access = beginAccess(to: volume.url)
            let readableURL = access?.url ?? volume.url
            // A volume can be readable through macOS's own permission model
            // without Folder holding a bookmark. Treat that as allowed rather
            // than prompting the user for the same access a second time.
            let status: AccessStatus = isReadable(readableURL) ? .allowed : .notRequested
            access?.stop()
            return VolumeAccess(
                url: volume.url,
                name: volume.name,
                isNetwork: !volume.isLocal,
                status: status
            )
        }
    }

    func authorizeVolume(_ volume: VolumeAccess) {
        let panel = NSOpenPanel()
        panel.directoryURL = volume.url.deletingLastPathComponent()
        panel.nameFieldStringValue = volume.url.lastPathComponent
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Allow"
        panel.message = "Choose “\(volume.name)” or one of its folders to grant access."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = addUserFolder(url: url)
        reloadVolumes()
    }

    // MARK: - Full Disk Access

    func detectFullDiskAccess() {
        let home = Self.loginUserHomeDirectory(fileManager: fileManager, userName: NSUserName())
        let protectedPaths = [
            home.appendingPathComponent("Library/Messages").path,
            home.appendingPathComponent("Library/Safari").path,
            home.appendingPathComponent("Library/Mail").path,
            home.appendingPathComponent("Library/Application Support/MobileSync").path
        ]
        fullDiskAccessGeneration += 1
        let generation = fullDiskAccessGeneration
        Task { [weak self] in
            let available = await Task.detached(priority: .utility) {
                protectedPaths.contains { FileManager.default.isReadableFile(atPath: $0) }
            }.value
            guard let self, generation == fullDiskAccessGeneration else { return }
            hasFullDiskAccess = available
            defaults.set(available, forKey: fullDiskAccessConfirmedKey)
            refreshFolderStatus()
        }
    }

    /// macOS owns this permission. Recheck the protected locations after the
    /// user returns from System Settings instead of accepting a confirmation.
    func confirmFullDiskAccess() {
        detectFullDiskAccess()
    }

    func clearFullDiskAccessConfirmation() {
        defaults.removeObject(forKey: fullDiskAccessConfirmedKey)
        hasFullDiskAccess = false
        detectFullDiskAccess()
    }

    // MARK: - Terminal automation

    func refreshTerminalStatuses() {
        let terminalRequested = defaults.bool(forKey: terminalRequestedKey)
        let iTermRequested = defaults.bool(forKey: iTermRequestedKey)
        terminalStatusGeneration += 1
        let generation = terminalStatusGeneration
        Task { [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                (
                    Self.backgroundAutomationStatus(for: .terminal, requested: terminalRequested),
                    Self.backgroundAutomationStatus(for: .iTerm, requested: iTermRequested)
                )
            }.value
            guard let self, generation == terminalStatusGeneration else { return }
            terminalAutomationStatus = statuses.0
            iTermAutomationStatus = statuses.1
        }
    }

    /// Ask macOS to show the automation prompt (that's the action the app can
    /// actually perform — granting/revoking lives in System Settings).
    func requestTerminalAutomation(for target: TerminalAutomationTarget) {
        guard isAutomationTargetInstalled(target) else {
            lastError = "\(target.title) is not installed. No Automation permission is needed until you install it."
            return
        }
        defaults.set(true, forKey: requestedKey(for: target))
        let allowed = checkTerminalPermission(for: target)
        refreshTerminalStatuses()
        if !allowed {
            lastError = "Automation access for \(target.title) was not granted. You can change it in System Settings → Privacy & Security → Automation."
        }
    }

    func terminalStatus(for target: TerminalAutomationTarget) -> AccessStatus {
        switch target {
        case .terminal: return terminalAutomationStatus
        case .iTerm: return iTermAutomationStatus
        }
    }

    func isAutomationTargetInstalled(_ target: TerminalAutomationTarget) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) != nil
    }

    private func requestedKey(for target: TerminalAutomationTarget) -> String {
        switch target {
        case .terminal: return terminalRequestedKey
        case .iTerm: return iTermRequestedKey
        }
    }

    private func automationStatus(
        for target: TerminalAutomationTarget,
        requestedKey: String
    ) -> AccessStatus {
        guard defaults.bool(forKey: requestedKey) else { return .notRequested }
        guard isAutomationTargetInstalled(target) else { return .notRequested }
        return checkTerminalPermission(for: target) ? .allowed : .denied
    }

    nonisolated private static func backgroundAutomationStatus(
        for target: TerminalAutomationTarget,
        requested: Bool
    ) -> AccessStatus {
        guard requested,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) != nil else {
            return .notRequested
        }
        return backgroundTerminalPermission(for: target) ? .allowed : .denied
    }

    nonisolated private static func backgroundTerminalPermission(for target: TerminalAutomationTarget) -> Bool {
        let source = """
            tell application id "\(target.bundleIdentifier)" to get name
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        return script?.executeAndReturnError(&error) != nil && error == nil
    }

    private func checkTerminalPermission(for target: TerminalAutomationTarget) -> Bool {
        let source = """
            tell application id "\(target.bundleIdentifier)" to get name
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error {
            permissionLogger.error(
                "Automation check failed for \(target.bundleIdentifier, privacy: .public): \(error.description, privacy: .public)"
            )
            return false
        }
        return result != nil
    }

    // MARK: - System actions

    /// Open the relevant pane of System Settings (used for Full Disk Access
    /// and files & folders, which macOS does not let the app set itself).
    func openSystemSettings(for action: SystemSettingsPane) {
        let urlString: String?
        switch action {
        case .fullDiskAccess:
            defaults.set(true, forKey: fullDiskAccessSettingsOpenedKey)
            fullDiskAccessSettingsOpened = true
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .filesAndFolders:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        case .general:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }

        if let urlString, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Offer to add the terminal app to the automation allow-list hint.
    func revealTerminalInSystemSettings() {
        openSystemSettings(for: .general)
    }

    // MARK: - Bookmarks & access

    /// Create a security-scoped bookmark for a URL (nil when not supported).
    func bookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            lastError = "Folder could not save access to \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Resolve a stored bookmark back to a URL. Returns nil when stale/broken.
    func resolve(url: URL, bookmarkData: Data?) -> URL? {
        guard let data = bookmarkData else {
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return isStale ? nil : resolved
        } catch {
            return nil
        }
    }

    func isReadable(_ url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.path)
    }

    /// Checks both direct macOS access and an existing security-scoped
    /// bookmark. This is deliberately the sole gate before presenting any
    /// recovery picker, so the normal walkthrough never becomes a recurring
    /// prompt for an already accessible location.
    func hasUsableAccess(to url: URL) -> Bool {
        let access = beginAccess(to: url)
        defer { access?.stop() }
        return isReadable(access?.url ?? url)
    }

    /// Begin access to a folder using any stored bookmark. Returns nil when
    /// the folder is already directly accessible or no bookmark exists.
    @discardableResult
    func beginAccess(to url: URL) -> ActiveAccess? {
        let standardized = url.standardizedFileURL

        // A bookmark grants its selected root and every descendant, not only an
        // exact URL match. Prefer the most specific matching root.
        if let folder = userFolders
            .filter({ Self.isDescendant(standardized, of: $0.url.standardizedFileURL) })
            .max(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }),
           let data = folder.bookmarkData,
           let resolved = resolve(url: folder.url, bookmarkData: data) {
            let started = resolved.startAccessingSecurityScopedResource()
            let relativeComponents = standardized.pathComponents.dropFirst(folder.url.standardizedFileURL.pathComponents.count)
            let resolvedTarget = relativeComponents.reduce(resolved) { partial, component in
                partial.appendingPathComponent(component)
            }
            return ActiveAccess(url: resolvedTarget, started: started)
        }

        // Standard-folder bookmarks
        let bookmarks = loadStandardBookmarks()
        for entry in standardFolderList() where Self.isDescendant(standardized, of: entry.url.standardizedFileURL) {
            if let data = bookmarks[entry.id],
               let resolved = resolve(url: entry.url, bookmarkData: data) {
                let started = resolved.startAccessingSecurityScopedResource()
                let relativeComponents = standardized.pathComponents.dropFirst(entry.url.standardizedFileURL.pathComponents.count)
                let resolvedTarget = relativeComponents.reduce(resolved) { partial, component in
                    partial.appendingPathComponent(component)
                }
                return ActiveAccess(url: resolvedTarget, started: started)
            }
        }

        return nil
    }

    private nonisolated static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Powerbox may return a protected folder through its APFS data-volume or
    /// firmlink representation. Path-string equality rejects that valid choice.
    /// Compare canonical paths first, then ask FileManager and finally compare
    /// stable file + volume identifiers so a different folder with the same
    /// display name is never accepted.
    nonisolated static func urlsReferToSameDirectory(
        _ first: URL,
        _ second: URL,
        fileManager: FileManager
    ) -> Bool {
        let canonicalFirst = first.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalSecond = second.standardizedFileURL.resolvingSymlinksInPath()
        if canonicalFirst == canonicalSecond { return true }

        var relationship: FileManager.URLRelationship = .other
        if (try? fileManager.getRelationship(
            &relationship,
            ofDirectoryAt: canonicalFirst,
            toItemAt: canonicalSecond
        )) != nil, relationship == .same {
            return true
        }

        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let firstValues = try? canonicalFirst.resourceValues(forKeys: keys),
              let secondValues = try? canonicalSecond.resourceValues(forKeys: keys),
              let firstFileID = firstValues.fileResourceIdentifier as? AnyHashable,
              let secondFileID = secondValues.fileResourceIdentifier as? AnyHashable,
              let firstVolumeID = firstValues.volumeIdentifier as? AnyHashable,
              let secondVolumeID = secondValues.volumeIdentifier as? AnyHashable else {
            return false
        }
        return firstFileID == secondFileID && firstVolumeID == secondVolumeID
    }

    /// Convenience helper: run `body` with a (possibly bookmarked) folder
    /// resolved, and stop access afterwards.
    func withAccess<R>(to url: URL, _ body: (URL) throws -> R) rethrows -> R {
        let access = beginAccess(to: url)
        defer { access?.stop() }
        return try body(access?.url ?? url)
    }

    // MARK: - Onboarding

    nonisolated static func normalizedOnboardingStep(_ step: Int) -> Int {
        min(max(step, 0), 5)
    }

    nonisolated static func onboardingStepIndices(fullDiskAccessGranted: Bool) -> [Int] {
        fullDiskAccessGranted ? [0, 1, 3, 4, 5] : [0, 1, 2, 3, 4, 5]
    }

    func saveOnboardingStep(_ step: Int) {
        let normalized = Self.normalizedOnboardingStep(step)
        defaults.set(normalized, forKey: onboardingStepKey)
        onboardingStep = normalized
    }

    func markOnboardingSeen() {
        defaults.set(true, forKey: onboardingSeenKey)
        defaults.removeObject(forKey: onboardingStepKey)
        hasSeenOnboarding = true
        onboardingStep = 0
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        // User folders
        if let data = defaults.data(forKey: userFoldersKey),
           let decoded = try? JSONDecoder().decode([BookmarkedFolder].self, from: data) {
            userFolders = decoded
        }
    }

    private func saveUserFolders() {
        if let encoded = try? JSONEncoder().encode(userFolders) {
            defaults.set(encoded, forKey: userFoldersKey)
        }
    }

    private func loadStandardBookmarks() -> [String: Data] {
        guard let data = defaults.data(forKey: standardBookmarksKey),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveStandardBookmarks(_ bookmarks: [String: Data]) {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            defaults.set(encoded, forKey: standardBookmarksKey)
        }
    }

    // MARK: - Reset

    /// Clear all stored access state (used by onboarding "Skip" and a debug reset).
    func resetAll() {
        userFolders = []
        saveUserFolders()
        defaults.removeObject(forKey: standardBookmarksKey)
        defaults.removeObject(forKey: onboardingSeenKey)
        defaults.removeObject(forKey: onboardingStepKey)
        defaults.removeObject(forKey: fullDiskAccessConfirmedKey)
        defaults.removeObject(forKey: fullDiskAccessSettingsOpenedKey)
        defaults.removeObject(forKey: terminalRequestedKey)
        defaults.removeObject(forKey: iTermRequestedKey)
        hasSeenOnboarding = false
        onboardingStep = 0
        hasFullDiskAccess = false
        fullDiskAccessSettingsOpened = false
        refreshFolderStatus()
        detectFullDiskAccess()
        refreshTerminalStatuses()
        reloadVolumes()
    }
}

// MARK: - System Settings pane

enum SystemSettingsPane {
    case fullDiskAccess
    case filesAndFolders
    case general
}
