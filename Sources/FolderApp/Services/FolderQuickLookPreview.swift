import Foundation
import UniformTypeIdentifiers

struct FolderQuickLookEntry: Codable, Sendable, Equatable {
    let name: String
    let kind: String
    let modified: String
    let size: String
    let isDirectory: Bool
    let sourcePath: String
}

struct FolderQuickLookPayload: Codable, Sendable, Equatable {
    let folderName: String
    let entries: [FolderQuickLookEntry]
    let truncated: Bool
    let errorMessage: String?
    let previewKind: String?
    let textContent: String?
    let textLanguage: String?
    let previewSessionID: String?
    let sourceFolderPath: String?
    let appearance: String?
}

enum FolderQuickLookPreview {
    static let maximumVisibleItems = 500
    static let maximumTextPreviewBytes = 1_500_000
    static let filenameExtension = "folderpreview"
    static let contentTypeIdentifier = "com.intellilab.folder.quicklook-list"

    static func createDocument(
        for folderURL: URL,
        in outputDirectory: URL,
        previewSessionID: String? = nil,
        appearance: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let payload: FolderQuickLookPayload
        do {
            let listing = try folderEntries(at: folderURL, fileManager: fileManager)
            payload = FolderQuickLookPayload(
                folderName: folderURL.lastPathComponent,
                entries: listing.entries,
                truncated: listing.truncated,
                errorMessage: nil,
                previewKind: "folder",
                textContent: nil,
                textLanguage: nil,
                previewSessionID: previewSessionID,
                sourceFolderPath: folderURL.path,
                appearance: appearance
            )
        } catch {
            payload = FolderQuickLookPayload(
                folderName: folderURL.lastPathComponent,
                entries: [],
                truncated: false,
                errorMessage: error.localizedDescription,
                previewKind: "folder",
                textContent: nil,
                textLanguage: nil,
                previewSessionID: previewSessionID,
                sourceFolderPath: folderURL.path,
                appearance: appearance
            )
        }

        let outputURL = outputDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(filenameExtension)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: outputURL, options: .atomic)
        return outputURL
    }

    static func decodeDocument(at url: URL) throws -> FolderQuickLookPayload {
        try JSONDecoder().decode(FolderQuickLookPayload.self, from: Data(contentsOf: url))
    }

    /// Builds the same native Quick Look extension payload for any UTF-8 text
    /// file. This intentionally detects text from its contents, rather than a
    /// short extension allow-list, so source files from all languages (and
    /// extensionless config files) receive the readable code preview too.
    static func createTextDocument(
        for fileURL: URL,
        in outputDirectory: URL,
        appearance: String? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        // HTML is a document, not merely source code: hand it to macOS's web
        // preview so relative CSS/assets and the rendered page are preserved.
        // Other UTF-8 source/config files use Folder's native text reader.
        guard !["html", "htm"].contains(fileURL.pathExtension.lowercased()) else {
            return nil
        }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumTextPreviewBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let payload = FolderQuickLookPayload(
                folderName: fileURL.lastPathComponent,
                entries: [],
                truncated: false,
                errorMessage: nil,
                previewKind: "text",
                textContent: text,
                textLanguage: textLanguage(for: fileURL),
                previewSessionID: nil,
                sourceFolderPath: nil,
                appearance: appearance
            )
            let outputURL = outputDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(filenameExtension)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            return nil
        }
    }

    private static func textLanguage(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        let names: [String: String] = [
            "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
            "ts": "TypeScript", "tsx": "TypeScript", "jsx": "JavaScript",
            "json": "JSON", "html": "HTML", "htm": "HTML", "css": "CSS",
            "scss": "SCSS", "sass": "Sass", "less": "Less", "xml": "XML",
            "yml": "YAML", "yaml": "YAML", "toml": "TOML", "md": "Markdown",
            "swift": "Swift", "py": "Python", "rb": "Ruby", "java": "Java",
            "c": "C", "h": "C/C++", "cpp": "C++", "cxx": "C++", "hpp": "C++",
            "cs": "C#", "go": "Go", "rs": "Rust", "php": "PHP", "sh": "Shell",
            "zsh": "Shell", "bash": "Shell", "sql": "SQL", "vue": "Vue",
            "svelte": "Svelte", "kt": "Kotlin", "kts": "Kotlin", "dart": "Dart",
            "lua": "Lua", "r": "R", "pl": "Perl", "ex": "Elixir", "exs": "Elixir"
        ]
        if let name = names[ext] { return name }
        return ext.isEmpty ? "Text" : ext.uppercased()
    }

    static func folderEntries(
        at folderURL: URL,
        fileManager: FileManager = .default
    ) throws -> (entries: [FolderQuickLookEntry], truncated: Bool) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentTypeKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file

        var candidates: [(entry: FolderQuickLookEntry, url: URL)] = []
        let truncated = urls.count > maximumVisibleItems
        for url in urls.prefix(maximumVisibleItems) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            let isDirectory = values.isDirectory == true
            let isSymbolicLink = values.isSymbolicLink == true
            let kind: String
            if isSymbolicLink {
                kind = "Alias"
            } else if isDirectory {
                kind = "Folder"
            } else {
                kind = values.contentType?.localizedDescription ?? "File"
            }

            candidates.append((
                entry: FolderQuickLookEntry(
                    name: url.lastPathComponent,
                    kind: kind,
                    modified: values.contentModificationDate.map(dateFormatter.string(from:)) ?? "—",
                    size: isDirectory ? "—" : values.fileSize.map { byteFormatter.string(fromByteCount: Int64($0)) } ?? "—",
                    isDirectory: isDirectory,
                    sourcePath: url.path
                ),
                url: url
            ))
        }

        candidates.sort {
            if $0.entry.isDirectory != $1.entry.isDirectory { return $0.entry.isDirectory }
            return $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
        }
        return (candidates.map(\.entry), truncated)
    }
}
