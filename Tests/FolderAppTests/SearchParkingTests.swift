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
