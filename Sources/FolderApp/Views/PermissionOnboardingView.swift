//
//  PermissionOnboardingView.swift
//  Folder
//
//  First-launch permission assistant. Walks the user through the access
//  areas the app can use — explaining each one and triggering the matching
//  macOS prompt only when the user chooses "Allow".
//

import SwiftUI
import AppKit

struct PermissionOnboardingView: View {
    @ObservedObject private var center = PermissionCenter.shared
    let onFinish: () -> Void

    @State private var step = PermissionCenter.shared.onboardingStep

    private let steps: [(title: String, summary: String)] = [
        ("Welcome", "Folder only needs access to the places you choose.\nYou can change everything later in Settings → Permissions."),
        ("Standard Folders", "Grant access to Desktop, Documents and Downloads — the places you use most."),
        ("Additional Folders", "Add project roots, cloud storage or network shares."),
        ("External Drives & Network", "Each mounted drive or share asks for access on first use."),
        ("Command-line Tools", "Choose how “Open Command Line Here” opens your preferred terminal or workspace."),
        ("You're all set", "Here's what's available now — and how to change it later.")
    ]

    /// Full Disk Access already covers the broad-access use case that the
    /// additional-folder picker is meant to solve. Keep the stored step
    /// indices stable, but omit that picker from the visible walkthrough.
    private var visibleStepIndices: [Int] {
        PermissionCenter.onboardingStepIndices(fullDiskAccessGranted: center.hasFullDiskAccess)
    }

