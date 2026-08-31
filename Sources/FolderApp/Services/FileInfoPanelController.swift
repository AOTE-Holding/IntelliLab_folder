//
//  FileInfoPanelController.swift
//  Folder
//

import AppKit
import SwiftUI

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
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
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
                Image(systemName: item.type == .folder ? "folder.fill" : item.iconName)
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(item.type == .folder ? Color.folderAccent : Color.secondary)
                    .frame(width: 46, height: 46)
                    .background(Color.folderAccent.opacity(item.type == .folder ? 0.12 : 0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .semibold))
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

            VStack(spacing: 0) {
                InfoRow(label: "Kind", value: snapshot.kind)
                InfoRow(label: "Size", value: snapshot.size)
                InfoRow(label: "Where", value: snapshot.location)
                InfoRow(label: "Created", value: snapshot.created)
                InfoRow(label: "Modified", value: snapshot.modified)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Spacer(minLength: 0)

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.path])
                }
                .buttonStyle(.bordered)

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
        .frame(width: 360, height: 430)
        .background(Color.folderBase)
        // Kein festes Dunkel: das Infofenster folgt dem eingestellten
        // Erscheinungsbild wie jedes andere Fenster auch.
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(label == "Where" ? 2 : 1)
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
    let location: String
    let created: String
    let modified: String

    init(item: FileSystemItem) {
        kind = Self.kind(for: item)
        size = Self.size(for: item)
        location = item.path.deletingLastPathComponent().path
        created = Self.dateFormatter.string(from: item.createdAt)
        modified = Self.dateFormatter.string(from: item.modifiedAt)
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
}
