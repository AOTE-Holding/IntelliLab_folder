//
//  MultiFileDragSource.swift
//  Folder
//
//  NSViewRepresentable wrapper that enables multi-file drag via AppKit's native drag API
//  with direct click/double-click callback support.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NativeFileClickAction: Equatable {
    case select
    case open
    case none
}

/// A transparent NSView that intercepts mouse drags for multi-file drag sessions.
/// Clicks are handled directly via callbacks instead of event re-sending,
/// which properly supports single-click, double-click, and modifier keys.
class DraggableView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    var dragEnabled = false
    var dropDestination: URL?
    var onDropFiles: (([URL], Bool) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onSingleClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onColorTagDrop: ((ColorTag.TagColor) -> Void)?
    var onColorTagHover: ((Bool) -> Void)?
    private var dragStartPoint: NSPoint?
    private var isDragging = false
    private var isHoveringDestination = false

    /// Diese Ansicht liegt ueber der Kachel und faengt jedes Ziehen ab, das sie
    /// annimmt. Ein Typ, der hier fehlt, kommt deshalb nirgends mehr an — auch
    /// nicht bei einem SwiftUI-Ziel darunter, denn fuer AppKit ist diese Ansicht
    /// die oberste. Der Farb-Tag muss darum hier stehen.
    static let colorTagType = NSPasteboard.PasteboardType(UTType.folderColorTag.identifier)

    static let acceptedDraggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), colorTagType
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(Self.acceptedDraggedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes(Self.acceptedDraggedTypes)
    }

    /// Finder accepts a file click even when its window was not key yet. Without
    /// this override, the first click can be consumed only to activate Folder,
    /// making selection feel delayed and breaking the first half of a double-click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if dragEnabled && !fileURLs.isEmpty {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            isDragging = false
            // Finder selects on the first mouse-down instead of waiting for
            // the system double-click interval to expire. The second click is
            // reserved for opening the already selected item.
            if Self.action(forMouseDownClickCount: event.clickCount) == .select {
                onSingleClick?(event.modifierFlags)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard FileOperationPolicy.isEnabled, dragEnabled, !fileURLs.isEmpty, !isDragging else {
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
            // Selection already happened on the first mouse-down. Only the
            // second mouse-up performs the open action.
            if Self.action(forMouseUpClickCount: event.clickCount) == .open {
                onDoubleClick?()
            }
        }
        dragStartPoint = nil
        isDragging = false
    }

    nonisolated static func action(forMouseDownClickCount clickCount: Int) -> NativeFileClickAction {
        clickCount == 1 ? .select : .none
    }

    nonisolated static func action(forMouseUpClickCount clickCount: Int) -> NativeFileClickAction {
        clickCount >= 2 ? .open : .none
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard FileOperationPolicy.isEnabled else { return [] }
        return context == .outsideApplication ? [.copy, .delete] : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .delete {
            let urls = fileURLs
            Task { @MainActor in
                FileOperationCoordinator.shared.moveToTrash(urls)
            }
        }
        isDragging = false
        dragStartPoint = nil
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ein Farb-Tag gilt fuer jede Datei, nicht nur fuer Ordner — deshalb vor
        // der Pruefung auf ein Ablageziel.
        if carriesColorTag(sender.draggingPasteboard) {
            onColorTagHover?(true)
            return .copy
        }
        guard let dropDestination else { return [] }
        let urls = droppedURLs(from: sender.draggingPasteboard)
        let operation = FileDropValidation.operation(
            for: urls,
            into: dropDestination,
            forceCopy: NSEvent.modifierFlags.contains(.option)
        )
        guard operation != [] else { return [] }
        if !isHoveringDestination {
            isHoveringDestination = true
            onDragEntered?()
        }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesColorTag(sender.draggingPasteboard) { return .copy }
        guard let dropDestination else { return [] }
        return FileDropValidation.operation(
            for: droppedURLs(from: sender.draggingPasteboard),
            into: dropDestination,
            forceCopy: NSEvent.modifierFlags.contains(.option)
        )
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if carriesColorTag(sender.draggingPasteboard) { return true }
        guard let dropDestination else { return false }
        return FileDropValidation.operation(
            for: droppedURLs(from: sender.draggingPasteboard),
            into: dropDestination,
            forceCopy: NSEvent.modifierFlags.contains(.option)
        ) != []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onColorTagHover?(false)
        if isHoveringDestination {
            isHoveringDestination = false
            onDragExited?()
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let farbe = draggedColorTag(from: sender.draggingPasteboard) {
            onColorTagHover?(false)
            onColorTagDrop?(farbe)
            return true
        }
        guard let dropDestination else { return false }
        let urls = droppedURLs(from: sender.draggingPasteboard)
        guard FileDropValidation.operation(
            for: urls,
            into: dropDestination,
            forceCopy: NSEvent.modifierFlags.contains(.option)
        ) != [] else { return false }
        onDropFiles?(urls, NSEvent.modifierFlags.contains(.option))
        if isHoveringDestination {
            isHoveringDestination = false
            onDragExited?()
        }
        return true
    }

    /// Ob ueberhaupt eine Farbe gezogen wird.
    ///
    /// Getrennt vom Auslesen, weil die Annahme nicht davon abhaengen darf, wann
    /// die Daten bereitstehen: SwiftUI liefert sie erst auf Nachfrage. Wer hier
    /// den Inhalt verlangt, lehnt den Zug ab, solange er noch nicht da ist —
    /// und der Nutzer sieht ein Verbotsschild, obwohl alles stimmt.
    private func carriesColorTag(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(Self.colorTagType) == true
            || pasteboard.pasteboardItems?.contains { $0.types.contains(Self.colorTagType) } == true
    }

    /// Die Farbe, die gerade gezogen wird — beim Loslassen ausgelesen.
    private func draggedColorTag(from pasteboard: NSPasteboard) -> ColorTag.TagColor? {
        var daten = pasteboard.data(forType: Self.colorTagType)
        if daten == nil {
            daten = pasteboard.pasteboardItems?
                .compactMap { $0.data(forType: Self.colorTagType) }
                .first
        }
        guard let daten,
              let fracht = try? JSONDecoder().decode(ColorTagDrag.self, from: daten)
        else { return nil }
        return fracht.color
    }

    private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !objects.isEmpty {
            return objects
        }
        let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: fileNamesType) as? [String] {
            return paths.map(URL.init(fileURLWithPath:))
        }
        return []
    }

}

