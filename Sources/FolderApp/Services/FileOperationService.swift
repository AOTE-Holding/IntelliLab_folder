import Foundation
import ImageIO
import Darwin
import ZIPFoundation

enum FileOperationKind: String, Codable, Sendable, Equatable {
    case createFolder
    case copy
    case move
    case trash
    case rename
    case duplicate
    case compress
    case rotate
}

enum FileConflictResolution: String, CaseIterable, Codable, Sendable, Equatable {
    case replace
    case keepBoth
    case skip
    case cancel
}

enum FileOperationOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case skipped
    case failed
    case cancelled
}

struct FileOperationPreview: Sendable {
    let kind: FileOperationKind
    let sources: [URL]
    let destinationDirectory: URL?
    let conflicts: [URL]
    let isDestructive: Bool

    var itemCount: Int { sources.count }
}

struct FileOperationProgress: Sendable {
    let completed: Int
    let total: Int
    let currentItem: URL?

    var fractionCompleted: Double {
        guard total > 0 else { return 1 }
        return Double(completed) / Double(total)
    }
}

struct FileOperationItemResult: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL?
    let outcome: FileOperationOutcome
    let message: String?
    let replacedItemInTrash: URL?
}

struct FileOperationReport: Sendable {
    let kind: FileOperationKind
    let results: [FileOperationItemResult]

    var succeeded: [FileOperationItemResult] { results.filter { $0.outcome == .succeeded } }
    var failed: [FileOperationItemResult] { results.filter { $0.outcome == .failed } }
    var skipped: [FileOperationItemResult] { results.filter { $0.outcome == .skipped } }
    var wasCancelled: Bool { results.contains { $0.outcome == .cancelled } }
    var allSucceeded: Bool { !results.isEmpty && succeeded.count == results.count }
}

struct FileRelocation: Sendable {
    let source: URL
    let destination: URL
}

enum FileOperationError: LocalizedError, Sendable {
    case noItems
    case destinationRequired
    case invalidName
    case unsupportedImageFormat(String)
    case unableToDecodeImage
    case unableToEncodeImage
    case unableToValidateOutput
    case unableToPreserveImageMetadata
    case compressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noItems: return "No files were selected."
        case .destinationRequired: return "This operation needs a destination folder."
        case .invalidName: return "The new name is empty or contains a path separator."
        case .unsupportedImageFormat(let ext):
            return "Rotation is not supported for .\(ext) files. A potentially destructive conversion was not attempted."
        case .unableToDecodeImage: return "The image could not be decoded."
        case .unableToEncodeImage: return "The rotated image could not be encoded."
        case .unableToValidateOutput: return "The temporary output failed validation; the original was not changed."
        case .unableToPreserveImageMetadata: return "The image metadata could not be preserved exactly; no rotated copy was created."
        case .compressionFailed(let reason): return "The archive could not be created: \(reason)"
        }
    }
}

