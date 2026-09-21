//
//  FileInfoPanelController.swift
//  Folder
//

import AppKit
import SwiftUI
import ImageIO

/// A small non-modal inspector, matching Finder's Get Info workflow while
/// keeping the user in Folder instead of handing the selection to Finder.
@MainActor
final class FileInfoPanelController {
    static let shared = FileInfoPanelController()

    private var panel: NSPanel?

    private init() {}

    func show(item: FileSystemItem) {
        let rootView = FileInfoView(item: item)

        if let panel {
            panel.contentView = NSHostingView(rootView: rootView)
        } else {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.contentView = NSHostingView(rootView: rootView)
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.center()
            self.panel = panel
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FileInfoView: View {
    let item: FileSystemItem
    private let snapshot: FileInfoSnapshot

    init(item: FileSystemItem) {
        self.item = item
        self.snapshot = FileInfoSnapshot(item: item)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 13) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 54)
                    .padding(5)
                    .background(Color.folderSubtleFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(snapshot.kind)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()
                .overlay(Color.folderStroke.opacity(0.72))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InfoSection("General") {
                        InfoRow(label: "Kind", value: snapshot.kind)
                        InfoRow(label: "Size", value: snapshot.size)
                        InfoRow(label: "Size on disk", value: snapshot.allocatedSize)
                        InfoRow(label: "Where", value: snapshot.location, multiline: true)
                        InfoRow(label: "Created", value: snapshot.created)
                        InfoRow(label: "Modified", value: snapshot.modified)
                        InfoRow(label: "Last opened", value: snapshot.lastOpened)
                    }

                    InfoSection("Name & Extension") {
                        InfoRow(label: "Name", value: item.name, multiline: true)
                        InfoRow(label: "Extension", value: snapshot.extensionName)
                        InfoRow(label: "Type identifier", value: snapshot.typeIdentifier, multiline: true)
                    }

                    if !snapshot.tags.isEmpty {
                        InfoSection("Tags") {
                            InfoRow(label: "Finder tags", value: snapshot.tags.joined(separator: ", "), multiline: true)
                        }
                    }

                    if let imageDetails = snapshot.imageDetails {
                        InfoSection("Image Details") {
                            InfoRow(label: "Dimensions", value: imageDetails.dimensions)
                            if let colorModel = imageDetails.colorModel {
                                InfoRow(label: "Color model", value: colorModel)
                            }
                        }
                    }

                    InfoSection("Access") {
                        InfoRow(label: "Owner", value: snapshot.owner)
                        InfoRow(label: "Group", value: snapshot.group)
                        InfoRow(label: "Permissions", value: snapshot.permissions)
                        InfoRow(label: "Locked", value: snapshot.isLocked ? "Yes" : "No")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            HStack {
                Spacer()

                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .tint(.folderAccent)
            }
            .padding(20)
            .background(Color.folderSurface.opacity(0.45))
        }
        .frame(width: 520, height: 680)
        .background(Color.folderBase)
        // Kein festes Dunkel: das Infofenster folgt dem eingestellten
        // Erscheinungsbild wie jedes andere Fenster auch.
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.folderAccent)
                .textCase(.uppercase)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.folderSubtleFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var multiline = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(multiline ? 3 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

private struct FileInfoSnapshot {
    let kind: String
    let size: String
    let allocatedSize: String
    let location: String
    let created: String
    let modified: String
    let lastOpened: String
    let extensionName: String
    let typeIdentifier: String
    let tags: [String]
    let owner: String
    let group: String
    let permissions: String
    let isLocked: Bool
    let imageDetails: ImageDetails?

    struct ImageDetails {
        let dimensions: String
        let colorModel: String?
    }

    init(item: FileSystemItem) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: item.path.path)) ?? [:]
        let resourceValues = try? item.path.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .contentAccessDateKey,
            .typeIdentifierKey,
            .tagNamesKey
        ])

        kind = Self.kind(for: item)
        size = Self.size(for: item)
        let allocatedBytes = Int64(resourceValues?.totalFileAllocatedSize ?? Int(item.size))
        allocatedSize = ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file)
        location = item.path.deletingLastPathComponent().path
        created = Self.dateFormatter.string(from: item.createdAt)
        modified = Self.dateFormatter.string(from: item.modifiedAt)
        lastOpened = resourceValues?.contentAccessDate.map(Self.dateFormatter.string(from:)) ?? "—"
        extensionName = item.path.pathExtension.isEmpty ? "—" : item.path.pathExtension.uppercased()
        typeIdentifier = resourceValues?.typeIdentifier ?? "—"
        tags = (resourceValues?.tagNames ?? []).map { raw in
            raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        }
        owner = attributes[.ownerAccountName] as? String ?? "—"
        group = attributes[.groupOwnerAccountName] as? String ?? "—"
        if let mode = attributes[.posixPermissions] as? NSNumber {
            permissions = String(format: "%04o", mode.intValue)
        } else {
            permissions = "—"
        }
        isLocked = (attributes[.immutable] as? NSNumber)?.boolValue
            ?? (attributes[.immutable] as? Bool)
            ?? false
        imageDetails = Self.imageDetails(for: item.path)
    }

    private static func kind(for item: FileSystemItem) -> String {
        switch item.type {
        case .folder: return "Folder"
        case .symlink: return "Alias"
        case .file:
            let extensionName = item.path.pathExtension
            return extensionName.isEmpty ? "Document" : "\(extensionName.uppercased()) document"
        }
    }

    private static func size(for item: FileSystemItem) -> String {
        guard item.type == .folder else {
            return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        }

        let childCount = (try? FileManager.default.contentsOfDirectory(
            at: item.path,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).count) ?? 0
        return "\(childCount) \(childCount == 1 ? "item" : "items")"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func imageDetails(for url: URL) -> ImageDetails? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let colorModel = properties[kCGImagePropertyColorModel] as? String
        return ImageDetails(dimensions: "\(width.intValue) × \(height.intValue) pixels", colorModel: colorModel)
    }
}
