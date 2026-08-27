import Foundation
import AppKit
import Darwin
import ImageIO
import Testing
import ZIPFoundation
@testable import FolderApp

@Test func aFolderCannotBeDroppedIntoItselfOrOneOfItsChildren() {
    let source = URL(fileURLWithPath: "/Volumes/Drive/Folder", isDirectory: true)

    #expect(FileDropValidation.isInvalidContainment(source: source, destination: source))
    #expect(FileDropValidation.isInvalidContainment(
        source: source,
        destination: source.appendingPathComponent("Child", isDirectory: true)
    ))
    #expect(!FileDropValidation.isInvalidContainment(
        source: source,
        destination: URL(fileURLWithPath: "/Volumes/Drive/Other", isDirectory: true)
    ))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func conflictSkipPreservesExistingDestination() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFolder = root.appendingPathComponent("source")
    let destinationFolder = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    let source = sourceFolder.appendingPathComponent("note.txt")
    let destination = destinationFolder.appendingPathComponent("note.txt")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)

    let report = await FileOperationService().transfer(
        [source], to: destinationFolder, kind: .copy, conflictResolution: .skip
    )

    #expect(report.skipped.count == 1)
    #expect(String(data: try Data(contentsOf: destination), encoding: .utf8) == "existing")
}

@Test func keepBothCreatesUniqueCopy() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFolder = root.appendingPathComponent("source")
    let destinationFolder = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    let source = sourceFolder.appendingPathComponent("note.txt")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destinationFolder.appendingPathComponent("note.txt"))

    let report = await FileOperationService().transfer(
        [source], to: destinationFolder, kind: .copy, conflictResolution: .keepBoth
    )

    #expect(report.allSucceeded)
    #expect(report.succeeded.first?.destination?.lastPathComponent == "note (2).txt")
}

@Test func createFolderUsesUniqueFinderStyleName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Untitled Folder"), withIntermediateDirectories: false)

    let report = await FileOperationService().createFolder(in: root, named: "Untitled Folder")

    #expect(report.allSucceeded)
    #expect(report.succeeded.first?.destination?.lastPathComponent == "Untitled Folder (2)")
}

@Test func compressionCreatesOneValidatedArchiveForMultipleItems() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let folder = root.appendingPathComponent("Notes", isDirectory: true)
    let nested = folder.appendingPathComponent("nested.txt")
    try Data("one".utf8).write(to: first)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data("two".utf8).write(to: nested)

    let report = await FileOperationService().compress([first, folder])

    #expect(report.allSucceeded)
    let archiveURL = try #require(report.succeeded.first?.destination)
    let archive = try Archive(url: archiveURL, accessMode: .read)
    let paths = Set(archive.map(\.path))
    #expect(paths.contains("first.txt"))
    #expect(paths.contains("Notes/"))
    #expect(paths.contains("Notes/nested.txt"))
}

@Test func rotationPreservesPixelsPhotoMetadataAndFileDates() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("metadata.jpg")
    try writeMetadataTestJPEG(to: source)

    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
        [.creationDate: fixedDate, .modificationDate: fixedDate, .posixPermissions: 0o640],
        ofItemAtPath: source.path
    )
    let expectedExtendedAttribute = Data("preserve-xattr".utf8)
    try setExtendedAttribute(expectedExtendedAttribute, named: "com.intellilab.folder.rotation-test", at: source)
    let sourcePixels = try decodedPixelBytes(at: source)

    let rotated = try SafeImageRotator.rotateCopy(at: source, quarterTurns: 1)
    let properties = try imageProperties(at: rotated)
    let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])

    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == CGImagePropertyOrientation.right.rawValue)
    #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "IntelliLab Metadata Test")
    #expect(exif[kCGImagePropertyExifUserComment] as? String == "Preserve this exact comment")
    #expect((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 47.3769)
    #expect(try decodedPixelBytes(at: rotated) == sourcePixels)

    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let rotatedAttributes = try FileManager.default.attributesOfItem(atPath: rotated.path)
    #expect(sourceAttributes[.creationDate] as? Date == rotatedAttributes[.creationDate] as? Date)
    #expect(sourceAttributes[.modificationDate] as? Date == rotatedAttributes[.modificationDate] as? Date)
    #expect(sourceAttributes[.posixPermissions] as? NSNumber == rotatedAttributes[.posixPermissions] as? NSNumber)
    #expect(try extendedAttribute(named: "com.intellilab.folder.rotation-test", at: rotated) == expectedExtendedAttribute)
}

@Test func rotationComposesEveryExifOrientationWithoutTouchingPixels() {
    let clockwiseExpected: [CGImagePropertyOrientation: CGImagePropertyOrientation] = [
        .up: .right,
        .upMirrored: .rightMirrored,
        .down: .left,
        .downMirrored: .leftMirrored,
        .leftMirrored: .upMirrored,
        .right: .down,
        .rightMirrored: .downMirrored,
        .left: .up
    ]

    for (source, expected) in clockwiseExpected {
        #expect(SafeImageRotator.rotatedOrientation(source, clockwiseQuarterTurns: 1) == expected)
        #expect(SafeImageRotator.rotatedOrientation(source, clockwiseQuarterTurns: 4) == source)
    }
}

private func writeMetadataTestJPEG(to url: URL) throws {
    let representation = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 8,
        bitsPerPixel: 32
    ))
    representation.setColor(.red, atX: 0, y: 0)
    representation.setColor(.blue, atX: 1, y: 0)
    let image = try #require(representation.cgImage)
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.jpeg" as CFString,
        1,
        nil
    ))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFArtist: "IntelliLab Metadata Test",
            kCGImagePropertyTIFFSoftware: "Folder Tests"
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "Preserve this exact comment"
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 47.3769,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 8.5417,
            kCGImagePropertyGPSLongitudeRef: "E"
        ],
        kCGImageDestinationLossyCompressionQuality: 0.82
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw FileOperationError.unableToEncodeImage
    }
}

private func imageProperties(at url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private func decodedPixelBytes(at url: URL) throws -> Data {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, [
        kCGImageSourceShouldCache: false
    ] as CFDictionary))
    let data = try #require(image.dataProvider?.data)
    return data as Data
}

private func setExtendedAttribute(_ data: Data, named name: String, at url: URL) throws {
    let result = url.path.withCString { path in
        name.withCString { attributeName in
            data.withUnsafeBytes { bytes in
                setxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
    }
    guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func extendedAttribute(named name: String, at url: URL) throws -> Data {
    let size = url.path.withCString { path in
        name.withCString { attributeName in
            getxattr(path, attributeName, nil, 0, 0, 0)
        }
    }
    guard size >= 0 else { throw CocoaError(.fileReadUnknown) }
    var data = Data(count: size)
    let result = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            name.withCString { attributeName in
                getxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
    }
    guard result == size else { throw CocoaError(.fileReadUnknown) }
    return data
}
