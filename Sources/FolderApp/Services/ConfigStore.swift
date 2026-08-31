//
//  ConfigStore.swift
//  Folder
//
//  Die eine Ablage für alles, was Folder sich merkt.
//

import Foundation

/// Wo Folder seine Konfiguration hinlegt — Favoriten, Einstellungen, Tags,
/// Berechtigungen, Fenstermasse.
///
/// Bewusst **nicht** `UserDefaults.standard`: dessen Datei heisst wie der
/// `CFBundleIdentifier`. Als der zwischen 1.1.3 und 1.2.0 von `com.folder.app`
/// auf `com.intellilab.folder.development` wechselte, las die App eine leere
/// Datei. Favoriten, Einstellungen und Tags galten als verloren, obwohl sie
/// unverändert unter dem alten Namen auf der Platte lagen.
///
/// Ein fester Suite-Name entkoppelt die Ablage vom Bundle. Ob die App künftig
/// als Entwicklungs- oder Release-Build läuft oder noch einmal umbenannt wird,
/// ändert nichts mehr daran, wo die Konfiguration steht.
enum ConfigStore {

    /// Fest verdrahtet und ab hier unveränderlich. Wer ihn anfasst, wiederholt
    /// genau den Fehler, den diese Datei behebt.
    static let suiteName = "com.intellilab.folder"

    /// Ablagen früherer Versionen, aus denen einmalig übernommen wird —
    /// **neueste zuerst**. `nil` steht für die bundle-abhängige Standardablage
    /// der gerade laufenden App.
    ///
    /// Zusammen mit der Regel „nur Lücken füllen" gewinnt damit pro Schlüssel
    /// die jüngste Quelle: was der Nutzer zuletzt eingestellt hat, ist das,
    /// was er meint. Und was schon in der Suite steht, bleibt unangetastet —
    /// so lässt sich ein Wert von Hand vorlegen, ohne dass die Übernahme ihn
    /// wieder überschreibt.
    private static let legacyDomains: [String?] = [
        nil,                // 1.2.0 — com.intellilab.folder[.development]
        "com.folder.app"    // bis einschliesslich 1.1.3
    ]

    private static let migrationMarker = "configStore.migratedFromLegacyDomains"

    /// Präfixe, die AppKit und das System selbst verwalten. Die gehören in die
    /// bundle-eigene Ablage und haben in einer geteilten Suite nichts verloren.
    private static let systemPrefixes = ["NS", "Apple", "com.apple.", "WebKit"]

    /// Die Ablage. Beim ersten Zugriff läuft die Übernahme aus den alten
    /// Domains — dadurch ist sie garantiert durch, bevor irgendein Manager
    /// zum ersten Mal liest, egal in welcher Reihenfolge die starten.
    /// `nonisolated(unsafe)`, weil `UserDefaults` nicht als `Sendable` markiert
    /// ist, laut Apple-Dokumentation aber threadsicher ist. Die einmalige
    /// Initialisierung übernimmt Swift, sie läuft garantiert genau einmal.
    nonisolated(unsafe) static let shared: UserDefaults = {
        guard let suite = UserDefaults(suiteName: suiteName) else {
            // Schlägt nur fehl, wenn der Suite-Name dem Bundle entspricht.
            // Dann ist `.standard` ohnehin dieselbe Datei.
            return .standard
        }
        migrate(into: suite)
        return suite
    }()

    /// Holt die Werte alter Versionen einmalig herüber.
    ///
    /// Läuft genau einmal. Danach ist die Suite die Wahrheit. Die alten Dateien
    /// werden nicht gelöscht — sie sind die einzige Sicherung, die es von der
    /// Konfiguration gibt, und sie kosten ein paar Kilobyte.
    private static func migrate(into suite: UserDefaults) {
        guard !suite.bool(forKey: migrationMarker) else { return }

        for domain in legacyDomains {
            guard let name = domainName(for: domain),
                  name != suiteName,
                  let werte = UserDefaults.standard.persistentDomain(forName: name)
            else { continue }

            for (schluessel, wert) in werte
            where !isSystemKey(schluessel) && suite.object(forKey: schluessel) == nil {
                suite.set(wert, forKey: schluessel)
            }
        }

        suite.set(true, forKey: migrationMarker)
    }

    private static func domainName(for domain: String?) -> String? {
        domain ?? Bundle.main.bundleIdentifier
    }

    private static func isSystemKey(_ schluessel: String) -> Bool {
        systemPrefixes.contains { schluessel.hasPrefix($0) }
    }
}
