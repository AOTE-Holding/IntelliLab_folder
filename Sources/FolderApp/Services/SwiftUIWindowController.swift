//
//  SwiftUIWindowController.swift
//  Folder
//
//  Window controller for SwiftUI windows with proper lifecycle management
//

import AppKit
import SwiftUI

@MainActor
class SwiftUIWindowController: NSWindowController, NSWindowDelegate {

    init<Content: View>(
        rootView: Content,
        title: String,
        size: NSSize = NSSize(width: 1000, height: 700),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    ) {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // Configure window appearance
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.title = title
        window.contentView = NSHostingView(rootView: rootView)
        window.backgroundColor = NSColor.folderSidebar

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
        // Only minimize the main window (like Finder); let other windows close normally
        if sender.title == "Folder" {
            sender.miniaturize(nil)
            return false
        }
        return true
    }
}
