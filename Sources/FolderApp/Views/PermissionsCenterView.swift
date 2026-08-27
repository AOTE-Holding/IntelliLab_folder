//
//  PermissionsCenterView.swift
//  Folder
//
//  The Permissions Center: live access status for every protected area and
//  a primary action to grant / repair access.
//

import SwiftUI
import AppKit

struct PermissionsCenterView: View {
    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section(title: "Standard Folders", systemImage: "folder") {
                    ForEach(center.standardFolderAccess) { entry in
                        standardFolderRow(entry)
                    }
                }

                userFoldersSection

                section(title: "External Drives & Network", systemImage: "externaldrive") {
                    volumesRow
                }

                section(title: "Full Disk Access", systemImage: "lock.fill") {
                    fullDiskAccessRow
                }

                section(title: "Command-line Tools & Automation", systemImage: "terminal") {
                    ForEach(TerminalAutomationTarget.allCases) { target in
                        terminalRow(target)
                    }
                    Text("Warp opens through its URL scheme and does not need Apple Events Automation permission.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Permission Error", isPresented: Binding(
            get: { center.lastError != nil },
            set: { if !$0 { center.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { center.lastError = nil }
        } message: {
            Text(center.lastError ?? "Unknown permission error")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Permissions Center")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Folder only needs access to the places you choose. You can change or revoke this anytime.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Section helper

    private func section<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
    }

    // MARK: - Status capsule

    private func statusBadge(_ status: AccessStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .foregroundColor(status.color)
            Text(status.label)
                .font(.caption)
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func actionButton(_ title: String, symbol: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.caption)
        }
        .controlSize(.small)
    }

    // MARK: - Standard folder row

    private func standardFolderRow(_ entry: StandardFolderAccess) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbolName)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(entry.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusBadge(entry.status)

            switch entry.status {
            case .allowed, .stale:
                actionButton(entry.status == .stale ? "Re-authorize" : "Re-authorize",
                             symbol: "arrow.clockwise") {
                    center.grantStandardFolder(entry)
                }
            case .notRequested, .denied:
                actionButton("Allow", symbol: "checkmark") {
                    center.grantStandardFolder(entry)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - User folders

    private var userFoldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Your Folders", systemImage: "folder.badge.plus")
                    .font(.headline)
                Spacer()
                actionButton("Select Folders…", symbol: "plus") {
                    center.pickAndGrantFolders(
                        message: "Select the folders you want Folder to access. You can select more than one."
                    )
                }
            }

            if center.userFolders.isEmpty {
                Text("No extra folders granted. Choose folders like project roots, cloud storage or network shares.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(center.userFolders) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text(folder.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statusBadge(center.status(for: folder))

                        if center.status(for: folder) == .stale {
                            actionButton("Re-authorize", symbol: "arrow.clockwise") {
                                center.reauthorize(folder)
                            }
                        }

                        actionButton("Remove", symbol: "xmark", role: .destructive) {
                            center.removeUserFolder(folder)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Volumes

    @ViewBuilder
    private var volumesRow: some View {
        if center.volumeAccess.isEmpty {
            Text("No external or network volumes mounted. Folder uses macOS-granted access without asking again.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(center.volumeAccess) { volume in
                HStack(spacing: 8) {
                    Image(systemName: volume.symbolName)
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    Text(volume.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statusBadge(volume.status)
                    if volume.status != .allowed {
                        actionButton("Allow", symbol: "checkmark") {
                            center.authorizeVolume(volume)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Full Disk Access

    private var fullDiskAccessRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Full Disk Access")
                    statusBadge(center.hasFullDiskAccess ? .allowed : .denied)
                }
                Text(center.hasFullDiskAccess
                    ? "macOS has granted Folder access to protected locations."
                     : "Enable Folder in macOS System Settings, then check the permission again here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("This status is based on an actual protected-location access check, not a confirmation-only setting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                actionButton("Open System Settings", symbol: "arrow.up.forward.app") {
                    center.openSystemSettings(for: .fullDiskAccess)
                }
                if !center.hasFullDiskAccess {
                    Button("Check Again") {
                        center.confirmFullDiskAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Terminal

    private func terminalRow(_ target: TerminalAutomationTarget) -> some View {
        let isInstalled = center.isAutomationTargetInstalled(target)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(target.title)
                    if isInstalled {
                        statusBadge(center.terminalStatus(for: target))
                    } else {
                        Text("Not Installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("Used only when you choose “Open Command Line Here” with \(target.title). macOS controls this permission under Privacy & Security → Automation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            actionButton("Request Permission", symbol: "paperplane") {
                center.requestTerminalAutomation(for: target)
            }
            .disabled(!isInstalled)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
