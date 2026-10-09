import AppKit
import SwiftUI
import Testing
@testable import FolderApp

/// Baut eine Aufteilung wie im Fenster: Sidebar links, Inhalt rechts.
@MainActor
private func makeSplitView() -> (
    split: FolderNativeSplitView,
    coordinator: NativeSidebarSplitView<Color, Color>.Coordinator,
    presentation: SidebarPresentationState
) {
    let split = FolderNativeSplitView()
    split.isVertical = true
    split.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)

    let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
    let detail = NSView(frame: NSRect(x: 208, y: 0, width: 792, height: 800))
    split.addSubview(sidebar)
    split.addSubview(detail)

    let presentation = SidebarPresentationState()
    let coordinator = NativeSidebarSplitView<Color, Color>.Coordinator(
        presentation: presentation
    )
    split.delegate = coordinator
    split.setPosition(200, ofDividerAt: 0)
    return (split, coordinator, presentation)
}

/// Der Umschalter muss **jedes Mal** wirken.
///
/// Vorher hing er an einem Zustand: Ihn auf einen Wert zu setzen, den er schon
/// hatte, tat nichts — nach einem Aufziehen war der Knopf deshalb tot.
@Test @MainActor func togglingClosesAndOpensAgain() {
    let (split, coordinator, _) = makeSplitView()

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
    let (split, coordinator, _) = makeSplitView()

    coordinator.toggleSidebar(in: split)                      // zu
    #expect(split.subviews[0].frame.width < 1)

    _ = coordinator.revealManuallyCollapsedSidebar(in: split)  // über den Rand auf
    #expect(split.subviews[0].frame.width > 0)

    coordinator.toggleSidebar(in: split)                       // Knopf: wieder zu
    #expect(split.subviews[0].frame.width < 1)
}

/// SwiftUI can leave the split view wider than the visible window. Resizing
/// must use the window's width and restore the sidebar when room returns.
@Test @MainActor func sidebarFollowsVisibleWindowWidth() {
    let (split, coordinator, _) = makeSplitView()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView?.addSubview(split)
    split.windowWidthDidChange = { coordinator.windowWidthDidChange(in: $0) }

    window.setContentSize(NSSize(width: 500, height: 800))
    #expect(split.bounds.width > window.contentView!.bounds.width)
    #expect(split.subviews[0].frame.width < 1)
    #expect(!split.allowsSidebarReveal)

    coordinator.toggleSidebar(in: split)
    #expect(!coordinator.beginRevealDrag(in: split))
    #expect(split.subviews[0].frame.width < 1)

    window.setContentSize(NSSize(width: 1000, height: 800))
    #expect(split.allowsSidebarReveal)
    #expect(split.subviews[0].frame.width >= 160)
}
