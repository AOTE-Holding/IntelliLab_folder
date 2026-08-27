import Foundation
import AppKit

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    enum ClipboardAction: String, Sendable {
        case copy
        case cut
    }

    @Published private(set) var clipboardItems: [FileSystemItem] = []
    @Published private(set) var clipboardAction: ClipboardAction = .copy
    @Published private(set) var isProcessing = false

    private let pasteboard: NSPasteboard
    private let operationService: FileOperationService
    private var ownedPasteboardChangeCount: Int?
    private var ownedURLs: [URL] = []

    init(
        pasteboard: NSPasteboard = .general,
        operationService: FileOperationService = .shared
    ) {
        self.pasteboard = pasteboard
        self.operationService = operationService
    }

    func copy(items: [FileSystemItem]) {
        write(items: items, action: .copy)
    }

    func cut(items: [FileSystemItem]) {
        write(items: items, action: .cut)
    }

    /// Executes immediately only when there are no conflicts. If conflicts
    /// exist, the caller receives a preview and can ask the user for one of the
    /// four explicit decisions before any file is changed.
    func paste(to destination: URL) async throws -> PasteResult {
        let urls = try pasteboardURLs()
        let action = effectiveAction(for: urls)
        let kind: FileOperationKind = action == .cut ? .move : .copy
        let preview = await operationService.previewTransfer(urls, to: destination, kind: kind)

        guard preview.conflicts.isEmpty else {
            return PasteResult(
                succeeded: [],
                failed: [],
                conflicts: preview.conflicts,
                sourceURLsForHistory: [],
                actionType: action,
                wasCancelled: false
            )
        }
        return await executePaste(urls: urls, to: destination, action: action, resolution: .skip)
    }

    func pasteWithResolution(
        to destination: URL,
        conflictResolution: FileConflictResolution
    ) async throws -> PasteResult {
        let urls = try pasteboardURLs()
        let action = effectiveAction(for: urls)
        return await executePaste(urls: urls, to: destination, action: action, resolution: conflictResolution)
    }

    func hasClipboardContent() -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        return !urls.isEmpty
    }

    func clearClipboard() {
        clipboardItems = []
        ownedURLs = []
        ownedPasteboardChangeCount = nil
        pasteboard.clearContents()
    }

    private func write(items: [FileSystemItem], action: ClipboardAction) {
        clipboardItems = items
        clipboardAction = action
        ownedURLs = items.map { $0.path.standardizedFileURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(ownedURLs.map { $0 as NSURL })
        ownedPasteboardChangeCount = pasteboard.changeCount
    }

    private func pasteboardURLs() throws -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            throw ClipboardError.nothingToPaste
        }
        return urls.map(\.standardizedFileURL)
    }

    private func effectiveAction(for urls: [URL]) -> ClipboardAction {
        Self.effectiveAction(
            requestedAction: clipboardAction,
            currentChangeCount: pasteboard.changeCount,
            ownedChangeCount: ownedPasteboardChangeCount,
            currentURLs: urls,
            ownedURLs: ownedURLs
        )
    }

    /// A cut is trusted only while the pasteboard is still exactly the content
    /// written by Folder. A later Finder copy therefore always pastes as Copy.
    nonisolated static func effectiveAction(
        requestedAction: ClipboardAction,
        currentChangeCount: Int,
        ownedChangeCount: Int?,
        currentURLs: [URL],
        ownedURLs: [URL]
    ) -> ClipboardAction {
        guard requestedAction == .cut,
              currentChangeCount == ownedChangeCount,
              currentURLs.map(\.standardizedFileURL) == ownedURLs.map(\.standardizedFileURL) else {
            return .copy
        }
        return .cut
    }

    private func executePaste(
        urls: [URL],
        to destination: URL,
        action: ClipboardAction,
        resolution: FileConflictResolution
    ) async -> PasteResult {
        isProcessing = true
        defer { isProcessing = false }

        let accessTokens = (urls + [destination]).compactMap { PermissionCenter.shared.beginAccess(to: $0) }
        defer { accessTokens.forEach { $0.stop() } }

        let kind: FileOperationKind = action == .cut ? .move : .copy
        let report = await operationService.transfer(
            urls,
            to: destination,
            kind: kind,
            conflictResolution: resolution
        )
        let successful = report.succeeded
        let result = PasteResult(
            succeeded: successful.compactMap(\.destination),
            failed: report.failed.map {
                PasteFailure(url: $0.source, message: $0.message ?? "Unknown file-system error")
            },
            conflicts: report.skipped.map(\.source),
            sourceURLsForHistory: successful.map(\.source),
            actionType: action,
            wasCancelled: report.wasCancelled
        )

        if !successful.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: action == .cut ? .move : .copy,
                sourceURLs: result.sourceURLsForHistory,
                destinationURLs: result.succeeded
            ))
        }
        if action == .cut && result.allSucceeded {
            clearClipboard()
        }
        return result
    }
}

struct PasteFailure: Sendable, Equatable {
    let url: URL
    let message: String
}

struct PasteResult: Sendable {
    let succeeded: [URL]
    let failed: [PasteFailure]
    let conflicts: [URL]
    let sourceURLsForHistory: [URL]
    let actionType: ClipboardManager.ClipboardAction
    let wasCancelled: Bool

    var hasConflicts: Bool { !conflicts.isEmpty }
    var allSucceeded: Bool {
        !wasCancelled && failed.isEmpty && conflicts.isEmpty && succeeded.count == sourceURLsForHistory.count
    }
}

typealias ConflictResolution = FileConflictResolution

enum ClipboardError: Error, LocalizedError {
    case nothingToPaste

    var errorDescription: String? {
        switch self {
        case .nothingToPaste: return "Nothing to paste."
        }
    }
}
