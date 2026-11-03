import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// ImageIO can decode and encode these formats without changing the extension.
/// Every frame is rotated so animated GIFs and multi-size icons stay complete.
enum ReencodedImageRotator {
    static let supportedExtensions: Set<String> = ["bmp", "gif", "ico", "icns", "jp2", "j2k"]

    static func rotateInPlace(at source: URL, quarterTurns: Int, fileManager: FileManager = .default) throws -> URL {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { throw FileOperationError.unableToEncodeImage }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(input),
              (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type as String) == true,
              CGImageSourceGetCount(input) > 0 else {
            throw FileOperationError.unableToDecodeImage
        }

        let temporaryURL = source.deletingLastPathComponent()
            .appendingPathComponent(".folder-rotation-\(UUID().uuidString).\(source.pathExtension)")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let count = CGImageSourceGetCount(input)
        guard let output = CGImageDestinationCreateWithURL(temporaryURL as CFURL, type, count, nil) else {
            throw FileOperationError.unableToEncodeImage
        }
        if let properties = CGImageSourceCopyProperties(input, nil) {
            CGImageDestinationSetProperties(output, properties)
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(input, index, nil),
                  let rotated = rotate(image, turns: turns) else {
                throw FileOperationError.unableToDecodeImage
            }
            var properties = (CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any]) ?? [:]
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
            properties[kCGImagePropertyOrientation] = 1
            CGImageDestinationAddImage(output, rotated, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(output) else { throw FileOperationError.unableToEncodeImage }

        let metadataFlags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        _ = source.path.withCString { sourcePath in
            temporaryURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, metadataFlags)
            }
        }
        guard let validation = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
              CGImageSourceGetType(validation) == type,
              CGImageSourceGetCount(validation) == count,
              (0..<count).allSatisfy({ CGImageSourceCreateImageAtIndex(validation, $0, nil) != nil }) else {
            throw FileOperationError.unableToValidateOutput
        }
        let replacementResult = temporaryURL.path.withCString { temporaryPath in
            source.path.withCString { sourcePath in rename(temporaryPath, sourcePath) }
        }
        guard replacementResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "The rotated image could not replace the original file."])
        }
        return source
    }

    private static func rotate(_ image: CGImage, turns: Int) -> CGImage? {
        let width = turns.isMultiple(of: 2) ? image.width : image.height
        let height = turns.isMultiple(of: 2) ? image.height : image.width
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch turns {
        case 1:
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
            context.rotate(by: .pi)
        default:
            context.translateBy(x: 0, y: CGFloat(image.width))
            context.rotate(by: -.pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
