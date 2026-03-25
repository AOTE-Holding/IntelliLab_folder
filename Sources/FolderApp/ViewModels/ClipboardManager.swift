//
//  ClipboardManager.swift
//  Folder
//
//  Manager for clipboard operations (copy/cut/paste)
//

import Foundation
import AppKit

@MainActor
class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var clipboardItems: [FileSystemItem] = []
    @Published var clipboardAction: ClipboardAction = .copy
    @Published var isProcessing = false

    enum ClipboardAction: Sendable {
        case copy
        case cut
    }

    private let fileSystemService = FileSystemService.shared
    private let pasteboard = NSPasteboard.general

    private init() {}

    // MARK: - Copy

    func copy(items: [FileSystemItem]) {
        clipboardItems = items
        clipboardAction = .copy

        let urls = items.map { $0.path as NSURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    // MARK: - Cut

    func cut(items: [FileSystemItem]) {
        clipboardItems = items
        clipboardAction = .cut

        let urls = items.map { $0.path as NSURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    // MARK: - Paste

    func paste(to destination: URL) async throws -> PasteResult {
        // Read pasteboard on main thread (required by AppKit)
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            throw ClipboardError.nothingToPaste
        }

        let actionType = clipboardAction
        isProcessing = true

        // Run heavy file I/O on background thread
        let result: PasteResult = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var succeeded: [URL] = []
            var sourceURLsForHistory: [URL] = []
            var failed: [(URL, Error)] = []
            var conflicts: [URL] = []

            for sourceURL in urls {
                let fileName = sourceURL.lastPathComponent
                var destinationURL = destination.appendingPathComponent(fileName)

                let isSameFolder = sourceURL.deletingLastPathComponent() == destination

                if fm.fileExists(atPath: destinationURL.path) {
                    if isSameFolder && actionType == .copy {
                        destinationURL = Self.generateUniqueURL(for: destinationURL)
                    } else {
                        conflicts.append(sourceURL)
                        continue
                    }
                }

                do {
                    if actionType == .cut {
                        try fm.moveItem(at: sourceURL, to: destinationURL)
                    } else {
                        try fm.copyItem(at: sourceURL, to: destinationURL)
                    }
                    sourceURLsForHistory.append(sourceURL)
                    succeeded.append(destinationURL)
                } catch {
                    failed.append((sourceURL, error))
                }
            }

            return PasteResult(
                succeeded: succeeded,
                failed: failed,
                conflicts: conflicts,
                sourceURLsForHistory: sourceURLsForHistory,
                actionType: actionType
            )
        }.value

        isProcessing = false

        // Record undo action on main
        if !result.succeeded.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: result.actionType == .cut ? .move : .copy,
                sourceURLs: result.sourceURLsForHistory,
                destinationURLs: result.succeeded
            ))
        }

        if clipboardAction == .cut && result.succeeded.count == urls.count {
            clearClipboard()
        }

        return result
    }

    // MARK: - Paste with conflict resolution

    func pasteWithResolution(to destination: URL, conflictResolution: ConflictResolution) async throws -> PasteResult {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            throw ClipboardError.nothingToPaste
        }

        let actionType = clipboardAction
        isProcessing = true

        let result: PasteResult = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var succeeded: [URL] = []
            var sourceURLsForHistory: [URL] = []
            var failed: [(URL, Error)] = []

            for sourceURL in urls {
                let fileName = sourceURL.lastPathComponent
                var destinationURL = destination.appendingPathComponent(fileName)

                if fm.fileExists(atPath: destinationURL.path) {
                    switch conflictResolution {
                    case .skip:
                        continue
                    case .replace:
                        try? fm.trashItem(at: destinationURL, resultingItemURL: nil)
                    case .keepBoth:
                        destinationURL = Self.generateUniqueURL(for: destinationURL)
                    }
                }

                do {
                    if actionType == .cut {
                        try fm.moveItem(at: sourceURL, to: destinationURL)
                    } else {
                        try fm.copyItem(at: sourceURL, to: destinationURL)
                    }
                    sourceURLsForHistory.append(sourceURL)
                    succeeded.append(destinationURL)
                } catch {
                    failed.append((sourceURL, error))
                }
            }

            return PasteResult(
                succeeded: succeeded,
                failed: failed,
                conflicts: [],
                sourceURLsForHistory: sourceURLsForHistory,
                actionType: actionType
            )
        }.value

        isProcessing = false

        if !result.succeeded.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: result.actionType == .cut ? .move : .copy,
                sourceURLs: result.sourceURLsForHistory,
                destinationURLs: result.succeeded
            ))
        }

        if clipboardAction == .cut && result.failed.isEmpty {
            clearClipboard()
        }

        return result
    }

    // MARK: - Helpers

    func hasClipboardContent() -> Bool {
        return !clipboardItems.isEmpty
    }

    func clearClipboard() {
        clipboardItems = []
        pasteboard.clearContents()
    }

    private nonisolated static func generateUniqueURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 2
        var newURL = url

        while FileManager.default.fileExists(atPath: newURL.path) {
            let newFilename: String
            if ext.isEmpty {
                newFilename = "\(filename) (\(counter))"
            } else {
                newFilename = "\(filename) (\(counter)).\(ext)"
            }
            newURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return newURL
    }
}

// MARK: - Supporting Types

struct PasteResult: Sendable {
    let succeeded: [URL]
    let failed: [(URL, any Error)]
    let conflicts: [URL]
    let sourceURLsForHistory: [URL]
    let actionType: ClipboardManager.ClipboardAction

    var hasConflicts: Bool {
        return !conflicts.isEmpty
    }

    var allSucceeded: Bool {
        return failed.isEmpty && conflicts.isEmpty
    }
}

enum ConflictResolution: Sendable {
    case replace
    case keepBoth
    case skip
}

enum ClipboardError: Error, LocalizedError {
    case nothingToPaste
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToPaste:
            return "Nothing to paste"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        }
    }
}
