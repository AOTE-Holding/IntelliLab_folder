import Foundation
import Testing
@testable import FolderApp

/// Legt einen Ordner mit `count` leeren Dateien an und gibt sie als Modelle zurück.
private func makeItems(count: Int) throws -> (items: [FileSystemItem], cleanup: () -> Void) {
    let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("GridArrowNavigationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

    let items = try (0..<count).map { index -> FileSystemItem in
        let datei = ordner.appendingPathComponent(String(format: "datei-%02d.txt", index))
        try Data().write(to: datei)
        return try FileSystemItem(from: datei)
    }

    return (items, { try? FileManager.default.removeItem(at: ordner) })
}

/// Sieben Einträge in drei Spalten:
///
///     0 1 2
///     3 4 5
///     6
@MainActor
private func modelWithSevenResults() throws -> (model: SearchViewModel, cleanup: () -> Void) {
    let (items, cleanup) = try makeItems(count: 7)
    let model = SearchViewModel()
    model.searchResults = items
    return (model, cleanup)
}

@MainActor
private func selectedIndex(_ model: SearchViewModel) -> Int? {
    guard let id = model.selectedItems.first else { return nil }
    return model.searchResults.firstIndex { $0.id == id }
}

@Test @MainActor func arrowDownMovesExactlyOneRowStraightDown() throws {
    let (model, cleanup) = try modelWithSevenResults()
    defer { cleanup() }

    model.selectedItems = [model.searchResults[1].id]   // erste Zeile, mittlere Spalte
    model.selectItemBelow(columnsPerRow: 3)

    #expect(selectedIndex(model) == 4)                  // zweite Zeile, mittlere Spalte
}

@Test @MainActor func arrowUpMovesExactlyOneRowStraightUp() throws {
    let (model, cleanup) = try modelWithSevenResults()
    defer { cleanup() }

    model.selectedItems = [model.searchResults[4].id]
    model.selectItemAbove(columnsPerRow: 3)

    #expect(selectedIndex(model) == 1)
}

/// Vorher wurde auf den letzten Eintrag geklemmt: aus Position 4 wurde 6 —
/// eine Zeile tiefer UND zwei Spalten nach links. Genau das sah schräg aus.
@Test @MainActor func arrowDownInTheLastRowKeepsTheSelectionWhereItIs() throws {
    let (model, cleanup) = try modelWithSevenResults()
    defer { cleanup() }

    model.selectedItems = [model.searchResults[4].id]   // zweite Zeile, mittlere Spalte
    model.selectItemBelow(columnsPerRow: 3)             // darunter liegt in dieser Spalte nichts

    #expect(selectedIndex(model) == 4)
}

/// Dasselbe nach oben: vorher landete man in der linken Ecke statt stehen zu bleiben.
@Test @MainActor func arrowUpInTheFirstRowKeepsTheSelectionWhereItIs() throws {
    let (model, cleanup) = try modelWithSevenResults()
    defer { cleanup() }

    model.selectedItems = [model.searchResults[1].id]
    model.selectItemAbove(columnsPerRow: 3)

    #expect(selectedIndex(model) == 1)
}

@Test @MainActor func arrowKeysStartAtTheFirstEntryWhenNothingIsSelected() throws {
    let (model, cleanup) = try modelWithSevenResults()
    defer { cleanup() }

    model.selectedItems = []
    model.selectItemBelow(columnsPerRow: 3)

    #expect(selectedIndex(model) == 0)
}

/// Die Spaltenzahl folgt derselben Regel, nach der SwiftUI `.adaptive` auflöst.
@Test func gridColumnsFollowTheAdaptiveLayoutRule() {
    let minimum = GridColumnMath.itemMinimum(iconSize: 64)   // 104
    #expect(minimum == 104)

    // 800 - 32 Innenabstand = 768 nutzbar; (768 + 16) / (104 + 16) = 6,53 → 6 Spalten
    #expect(GridColumnMath.columns(availableWidth: 800, itemMinimum: minimum) == 6)

    // Grössere Symbole, dieselbe Breite: weniger Spalten
    #expect(
        GridColumnMath.columns(
            availableWidth: 800,
            itemMinimum: GridColumnMath.itemMinimum(iconSize: 128)
        ) == 4
    )
}

/// Ein schmales Fenster darf nie 0 Spalten ergeben — sonst bewegt sich die
/// Auswahl beim Pfeildruck überhaupt nicht mehr.
@Test func gridColumnsNeverFallBelowOne() {
    let minimum = GridColumnMath.itemMinimum(iconSize: 64)
    #expect(GridColumnMath.columns(availableWidth: 100, itemMinimum: minimum) == 1)
    #expect(GridColumnMath.columns(availableWidth: 0, itemMinimum: minimum) == 1)
    #expect(GridColumnMath.columns(availableWidth: -50, itemMinimum: minimum) == 1)
}
