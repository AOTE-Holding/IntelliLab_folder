import AppKit
import SwiftUI
import Testing
@testable import FolderApp

/// Baut eine Aufteilung wie im Fenster: Sidebar links, Inhalt rechts.
@MainActor
private func makeSplitView(collapsed: Binding<Bool>) -> (
    split: FolderNativeSplitView,
    coordinator: NativeSidebarSplitView<Color, Color>.Coordinator
) {
    let split = FolderNativeSplitView()
    split.isVertical = true
    split.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)

    let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
    let detail = NSView(frame: NSRect(x: 208, y: 0, width: 792, height: 800))
    split.addSubview(sidebar)
    split.addSubview(detail)

    let coordinator = NativeSidebarSplitView<Color, Color>.Coordinator(
        isEffectivelyCollapsed: collapsed
    )
    split.delegate = coordinator
    split.setPosition(200, ofDividerAt: 0)
    return (split, coordinator)
}

/// Der Umschalter muss **jedes Mal** wirken.
///
/// Vorher hing er an einem Zustand: Ihn auf einen Wert zu setzen, den er schon
/// hatte, tat nichts — nach einem Aufziehen oder nach dem automatischen
/// Zuklappen im schmalen Fenster war der Knopf deshalb tot.
@Test @MainActor func togglingClosesAndOpensAgain() {
    var zustand = false
    let bindung = Binding(get: { zustand }, set: { zustand = $0 })
    let (split, coordinator) = makeSplitView(collapsed: bindung)

    #expect(split.subviews[0].frame.width > 0)

    coordinator.toggleSidebar(in: split)
    #expect(split.subviews[0].frame.width < 1)

    coordinator.toggleSidebar(in: split)
    #expect(split.subviews[0].frame.width > 0)

    coordinator.toggleSidebar(in: split)
    #expect(split.subviews[0].frame.width < 1)
}

/// Auch nach dem Aufziehen über den Rand bleibt der Umschalter wirksam —
/// genau die Abfolge, in der er zuletzt hängenblieb.
@Test @MainActor func theToggleStillWorksAfterRevealingFromTheEdge() {
    var zustand = false
    let bindung = Binding(get: { zustand }, set: { zustand = $0 })
    let (split, coordinator) = makeSplitView(collapsed: bindung)

    coordinator.toggleSidebar(in: split)                      // zu
    #expect(split.subviews[0].frame.width < 1)

    _ = coordinator.revealManuallyCollapsedSidebar(in: split)  // über den Rand auf
    #expect(split.subviews[0].frame.width > 0)

    coordinator.toggleSidebar(in: split)                       // Knopf: wieder zu
    #expect(split.subviews[0].frame.width < 1)
}
