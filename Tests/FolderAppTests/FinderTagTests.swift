import Foundation
import UniformTypeIdentifiers
import Testing
@testable import FolderApp

private func makeTempFile() throws -> (url: URL, cleanup: () -> Void) {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("FinderTagTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    let datei = ordner.appendingPathComponent("probe.txt")
    try Data("inhalt".utf8).write(to: datei)
    return (datei, { try? FileManager.default.removeItem(at: ordner) })
}

/// Ein gesetzter Tag muss auf der Datei landen und von dort wieder lesbar sein.
@Test func aColorTagIsWrittenToTheFileAndReadBack() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    #expect(FinderTagService.colorTag(for: datei) == nil)

    try FinderTagService.setColorTag(.red, for: datei)
    #expect(FinderTagService.colorTag(for: datei) == .red)

    try FinderTagService.setColorTag(.blue, for: datei)
    #expect(FinderTagService.colorTag(for: datei) == .blue)

    try FinderTagService.setColorTag(nil, for: datei)
    #expect(FinderTagService.colorTag(for: datei) == nil)
}

/// Die Falle: schreibt man nur den Namen, ergänzt macOS `"\n0"` — ein Tag
/// namens Rot, aber ohne Farbe. In Finder erscheint er ohne Punkt. Der
/// Farbindex muss deshalb mitgeschrieben werden.
@Test func theColorNumberIsWrittenAlongWithTheName() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    try FinderTagService.setColorTag(.red, for: datei)

    // Gelesen wird der blosse Name — die Nummer gibt die API nicht zurück.
    let roh = FinderTagService.rawTagNames(for: datei)
    #expect(roh.contains(FinderTagService.name(for: .red)))

    // Dass die Farbe wirklich gesetzt ist, bestätigt macOS über die labelNumber.
    // Sie wäre 0, wenn nur der Name ohne Farbnummer geschrieben worden wäre.
    #expect(FinderTagService.labelNumber(for: datei) == 1)
}

/// Teal belegt Finders Grau-Platz: in Folder Teal, auf der Platte der graue
/// Standard-Tag. Finder kennt kein Teal.
@Test func tealOccupiesFindersGraySlot() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    try FinderTagService.setColorTag(.teal, for: datei)

    #expect(ColorTag.TagColor.teal.labelNumber == 7)
    #expect(FinderTagService.labelNumber(for: datei) == 7)
    #expect(FinderTagService.rawTagNames(for: datei).contains("Gray"))
    #expect(FinderTagService.colorTag(for: datei) == .teal)
}

/// Jede der sieben Farben belegt genau einen eigenen Platz — sonst
/// überschreiben sich zwei gegenseitig.
@Test func everyColorHasItsOwnSlot() {
    let plaetze = ColorTag.TagColor.allCases.map(\.labelNumber)
    #expect(Set(plaetze).count == ColorTag.TagColor.allCases.count)
    #expect(plaetze.allSatisfy { (1...7).contains($0) })

    for farbe in ColorTag.TagColor.allCases {
        #expect(ColorTag.TagColor.withLabelNumber(farbe.labelNumber) == farbe)
    }
}

/// Eigene Tags des Nutzers dürfen beim Farbwechsel nicht verschwinden.
@Test func ownTagsSurviveAColorChange() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    try NSURL(fileURLWithPath: datei.path)
        .setResourceValue(["Steuern 2026", "Rot"] as NSArray, forKey: .tagNamesKey)

    try FinderTagService.setColorTag(.green, for: datei)

    let roh = FinderTagService.rawTagNames(for: datei)
    #expect(roh.contains { $0.hasPrefix("Steuern 2026") })
    #expect(FinderTagService.colorTag(for: datei) == .green)

    try FinderTagService.setColorTag(nil, for: datei)
    let danach = FinderTagService.rawTagNames(for: datei)
    #expect(danach.contains { $0.hasPrefix("Steuern 2026") })
    #expect(FinderTagService.colorTag(for: datei) == nil)
}

