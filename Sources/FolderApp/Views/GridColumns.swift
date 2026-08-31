//
//  GridColumns.swift
//  Folder
//
//  Wie viele Spalten das Gitter gerade wirklich hat.
//

import SwiftUI

/// Die Spaltenzahl des Icon-Gitters — gemessen, nicht geraten.
///
/// Pfeil hoch und runter springen im Gitter um genau eine Spaltenbreite mal die
/// Spaltenzahl. Stimmt diese Zahl nicht exakt mit dem überein, was `LazyVGrid`
/// tatsächlich gelegt hat, landet die Auswahl eine Position daneben — die
/// Bewegung sieht dann schräg aus statt gerade.
///
/// Vorher wurde die Zahl aus `NSApp.keyWindow.frame` und der gespeicherten
/// Sidebar-Breite nachgerechnet. Diese Rechnung musste abweichen:
/// das Fensterrahmenmass ist nicht die Inhaltsbreite, die Sidebar-Breite steht
/// erst 0,35 Sekunden nach dem Ziehen in der Ablage (vorher liest man 0), und
/// `keyWindow` ist zeitweise die Vorschau oder das Einstellungsfenster.
///
/// Deshalb misst jetzt die Ansicht selbst und meldet ihr Ergebnis nach oben.
enum GridColumnMath {

    /// Abstand zwischen zwei Kacheln. Muss mit dem `spacing` der `LazyVGrid`
    /// übereinstimmen, sonst rechnet diese Datei an der Realität vorbei.
    static let spacing: CGFloat = 16

    /// Das `.padding()` um das Gitter — links und rechts je der Standardwert.
    static let contentPadding: CGFloat = 16

    /// Die Mindestbreite einer Kachel, wie sie `GridItem(.adaptive(minimum:))`
    /// bekommt: Symbolgrösse plus Platz für den Dateinamen.
    static func itemMinimum(iconSize: Int) -> CGFloat {
        CGFloat(iconSize + 40)
    }

    /// Dieselbe Regel, nach der SwiftUI `.adaptive` auflöst: es passen so viele
    /// Spalten hinein, wie `n * minimum + (n - 1) * spacing` in die Breite passen.
    static func columns(availableWidth: CGFloat, itemMinimum: CGFloat) -> Int {
        let content = availableWidth - contentPadding * 2
        guard content > 0, itemMinimum > 0 else { return 1 }
        return max(1, Int((content + spacing) / (itemMinimum + spacing)))
    }
}

/// Misst die Breite, die das Gitter tatsächlich bekommen hat, und meldet die
/// daraus folgende Spaltenzahl.
///
/// Liegt als Hintergrund über der Ansicht statt als Rahmen darum: ein
/// `GeometryReader` als Container würde die Grösse der Ansicht verändern,
/// als Hintergrund misst er nur.
struct GridColumnReporter: ViewModifier {
    let iconSize: Int
    let report: (Int) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { melden(width: geometry.size.width, iconSize: iconSize) }
                    .onChange(of: geometry.size.width) { width in
                        melden(width: width, iconSize: iconSize)
                    }
                    .onChange(of: iconSize) { size in
                        melden(width: geometry.size.width, iconSize: size)
                    }
            }
        )
    }

    private func melden(width: CGFloat, iconSize: Int) {
        report(
            GridColumnMath.columns(
                availableWidth: width,
                itemMinimum: GridColumnMath.itemMinimum(iconSize: iconSize)
            )
        )
    }
}

extension View {
    /// Meldet die tatsächliche Spaltenzahl dieses Gitters nach oben.
    func reportsGridColumns(iconSize: Int, to report: @escaping (Int) -> Void) -> some View {
        modifier(GridColumnReporter(iconSize: iconSize, report: report))
    }
}
