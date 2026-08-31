//
//  ColorTagDragSource.swift
//  Folder
//
//  Zieht eine Farbe aus der Sidebar — der Ball hängt am Mauszeiger.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Eine durchsichtige Fläche über der Tag-Zeile, die den Mauszug übernimmt.
///
/// SwiftUIs eigenes Ziehen legt seine Vorschau dorthin, wo die Maus die Zeile
/// erwischt hat — bei einer breiten Zeile also irgendwo neben dem Zeiger. Wo
/// das Bild sitzt, lässt sich dort nicht bestimmen. Über AppKit schon: der
/// Rahmen des gezogenen Bildes wird von Hand gesetzt, und zwar mittig auf den
/// Zeiger. Dieselbe Stelle regelt das Ziehen von Dateien seit je so.
final class ColorTagDragView: NSView, NSDraggingSource {
    var color: ColorTag.TagColor = .red
    var onClick: (() -> Void)?

    /// Durchmesser des Balls. Gross genug, um die Farbe klar zu erkennen, klein
    /// genug, um die Datei darunter nicht zu verdecken.
    private static let ballDiameter: CGFloat = 18

    private var dragStartPoint: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = dragStartPoint else { return }

        let jetzt = convert(event.locationInWindow, from: nil)
        // Erst ab ein paar Pixeln ein Zug — sonst wird jeder zittrige Klick einer.
        guard hypot(jetzt.x - start.x, jetzt.y - start.y) > 4 else { return }
        isDragging = true

        let eintrag = NSDraggingItem(pasteboardWriter: pasteboardItem())
        let d = Self.ballDiameter
        // Mittig auf den Zeiger, nicht auf den Anfasspunkt in der Zeile.
        eintrag.setDraggingFrame(
            NSRect(x: jetzt.x - d / 2, y: jetzt.y - d / 2, width: d, height: d),
            contents: Self.ballImage(for: color, diameter: d)
        )

        beginDraggingSession(with: [eintrag], event: event, source: self)
        dragStartPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging, dragStartPoint != nil {
            onClick?()
        }
        dragStartPoint = nil
        isDragging = false
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Eine Farbe hat ausserhalb von Folder keine Bedeutung.
        context == .withinApplication ? .copy : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        dragStartPoint = nil
    }

    // MARK: - Fracht und Bild

    private func pasteboardItem() -> NSPasteboardItem {
        let eintrag = NSPasteboardItem()
        if let daten = try? JSONEncoder().encode(ColorTagDrag(color: color)) {
            eintrag.setData(daten, forType: DraggableView.colorTagType)
        }
        return eintrag
    }

    /// Der Ball: gefüllter Kreis in der Tag-Farbe, heller Ring, weicher Schatten.
    /// Der Ring hält ihn auch über einem gleichfarbigen Untergrund sichtbar.
    private static func ballImage(for color: ColorTag.TagColor, diameter: CGFloat) -> NSImage {
        let rand: CGFloat = 3
        let größe = NSSize(width: diameter + rand * 2, height: diameter + rand * 2)

        return NSImage(size: größe, flipped: false) { _ in
            let kreis = NSRect(x: rand, y: rand, width: diameter, height: diameter)
            let pfad = NSBezierPath(ovalIn: kreis)

            NSGraphicsContext.current?.saveGraphicsState()
            let schatten = NSShadow()
            schatten.shadowColor = NSColor.black.withAlphaComponent(0.35)
            schatten.shadowBlurRadius = 3
            schatten.shadowOffset = NSSize(width: 0, height: -1)
            schatten.set()

            NSColor(Color(hex: color.rawValue)).setFill()
            pfad.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.75).setStroke()
            pfad.lineWidth = 1.5
            pfad.stroke()
            return true
        }
    }
}

/// Legt die Zieh-Fläche über die Tag-Zeile.
struct ColorTagDragSource: NSViewRepresentable {
    let color: ColorTag.TagColor
    let onClick: () -> Void

    func makeNSView(context: Context) -> ColorTagDragView {
        let view = ColorTagDragView()
        view.color = color
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ColorTagDragView, context: Context) {
        nsView.color = color
        nsView.onClick = onClick
    }
}
