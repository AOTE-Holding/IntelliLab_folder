//
//  WindowControlsInset.swift
//  Folder
//
//  Der Platz, den die Ampelknöpfe oben links belegen.
//

import Foundation

/// Wie weit die Schliessen/Minimieren/Vollbild-Knöpfe in das Fenster hineinragen.
///
/// **Feste Werte, bewusst.** Vorher wurde die Lage der Knöpfe laufend gemessen
/// und der Abstand daraus abgeleitet. Das war beweglicher als nötig: Beim Ziehen
/// der Sidebar verschob der Trennbereich die Leiste, die Messung hinkte hinterher
/// und der zuletzt gemessene Abstand blieb als Lücke stehen. Ein Wert, der sich
/// bewegen kann, kann auch falsch stehen bleiben.
///
/// macOS setzt diese Knöpfe in jedem gewöhnlichen Fenster an dieselbe Stelle.
/// Nachgemessen an einem Standardfenster: sie belegen waagerecht 7 bis 61 Punkt
/// und senkrecht die obersten 6 bis 22 Punkt.
enum WindowControls {

    /// Einrückung für die Navigationsleiste, wenn sie am Fensterrand beginnt.
    ///
    /// 61 Punkt bis zum Ende des letzten Knopfes, plus 12 Punkt Luft, minus die
    /// 12 Punkt Rand, die der Inhaltsbereich ohnehin schon hält.
    static let leadingInset: CGFloat = 61

    /// Abstand für alles, was am oberen Fensterrand beginnt — die Sidebar.
    ///
    /// 22 Punkt bis zur Unterkante der Knöpfe, plus 4 Punkt Luft.
    static let topInset: CGFloat = 26
}
