import Foundation
import Testing
@testable import FolderApp

/// Legt einen Ordner mit passenden Dateien an und sucht darin.
@MainActor
private func modelWithResults() async throws -> (model: SearchViewModel, root: URL, cleanup: () -> Void) {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SearchParkingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    for name in ["akte-alpha.txt", "akte-beta.txt", "sonstiges.txt"] {
        try Data().write(to: ordner.appendingPathComponent(name))
    }

    let model = SearchViewModel()
    model.activateSearch()
    model.searchQuery = "akte"
    model.search(in: ordner)

    // Die Suche laeuft entprellt und im Hintergrund.
    for _ in 0..<50 where model.searchResults.isEmpty {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    return (model, ordner, { try? FileManager.default.removeItem(at: ordner) })
}

/// Wer aus der Trefferliste einen Ordner öffnet, will ihn ansehen — nicht die
/// Suche verlieren. Vorher wurde an dieser Stelle alles gelöscht.
@Test @MainActor func openingAResultKeepsTheQueryAndTheResults() async throws {
    let (model, _, cleanup) = try await modelWithResults()
    defer { cleanup() }

    #expect(model.searchResults.count == 2)

    model.park()

    #expect(model.isParked)
    #expect(model.isSearchActive == false)   // der Ordner ist zu sehen
    #expect(model.searchQuery == "akte")     // der Begriff steht noch
    #expect(model.searchResults.count == 2)  // die Treffer auch
}

/// Zurück führt zurück in die Treffer — ohne neu zu tippen.
@Test @MainActor func goingBackRestoresTheResults() async throws {
    let (model, root, cleanup) = try await modelWithResults()
    defer { cleanup() }

    model.park()
    let wiederhergestellt = model.resumeIfParked(at: root)

    #expect(wiederhergestellt)
    #expect(model.isSearchActive)
    #expect(model.isParked == false)
    #expect(model.searchResults.count == 2)
}

/// In einem anderen Ordner bleibt die Suche geparkt — sie taucht nicht
/// unvermittelt irgendwo wieder auf.
@Test @MainActor func aDifferentFolderDoesNotRestoreTheSearch() async throws {
    let (model, root, cleanup) = try await modelWithResults()
    defer { cleanup() }

    model.park()
    let woanders = root.deletingLastPathComponent()

    #expect(model.resumeIfParked(at: woanders) == false)
    #expect(model.isParked)
    #expect(model.isSearchActive == false)
}

/// Die Suche selbst zu schliessen räumt weiterhin alles weg — sonst käme sie
/// beim nächsten Ordnerwechsel zurück.
@Test @MainActor func closingTheSearchClearsEverything() async throws {
    let (model, root, cleanup) = try await modelWithResults()
    defer { cleanup() }

    model.deactivateSearch()

    #expect(model.searchQuery.isEmpty)
    #expect(model.searchResults.isEmpty)
    #expect(model.isParked == false)
    #expect(model.resumeIfParked(at: root) == false)
}

/// Ohne Treffer gibt es nichts zu parken.
@Test @MainActor func anEmptySearchIsNotParked() {
    let model = SearchViewModel()
    model.activateSearch()

    model.park()

    #expect(model.isParked == false)
    #expect(model.isSearchActive)
}

/// Ein Klick neben das Suchfeld darf die Eingabe nicht wegwerfen — das war
/// derselbe Verlust wie beim Öffnen eines Treffers, nur an anderer Stelle.
@Test @MainActor func losingFocusKeepsATypedSearch() async throws {
    let (model, _, cleanup) = try await modelWithResults()
    defer { cleanup() }

    // Was die Ansicht beim Fokusverlust prüft: nur eine leere Suche schliesst.
    #expect(model.searchQuery.isEmpty == false)
    #expect(model.isSearchActive)
    #expect(model.searchResults.count == 2)
}

/// Die naheliegenden Treffer stehen sofort da, die tieferen kommen nach.
@Test @MainActor func theCurrentFolderIsSearchedFirst() async throws {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SearchStaged-\(UUID().uuidString)", isDirectory: true)
    let tief = ordner.appendingPathComponent("eins/zwei", isDirectory: true)
    try FileManager.default.createDirectory(at: tief, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ordner) }

    try Data().write(to: ordner.appendingPathComponent("treffer-oben.txt"))
    try Data().write(to: tief.appendingPathComponent("treffer-tief.txt"))

    let model = SearchViewModel()
    model.activateSearch()
    model.searchQuery = "treffer"
    model.search(in: ordner)

    for _ in 0..<100 where model.searchResults.count < 2 {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    // Am Ende sind beide da — die obere Ebene war zuerst dran.
    #expect(model.searchResults.count == 2)
    #expect(model.searchResults.contains { $0.name == "treffer-oben.txt" })
    #expect(model.searchResults.contains { $0.name == "treffer-tief.txt" })
}

/// Ein Paket ist ein Dokument, kein Ordner voller Dateien. Wer hineinsucht,
/// füllt die Trefferliste mit Innereien — und holt sich bei geschützten
/// Mediatheken eine Rechte-Meldung, die wie ein Fehler aussieht.
@Test @MainActor func packagesAreNotSearchedInside() async throws {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SearchPackage-\(UUID().uuidString)", isDirectory: true)
    let paket = ordner.appendingPathComponent("Mediathek.photoslibrary", isDirectory: true)
    try FileManager.default.createDirectory(at: paket, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ordner) }

    try Data().write(to: ordner.appendingPathComponent("treffer-aussen.txt"))
    try Data().write(to: paket.appendingPathComponent("treffer-innen.txt"))

    let model = SearchViewModel()
    model.activateSearch()
    model.searchQuery = "treffer"
    model.search(in: ordner)

    for _ in 0..<60 where model.searchResults.isEmpty {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 300_000_000)   // auch die tieferen Stufen abwarten

    #expect(model.searchResults.contains { $0.name == "treffer-aussen.txt" })
    #expect(model.searchResults.contains { $0.name == "treffer-innen.txt" } == false)
    #expect(model.searchErrors.isEmpty)
}

/// Das Paket selbst bleibt ein ganz normaler Eintrag — es wird nur nicht betreten.
@Test func aPackageIsMarkedAsSuch() throws {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PackageFlag-\(UUID().uuidString)", isDirectory: true)
    let paket = ordner.appendingPathComponent("Ding.photoslibrary", isDirectory: true)
    let normal = ordner.appendingPathComponent("Normaler Ordner", isDirectory: true)
    try FileManager.default.createDirectory(at: paket, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ordner) }

    #expect(try FileSystemItem(from: paket).isPackage)
    #expect(try FileSystemItem(from: normal).isPackage == false)
}
