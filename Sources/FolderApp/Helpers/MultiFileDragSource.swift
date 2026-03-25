//
//  MultiFileDragSource.swift
//  Folder
//
//  NSViewRepresentable wrapper that enables multi-file drag via AppKit's native drag API
//  with direct click/double-click callback support.
//

import SwiftUI
import AppKit

/// A transparent NSView that intercepts mouse drags for multi-file drag sessions.
/// Clicks are handled directly via callbacks instead of event re-sending,
/// which properly supports single-click, double-click, and modifier keys.
class DraggableView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    var dragEnabled = false
    var onSingleClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var dragStartPoint: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func mouseDown(with event: NSEvent) {
        if dragEnabled && !fileURLs.isEmpty {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            isDragging = false
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, !fileURLs.isEmpty, !isDragging else {
            super.mouseDragged(with: event)
            return
        }

        guard let startPoint = dragStartPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)

        guard distance > 5 else { return }

        isDragging = true

        var draggingItems: [NSDraggingItem] = []
        for (index, url) in fileURLs.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let offsetX = CGFloat(index) * 4
            let offsetY = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: startPoint.x + offsetX, y: startPoint.y - 32 + offsetY, width: 32, height: 32), contents: icon)
            draggingItems.append(item)
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        let filePaths = fileURLs.map { $0.path }
        session.draggingPasteboard.setPropertyList(filePaths, forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"))

        dragStartPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging, dragStartPoint != nil {
            // This was a click, not a drag. Call the appropriate handler directly.
            if event.clickCount >= 2 {
                onDoubleClick?()
            } else {
                onSingleClick?(NSEvent.modifierFlags)
            }
        }
        dragStartPoint = nil
        isDragging = false
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .delete] : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete {
            var sourceURLs: [URL] = []
            var trashURLs: [URL] = []
            for url in fileURLs {
                var trashNSURL: NSURL?
                try? FileManager.default.trashItem(at: url, resultingItemURL: &trashNSURL)
                sourceURLs.append(url)
                if let trashURL = trashNSURL as URL? {
                    trashURLs.append(trashURL)
                }
            }
            if sourceURLs.count == trashURLs.count && !sourceURLs.isEmpty {
                Task { @MainActor in
                    ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                        type: .trash, sourceURLs: sourceURLs, destinationURLs: trashURLs
                    ))
                }
            }
        }
        isDragging = false
        dragStartPoint = nil
    }
}

/// NSViewRepresentable that wraps the DraggableView
struct MultiFileDragView: NSViewRepresentable {
    let fileURLs: [URL]
    let isEnabled: Bool
    let onSingleClick: ((NSEvent.ModifierFlags) -> Void)?
    let onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DraggableView {
        let view = DraggableView(frame: .zero)
        view.fileURLs = fileURLs
        view.dragEnabled = isEnabled
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DraggableView, context: Context) {
        nsView.fileURLs = fileURLs
        nsView.dragEnabled = isEnabled
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

extension View {
    @ViewBuilder
    func multiFileDrag(
        urls: [URL],
        enabled: Bool = true,
        onSingleClick: ((NSEvent.ModifierFlags) -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil
    ) -> some View {
        ZStack {
            self
            MultiFileDragView(fileURLs: urls, isEnabled: enabled, onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
        }
    }
}
