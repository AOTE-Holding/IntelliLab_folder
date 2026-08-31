//
//  FileSystemItem.swift
//  Folder
//
//  Core data model for files and folders
//

import Foundation

struct FileSystemItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let path: URL
    var name: String
    let type: FileType
    let size: Int64  // bytes, 0 for folders
    let modifiedAt: Date
    let createdAt: Date
    var tags: [UUID]  // References to Tag.id
    var isFavorite: Bool
    var isRecent: Bool
    let parentPath: URL?
    let isSymlink: Bool
    /// Der Finder-Farb-Tag der Datei. Wird beim Einlesen des Ordners
    /// mitgenommen — ein zweiter Gang auf die Platte pro Kachel wäre bei
    /// tausend Dateien teuer.
    var colorTag: ColorTag.TagColor?

    enum FileType: String, Codable, Sendable {
        case file
        case folder
        case symlink
    }

    // Computed property for icon name
    var iconName: String {
        switch type {
        case .folder:
            return "folder.fill"
        case .symlink:
            return "link"
        case .file:
            return "doc.fill"
        }
    }

    // Initialize from URL using FileManager
    init(from url: URL, fileManager: FileManager = .default) throws {
        self.id = UUID()
        self.path = url
        self.name = url.lastPathComponent
        self.parentPath = url.deletingLastPathComponent()
        self.tags = []
        self.isFavorite = false
        self.isRecent = false

        // Get file attributes
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .labelNumberKey
        ])

        self.colorTag = FinderTagService.color(forLabelNumber: resourceValues.labelNumber)

        // Determine type
        if resourceValues.isSymbolicLink == true {
            self.type = .symlink
            self.isSymlink = true
        } else if resourceValues.isDirectory == true {
            self.type = .folder
            self.isSymlink = false
        } else {
            self.type = .file
            self.isSymlink = false
        }

        // Set size (0 for folders)
        self.size = self.type == .folder ? 0 : (resourceValues.fileSize.map { Int64($0) } ?? 0)

        // Set dates
        self.modifiedAt = resourceValues.contentModificationDate ?? Date()
        self.createdAt = resourceValues.creationDate ?? Date()
    }

    // Manual initializer for testing or custom creation
    init(
        id: UUID = UUID(),
        path: URL,
        name: String,
        type: FileType,
        size: Int64 = 0,
        modifiedAt: Date = Date(),
        createdAt: Date = Date(),
        tags: [UUID] = [],
        isFavorite: Bool = false,
        isRecent: Bool = false,
        parentPath: URL? = nil,
        isSymlink: Bool = false,
        colorTag: ColorTag.TagColor? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.tags = tags
        self.isFavorite = isFavorite
        self.isRecent = isRecent
        self.parentPath = parentPath
        self.isSymlink = isSymlink
        self.colorTag = colorTag
    }

    /// Directory enumerations create fresh value objects. Preserve the ID of
    /// an item already visible at the same path so SwiftUI does not tear down
    /// and rebuild every row/tile on a background watcher refresh.
    func preservingIdentity(_ stableID: UUID) -> FileSystemItem {
        FileSystemItem(
            id: stableID,
            path: path,
            name: name,
            type: type,
            size: size,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            tags: tags,
            isFavorite: isFavorite,
            isRecent: isRecent,
            parentPath: parentPath,
            isSymlink: isSymlink,
            colorTag: colorTag
        )
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Comparable for sorting
extension FileSystemItem: Comparable {
    static func < (lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        // Folders come before files
        if lhs.type == .folder && rhs.type != .folder {
            return true
        }
        if lhs.type != .folder && rhs.type == .folder {
            return false
        }
        // Then sort by name
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
