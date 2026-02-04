//
//  FileSystemService.swift
//  Folder
//
//  Service for interacting with the file system
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Error Types

enum CompressionError: Error {
    case noItemsToCompress
    case compressionFailed
}

enum ImageError: Error {
    case unableToLoadImage
    case unableToCreateContext
    case unableToCreateRotatedImage
    case unableToCreateBitmapRep
    case unableToCreateImageData
}

@MainActor
class FileSystemService: ObservableObject {
    static let shared = FileSystemService()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Directory Reading

    /// Read contents of a directory and return FileSystemItems
    func contentsOfDirectory(at url: URL, showHidden: Bool = false) throws -> [FileSystemItem] {
        var items: [FileSystemItem] = []

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isHiddenKey
            ],
            options: []
        )

        for itemURL in contents {
            // Skip hidden files if not showing them
            if !showHidden {
                let resourceValues = try? itemURL.resourceValues(forKeys: [.isHiddenKey])
                if resourceValues?.isHidden == true || itemURL.lastPathComponent.hasPrefix(".") {
                    continue
                }
            }

            // Create FileSystemItem
            if let item = try? FileSystemItem(from: itemURL) {
                items.append(item)
            }
        }

        return items.sorted()
    }

    // MARK: - Navigation Helpers

    /// Check if a path exists and is accessible
    func pathExists(_ url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    /// Get parent directory of a URL
    func parentDirectory(of url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        return parent.path != url.path ? parent : nil
    }

    /// Get home directory
    func homeDirectory() -> URL {
        return fileManager.homeDirectoryForCurrentUser
    }

    // MARK: - File Operations

    /// Move item to trash
    func moveToTrash(_ url: URL) throws {
        var trashedURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
    }

    /// Copy item to destination
    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Move item to destination
    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Rename item
    func renameItem(at url: URL, to newName: String) throws {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: url, to: newURL)
    }

    /// Create new folder
    func createFolder(at url: URL, named name: String) throws {
        let folderURL = url.appendingPathComponent(name)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false, attributes: nil)
    }

    // MARK: - Path Validation

    /// Validate and resolve a path string to URL
    func resolveURL(from pathString: String) -> URL? {
        // Expand tilde
        let expandedPath = NSString(string: pathString).expandingTildeInPath

        // Create URL
        let url = URL(fileURLWithPath: expandedPath)

        // Check if exists
        guard pathExists(url) else {
            return nil
        }

        return url
    }

    // MARK: - Folder Size Calculation

    /// Calculate total size of a folder recursively
    func calculateFolderSize(at url: URL) async throws -> Int64 {
        var totalSize: Int64 = 0

        // Get directory enumerator
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            // Check for cancellation
            if Task.isCancelled {
                throw CancellationError()
            }

            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])

            // Only add file sizes (not directories themselves)
            if resourceValues.isDirectory == false {
                totalSize += Int64(resourceValues.fileSize ?? 0)
            }
        }

        return totalSize
    }

    // MARK: - Duplicate, Compress, Rotate Operations

    /// Duplicate a file or folder with " copy" suffix
    func duplicateItem(at url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 1
        var newURL: URL

        repeat {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let newFilename = ext.isEmpty ? "\(filename)\(suffix)" : "\(filename)\(suffix).\(ext)"
            newURL = directory.appendingPathComponent(newFilename)
            counter += 1
        } while fileManager.fileExists(atPath: newURL.path)

        try fileManager.copyItem(at: url, to: newURL)
        return newURL
    }

    /// Compress files/folders into a .zip archive
    func compressItems(at urls: [URL]) throws -> URL {
        guard !urls.isEmpty else { throw CompressionError.noItemsToCompress }

        let directory = urls[0].deletingLastPathComponent()
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        var archiveURL = directory.appendingPathComponent("\(baseName).zip")

        // Ensure unique name
        var counter = 2
        while fileManager.fileExists(atPath: archiveURL.path) {
            archiveURL = directory.appendingPathComponent("\(baseName) \(counter).zip")
            counter += 1
        }

        // Use /usr/bin/zip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-r", archiveURL.lastPathComponent] + urls.map { $0.lastPathComponent }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CompressionError.compressionFailed
        }

        return archiveURL
    }

    /// Rotate image by 90 degrees (positive = clockwise, negative = counter-clockwise)
    func rotateImage(at url: URL, degrees: CGFloat) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw ImageError.unableToLoadImage
        }

        let originalSize = image.size
        // Swap dimensions for 90 degree rotations
        let rotatedSize = NSSize(width: originalSize.height, height: originalSize.width)

        // Create rotated image
        let rotatedImage = NSImage(size: rotatedSize)
        rotatedImage.lockFocus()

        let transform = NSAffineTransform()
        transform.translateX(by: rotatedSize.width / 2, yBy: rotatedSize.height / 2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -originalSize.width / 2, yBy: -originalSize.height / 2)
        transform.concat()

        image.draw(at: .zero, from: NSRect(origin: .zero, size: originalSize), operation: .copy, fraction: 1.0)
        rotatedImage.unlockFocus()

        // Get bitmap representation
        guard let tiffData = rotatedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw ImageError.unableToCreateBitmapRep
        }

        let ext = url.pathExtension.lowercased()
        let imageData: Data?
        switch ext {
        case "jpg", "jpeg":
            imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case "png":
            imageData = bitmap.representation(using: .png, properties: [:])
        case "gif":
            imageData = bitmap.representation(using: .gif, properties: [:])
        case "bmp":
            imageData = bitmap.representation(using: .bmp, properties: [:])
        case "tiff", "tif":
            imageData = bitmap.representation(using: .tiff, properties: [:])
        default:
            imageData = bitmap.representation(using: .png, properties: [:])
        }

        guard let data = imageData else { throw ImageError.unableToCreateImageData }
        try data.write(to: url)
    }
}

