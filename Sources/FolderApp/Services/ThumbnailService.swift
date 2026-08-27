import Foundation
import AppKit
import QuickLookThumbnailing
import ImageIO

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

/// Service for generating thumbnails for images and PDFs
@MainActor
class ThumbnailService: ObservableObject {
    static let shared = ThumbnailService()

    // Cache for generated thumbnails
    private let cache = NSCache<NSString, NSImage>()

    // Supported image formats
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico", "icns"]

    // Supported document formats for thumbnails
    private let documentExtensions: Set<String> = ["pdf"]

    private init() {
        // Configure cache
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB
    }

    /// Check if a file supports thumbnail generation
    func supportsThumbnail(for path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(fileExtension) || documentExtensions.contains(fileExtension)
    }

    /// Get thumbnail for a file
    /// - Parameters:
    ///   - path: File path
    ///   - size: Desired thumbnail size
    /// - Returns: Thumbnail image or nil if generation fails
    func getThumbnail(for path: String, size: CGSize) async -> NSImage? {
        let cacheKey = "\(path)_\(Int(size.width))x\(Int(size.height))" as NSString

        // Check cache first
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let fileExtension = (path as NSString).pathExtension.lowercased()

        // Generate thumbnail based on file type
        var thumbnail: NSImage?

        if imageExtensions.contains(fileExtension) {
            thumbnail = await generateImageThumbnail(path: path, size: size)
        } else if documentExtensions.contains(fileExtension) {
            thumbnail = await generateQuickLookThumbnail(path: path, size: size)
        }

        // Cache the result
        if let thumbnail = thumbnail {
            cache.setObject(thumbnail, forKey: cacheKey)
        }

        return thumbnail
    }

    /// Generate thumbnail for image files using NSImage
    private func generateImageThumbnail(path: String, size: CGSize) async -> NSImage? {
        // Skip files larger than 100MB to avoid loading huge files into memory
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let fileSize = attrs[.size] as? Int64,
           fileSize > 100 * 1024 * 1024 {
            return await generateQuickLookThumbnail(path: path, size: size)
        }

        let image = await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil as SendableCGImage? }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 2)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return SendableCGImage(value: cgImage)
        }.value
        guard let image else { return nil }
        return NSImage(cgImage: image.value, size: size)
    }

    /// Generate thumbnail using Quick Look Thumbnailing service
    private func generateQuickLookThumbnail(path: URL, size: CGSize) async -> NSImage? {
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<SendableCGImage?, Never>) in
            let request = QLThumbnailGenerator.Request(
                fileAt: path,
                size: size,
                scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, type, error in
                if let thumbnail {
                    continuation.resume(returning: SendableCGImage(value: thumbnail.cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let image else { return nil }
        return NSImage(cgImage: image.value, size: size)
    }

    /// Generate thumbnail using Quick Look Thumbnailing service (path version)
    private func generateQuickLookThumbnail(path: String, size: CGSize) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        return await generateQuickLookThumbnail(path: url, size: size)
    }

    /// Clear the thumbnail cache
    func clearCache() {
        cache.removeAllObjects()
    }
}
