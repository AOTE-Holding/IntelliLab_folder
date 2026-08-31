//
//  AppearanceController.swift
//  Folder
//
//  Setzt das gewählte Erscheinungsbild auf die ganze App.
//

import AppKit

/// Trägt die Einstellung „Theme" dorthin, wo sie wirkt: auf `NSApp.appearance`.
///
/// Vorher stand die Auswahl nur als `preferredColorScheme` an der SwiftUI-Wurzel
/// des Browserfensters. Das färbt die SwiftUI-Ansichten *innerhalb* dieses einen
/// Fensters ein und sonst nichts — Fensterrahmen, Titelleiste, Fenstergrund und
/// jedes weitere Fenster (Einstellungen, Info, Onboarding) blieben beim
/// Systemwert. Auf einem dunkel eingestellten Mac sah man deshalb nach der Wahl
/// von „Light" keinerlei Veränderung.
///
/// `NSApp.appearance` ist die eine Stelle, die alle Fenster erfasst, auch die,
/// die es beim Umschalten noch gar nicht gibt.
@MainActor
enum AppearanceController {

    private static var observer: NSObjectProtocol?

    /// Einmal beim Start aufrufen. Setzt das Erscheinungsbild und hält es
    /// danach an der Einstellung.
    static func start() {
        apply(SettingsManager.shared.settings.theme)

        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                apply(SettingsManager.shared.settings.theme)
            }
        }
    }

    static func apply(_ theme: AppSettings.Theme) {
        NSApp.appearance = nsAppearance(for: theme)
    }

    /// `nil` heisst: dem System folgen. Das ist kein Fehlerfall, sondern die
    /// dritte gültige Wahl.
    static func nsAppearance(for theme: AppSettings.Theme) -> NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}
