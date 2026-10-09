//
//  SwiftUIWindowController.swift
//  Folder
//
//  Window controller for SwiftUI windows with proper lifecycle management
//

import AppKit
import SwiftUI
@preconcurrency import Quartz

@MainActor
class SwiftUIWindowController: NSWindowController, NSWindowDelegate {
    private let minimumWindowSize: NSSize

    init<Content: View>(
        rootView: Content,
        title: String,
        size: NSSize = NSSize(width: 1000, height: 700),
        minimumSize: NSSize = NSSize(width: 320, height: 360),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        hidesTitle: Bool = false
    ) {
        minimumWindowSize = minimumSize
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // Configure window appearance
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = hidesTitle ? .hidden : .visible
        // Respect Folder's selected appearance instead of pinning all AppKit
        // colors to Dark Aqua.
        window.appearance = nil
        window.center()
        window.title = title
        let hostingView = NSHostingView(rootView: rootView)
        if hidesTitle, #available(macOS 13.3, *) {
            // `fullSizeContentView` still exposes a titlebar safe-area to
            // SwiftUI. The browser intentionally owns that strip, so its
            // navigation chrome can reach the actual window edge.
            hostingView.safeAreaRegions = []
        }
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.backgroundColor = NSColor.folderSidebar
        window.minSize = minimumSize

        // Initialize the controller with the window
        super.init(window: window)

        // Set self as delegate
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Cleanup happens here if needed
        // The window controller will be deallocated properly
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Native macOS behavior: close the window. AppDelegate keeps the
        // process alive and recreates/reopens a browser window from Dock/Menu.
        return true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, minimumWindowSize.width),
            height: max(frameSize.height, minimumWindowSize.height)
        )
    }

    func enforceMinimumSize() {
        guard let window else { return }
        let frame = window.frame
        let width = max(frame.width, minimumWindowSize.width)
        let height = max(frame.height, minimumWindowSize.height)
        guard width != frame.width || height != frame.height else { return }
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height),
            display: true
        )
    }

    // MARK: - Quick Look responder-chain ownership

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            QuickLookManager.shared.beginPreviewPanelControl(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            QuickLookManager.shared.endPreviewPanelControl(panel)
        }
    }
}
