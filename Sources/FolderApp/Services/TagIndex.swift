//
//  TagIndex.swift
//  Folder
//
//  Welche Dateien im Benutzerordner einen Farb-Tag tragen.
//

import Foundation

/// Hält die Übersicht: welche Datei trägt welchen Farb-Tag.
///
/// Die Tags liegen auf den Dateien, nicht in einer Liste der App. Um zu wissen,
/// welche Dateien überhaupt einen tragen, gibt es nur einen sinnvollen Weg —
/// Spotlight fragen. Genau das macht Finder für seine Tag-Einträge auch.
///
/// Vorher zählte die Sidebar eine app-eigene Liste, die niemand füllte, weil
/// das Kontextmenü keinen Weg anbot, einen Tag zu setzen. Die Liste blieb
/// deshalb dauerhaft leer.
@MainActor
final class TagIndex: ObservableObject {
    static let shared = TagIndex()

    /// Pfad zu Farbe, für alles im Benutzerordner.
    @Published private(set) var taggedFiles: [URL: ColorTag.TagColor] = [:]

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    /// Was Spotlight zuletzt gemeldet hat.
    private var ausSpotlight: [URL: ColorTag.TagColor] = [:]

    /// Was der Nutzer gerade selbst gesetzt hat und was Spotlight noch nicht
    /// weiss. `nil` als Wert heisst: Farbe wurde heruntergenommen.
    private var vorgemerkt: [URL: ColorTag.TagColor?] = [:]

    private init() {
        // Spotlights eigene Abfragesprache, nicht NSPredicate-Syntax:
        // `kMDItemUserTags == "*"` findet jede Datei mit irgendeinem Tag,
        // `LIKE "*"` findet nichts. Nachgemessen mit mdfind.
        query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \"*\"")
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate
        ] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
            observers.append(token)
        }

        query.start()
    }

    /// Nimmt eine gerade gesetzte Farbe sofort auf.
    ///
    /// Spotlight braucht einen Moment, bis es die Änderung sieht — und meldet
    /// sich in der Zwischenzeit noch mit seinem alten Stand. Die eigene Änderung
    /// nur in die Liste zu schreiben genügt deshalb nicht: der nächste Bericht
    /// von Spotlight überschrieb sie wieder, der Zähler sprang zurück und ging
    /// erst Sekunden später weg.
    ///
    /// Sie wird darum zusätzlich vorgemerkt und gewinnt gegen Spotlight, bis der
    /// Index dasselbe sagt.
    func note(_ color: ColorTag.TagColor?, for url: URL) {
        vorgemerkt.updateValue(color, forKey: url.standardizedFileURL)
        veroeffentlichen()
    }

    func color(for url: URL) -> ColorTag.TagColor? {
        taggedFiles[url.standardizedFileURL]
    }

    /// Liefert bewusst **frische** URL-Objekte statt der gespeicherten.
    ///
    /// Foundation puffert Dateieigenschaften an der URL. Die Schlüssel dieser
    /// Liste überleben mehrere Tag-Wechsel, und wer aus ihnen einen Eintrag
    /// baut, bekäme den Stand von vorhin — nach einem Wechsel von Lila auf Grün
    /// stünde in der Grün-Ansicht weiterhin Lila.
    func urls(taggedWith color: ColorTag.TagColor) -> [URL] {
        taggedFiles
            .filter { $0.value == color }
            .map { URL(fileURLWithPath: $0.key.path) }
    }

    func count(of color: ColorTag.TagColor) -> Int {
        taggedFiles.count { $0.value == color }
    }

    private func rebuild() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var gefunden: [URL: ColorTag.TagColor] = [:]
        for zeile in 0..<query.resultCount {
            guard let treffer = query.result(at: zeile) as? NSMetadataItem,
                  let pfad = treffer.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let namen = treffer.value(forAttribute: "kMDItemUserTags") as? [String],
                  let farbe = FinderTagService.color(inSpotlightTagNames: namen)
            else { continue }
            gefunden[URL(fileURLWithPath: pfad).standardizedFileURL] = farbe
        }
        ausSpotlight = gefunden
        veroeffentlichen()
    }

    /// Spotlights Stand, überlagert von dem, was der Nutzer eben getan hat.
    ///
    /// Eine Vormerkung fällt weg, sobald Spotlight dasselbe meldet — danach ist
    /// der Index wieder die alleinige Wahrheit, auch wenn die Datei später
    /// woanders geändert wird.
    private func veroeffentlichen() {
        let (ergebnis, verbleibend) = Self.zusammenfuehren(
            spotlight: ausSpotlight,
            vorgemerkt: vorgemerkt
        )
        vorgemerkt = verbleibend
        taggedFiles = ergebnis
    }

    /// Die reine Rechnung dahinter, ohne Spotlight und ohne Oberfläche.
    nonisolated static func zusammenfuehren(
        spotlight: [URL: ColorTag.TagColor],
        vorgemerkt: [URL: ColorTag.TagColor?]
    ) -> (ergebnis: [URL: ColorTag.TagColor], verbleibend: [URL: ColorTag.TagColor?]) {
        let verbleibend = vorgemerkt.filter { spotlight[$0.key] != $0.value }

        var ergebnis = spotlight
        for (pfad, farbe) in verbleibend {
            if let farbe {
                ergebnis[pfad] = farbe
            } else {
                ergebnis.removeValue(forKey: pfad)
            }
        }
        return (ergebnis, verbleibend)
    }
}
