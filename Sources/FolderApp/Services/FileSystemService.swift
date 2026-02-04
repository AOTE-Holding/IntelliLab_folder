//
//  FileSystemService.swift
//  Folder
//
//  Service for interacting with the file system
//

import Foundation
import AppKit
import CoreGraphics
import CoreImage

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
        // Load image as CIImage
        guard let ciImage = CIImage(contentsOf: url) else {
            throw ImageError.unableToLoadImage
        }

        // Create rotation transform (Core Image uses radians, clockwise is negative)
        let radians = -degrees * .pi / 180
        let transform = CGAffineTransform(rotationAngle: radians)

        // Apply rotation
        var rotatedImage = ciImage.transformed(by: transform)

        // After rotation, the image origin may be negative - translate to origin
        let originX = rotatedImage.extent.origin.x
        let originY = rotatedImage.extent.origin.y
        rotatedImage = rotatedImage.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))

        // Create CIContext for rendering
        let context = CIContext(options: [.useSoftwareRenderer: false])

        // Determine output format and save
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "jpg", "jpeg":
            guard let colorSpace = rotatedImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let jpegData = context.jpegRepresentation(of: rotatedImage, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else {
                throw ImageError.unableToCreateImageData
            }
            try jpegData.write(to: url)

        case "png":
            guard let colorSpace = rotatedImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let pngData = context.pngRepresentation(of: rotatedImage, format: .RGBA8, colorSpace: colorSpace) else {
                throw ImageError.unableToCreateImageData
            }
            try pngData.write(to: url)

        case "heic", "heif":
            guard let colorSpace = rotatedImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let heicData = context.heifRepresentation(of: rotatedImage, format: .RGBA8, colorSpace: colorSpace) else {
                throw ImageError.unableToCreateImageData
            }
            try heicData.write(to: url)

        default:
            // Fallback: render to CGImage and save as PNG
            guard let cgImage = context.createCGImage(rotatedImage, from: rotatedImage.extent) else {
                throw ImageError.unableToCreateRotatedImage
            }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw ImageError.unableToCreateImageData
            }
            try pngData.write(to: url)
        }
    }
}

