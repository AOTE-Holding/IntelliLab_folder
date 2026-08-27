import SwiftUI
import AppKit

struct QuickLookSourceAnchor: NSViewRepresentable {
    let url: URL
    let transitionImage: NSImage

    func makeNSView(context: Context) -> SourceFrameView {
        let view = SourceFrameView()
        view.url = url
        view.transitionImage = transitionImage
        return view
    }

    func updateNSView(_ nsView: SourceFrameView, context: Context) {
        let sourceChanged = nsView.url?.standardizedFileURL != url.standardizedFileURL
        let imageChanged = nsView.transitionImage !== transitionImage
        nsView.url = url
        nsView.transitionImage = transitionImage
        // Selection changes redraw file cells but do not move their source
        // geometry. Avoid scheduling one MainActor registration per visible
        // cell for those no-op redraws.
        if sourceChanged || imageChanged {
            nsView.reportFrame()
        }
    }

    static func dismantleNSView(_ nsView: SourceFrameView, coordinator: ()) {
        guard let url = nsView.url else { return }
        Task { @MainActor in
            QuickLookManager.shared.unregisterSourceFrame(for: url, identifier: nsView.sourceIdentifier)
        }
    }
}

final class SourceFrameView: NSView {
    let sourceIdentifier = UUID()
    var url: URL?
    var transitionImage: NSImage?
    private var lastReportedFrame: NSRect?
    private weak var lastReportedImage: NSImage?
    private var isRegistered = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGeometryObservers()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    private func updateGeometryObservers() {
        NotificationCenter.default.removeObserver(self)

        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(geometryDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(geometryDidChange(_:)),
                    name: name,
                    object: window
                )
            }
        }
    }

    @objc private func geometryDidChange(_ notification: Notification) {
        reportFrame()
    }

    func reportFrame() {
        guard let url, let transitionImage else { return }
        guard let window,
              !isHidden,
              bounds.width > 0,
              bounds.height > 0,
              visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
              window.occlusionState.contains(.visible) else {
            unregisterIfNeeded(url: url)
            return
        }
        let windowRect = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        guard screenRect.width > 1, screenRect.height > 1 else {
            unregisterIfNeeded(url: url)
            return
        }
        guard !isRegistered || lastReportedFrame != screenRect || lastReportedImage !== transitionImage else {
            return
        }
        lastReportedFrame = screenRect
        lastReportedImage = transitionImage
        isRegistered = true
        Task { @MainActor in
            QuickLookManager.shared.registerSourceFrame(
                screenRect,
                image: transitionImage,
                for: url,
                identifier: sourceIdentifier
            )
        }
    }

    private func unregisterIfNeeded(url: URL) {
        guard isRegistered else { return }
        isRegistered = false
        lastReportedFrame = nil
        lastReportedImage = nil
        Task { @MainActor in
            QuickLookManager.shared.unregisterSourceFrame(for: url, identifier: sourceIdentifier)
        }
    }
}
