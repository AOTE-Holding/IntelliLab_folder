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

@Test @MainActor func deletingWaitsForConfirmation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: file)
    let coordinator = FileOperationCoordinator(service: FileOperationService())

    coordinator.moveToTrash([file])
    #expect(coordinator.pendingDeletion?.permanently == false)
    #expect(FileManager.default.fileExists(atPath: file.path))
    coordinator.cancelPendingDeletion()

    coordinator.deletePermanently([file])
    #expect(coordinator.pendingDeletion?.permanently == true)
    #expect(FileManager.default.fileExists(atPath: file.path))
    coordinator.cancelPendingDeletion()
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func permanentDeletionRemovesTheFileWithoutTrashDestination() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("delete-me.txt")
    try Data("temporary".utf8).write(to: file)

    let report = await FileOperationService().deletePermanently([file])

    #expect(report.kind == .deletePermanently)
    #expect(report.allSucceeded)
    #expect(report.succeeded.first?.destination == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
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

@Test func createFileUsesTheEnteredExtensionAndNeverOverwritesAnExistingFile() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = FileOperationService()

    let created = await service.createFile(in: root, named: "notes.md")
    #expect(created.allSucceeded)
    let file = root.appendingPathComponent("notes.md")
    #expect(try Data(contentsOf: file).isEmpty)

    try Data("keep".utf8).write(to: file)
    let collision = await service.createFile(in: root, named: "notes.md")
    #expect(collision.failed.count == 1)
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
}

@Test func createFileRequiresANameAndExtension() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    for name in ["notes", ".hidden", "notes.", "../escape.txt"] {
        let report = await FileOperationService().createFile(in: root, named: name)
        #expect(report.failed.count == 1)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func cancellingParallelDuplicateKeepsEveryItemAccountedFor() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = ["first.txt", "second.txt"].map { root.appendingPathComponent($0) }
    for source in sources { try Data("content".utf8).write(to: source) }

    let operation = Task {
        await FileOperationService().duplicate(sources) { progress in
            if progress.completed == 0 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    let report = await operation.value

    // Duplicates begin together. A small file may finish before cancellation
    // reaches the task group, but no selected item may disappear from the report.
    #expect(report.results.count == sources.count)
    #expect(Set(report.results.map(\.source)) == Set(sources))
    #expect(report.results.allSatisfy { $0.outcome == .succeeded || $0.outcome == .cancelled })
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

    let rotated = try SafeImageRotator.rotateInPlace(at: source, quarterTurns: 1)
    #expect(rotated == source)
    let properties = try imageProperties(at: source)
    let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])

    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == CGImagePropertyOrientation.right.rawValue)
    #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "IntelliLab Metadata Test")
    #expect(exif[kCGImagePropertyExifUserComment] as? String == "Preserve this exact comment")
    #expect((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue == 47.3769)
    #expect(try decodedPixelBytes(at: source) == sourcePixels)

    let rotatedAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    #expect(rotatedAttributes[.creationDate] as? Date == fixedDate)
    #expect(rotatedAttributes[.modificationDate] as? Date == fixedDate)
    #expect(rotatedAttributes[.posixPermissions] as? NSNumber == 0o640)
    #expect(try extendedAttribute(named: "com.intellilab.folder.rotation-test", at: source) == expectedExtendedAttribute)
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

@Test func batchRotationProcessesImagesAndReportsUnsupportedFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.jpg")
    let second = root.appendingPathComponent("second.jpg")
    let svg = root.appendingPathComponent("vector.svg")
    let pdf = root.appendingPathComponent("document.pdf")
    try writeMetadataTestJPEG(to: first)
    try writeMetadataTestJPEG(to: second)
    let unrecognizedExtension = root.appendingPathComponent("photo.unknown")
    try FileManager.default.copyItem(at: first, to: unrecognizedExtension)
    #expect(ImagePreviewSupport.isImage(unrecognizedExtension))
    let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\" viewBox=\"0 0 40 20\"><rect width=\"20\" height=\"20\" fill=\"red\"/><rect x=\"20\" width=\"20\" height=\"20\" fill=\"blue\"/></svg>".utf8)
    try svgData.write(to: svg)
    try Data("PDF placeholder".utf8).write(to: pdf)

    let report = await FileOperationService().rotate([first, svg, second, pdf], quarterTurns: 1)

    #expect(report.succeeded.map(\.source) == [first, svg, second])
    #expect(report.skipped.map(\.source) == [pdf])
    #expect(report.failed.isEmpty)
    let rotatedSVG = try XMLDocument(contentsOf: svg, options: [])
    #expect(rotatedSVG.rootElement()?.attribute(forName: "viewBox")?.stringValue == "0 0 20.0 40.0")
    #expect(rotatedSVG.rootElement()?.attribute(forName: "width")?.stringValue == "20")
    #expect(rotatedSVG.rootElement()?.attribute(forName: "height")?.stringValue == "40")
    #expect(rotatedSVG.rootElement()?.elements(forName: "g").first?.attribute(forName: "transform")?.stringValue == "matrix(0 1 -1 0 20.0 -0.0)")
    #expect(NSImage(contentsOf: svg) != nil)
    #expect((try imageProperties(at: first)[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == CGImagePropertyOrientation.right.rawValue)
    #expect((try imageProperties(at: second)[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == CGImagePropertyOrientation.right.rawValue)
}