    private var visibleStepPosition: Int {
        visibleStepIndices.firstIndex(of: step) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 18) {
                progress

                VStack(alignment: .leading, spacing: 8) {
                    Label("Step \(visibleStepPosition + 1) of \(visibleStepIndices.count)", systemImage: stepSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.folderAccent)

                    Text(steps[step].title)
                        .font(.system(size: 27, weight: .bold, design: .rounded))

                    Text(steps[step].summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack {
                    Group {
                        switch step {
                        case 0: welcomeContent
                        case 1: standardFoldersContent
                        case 2: additionalFoldersContent
                        case 3: drivesContent
                        case 4: terminalContent
                        default: doneContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(20)
                .background(Color.folderSidebar.opacity(0.7))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.folderAccent.opacity(0.18), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if visibleStepPosition > 0 {
                    Button("Back") { move(to: visibleStepIndices[visibleStepPosition - 1]) }
                        .keyboardShortcut(.cancelAction)
                }

                Spacer()

                if visibleStepPosition < visibleStepIndices.count - 1 {
                    Button("Continue") { move(to: visibleStepIndices[visibleStepPosition + 1]) }
                        .buttonStyle(.borderedProminent)
                        .tint(.folderAccent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { finish() }
                        .buttonStyle(.borderedProminent)
                        .tint(.folderAccent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .background(Color.folderBase)
        .frame(width: 660, height: 600)
        .alert("Permission Error", isPresented: Binding(
            get: { center.lastError != nil },
            set: { if !$0 { center.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { center.lastError = nil }
        } message: {
            Text(center.lastError ?? "Unknown permission error")
        }
        .onAppear {
            step = center.onboardingStep
            center.detectFullDiskAccess()
            center.refreshTerminalStatuses()
        }
        .onReceive(center.$hasFullDiskAccess) { _ in
            reconcileStepWithAvailablePermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.folderAccent)
                    .frame(width: 42, height: 42)
                Image(systemName: "folder.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Folder setup")
                    .font(.headline)
                Text("Choose what Folder can access")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color.folderSidebar.opacity(0.5))
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(visibleStepIndices, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.folderAccent : Color.secondary.opacity(0.22))
                    .frame(height: 5)
                    .accessibilityLabel("Step \((visibleStepIndices.firstIndex(of: index) ?? 0) + 1)")
                    .accessibilityValue(index <= step ? "Complete" : "Not complete")
            }
        }
    }

    private var stepSymbol: String {
        switch step {
        case 0: return "hand.wave.fill"
        case 1: return "folder.badge.gearshape"
        case 2: return "folder.badge.plus"
        case 3: return "externaldrive.fill"
        case 4: return "terminal.fill"
        default: return "checkmark.seal.fill"
        }
    }

    private func move(to newStep: Int) {
        let normalized = PermissionCenter.normalizedOnboardingStep(newStep)
        center.saveOnboardingStep(normalized)
        step = normalized
    }

    private func reconcileStepWithAvailablePermissions() {
        guard !visibleStepIndices.contains(step) else { return }
        // The only currently skippable page is “Additional Folders” (index 2).
        // Advance rather than sending the user backwards when Full Disk Access
        // becomes available while the walkthrough is open.
        move(to: visibleStepIndices.first(where: { $0 > step }) ?? visibleStepIndices.last ?? 0)
    }

    private func finish() {
        guard step == visibleStepIndices.last else { return }
        center.markOnboardingSeen()
        onFinish()
    }

    // MARK: - Step content

    private var welcomeContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.folderAccent)
            Text("Your files stay in your control.")
                .font(.headline)
            Text("Folder only receives access where you explicitly allow it. You can review or change this later in Settings.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var standardFoldersContent: some View {
        VStack(spacing: 10) {
            ForEach(center.standardFolderAccess) { entry in
                HStack {
                    Image(systemName: entry.symbolName).foregroundColor(.accentColor)
                    Text(entry.title).frame(maxWidth: .infinity, alignment: .leading)
                    if entry.status == .allowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            center.grantStandardFolder(entry)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.folderBase.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Divider()
                .padding(.vertical, 2)

            fullDiskAccessOption

            Text("Granting a folder stores a security-scoped bookmark so access survives relaunch.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var fullDiskAccessOption: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(center.hasFullDiskAccess ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Full Disk Access")
                            .font(.subheadline.weight(.semibold))
                        Text("Optional")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }

                    Text(center.hasFullDiskAccess
                         ? "Enabled in macOS System Settings. Standard-folder access stays separate."
                         : "Only for protected app data such as Mail or Safari. It does not replace the folder permissions above.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if center.hasFullDiskAccess {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.green)
                } else {
                    VStack(alignment: .trailing, spacing: 5) {
                        Button(center.fullDiskAccessSettingsOpened ? "Open Again" : "Open Settings") {
                            center.openSystemSettings(for: .fullDiskAccess)
                        }
                        .controlSize(.small)

                        Button("Check Again") {
                            center.confirmFullDiskAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.folderAccent)
                        .controlSize(.small)
                    }
                }
            }

            if !center.hasFullDiskAccess, center.fullDiskAccessSettingsOpened {
                fullDiskAccessDragSource
            }
        }
        .padding(11)
        .background(Color.folderBase.opacity(0.62))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.folderAccent.opacity(center.hasFullDiskAccess ? 0.42 : 0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Full Disk Access")
        .accessibilityValue(center.hasFullDiskAccess ? "Enabled" : "Optional, not enabled")
        .accessibilityHint("This permission is separate from Desktop, Documents and Downloads.")
    }

    /// System Settings accepts app bundles through its Full Disk Access list.
    /// Expose Folder.app as a native file drag only after opening that pane, so
    /// the action is immediately obvious and does not clutter initial setup.
    private var fullDiskAccessDragSource: some View {
        let applicationURL = Bundle.main.bundleURL
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Drag & drop me")
                    .font(.caption.weight(.semibold))
                Text("Drag Folder.app into the Full Disk Access list.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "hand.draw.fill")
                .foregroundColor(.folderAccent)
        }
        .padding(9)
        .background(Color.folderAccent.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.folderAccent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            AppBundleDragSource(applicationURL: applicationURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag Folder app to Full Disk Access")
        .accessibilityHint("Drag this app bundle into the Full Disk Access list in System Settings.")
    }

    private var additionalFoldersContent: some View {
        VStack(spacing: 8) {
            Text("Choose any other folders you work with — you can select several at once.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                center.pickAndGrantFolders(
                    message: "Select the folders you want Folder to access. You can select more than one."
                )
            } label: {
                Label("Select Folders…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            if center.userFolders.isEmpty {
                Text("No additional folders granted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(center.userFolders) { folder in
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.accentColor)
                                Text(folder.name).lineLimit(1)
                                Spacer()
                                Button("Remove") { center.removeUserFolder(folder) }
                                    .controlSize(.small)
                            }
                            .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private var drivesContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 40))
                .foregroundColor(.folderAccent)
            Text("Folder uses any access macOS has already granted. It only asks you to choose a drive when that access is actually missing.")
                .multilineTextAlignment(.center)
            if !center.volumeAccess.isEmpty {
                Text("%d mounted".replacingOccurrences(of: "%d", with: "\(center.volumeAccess.count))") + " drive(s) connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("You can review them anytime in Settings → Permissions.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 40))
                .foregroundColor(.folderAccent)
            Text("Only Terminal and iTerm use macOS Automation. Ghostty, Warp, cmux, tmux, Kitty and Alacritty use their native command-line or URL integration.")
                .multilineTextAlignment(.center)
            HStack {
                ForEach(TerminalAutomationTarget.allCases) { target in
                    if center.terminalStatus(for: target) == .allowed {
                        Label("\(target.title) Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button(center.terminalStatus(for: target) == .denied ? "Retry \(target.title)" : "Allow \(target.title)") {
                            center.requestTerminalAutomation(for: target)
                        }
                        .disabled(!center.isAutomationTargetInstalled(target))
                    }
                }
            }
            .buttonStyle(.bordered)
            Text("Choose your default command-line target in Settings. tmux opens a Folder session inside Terminal.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("You can revoke it later in System Settings → Privacy & Security → Automation.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var doneContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.folderAccent)
            Text("You're ready. You can review or change access anytime in Settings → Permissions.")
                .multilineTextAlignment(.center)
        }
    }
}

/// A dedicated native file drag source for the app bundle. System Settings
/// consumes the file URL from AppKit's dragging pasteboard, just like Finder.
private struct AppBundleDragSource: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context: Context) -> AppBundleDragView {
        let view = AppBundleDragView(frame: .zero)
        view.applicationURL = applicationURL
        return view
    }

    func updateNSView(_ nsView: AppBundleDragView, context: Context) {
        nsView.applicationURL = applicationURL
    }
}

private final class AppBundleDragView: NSView, NSDraggingSource {
    var applicationURL: URL?
    private var dragStartPoint: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let applicationURL,
              let dragStartPoint,
              !isDragging else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - dragStartPoint.x, currentPoint.y - dragStartPoint.y) > 4 else { return }

        isDragging = true
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 40, height: 40)
        item.setDraggingFrame(
            NSRect(x: dragStartPoint.x - 20, y: dragStartPoint.y - 20, width: 40, height: 40),
            contents: icon
        )

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingPasteboard.setPropertyList(
            [applicationURL.path],
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        isDragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStartPoint = nil
        isDragging = false
    }
}
