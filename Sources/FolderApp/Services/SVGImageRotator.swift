import AppKit
import Darwin
import Foundation

/// Rotates SVG coordinates while keeping the file vector based and in place.
enum SVGImageRotator {
    static func rotateInPlace(at source: URL, quarterTurns: Int, fileManager: FileManager = .default) throws -> URL {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { throw FileOperationError.unableToEncodeImage }

        let document = try XMLDocument(data: Data(contentsOf: source), options: .nodePreserveAll)
        guard let root = document.rootElement(), root.localName == "svg" || root.name == "svg" else {
            throw FileOperationError.unableToDecodeImage
        }

        let bounds: (Double, Double, Double, Double)
        if let viewBox = root.attribute(forName: "viewBox")?.stringValue {
            let values = viewBox.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
            guard values.count == 4 else { throw FileOperationError.unableToDecodeImage }
            bounds = (values[0], values[1], values[2], values[3])
        } else if let width = coordinate(root.attribute(forName: "width")?.stringValue),
                  let height = coordinate(root.attribute(forName: "height")?.stringValue) {
            bounds = (0, 0, width, height)
        } else {
            throw FileOperationError.unableToDecodeImage
        }
        let (x, y, width, height) = bounds
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
            throw FileOperationError.unableToDecodeImage
        }

        let transform: String
        switch turns {
        case 1: transform = "matrix(0 1 -1 0 \(y + height) \(-x))"
        case 2: transform = "matrix(-1 0 0 -1 \(x + width) \(y + height))"
        default: transform = "matrix(0 -1 1 0 \(-y) \(x + width))"
        }

        let group = XMLElement(name: "g")
        group.addAttribute(XMLNode.attribute(withName: "transform", stringValue: transform) as! XMLNode)
        for child in root.children ?? [] {
            child.detach()
            group.addChild(child)
        }
        root.addChild(group)
        let outputWidth = turns.isMultiple(of: 2) ? width : height
        let outputHeight = turns.isMultiple(of: 2) ? height : width
        setAttribute("viewBox", "0 0 \(outputWidth) \(outputHeight)", on: root)

        if turns.isMultiple(of: 2) == false {
            let oldWidth = root.attribute(forName: "width")?.stringValue
            let oldHeight = root.attribute(forName: "height")?.stringValue
            root.removeAttribute(forName: "width")
            root.removeAttribute(forName: "height")
            if let oldHeight { setAttribute("width", oldHeight, on: root) }
            if let oldWidth { setAttribute("height", oldWidth, on: root) }
        }

        let temporaryURL = source.deletingLastPathComponent()
            .appendingPathComponent(".folder-rotation-\(UUID().uuidString).svg")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try document.xmlData(options: .nodePreserveAll).write(to: temporaryURL)

        let metadataFlags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        _ = source.path.withCString { sourcePath in
            temporaryURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, metadataFlags)
            }
        }
        guard let validation = try? XMLDocument(contentsOf: temporaryURL, options: []),
              validation.rootElement()?.localName == "svg",
              NSImage(contentsOf: temporaryURL) != nil else {
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

    private static func coordinate(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
        return Double(number)
    }

    private static func setAttribute(_ name: String, _ value: String, on element: XMLElement) {
        element.removeAttribute(forName: name)
        element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }
}
