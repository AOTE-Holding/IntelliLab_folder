//
//  SettingsNavigation.swift
//  Folder
//
//  Welcher Bereich der Einstellungen gezeigt wird.
//

import Foundation

/// Merkt sich, welcher Bereich im Einstellungsfenster offen sein soll.
///
/// Das Fenster wird beim ersten Öffnen gebaut und danach wiederverwendet. Ein
/// Menüpunkt, der einen bestimmten Bereich meint, kann ihn deshalb nicht beim
/// Erzeugen mitgeben — er braucht einen Weg, ihn auch an ein bereits offenes
/// Fenster zu melden. Genau der fehlte: „Permissions…" rief dieselbe Funktion
/// auf wie „Settings…" und landete darum immer im allgemeinen Bereich.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    enum Tab: Hashable {
        case general
        case permissions
    }

    /// Bleibt zwischen zwei Aufrufen stehen: Wer die Einstellungen über
    /// „Settings…" öffnet, landet dort, wo er zuletzt war.
    @Published var selectedTab: Tab = .general

    private init() {}
}
