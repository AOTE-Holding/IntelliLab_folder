import Foundation
import Testing
@testable import FolderApp

/// Ein Update, das ein Feld ergänzt, darf nicht die ganze Konfiguration
/// zurücksetzen. Genau daran gingen in 1.2.0 die Einstellungen verloren.
@Test func settingsSurviveAFieldThatDidNotExistYet() throws {
    // So sah der gespeicherte Stand einer älteren Version aus: die später
    // ergänzten Felder fehlen schlicht — und `autoSaveSearchHistory` gibt es
    // inzwischen nicht mehr, steht aber noch in jeder gespeicherten Datei.
    let alterStand = """
    {
      "defaultViewMode": "list",
      "showHiddenFiles": false,
      "autoSaveSearchHistory": true,
      "theme": "light",
      "iconSize": 96,
      "launchAtLogin": true,
      "showMenuBarIcon": false,
      "showSidebar": true,
      "undoRedoEnabled": false
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(alterStand.utf8))

    // Was gespeichert war, bleibt.
    #expect(settings.defaultViewMode == .list)
    #expect(settings.showHiddenFiles == false)
    #expect(settings.theme == .light)
    #expect(settings.iconSize == 96)
    #expect(settings.launchAtLogin == true)
    #expect(settings.undoRedoEnabled == false)

    // Was fehlte, kommt aus den Standardwerten — und nur das.
    #expect(settings.showColorTagsSection == AppSettings.default.showColorTagsSection)
    #expect(settings.defaultTerminal == AppSettings.default.defaultTerminal)
}

/// Der umgekehrte Weg: eine ältere Version liest den Stand einer neueren.
/// Unbekannte Felder werden übergangen statt zum Abbruch zu führen.
@Test func settingsIgnoreFieldsFromANewerVersion() throws {
    let neuererStand = """
    {
      "defaultViewMode": "iconGrid",
      "theme": "dark",
      "iconSize": 48,
      "zukuenftigesFeature": { "an": true }
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(neuererStand.utf8))

    #expect(settings.theme == .dark)
    #expect(settings.iconSize == 48)
}

/// Ein einzelnes kaputtes Feld kostet dieses Feld — nicht alle anderen.
@Test func settingsRecoverFromASingleUnreadableField() throws {
    let beschaedigt = """
    {
      "theme": "dark",
      "iconSize": 112,
      "keyboardShortcuts": "das war einmal ein Objekt"
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(beschaedigt.utf8))

    #expect(settings.theme == .dark)
    #expect(settings.iconSize == 112)
    #expect(settings.keyboardShortcuts.searchEnabled == AppSettings.default.keyboardShortcuts.searchEnabled)
}

/// Die Ablage darf nicht mehr am Bundle-Namen hängen — das war die Ursache.
@Test func configStoreUsesAFixedSuiteRatherThanTheBundleIdentifier() {
    #expect(ConfigStore.suiteName == "com.intellilab.folder")
    #expect(ConfigStore.suiteName != Bundle.main.bundleIdentifier)
}
