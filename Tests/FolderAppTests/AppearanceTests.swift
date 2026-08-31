import AppKit
import Testing
@testable import FolderApp

/// Die Einstellung muss auf einem `NSAppearance` landen. Nur das erfasst alle
/// Fenster — `preferredColorScheme` allein färbt nur die SwiftUI-Ansichten
/// innerhalb eines einzelnen Fensters ein.
@Test @MainActor func themeMapsToAWindowAppearance() {
    #expect(AppearanceController.nsAppearance(for: .light)?.name == .aqua)
    #expect(AppearanceController.nsAppearance(for: .dark)?.name == .darkAqua)
}

/// „System" ist kein Fehlerfall, sondern die dritte gültige Wahl: kein
/// erzwungenes Erscheinungsbild, also dem Mac folgen.
@Test @MainActor func systemThemeLeavesTheAppearanceToMacOS() {
    #expect(AppearanceController.nsAppearance(for: .system) == nil)
}

/// Der Fenstergrund darf nicht fest dunkel sein — sonst bleibt das Fenster
/// dunkel, egal was eingestellt ist.
@Test @MainActor func windowBackgroundFollowsTheAppearance() throws {
    let hell = try #require(NSAppearance(named: .aqua))
    let dunkel = try #require(NSAppearance(named: .darkAqua))

    var hellerGrund: NSColor?
    var dunklerGrund: NSColor?
    hell.performAsCurrentDrawingAppearance {
        hellerGrund = NSColor.folderSidebar.usingColorSpace(.sRGB)
    }
    dunkel.performAsCurrentDrawingAppearance {
        dunklerGrund = NSColor.folderSidebar.usingColorSpace(.sRGB)
    }

    let heller = try #require(hellerGrund)
    let dunkler = try #require(dunklerGrund)

    #expect(heller != dunkler)
    #expect(heller.brightnessComponent > dunkler.brightnessComponent)
}
