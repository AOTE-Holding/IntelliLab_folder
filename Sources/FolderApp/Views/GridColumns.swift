//
//  GridColumns.swift
//  Folder
//
//  Eine Spaltenzahl für Layout und Tastaturnavigation.
//

import SwiftUI

/// Die Spaltenzahl des Icon-Gitters wird aus der verfügbaren Breite bestimmt.
///
/// `LazyVGrid(.adaptive)` legte nach einer Fensterverkleinerung manchmal drei
/// Spalten, während die getrennte Breitenrechnung vier meldete. Die Ansicht
/// baut deshalb genau so viele explizite Spalten, wie die Pfeiltasten nutzen.
enum GridColumnMath {

    /// Abstand zwischen zwei Kacheln. Muss mit dem `spacing` der `LazyVGrid`
    /// übereinstimmen, sonst rechnet diese Datei an der Realität vorbei.
    static let spacing: CGFloat = 16

    /// Das `.padding()` um das Gitter — links und rechts je der Standardwert.
    static let contentPadding: CGFloat = 16

    /// Die Mindestbreite einer vollständigen Kachel inklusive ihres äußeren
    /// Acht-Punkt-Abstands auf beiden Seiten. Der Auswahlrahmen wird um diese
    /// volle Zelle gezeichnet; ohne die 16 Punkte liefen ausgewählte Rahmen
    /// ineinander, obwohl das Raster selbst einen Abstand hatte.
    static func itemMinimum(iconSize: Int) -> CGFloat {
        CGFloat(iconSize + 40 + 16)
    }

    /// Es passen so viele Spalten hinein, wie `n * minimum + (n - 1) * spacing`
    /// in die Breite passen. Ein kleiner Puffer hält Platz für die Scrollleiste.
    static func columns(availableWidth: CGFloat, itemMinimum: CGFloat) -> Int {
        let content = availableWidth - contentPadding * 2 - 16
        guard content > 0, itemMinimum > 0 else { return 1 }
        return max(1, Int((content + spacing) / (itemMinimum + spacing)))
    }

    static func gridItems(count: Int, iconSize: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: itemMinimum(iconSize: iconSize)), spacing: spacing), count: max(count, 1))
    }
}
