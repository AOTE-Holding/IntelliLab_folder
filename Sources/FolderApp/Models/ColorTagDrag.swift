//
//  ColorTagDrag.swift
//  Folder
//
//  Eine Farbe, die man aus der Sidebar auf eine Datei ziehen kann.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Ein eigener Typ, damit ein gezogener Tag nichts anderes auslöst.
    ///
    /// Bewusst kein Text: würde die Farbe als Text gezogen, liesse sich jede
    /// beliebige Textauswahl auf eine Datei fallen und würde sie markieren.
    /// Der Typ ist in `Resources/Info.plist.template` angemeldet.
    static let folderColorTag = UTType(exportedAs: "com.intellilab.folder.color-tag")
}

/// Die Fracht beim Ziehen: welche Farbe hängt am Mauszeiger.
///
/// Wird als JSON unter dem Typ oben auf die Zwischenablage gelegt und beim
/// Loslassen dort wieder ausgelesen.
struct ColorTagDrag: Codable {
    let color: ColorTag.TagColor
}
