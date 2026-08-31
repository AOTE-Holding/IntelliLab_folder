//
//  FinderTagService.swift
//  Folder
//
//  Farb-Tags lesen und schreiben — als echte Finder-Tags auf der Datei.
//

import Foundation

/// Liest und schreibt die Farb-Tags von macOS.
///
/// Die Tags liegen auf der Datei selbst, im erweiterten Attribut
/// `com.apple.metadata:_kMDItemUserTags`. Das ist dieselbe Ablage, die Finder
/// benutzt: ein Tag, den Folder setzt, ist in Finder sichtbar und umgekehrt.
/// Er überlebt Umbenennen und Verschieben, weil er an der Datei hängt und nicht
/// an ihrem Pfad.
///
/// Vorher führte Folder eine eigene Liste in den Einstellungen, die einen Pfad
/// auf eine Farbe abbildete. Die kannte Finder nicht, und beim ersten Umbenennen
/// zeigte sie ins Leere.
///
/// **Schreiben und Lesen sind nicht symmetrisch — das ist die Falle.**
/// Geschrieben wird ein Text aus Name und Farbnummer, getrennt durch einen
/// Zeilenumbruch: `"Red\n1"`. Schreibt man nur `"Red"`, ergänzt macOS still
/// `"\n0"`, und das ist ein Tag mit dem Namen Rot und *ohne* Farbe — in Finder
/// ohne Punkt. Gelesen wird über `tagNames` aber nur der blosse Name
/// zurückgegeben, die Nummer fehlt dort. Die Farbe steht stattdessen in
/// `labelNumber`. Beides nachgemessen, nicht aus der Dokumentation abgeleitet.
enum FinderTagService {

    // MARK: - Die sieben Plätze

    /// Die Plätze in der Reihenfolge von Finders `FavoriteTagNames`. Der Index
    /// ist genau die `labelNumber`, die macOS zurückmeldet. Platz 0 ist leer.
    private static let englishNames = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    /// Wie die sieben Plätze auf diesem Mac heissen.
    ///
    /// Finder legt seine übersetzten Namen unter `FavoriteTagNames` ab. Auf einem
    /// deutschen System steht dort „Rot" statt „Red", und ein Tag namens „Red"
    /// wäre dort ein eigener, farbloser Tag neben dem roten. Fehlt der Eintrag,
    /// gelten die englischen Namen — das ist auch der Auslieferungszustand.
    static let standardNames: [String] = {
        guard let finder = UserDefaults.standard.persistentDomain(forName: "com.apple.finder"),
              let namen = finder["FavoriteTagNames"] as? [String],
              namen.count == englishNames.count
        else { return englishNames }
        // Ein leerer Eintrag ist kein Name. Dann lieber den englischen nehmen,
        // als einen namenlosen Tag zu schreiben.
        return zip(namen, englishNames).map { $0.isEmpty ? $1 : $0 }
    }()

    static func name(for color: ColorTag.TagColor) -> String {
        let nummer = color.labelNumber
        guard standardNames.indices.contains(nummer) else { return englishNames[nummer] }
        return standardNames[nummer]
    }

    // MARK: - Lesen

    /// Die Farbe, die auf dieser Datei liegt — oder `nil`, wenn keine drauf ist.
    static func colorTag(for url: URL) -> ColorTag.TagColor? {
        color(forLabelNumber: labelNumber(for: url))
    }

    /// Aus der `labelNumber` die Farbe machen. Öffentlich, weil das Einlesen
    /// eines Ordners die Nummer ohnehin schon hat und keinen zweiten Zugriff
    /// auf die Platte machen soll.
    static func color(forLabelNumber number: Int?) -> ColorTag.TagColor? {
        guard let number, (1...7).contains(number) else { return nil }
        return ColorTag.TagColor.withLabelNumber(number)
    }

    /// Dasselbe für die Namen, die Spotlight liefert.
    ///
    /// Spotlight kennt nur Namen, keine Nummern. Die Farbe muss deshalb über
    /// den Namen zugeordnet werden, und zwar über die übersetzten Namen dieses Macs.
    static func color(inSpotlightTagNames tagNames: [String]) -> ColorTag.TagColor? {
        for eintrag in tagNames {
            let name = eintrag.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? eintrag
            guard let nummer = standardNames.firstIndex(of: name), nummer > 0,
                  let farbe = ColorTag.TagColor.withLabelNumber(nummer) else { continue }
            return farbe
        }
        return nil
    }

    // MARK: - Schreiben

    /// Setzt die Farbe auf der Datei. `nil` nimmt sie herunter.
    ///
    /// Eigene, selbst vergebene Tags des Nutzers bleiben stehen — ersetzt wird
    /// nur der farbige. Alles andere wäre stiller Datenverlust an einer Stelle,
    /// an der niemand damit rechnet.
    static func setColorTag(_ color: ColorTag.TagColor?, for url: URL) throws {
        let bisherige = rawTagNames(for: url)
        var neue = bisherige.filter { !isStandardColorName($0) }

        if let color {
            neue.append("\(name(for: color))\n\(color.labelNumber)")
        }

        try NSURL(fileURLWithPath: url.path)
            .setResourceValue(neue as NSArray, forKey: .tagNamesKey)
    }

    // MARK: - Innereien

    /// Die rohen Tag-Namen der Datei, frisch von der Platte.
    ///
    /// Foundation puffert Ressourcenwerte an der URL. Wer einmal gelesen, dann
    /// geschrieben und danach wieder gelesen hat, bekam den alten Stand aus dem
    /// Puffer — der eben gesetzte Tag schien nicht anzukommen. Deshalb für jeden
    /// Zugriff ein frisches Objekt mit geleertem Puffer.
    static func rawTagNames(for url: URL) -> [String] {
        read(.tagNamesKey, from: url) as? [String] ?? []
    }

    static func labelNumber(for url: URL) -> Int? {
        read(.labelNumberKey, from: url) as? Int
    }

    private static func read(_ key: URLResourceKey, from url: URL) -> AnyObject? {
        let frisch = NSURL(fileURLWithPath: url.path)
        frisch.removeAllCachedResourceValues()
        var wert: AnyObject?
        do {
            try frisch.getResourceValue(&wert, forKey: key)
        } catch {
            return nil
        }
        return wert
    }

    /// Trägt dieser Name einen der sieben Standardplätze? Dann gehört er uns,
    /// alles andere ist ein eigener Tag des Nutzers und bleibt unangetastet.
    private static func isStandardColorName(_ tagName: String) -> Bool {
        let name = tagName.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? tagName
        guard let index = standardNames.firstIndex(of: name) else {
            return englishNames.dropFirst().contains(name)
        }
        return index > 0
    }
}

extension ColorTag.TagColor {
    /// Der Platz dieser Farbe in Finders Farbleiste.
    ///
    /// Teal belegt Finders Grau-Platz: Folder zeigt seinen eigenen Farbton, auf
    /// der Platte steht der graue Standard-Tag. Ein Platz, zwei Namen — Finder
    /// kennt kein Teal, und ein farbloser Tag wäre dort ein Fremdkörper neben
    /// den sechs anderen.
    var labelNumber: Int {
        switch self {
        case .red: return 1
        case .orange: return 2
        case .yellow: return 3
        case .green: return 4
        case .blue: return 5
        case .purple: return 6
        case .teal: return 7   // Finders Grau
        }
    }

    static func withLabelNumber(_ number: Int) -> ColorTag.TagColor? {
        allCases.first { $0.labelNumber == number }
    }
}