/// The only component allowed to mutate user files. It is an actor so file I/O
/// never inherits MainActor isolation from SwiftUI view models.
actor FileOperationService {
    static let shared = FileOperationService()

    typealias ProgressHandler = @Sendable (FileOperationProgress) async -> Void

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func previewTransfer(
        _ sources: [URL],
        to destinationDirectory: URL,
        kind: FileOperationKind
    ) -> FileOperationPreview {
        let conflicts = sources.filter {
            fileManager.fileExists(atPath: destinationDirectory.appendingPathComponent($0.lastPathComponent).path)
        }
        return FileOperationPreview(
            kind: kind,
            sources: sources,
            destinationDirectory: destinationDirectory,
            conflicts: conflicts,
            isDestructive: kind == .move
        )
    }

    func recommendedDropOperation(from source: URL, to destinationDirectory: URL) -> FileOperationKind {
        let sourceVolume = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let destinationVolume = try? destinationDirectory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let sourceVolume, let destinationVolume else { return .copy }
        return String(describing: sourceVolume) == String(describing: destinationVolume) ? .move : .copy
    }

    func transfer(
        _ sources: [URL],
        to destinationDirectory: URL,
        kind: FileOperationKind,
        conflictResolution: FileConflictResolution,
        progress: ProgressHandler? = nil
    ) async -> FileOperationReport {
        precondition(kind == .copy || kind == .move)
        var results: [FileOperationItemResult] = []

        for (index, source) in sources.enumerated() {
            if Task.isCancelled || conflictResolution == .cancel {
                results.append(contentsOf: sources[index...].map {
                    result(source: $0, outcome: .cancelled, message: "Operation cancelled.")
                })
                break
            }

            await progress?(FileOperationProgress(completed: index, total: sources.count, currentItem: source))
            var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)

            if source.standardizedFileURL == destination.standardizedFileURL {
                if kind == .copy {
                    destination = uniqueURL(for: destination)
                } else {
                    results.append(result(source: source, destination: destination, outcome: .skipped, message: "The item is already in this folder."))
                    continue
                }
            }

            var replacedTrashURL: URL?
            if fileManager.fileExists(atPath: destination.path) {
                switch conflictResolution {
                case .keepBoth:
                    destination = uniqueURL(for: destination)
                case .skip:
                    results.append(result(source: source, destination: destination, outcome: .skipped, message: "An item with this name already exists."))
                    continue
                case .cancel:
                    continue
                case .replace:
                    do {
                        var trashURL: NSURL?
                        try fileManager.trashItem(at: destination, resultingItemURL: &trashURL)
                        replacedTrashURL = trashURL as URL?
                    } catch {
                        results.append(result(source: source, destination: destination, outcome: .failed, message: "Could not preserve the existing item: \(error.localizedDescription)"))
                        continue
                    }
                }
            }

            do {
                if kind == .move {
                    try fileManager.moveItem(at: source, to: destination)
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
                results.append(result(source: source, destination: destination, outcome: .succeeded, replacedItemInTrash: replacedTrashURL))
            } catch {
                let originalError = error
                if let replacedTrashURL {
                    do {
                        try fileManager.moveItem(at: replacedTrashURL, to: destination)
                    } catch {
                        results.append(result(
                            source: source,
                            destination: destination,
                            outcome: .failed,
                            message: "\(originalError.localizedDescription) The replaced item also could not be restored: \(error.localizedDescription)"
                        ))
                        continue
                    }
                }
                results.append(result(source: source, destination: destination, outcome: .failed, message: originalError.localizedDescription))
            }
        }

        await progress?(FileOperationProgress(completed: results.count, total: sources.count, currentItem: nil))
        return FileOperationReport(kind: kind, results: results)
    }

    func moveToTrash(
        _ sources: [URL],
        progress: ProgressHandler? = nil
    ) async -> FileOperationReport {
        var results: [FileOperationItemResult] = []
        for (index, source) in sources.enumerated() {
            if Task.isCancelled {
                results.append(contentsOf: sources[index...].map {
                    result(source: $0, outcome: .cancelled, message: "Operation cancelled.")
                })
                break
            }
            await progress?(FileOperationProgress(completed: index, total: sources.count, currentItem: source))
            do {
                var trashURL: NSURL?
                try fileManager.trashItem(at: source, resultingItemURL: &trashURL)
                results.append(result(source: source, destination: trashURL as URL?, outcome: .succeeded))
            } catch {
                results.append(result(source: source, outcome: .failed, message: error.localizedDescription))
            }
        }
        await progress?(FileOperationProgress(completed: results.count, total: sources.count, currentItem: nil))
        return FileOperationReport(kind: .trash, results: results)
    }

    func relocateExactly(_ items: [FileRelocation], kind: FileOperationKind) async -> FileOperationReport {
        precondition(kind == .copy || kind == .move)
        var results: [FileOperationItemResult] = []
        for item in items {
            if Task.isCancelled {
                results.append(result(source: item.source, destination: item.destination, outcome: .cancelled, message: "Operation cancelled."))
                continue
            }
            guard !fileManager.fileExists(atPath: item.destination.path) else {
                results.append(result(source: item.source, destination: item.destination, outcome: .failed, message: "The original location is occupied."))
                continue
            }
            do {
                if kind == .move {
                    try fileManager.moveItem(at: item.source, to: item.destination)
                } else {
                    try fileManager.copyItem(at: item.source, to: item.destination)
                }
                results.append(result(source: item.source, destination: item.destination, outcome: .succeeded))
            } catch {
                results.append(result(source: item.source, destination: item.destination, outcome: .failed, message: error.localizedDescription))
            }
        }
        return FileOperationReport(kind: kind, results: results)
    }

    func rename(_ source: URL, to newName: String) async -> FileOperationReport {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/") else {
            return FileOperationReport(kind: .rename, results: [result(source: source, outcome: .failed, message: FileOperationError.invalidName.localizedDescription)])
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(cleanName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            return FileOperationReport(kind: .rename, results: [result(source: source, destination: destination, outcome: .failed, message: "An item with this name already exists.")])
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            return FileOperationReport(kind: .rename, results: [result(source: source, destination: destination, outcome: .succeeded)])
        } catch {
            return FileOperationReport(kind: .rename, results: [result(source: source, destination: destination, outcome: .failed, message: error.localizedDescription)])
        }
    }

    func createFolder(in parent: URL, named requestedName: String) async -> FileOperationReport {
        let cleanName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/") else {
            return FileOperationReport(kind: .createFolder, results: [result(source: parent, outcome: .failed, message: FileOperationError.invalidName.localizedDescription)])
        }
        var destination = parent.appendingPathComponent(cleanName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            var counter = 2
            repeat {
                destination = parent.appendingPathComponent("\(cleanName) (\(counter))", isDirectory: true)
                counter += 1
            } while fileManager.fileExists(atPath: destination.path)
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return FileOperationReport(kind: .createFolder, results: [result(source: parent, destination: destination, outcome: .succeeded)])
        } catch {
            return FileOperationReport(kind: .createFolder, results: [result(source: parent, destination: destination, outcome: .failed, message: error.localizedDescription)])
        }
    }

    func duplicate(_ sources: [URL], progress: ProgressHandler? = nil) async -> FileOperationReport {
        var results: [FileOperationItemResult] = []
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { break }
            await progress?(FileOperationProgress(completed: index, total: sources.count, currentItem: source))
            let destination = uniqueDuplicateURL(for: source)
            do {
                try fileManager.copyItem(at: source, to: destination)
                results.append(result(source: source, destination: destination, outcome: .succeeded))
            } catch {
                results.append(result(source: source, destination: destination, outcome: .failed, message: error.localizedDescription))
            }
        }
        await progress?(FileOperationProgress(completed: results.count, total: sources.count, currentItem: nil))
        return FileOperationReport(kind: .duplicate, results: results)
    }

    func compress(
        _ sources: [URL],
        progress: ProgressHandler? = nil
    ) async -> FileOperationReport {
        guard let first = sources.first else {
            return FileOperationReport(kind: .compress, results: [])
        }

        let directory = first.deletingLastPathComponent()
        let baseName = sources.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let destination = uniqueURL(for: directory.appendingPathComponent("\(baseName).zip"))
        let temporaryURL = directory.appendingPathComponent(".folder-archive-\(UUID().uuidString).zip")

        do {
            let entries = try archiveEntries(for: sources)
            try Task.checkCancellation()

            do {
                let archive = try Archive(url: temporaryURL, accessMode: .create)
                for (index, entry) in entries.enumerated() {
                    try Task.checkCancellation()
                    await progress?(FileOperationProgress(
                        completed: index,
                        total: entries.count,
                        currentItem: entry.fileURL
                    ))

                    let entryProgress = Progress(totalUnitCount: 1)
                    try await withTaskCancellationHandler {
                        try archive.addEntry(
                            with: entry.path,
                            fileURL: entry.fileURL,
                            compressionMethod: .deflate,
                            progress: entryProgress
                        )
                    } onCancel: {
                        entryProgress.cancel()
                    }
                }
            }

            try validateArchive(at: temporaryURL, expectedPaths: Set(entries.map(\.path)))
            try Task.checkCancellation()
            try fileManager.moveItem(at: temporaryURL, to: destination)
            await progress?(FileOperationProgress(completed: entries.count, total: entries.count, currentItem: nil))
            return FileOperationReport(kind: .compress, results: sources.map {
                result(source: $0, destination: destination, outcome: .succeeded)
            })
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            let cancelled = error is CancellationError || Task.isCancelled
            return FileOperationReport(kind: .compress, results: sources.map {
                result(
                    source: $0,
                    destination: destination,
                    outcome: cancelled ? .cancelled : .failed,
                    message: cancelled ? "Operation cancelled." : error.localizedDescription
                )
            })
        }
    }

    /// Rotation never overwrites the source. It writes a sibling temporary
    /// file, validates that output, and only then renames it to a visible copy.
    func rotateCopy(_ source: URL, quarterTurns: Int) async -> FileOperationReport {
        do {
            let destination = try SafeImageRotator.rotateCopy(
                at: source,
                quarterTurns: quarterTurns,
                fileManager: fileManager
            )
            return FileOperationReport(kind: .rotate, results: [result(source: source, destination: destination, outcome: .succeeded)])
        } catch {
            return FileOperationReport(kind: .rotate, results: [result(source: source, outcome: .failed, message: error.localizedDescription)])
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func uniqueDuplicateURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 1
        while true {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private struct ArchiveEntry {
        let fileURL: URL
        let path: String
    }

    private func archiveEntries(for sources: [URL]) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var usedRootNames: Set<String> = []

        for source in sources {
            try Task.checkCancellation()
            let rootName = uniqueArchiveRootName(for: source.lastPathComponent, usedNames: &usedRootNames)
            try appendArchiveEntries(from: source, path: rootName, to: &entries)
        }
        return entries
    }

    private func appendArchiveEntries(
        from fileURL: URL,
        path: String,
        to entries: inout [ArchiveEntry]
    ) throws {
        try Task.checkCancellation()
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        entries.append(ArchiveEntry(fileURL: fileURL, path: path))

        guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        let children = try fileManager.contentsOfDirectory(
            at: fileURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for child in children {
            try appendArchiveEntries(
                from: child,
                path: "\(path)/\(child.lastPathComponent)",
                to: &entries
            )
        }
    }

    private func uniqueArchiveRootName(for requestedName: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(requestedName) else {
            usedNames.insert(requestedName)
            return requestedName
        }

        let nameURL = URL(fileURLWithPath: requestedName)
        let stem = nameURL.deletingPathExtension().lastPathComponent
        let ext = nameURL.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    private func validateArchive(at url: URL, expectedPaths: Set<String>) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let actualPaths = Set(archive.map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        let normalizedExpected = Set(expectedPaths.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        })
        guard actualPaths == normalizedExpected else {
            throw FileOperationError.compressionFailed("The finished archive did not contain every selected item.")
        }
    }

    private func result(
        source: URL,
        destination: URL? = nil,
        outcome: FileOperationOutcome,
        message: String? = nil,
        replacedItemInTrash: URL? = nil
    ) -> FileOperationItemResult {
        FileOperationItemResult(
            source: source,
            destination: destination,
            outcome: outcome,
            message: message,
            replacedItemInTrash: replacedItemInTrash
        )
    }
}

enum SafeImageRotator {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    static func rotateCopy(at source: URL, quarterTurns: Int, fileManager: FileManager = .default) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw FileOperationError.unsupportedImageFormat(ext.isEmpty ? "unknown" : ext)
        }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(input),
              CGImageSourceGetCount(input) > 0 else {
            throw FileOperationError.unableToDecodeImage
        }

        let normalizedTurns = ((quarterTurns % 4) + 4) % 4
        guard normalizedTurns != 0 else { throw FileOperationError.unableToEncodeImage }

        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]) ?? [:]
        let sourceOrientationRaw = (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? CGImagePropertyOrientation.up.rawValue
        let destinationOrientation = rotatedOrientation(
            CGImagePropertyOrientation(rawValue: sourceOrientationRaw) ?? .up,
            clockwiseQuarterTurns: normalizedTurns
        )

        let finalURL = uniqueRotatedURL(for: source, fileManager: fileManager)
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".folder-rotation-\(UUID().uuidString).\(ext)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let output = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            sourceType,
            CGImageSourceGetCount(input),
            nil
        ) else {
            throw FileOperationError.unableToEncodeImage
        }

        var copyOptions: [CFString: Any] = [
            kCGImageDestinationOrientation: destinationOrientation.rawValue,
            kCGImageDestinationMergeMetadata: true
        ]
        if #available(macOS 14.0, *) {
            copyOptions[kCGImageDestinationPreserveGainMap] = true
        }

        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            output,
            input,
            copyOptions as CFDictionary,
            &copyError
        ) else {
            throw FileOperationError.unableToEncodeImage
        }

        let metadataFlags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        let metadataResult = source.path.withCString { sourcePath in
            temporaryURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, metadataFlags)
            }
        }
        guard metadataResult == 0 else {
            throw FileOperationError.unableToPreserveImageMetadata
        }

        guard let validation = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
              CGImageSourceGetCount(validation) == CGImageSourceGetCount(input),
              CGImageSourceCreateImageAtIndex(validation, 0, nil) != nil,
              let validationProperties = CGImageSourceCopyPropertiesAtIndex(validation, 0, nil) as? [CFString: Any] else {
            throw FileOperationError.unableToValidateOutput
        }
        let writtenOrientation = (validationProperties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        guard writtenOrientation == destinationOrientation.rawValue else {
            throw FileOperationError.unableToValidateOutput
        }
        guard metadataIsOtherwisePreserved(sourceProperties, validationProperties) else {
            throw FileOperationError.unableToValidateOutput
        }
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        return finalURL
    }

    /// Compose a visual clockwise rotation with the existing EXIF transform,
    /// including all mirrored orientations. The encoded pixels stay untouched.
    static func rotatedOrientation(
        _ orientation: CGImagePropertyOrientation,
        clockwiseQuarterTurns: Int
    ) -> CGImagePropertyOrientation {
        let clockwise: [CGImagePropertyOrientation: CGImagePropertyOrientation] = [
            .up: .right,
            .upMirrored: .rightMirrored,
            .down: .left,
            .downMirrored: .leftMirrored,
            .leftMirrored: .upMirrored,
            .right: .down,
            .rightMirrored: .downMirrored,
            .left: .up
        ]
        var result = orientation
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        for _ in 0..<turns {
            result = clockwise[result] ?? .up
        }
        return result
    }

    private static func metadataIsOtherwisePreserved(
        _ source: [CFString: Any],
        _ destination: [CFString: Any]
    ) -> Bool {
        metadataValue(
            removingOrientation(from: source),
            isPreservedIn: removingOrientation(from: destination)
        )
    }

    private static func metadataValue(_ source: Any, isPreservedIn destination: Any) -> Bool {
        if let sourceDictionary = source as? [String: Any],
           let destinationDictionary = destination as? [String: Any] {
            return sourceDictionary.allSatisfy { key, sourceValue in
                guard let destinationValue = destinationDictionary[key] else { return false }
                return metadataValue(sourceValue, isPreservedIn: destinationValue)
            }
        }
        if let sourceArray = source as? NSArray,
           let destinationArray = destination as? NSArray {
            return sourceArray.isEqual(to: destinationArray as! [Any])
        }
        if let sourceObject = source as? NSObject,
           let destinationObject = destination as? NSObject {
            return sourceObject.isEqual(destinationObject)
        }
        return String(describing: source) == String(describing: destination)
    }

    private static func removingOrientation(from dictionary: [CFString: Any]) -> [String: Any] {
        dictionary.reduce(into: [String: Any]()) { result, pair in
            let key = pair.key as String
            guard key.caseInsensitiveCompare(kCGImagePropertyOrientation as String) != .orderedSame,
                  key.caseInsensitiveCompare("Orientation") != .orderedSame else {
                return
            }
            if let nested = pair.value as? [CFString: Any] {
                result[key] = removingOrientation(from: nested)
            } else if let nested = pair.value as? [String: Any] {
                result[key] = removingOrientation(from: Dictionary(uniqueKeysWithValues: nested.map { ($0.key as CFString, $0.value) }))
            } else {
                result[key] = pair.value
            }
        }
    }

    private static func uniqueRotatedURL(for source: URL, fileManager: FileManager) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 1
        while true {
            let suffix = counter == 1 ? " rotated" : " rotated \(counter)"
            let candidate = directory.appendingPathComponent("\(stem)\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