/// Der Tag hängt an der Datei, nicht an ihrem Pfad — er überlebt das Umbenennen.
/// Genau daran scheiterte die frühere app-eigene Liste.
@Test func aTagSurvivesRenaming() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    try FinderTagService.setColorTag(.purple, for: datei)

    let neu = datei.deletingLastPathComponent().appendingPathComponent("anders.txt")
    try FileManager.default.moveItem(at: datei, to: neu)

    #expect(FinderTagService.colorTag(for: neu) == .purple)
}

/// Spotlight liefert den Namen ohne die Farbnummer. Die Zuordnung muss auch
/// über den blossen Namen gelingen, sonst bleibt die Sidebar leer.
@Test func spotlightNamesWithoutANumberStillMapToAColor() {
    let rot = FinderTagService.name(for: .red)
    #expect(FinderTagService.color(inSpotlightTagNames: [rot]) == .red)
    #expect(FinderTagService.color(inSpotlightTagNames: ["Steuern 2026"]) == nil)
}

/// Die Namen kommen von diesem Mac, damit ein deutsches System „Rot" schreibt
/// und nicht einen zweiten, farblosen Tag namens „Red" anlegt.
@Test func standardNamesCoverAllSevenSlots() {
    #expect(FinderTagService.standardNames.count == 8)   // Platz 0 ist unbenutzt
    for farbe in ColorTag.TagColor.allCases {
        #expect(!FinderTagService.name(for: farbe).isEmpty)
    }
}

/// Ein Eintrag, der aus einer getaggten Datei entsteht, muss die Farbe
/// mitbringen. Fehlte sie, hielt die App die Datei für unmarkiert — in der
/// Tag-Ansicht blieb „Remove Tag" deshalb ausgegraut.
@Test func anItemBuiltFromATaggedFileCarriesItsColor() throws {
    let (datei, cleanup) = try makeTempFile()
    defer { cleanup() }

    try FinderTagService.setColorTag(.purple, for: datei)

    let eintrag = try FileSystemItem(from: datei)
    #expect(eintrag.colorTag == .purple)

    try FinderTagService.setColorTag(nil, for: datei)

    // Frisches URL-Objekt: Foundation puffert Dateieigenschaften an der URL,
    // ueber die schon einmal gelesen wurde. Wer dieselbe weiterverwendet,
    // bekommt den Stand von vorhin. Deshalb liefert der TagIndex seine
    // Ergebnisse ebenfalls als frische Objekte.
    let frisch = URL(fileURLWithPath: datei.path)
    #expect(try FileSystemItem(from: frisch).colorTag == nil)

    // Und die alte URL zeigt tatsaechlich noch den alten Stand — damit nicht
    // jemand spaeter denkt, der Umweg sei ueberfluessig.
    #expect(try FileSystemItem(from: datei).colorTag == .purple)
}

/// Die gezogene Farbe muss über die Zwischenablage und zurück kommen. Passt die
/// Kodierung nicht zusammen, lehnt das Ziel den Zug ab — sichtbar als
/// Verbotsschild am Mauszeiger.
@Test func aDraggedColorSurvivesEncodingAndDecoding() throws {
    for farbe in ColorTag.TagColor.allCases {
        let daten = try JSONEncoder().encode(ColorTagDrag(color: farbe))
        let zurueck = try JSONDecoder().decode(ColorTagDrag.self, from: daten)
        #expect(zurueck.color == farbe)
    }
}

/// Der gezogene Typ ist ein eigener. Waere es schlichter Text, liesse sich jede
/// Textauswahl auf eine Datei fallen und wuerde sie markieren.
@Test func theDraggedTypeIsOurOwn() {
    #expect(UTType.folderColorTag.identifier == "com.intellilab.folder.color-tag")
    #expect(UTType.folderColorTag != .text)
}
