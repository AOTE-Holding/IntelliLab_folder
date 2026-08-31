//
//  AppleScriptLiteral.swift
//  Folder
//
//  Text sicher in ein AppleScript einsetzen.
//

import Foundation

/// Setzt Text als Zeichenkette in ein AppleScript ein.
///
/// Ein Dateipfad darf Anführungszeichen und Rückwärtsschrägstriche enthalten.
/// Wird er ungeprüft zwischen zwei Anführungszeichen gestellt, endet die
/// Zeichenkette an der falschen Stelle: das Skript ist dann entweder ungültig
/// oder tut etwas anderes als gemeint. Ein Ordner namens `Mein "Projekt"`
/// genügt dafür.
enum AppleScriptLiteral {

    /// Gibt den Text **einschliesslich** der umschliessenden Anführungszeichen
    /// zurück — so kann der Aufrufer sie nicht versehentlich weglassen.
    ///
    /// Reihenfolge zwingend: erst der Rückwärtsschrägstrich, dann das
    /// Anführungszeichen. Andersherum würde der eben eingefügte Schrägstrich
    /// gleich wieder verdoppelt.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