@Test func rotationKeepsGIFFramesAndBMPFormat() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gif = root.appendingPathComponent("animation.gif")
    let bmp = root.appendingPathComponent("picture.bmp")
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
    ))
    bitmap.setColor(.red, atX: 0, y: 0)
    let gifFixture = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAFAAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEAR4AAQAsAAAAAAQAAgCBAAD/AAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gifFixture.write(to: gif)
    let originalGIF = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    #expect(CGImageSourceGetCount(originalGIF) == 2)
    let bmpData = try #require(bitmap.representation(using: .bmp, properties: [:]))
    try bmpData.write(to: bmp)

    _ = try SafeImageRotator.rotateInPlace(at: gif, quarterTurns: 1)
    _ = try SafeImageRotator.rotateInPlace(at: bmp, quarterTurns: -1)
    let gifSource = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    let bmpSource = try #require(CGImageSourceCreateWithURL(bmp as CFURL, nil))
    #expect(CGImageSourceGetCount(gifSource) == 2)
    #expect(CGImageSourceGetType(gifSource) as String? == "com.compuserve.gif")
    #expect(CGImageSourceGetType(bmpSource) as String? == "com.microsoft.bmp")
    #expect(CGImageSourceCreateImageAtIndex(gifSource, 0, nil)?.width == 2)
    #expect(CGImageSourceCreateImageAtIndex(gifSource, 0, nil)?.height == 4)
    let gifFrame = try #require(CGImageSourceCopyPropertiesAtIndex(gifSource, 0, nil) as? [CFString: Any])
    let gifProperties = try #require(gifFrame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
    #expect((gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue == 0.2)
    #expect(CGImageSourceCreateImageAtIndex(bmpSource, 0, nil)?.width == 2)
    #expect(CGImageSourceCreateImageAtIndex(bmpSource, 0, nil)?.height == 4)
}

@Test func svgRightRotationMovesLeftHalfToTop() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let svg = root.appendingPathComponent("direction.svg")
    let leftSVG = root.appendingPathComponent("left-direction.svg")
    try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\" viewBox=\"0 0 40 20\"><rect width=\"20\" height=\"20\" fill=\"red\"/><rect x=\"20\" width=\"20\" height=\"20\" fill=\"blue\"/></svg>".utf8).write(to: svg)
    try FileManager.default.copyItem(at: svg, to: leftSVG)
    _ = try SafeImageRotator.rotateInPlace(at: svg, quarterTurns: 1)
    _ = try SafeImageRotator.rotateInPlace(at: leftSVG, quarterTurns: -1)
    func sample(_ file: URL, atY y: Int) throws -> NSColor {
        let image = try #require(NSImage(contentsOf: file))
        let output = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 80, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: output))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 40), from: .zero,
                   operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(output.colorAt(x: 10, y: y)?.usingColorSpace(.deviceRGB))
    }
    let svgTop = try sample(svg, atY: 5)
    let svgBottom = try sample(svg, atY: 35)
    let leftTop = try sample(leftSVG, atY: 5)
    let leftBottom = try sample(leftSVG, atY: 35)
    #expect(svgTop.redComponent > svgTop.blueComponent)
    #expect(svgBottom.blueComponent > svgBottom.redComponent)
    #expect(leftTop.blueComponent > leftTop.redComponent)
    #expect(leftBottom.redComponent > leftBottom.blueComponent)
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
