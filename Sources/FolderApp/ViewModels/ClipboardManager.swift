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

    enum ClipboardAction {
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

        // Write URLs to system pasteboard
        let urls = items.map { $0.path as NSURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    // MARK: - Cut

    func cut(items: [FileSystemItem]) {
        clipboardItems = items
        clipboardAction = .cut

        // Write URLs to system pasteboard
        let urls = items.map { $0.path as NSURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
    }

    // MARK: - Paste

    func paste(to destination: URL) async throws -> PasteResult {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            throw ClipboardError.nothingToPaste
        }

        var succeeded: [URL] = []
        var sourceURLsForHistory: [URL] = []
        var failed: [(URL, Error)] = []
        var conflicts: [URL] = []
        let actionType = clipboardAction

        for sourceURL in urls {
            let fileName = sourceURL.lastPathComponent
            var destinationURL = destination.appendingPathComponent(fileName)

            let isSameFolder = sourceURL.deletingLastPathComponent() == destination

            if fileSystemService.pathExists(destinationURL) {
                if isSameFolder && clipboardAction == .copy {
                    destinationURL = generateUniqueURL(for: destinationURL)
                } else {
                    conflicts.append(sourceURL)
                    continue
                }
            }

            do {
                if clipboardAction == .cut {
                    try fileSystemService.moveItem(at: sourceURL, to: destinationURL)
                } else {
                    try fileSystemService.copyItem(at: sourceURL, to: destinationURL)
                }
                sourceURLsForHistory.append(sourceURL)
                succeeded.append(destinationURL)
            } catch {
                failed.append((sourceURL, error))
            }
        }

        // Record undo action
        if !succeeded.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: actionType == .cut ? .move : .copy,
                sourceURLs: sourceURLsForHistory,
                destinationURLs: succeeded
            ))
        }

        if clipboardAction == .cut && succeeded.count == urls.count {
            clearClipboard()
        }

        return PasteResult(succeeded: succeeded, failed: failed, conflicts: conflicts)
    }

    // MARK: - Paste with conflict resolution

    func pasteWithResolution(to destination: URL, conflictResolution: ConflictResolution) async throws -> PasteResult {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            throw ClipboardError.nothingToPaste
        }

        var succeeded: [URL] = []
        var sourceURLsForHistory: [URL] = []
        var failed: [(URL, Error)] = []
        let actionType = clipboardAction

        for sourceURL in urls {
            let fileName = sourceURL.lastPathComponent
            var destinationURL = destination.appendingPathComponent(fileName)

            if fileSystemService.pathExists(destinationURL) {
                switch conflictResolution {
                case .skip:
                    continue
                case .replace:
                    try? fileSystemService.moveToTrash(destinationURL)
                case .keepBoth:
                    destinationURL = generateUniqueURL(for: destinationURL)
                }
            }

            do {
                if clipboardAction == .cut {
                    try fileSystemService.moveItem(at: sourceURL, to: destinationURL)
                } else {
                    try fileSystemService.copyItem(at: sourceURL, to: destinationURL)
                }
                sourceURLsForHistory.append(sourceURL)
                succeeded.append(destinationURL)
            } catch {
                failed.append((sourceURL, error))
            }
        }

        if !succeeded.isEmpty {
            ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                type: actionType == .cut ? .move : .copy,
                sourceURLs: sourceURLsForHistory,
                destinationURLs: succeeded
            ))
        }

        if clipboardAction == .cut && failed.isEmpty {
            clearClipboard()
        }

        return PasteResult(succeeded: succeeded, failed: failed, conflicts: [])
    }

    // MARK: - Helpers

    func hasClipboardContent() -> Bool {
        return !clipboardItems.isEmpty
    }

    func clearClipboard() {
        clipboardItems = []
        pasteboard.clearContents()
    }

    private func generateUniqueURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 2
        var newURL = url

        while fileSystemService.pathExists(newURL) {
            let newFilename: String
            if ext.isEmpty {
                // No extension: append (2) to end
                newFilename = "\(filename) (\(counter))"
            } else {
                // With extension: insert (2) before extension
                newFilename = "\(filename) (\(counter)).\(ext)"
            }
            newURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return newURL
    }
}

// MARK: - Supporting Types

struct PasteResult {
    let succeeded: [URL]
    let failed: [(URL, Error)]
    let conflicts: [URL]

    var hasConflicts: Bool {
        return !conflicts.isEmpty
    }

    var allSucceeded: Bool {
        return failed.isEmpty && conflicts.isEmpty
    }
}

enum ConflictResolution {
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
