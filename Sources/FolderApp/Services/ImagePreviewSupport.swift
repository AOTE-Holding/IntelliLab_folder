import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImagePreviewSupport {
    // Launch Services may return a dynamic type in fresh/test accounts, so
    // retain a small baseline for the formats macOS commonly decodes.
    private static let knownImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif",
        "webp", "ico", "icns", "jp2", "j2k", "psd", "raw", "dng", "avif"
    ]

    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "svg" || knownImageExtensions.contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            return true
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    /// Quick Look treats SVG source as text on some macOS installations. Give
    /// the panel a rendered image so it uses the same image transition as JPG
    /// and PNG previews, including the source tile's opening animation.
    static func createSVGPreview(for source: URL, in directory: URL) -> URL? {
        guard source.pathExtension.lowercased() == "svg" else { return nil }
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= 20_000_000,
              let data = try? Data(contentsOf: source, options: .mappedIfSafe) else {
            return writeHTML("<p>This SVG image could not be read or exceeds the 20 MB preview limit.</p>", in: directory)
        }

        guard let document = try? XMLDocument(data: data),
              document.rootElement()?.name?.split(separator: ":").last == "svg" else {
            return writeHTML("<p>This SVG image is invalid and cannot be displayed.</p>", in: directory)
        }

        guard let image = NSImage(contentsOf: source),
              image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else {
            return writeHTML("<p>This SVG image could not be rendered.</p>", in: directory)
        }

        let longestSide = max(image.size.width, image.size.height)
        let scale = 650 / longestSide
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

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            try png.write(to: output, options: .atomic)
            return output
        } catch {
            return nil
        }
    }

    private static func writeHTML(_ html: String, in directory: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("html")
            try Data(html.utf8).write(to: output, options: .atomic)
            return output
        } catch {
            return nil
        }
    }
}