/// NSViewRepresentable that wraps the DraggableView
struct MultiFileDragView: NSViewRepresentable {
    let fileURLs: [URL]
    let isEnabled: Bool
    let dropDestination: URL?
    let onDropFiles: (([URL], Bool) -> Void)?
    let onDragEntered: (() -> Void)?
    let onDragExited: (() -> Void)?
    let onSingleClick: ((NSEvent.ModifierFlags) -> Void)?
    let onDoubleClick: (() -> Void)?
    let onColorTagDrop: ((ColorTag.TagColor) -> Void)?
    let onColorTagHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DraggableView {
        let view = DraggableView(frame: .zero)
        view.fileURLs = fileURLs
        view.dragEnabled = isEnabled
        view.dropDestination = dropDestination
        view.onDropFiles = onDropFiles
        view.onDragEntered = onDragEntered
        view.onDragExited = onDragExited
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onColorTagDrop = onColorTagDrop
        view.onColorTagHover = onColorTagHover
        return view
    }

    func updateNSView(_ nsView: DraggableView, context: Context) {
        nsView.fileURLs = fileURLs
        nsView.dragEnabled = isEnabled
        nsView.dropDestination = dropDestination
        nsView.onDropFiles = onDropFiles
        nsView.onDragEntered = onDragEntered
        nsView.onDragExited = onDragExited
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onColorTagDrop = onColorTagDrop
        nsView.onColorTagHover = onColorTagHover
    }
}

extension View {
    @ViewBuilder
    func multiFileDrag(
        urls: [URL],
        enabled: Bool = true,
        dropDestination: URL? = nil,
        onDropFiles: (([URL], Bool) -> Void)? = nil,
        onDragEntered: (() -> Void)? = nil,
        onDragExited: (() -> Void)? = nil,
        onSingleClick: ((NSEvent.ModifierFlags) -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil,
        onColorTagDrop: ((ColorTag.TagColor) -> Void)? = nil,
        onColorTagHover: ((Bool) -> Void)? = nil
    ) -> some View {
        ZStack {
            self
            MultiFileDragView(
                fileURLs: urls,
                isEnabled: enabled,
                dropDestination: dropDestination,
                onDropFiles: onDropFiles,
                onDragEntered: onDragEntered,
                onDragExited: onDragExited,
                onSingleClick: onSingleClick,
                onDoubleClick: onDoubleClick,
                onColorTagDrop: onColorTagDrop,
                onColorTagHover: onColorTagHover
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Handles clicks in transparent background regions at mouse-down time. This
/// keeps deselection responsive without intercepting the file item views above.
struct ImmediateBackgroundClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
    }

    final class ClickView: NSView {
        var action: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            action()
        }
    }
}
