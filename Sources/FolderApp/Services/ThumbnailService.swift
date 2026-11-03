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
    /// Advances whenever a file has been changed in place. Including this in
    /// the cache key prevents an in-flight old decode from being reused after
    /// a rotation has completed.
    @Published private(set) var cacheGeneration: UInt = 0
    @Published private(set) var invalidatedThumbnailPaths: Set<String> = []

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
        return ImagePreviewSupport.isImage(URL(fileURLWithPath: path)) || documentExtensions.contains(fileExtension)
    }

    /// Get thumbnail for a file
    /// - Parameters:
    ///   - path: File path
    ///   - size: Desired thumbnail size
    /// - Returns: Thumbnail image or nil if generation fails
    func getThumbnail(for path: String, size: CGSize) async -> NSImage? {
        let generation = cacheGeneration
        let cacheKey = "\(generation)_\(path)_\(Int(size.width))x\(Int(size.height))" as NSString

        // Check cache first
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let fileExtension = (path as NSString).pathExtension.lowercased()

        // Generate thumbnail based on file type
        var thumbnail: NSImage?

        if ImagePreviewSupport.isImage(URL(fileURLWithPath: path)) {
            thumbnail = await generateImageThumbnail(path: path, size: size)
                ?? generateVectorThumbnail(path: path, size: size)
            if thumbnail == nil {
                thumbnail = await generateQuickLookThumbnail(path: path, size: size)
            }
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
        return NSImage(
            cgImage: image.value,
            size: NSSize(width: image.value.width, height: image.value.height)
        )
    }

    private func generateVectorThumbnail(path: String, size: CGSize) -> NSImage? {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "svg",
              let image = NSImage(contentsOfFile: path),
              image.isValid,
              image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else { return nil }

        // The same thumbnail is passed to Quick Look as its transition image.
        // Returning the source NSImage here exposes the SVG's intrinsic size
        // (often 1024 pt or more), which makes the opening transition expand
        // from a huge image instead of the visible file tile.
        let maxSide = max(size.width, size.height) * 2
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
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
        return NSImage(
            cgImage: image.value,
            size: NSSize(width: image.value.width, height: image.value.height)
        )
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

    /// Invalidates a changed file immediately. Existing views observe the
    /// generation and request a fresh thumbnail without needing to be closed,
    /// reselected or recreated.
    func invalidateThumbnail(for path: String) {
        invalidateThumbnails(for: [path])
    }

    func invalidateThumbnails(for paths: [String]) {
        guard !paths.isEmpty else { return }
        cache.removeAllObjects()
        invalidatedThumbnailPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        cacheGeneration &+= 1
    }
}
