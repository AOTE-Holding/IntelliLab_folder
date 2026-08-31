import Foundation
import Testing
@testable import FolderApp

private let datei = URL(fileURLWithPath: "/Users/test/akte.txt")
private let andere = URL(fileURLWithPath: "/Users/test/notiz.txt")

/// Spotlight meldet sich nach einer Änderung noch einmal mit seinem alten Stand.
/// Ohne Vormerkung sprang der Zähler in der Sidebar zurück und ging erst
/// Sekunden später weg.
@Test func aRemovedTagStaysGoneWhileSpotlightIsStillBehind() {
    let (ergebnis, verbleibend) = TagIndex.zusammenfuehren(
        spotlight: [datei: .green],          // Spotlight kennt den Tag noch
        vorgemerkt: [datei: ColorTag.TagColor?.none]  // gerade entfernt
    )

    #expect(ergebnis[datei] == nil)
    #expect(verbleibend.count == 1)          // Vormerkung bleibt bestehen
}

/// Dasselbe beim Setzen: die neue Farbe zählt sofort, nicht erst wenn der
/// Index nachgezogen hat.
@Test func aNewTagCountsImmediately() {
    let (ergebnis, verbleibend) = TagIndex.zusammenfuehren(
        spotlight: [:],
        vorgemerkt: [datei: .purple]
    )

    #expect(ergebnis[datei] == .purple)
    #expect(verbleibend.count == 1)
}

/// Sobald Spotlight dasselbe sagt, verschwindet die Vormerkung — der Index ist
/// danach wieder die alleinige Wahrheit, auch wenn die Datei später woanders
/// geändert wird.
@Test func aPendingChangeIsDroppedOnceSpotlightAgrees() {
    let (ergebnis, verbleibend) = TagIndex.zusammenfuehren(
        spotlight: [datei: .purple],
        vorgemerkt: [datei: .purple]
    )

    #expect(ergebnis[datei] == .purple)
    #expect(verbleibend.isEmpty)
}

/// Eine Vormerkung gilt nur für ihre eigene Datei.
@Test func aPendingChangeDoesNotTouchOtherFiles() {
    let (ergebnis, _) = TagIndex.zusammenfuehren(
        spotlight: [datei: .green, andere: .blue],
        vorgemerkt: [datei: ColorTag.TagColor?.none]
    )

    #expect(ergebnis[datei] == nil)
    #expect(ergebnis[andere] == .blue)
}

/// Ein Farbwechsel schlägt sofort durch, statt beide Zähler kurz gleichzeitig
/// stehen zu lassen.
@Test func changingTheColorMovesTheFileBetweenCountsAtOnce() {
    let (ergebnis, _) = TagIndex.zusammenfuehren(
        spotlight: [datei: .purple],
        vorgemerkt: [datei: .green]
    )

    #expect(ergebnis[datei] == .green)
    #expect(ergebnis.values.contains(.purple) == false)
}
