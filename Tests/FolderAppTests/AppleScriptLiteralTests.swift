import Foundation
import Testing
@testable import FolderApp

/// Ein Pfad mit Anführungszeichen darf die Zeichenkette im Skript nicht
/// vorzeitig beenden. Ein Ordner namens `Mein "Projekt"` genügt dafür.
@Test func aQuoteInAPathDoesNotEndTheScriptString() {
    let literal = AppleScriptLiteral.quoted("/Users/test/Mein \"Projekt\"")

    #expect(literal == "\"/Users/test/Mein \\\"Projekt\\\"\"")
    // Genau zwei unmaskierte Anführungszeichen: Anfang und Ende.
    #expect(unmaskierteAnfuehrungszeichen(in: literal) == 2)
}

/// Rückwärtsschrägstriche werden zuerst verdoppelt. Andersherum würde der beim
/// Maskieren eingefügte Schrägstrich gleich wieder mitverdoppelt.
@Test func aBackslashIsDoubledBeforeQuotesAreEscaped() {
    #expect(AppleScriptLiteral.quoted("a\\b") == "\"a\\\\b\"")
    #expect(AppleScriptLiteral.quoted("a\\\"b") == "\"a\\\\\\\"b\"")
}

/// Gewöhnliche Pfade bleiben unverändert — auch die mit Punkt am Anfang und
/// mit Leerzeichen, um die es im Befund ging.
@Test func ordinaryPathsPassThroughUnchanged() {
    #expect(AppleScriptLiteral.quoted("/Users/test/.claude") == "\"/Users/test/.claude\"")
    #expect(AppleScriptLiteral.quoted("/Users/test/Mein Ordner") == "\"/Users/test/Mein Ordner\"")
}

/// Die Anführungszeichen gehören zum Ergebnis, damit der Aufrufer sie nicht
/// vergessen kann.
@Test func theResultBringsItsOwnQuotes() {
    let literal = AppleScriptLiteral.quoted("x")
    #expect(literal.hasPrefix("\""))
    #expect(literal.hasSuffix("\""))
}

private func unmaskierteAnfuehrungszeichen(in text: String) -> Int {
    var anzahl = 0
    var maskiert = false
    for zeichen in text {
        if maskiert {
            maskiert = false
        } else if zeichen == "\\" {
            maskiert = true
        } else if zeichen == "\"" {
            anzahl += 1
        }
    }
    return anzahl
}
