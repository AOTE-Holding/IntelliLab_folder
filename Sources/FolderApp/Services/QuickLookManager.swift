import Foundation
import AppKit
@preconcurrency import Quartz
@preconcurrency import QuickLookThumbnailing

private struct SendableTransitionImage: @unchecked Sendable {
    let image: NSImage
    let contentRect: NSRect
}

private struct QuickLookSource {
    let identifier: UUID
    let frame: NSRect
    let image: NSImage
    let contentRect: NSRect
}

private struct PreviewScrollInput: Sendable {
    let horizontal: CGFloat
    let vertical: CGFloat
    let hasPreciseDeltas: Bool
    let began: Bool
}

/// AppKit invokes NSWindowDelegate callbacks on the main thread, but the
/// Objective-C delegate requirement is imported as nonisolated in Swift 6.
/// This wrapper makes that main-thread handoff explicit before we access the
/// panel's MainActor-isolated geometry.
private struct MainThreadPreviewPanel: @unchecked Sendable {
    let panel: QLPreviewPanel
}

private final class ManagedQuickLookItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let sourceURL: URL
    let previewItemURL: URL?
    let previewItemTitle: String?
    let isFolder: Bool

    init(sourceURL: URL, previewURL: URL, title: String, isFolder: Bool) {
        self.sourceURL = sourceURL
        self.previewItemURL = previewURL
        self.previewItemTitle = title
        self.isFolder = isFolder
    }
}

private struct PreparedQuickLookSession {
    let items: [ManagedQuickLookItem]
    let generatedDirectory: URL?
}

/// Manager for Quick Look preview functionality
@MainActor
class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookManager()
    private static let folderEntryPreviewRequest = Notification.Name("com.intellilab.folder.quicklook.preview-entry")
    private static let finderPreviewContentSize = NSSize(width: 1_040, height: 780)
    private static let standardPreviewFallbackSize = NSSize(width: 900, height: 650)
    private static let standardPreviewWidthKey = "quickLook.standardPreviewWidth"
    private static let standardPreviewHeightKey = "quickLook.standardPreviewHeight"

    private var previewItems: [ManagedQuickLookItem] = []
    private var generatedPreviewDirectory: URL?
    private var folderHydrationTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var currentIndex: Int = 0
    private var sources: [URL: QuickLookSource] = [:]
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollDirection = 0
    private var lastScrollNavigationTime: TimeInterval = 0
    private var selectionDidChange: ((Int) -> Void)?
    private var navigationTargetForKeyCode: ((UInt16) -> Int?)?
    private var directoryPrewarmTask: Task<Void, Never>?
    private var priorityPrewarmTask: Task<Void, Never>?
    private var prewarmDirectory: URL?
    private var prewarmedURLs: Set<URL> = []
    private var standardPreviewContentSize: NSSize
    private var folderPreviewSessionID: String?
    private var previewPanelWasMovedByUser = false
    private var isApplyingPreviewPanelGeometry = false
    private var automaticallyPositionedPreviewFrame: NSRect?
    private var pendingProgrammaticPreviewContentSizes: [NSSize] = []

    private override init() {
        let defaults = ConfigStore.shared
        let storedWidth = defaults.double(forKey: Self.standardPreviewWidthKey)
        let storedHeight = defaults.double(forKey: Self.standardPreviewHeightKey)
        let storedSize = NSSize(width: storedWidth, height: storedHeight)
        if storedWidth >= 480,
           storedHeight >= 360,
           !Self.contentSizesMatch(storedSize, Self.finderPreviewContentSize) {
            standardPreviewContentSize = storedSize
        } else {
            standardPreviewContentSize = Self.standardPreviewFallbackSize
        }
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(previewFolderEntry(_:)),
            name: Self.folderEntryPreviewRequest,
            object: nil
        )
    }

    /// Toggle Quick Look preview panel
    func togglePreview(for items: [FileSystemItem], selectedIndex: Int = 0) {
        guard !items.isEmpty else { return }

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                previewGeneration = UUID()
                folderHydrationTask?.cancel()
                folderHydrationTask = nil
                panel.orderOut(nil)
            } else {
                removeGeneratedPreviews()
                let requestedIndex = Self.clampedPreviewIndex(selectedIndex, itemCount: items.count)
                previewGeneration = UUID()
                folderPreviewSessionID = UUID().uuidString
                let prepared = preparePreviewItems(items, folderPreviewSessionID: folderPreviewSessionID)
                previewItems = prepared.items
                generatedPreviewDirectory = prepared.generatedDirectory
                currentIndex = requestedIndex
                scrollAccumulator = 0
                lastScrollDirection = 0
                lastScrollNavigationTime = 0
                previewPanelWasMovedByUser = false
                automaticallyPositionedPreviewFrame = nil
                pendingProgrammaticPreviewContentSizes = []

                // Match Finder's public Quick Look path: hand macOS the real
                // file URLs and show its panel in the same event turn. Preview
                // rendering remains entirely in the system Quick Look process.
                // Do not force a size for normal files: macOS then retains its
                // native Quick Look geometry instead of Folder overriding it.
                // Folder previews are our deliberate exception because their
                // list needs a consistently readable viewport.
                panel.dataSource = self
                panel.delegate = self
                updatePreviewContentSize(in: panel, for: previewItems[requestedIndex])
                panel.reloadData()
                panel.currentPreviewItemIndex = requestedIndex
                panel.makeKeyAndOrderFront(nil)
                hydrateFolderPreviewIfNeeded(at: requestedIndex, in: panel)
            }
        }
    }

    /// Show Quick Look preview for a specific item
    func showPreview(for item: FileSystemItem) {
        selectionDidChange = nil
        navigationTargetForKeyCode = nil
        folderPreviewSessionID = nil
        togglePreview(for: [item], selectedIndex: 0)
    }

    /// Show Quick Look preview for multiple items
    func showPreview(for items: [FileSystemItem], startingAt index: Int) {
        selectionDidChange = nil
        navigationTargetForKeyCode = nil
        togglePreview(for: items, selectedIndex: index)
    }

    /// Show Quick Look and keep the browser selection synchronized with its item.
    func showPreview(
        for items: [FileSystemItem],
        startingAt index: Int,
        selectionDidChange: @escaping (Int) -> Void,
        navigationTargetForKeyCode: @escaping (UInt16) -> Int?
    ) {
        self.selectionDidChange = selectionDidChange
        self.navigationTargetForKeyCode = navigationTargetForKeyCode
        togglePreview(for: items, selectedIndex: index)
    }

    /// Close Quick Look preview panel
    func closePreview() {
        previewGeneration = UUID()
        folderHydrationTask?.cancel()
        folderHydrationTask = nil
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        selectionDidChange = nil
        navigationTargetForKeyCode = nil
    }

    /// Warm macOS's native Quick Look cache for the files currently visible in
    /// a directory. Work is throttled and cancellable so it never competes with
    /// scrolling or selection on the main thread.
    func prewarmPreviewCache(for items: [FileSystemItem], in directory: URL) {
        let standardizedDirectory = directory.standardizedFileURL
        if prewarmDirectory != standardizedDirectory {
            directoryPrewarmTask?.cancel()
            prewarmDirectory = standardizedDirectory
            prewarmedURLs.removeAll(keepingCapacity: true)
        }

        let urls = items
            .filter { $0.type == .file }
            .map { $0.path.standardizedFileURL }
            .filter { !prewarmedURLs.contains($0) }
        guard !urls.isEmpty else { return }

        directoryPrewarmTask?.cancel()
        let access = PermissionCenter.shared.beginAccess(to: directory)
        directoryPrewarmTask = Task { [weak self] in
            defer { access?.stop() }
            let warmed = await Self.warmNativeQuickLookCache(for: urls)
            guard let self, !Task.isCancelled, self.prewarmDirectory == standardizedDirectory else { return }
            self.storeWarmedPreviews(warmed)
        }
    }

    /// A click is a strong signal that Space may follow. Warm that one item at
    /// user-initiated priority without waiting for the directory queue.
    func prioritizePreview(for item: FileSystemItem) {
        guard item.type == .file else { return }
        let url = item.path.standardizedFileURL
        guard !prewarmedURLs.contains(url) else { return }

        priorityPrewarmTask?.cancel()
        let access = PermissionCenter.shared.beginAccess(to: url)
        priorityPrewarmTask = Task { [weak self] in
            defer { access?.stop() }
            let warmed = await Self.warmNativeQuickLookCache(for: [url], maximumConcurrentRequests: 1)
            guard let self, !Task.isCancelled else { return }
            self.storeWarmedPreviews(warmed)
        }
    }

    private func storeWarmedPreviews(_ warmed: [URL]) {
        prewarmedURLs.formUnion(warmed)
    }

    var isPreviewVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    /// Keeps mouse selection in the file browser on the exact same preview
    /// path as Quick Look's arrow-key navigation. If the clicked item belongs
    /// to the active preview list, change only the current preview index – do
    /// not close/reopen the panel or start a second preview session.
    func selectVisiblePreviewItem(at url: URL) {
        guard let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              let index = previewItems.firstIndex(where: {
                  $0.sourceURL.standardizedFileURL == url.standardizedFileURL
              }) else { return }
        selectPreview(at: index, in: panel, notifySelection: false)
    }

    /// Processes one browser-style arrow event and consumes it before Quick Look
    /// can independently advance the panel a second time.
    func handleNavigationKey(_ keyCode: UInt16) -> Bool {
        guard Self.navigationDirection(forKeyCode: keyCode) != nil,
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return false }

        if let target = navigationTargetForKeyCode?(keyCode),
           previewItems.indices.contains(target) {
            selectPreview(at: target, in: panel, notifySelection: false)
            return true
        }

        guard let direction = Self.navigationDirection(forKeyCode: keyCode) else { return false }
        return movePreview(in: panel, direction: direction)
    }

    func registerSourceFrame(
        _ frame: NSRect,
        image: NSImage,
        for url: URL,
        identifier: UUID
    ) {
        let fullImageRect = NSRect(origin: .zero, size: image.size)
        let alignmentRect = image.alignmentRect.intersection(fullImageRect)
        sources[url.standardizedFileURL] = QuickLookSource(
            identifier: identifier,
            frame: frame,
            image: image,
            contentRect: alignmentRect.isEmpty ? fullImageRect : alignmentRect
        )
    }

    func unregisterSourceFrame(for url: URL, identifier: UUID) {
        let key = url.standardizedFileURL
        // SwiftUI may dismantle an old cell after it has already created a new
        // visible cell for the same URL. Only the source that registered this
        // frame is allowed to remove it, otherwise Quick Look loses its return
        // target and animates to a fallback location.
        guard sources[key]?.identifier == identifier else { return }
        sources.removeValue(forKey: key)
    }

    private func preparePreviewItems(
        _ items: [FileSystemItem],
        folderPreviewSessionID: String?
    ) -> PreparedQuickLookSession {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folder-QuickLook-\(UUID().uuidString)", isDirectory: true)
        // The custom preview extension renders folders and UTF-8 text/code
        // files. Keep a session directory for every preview list; unused
        // directories are never created and are harmlessly removed on close.
        let generatedDirectory: URL? = outputDirectory

        var preparedItems: [ManagedQuickLookItem] = []
        preparedItems.reserveCapacity(items.count)
        let previewAppearance = SettingsManager.shared.settings.theme.rawValue
        for item in items {
            let isFolder = item.type == .folder
            let previewURL: URL
            if isFolder, let generatedDirectory {
                // Build the folder listing before presenting Quick Look so the
                // first visible preview already contains the folder contents.
                let access = PermissionCenter.shared.beginAccess(to: item.path)
                defer { access?.stop() }
                let readableURL = access?.url ?? item.path
                previewURL = (try? FolderQuickLookPreview.createDocument(
                    for: readableURL,
                    in: generatedDirectory,
                    previewSessionID: folderPreviewSessionID,
                    appearance: previewAppearance
                )) ?? item.path
            } else if let generatedDirectory,
                      let textPreview = FolderQuickLookPreview.createTextDocument(
                        for: item.path,
                        in: generatedDirectory,
                        appearance: previewAppearance
                      ) {
                previewURL = textPreview
            } else {
                previewURL = item.path
            }
            preparedItems.append(ManagedQuickLookItem(
                sourceURL: item.path,
                previewURL: previewURL,
                title: item.name,
                isFolder: isFolder
            ))
        }
        return PreparedQuickLookSession(items: preparedItems, generatedDirectory: generatedDirectory)
    }

    nonisolated private static func buildFolderPreviewDocument(
        for folderURL: URL,
        in outputDirectory: URL,
        previewSessionID: String?,
        appearance: String?
    ) async -> URL? {
        let worker = Task.detached(priority: .userInitiated) {
            try FolderQuickLookPreview.createDocument(
                for: folderURL,
                in: outputDirectory,
                previewSessionID: previewSessionID,
                appearance: appearance
            )
        }
        return await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func hydrateFolderPreviewIfNeeded(at index: Int, in panel: QLPreviewPanel) {
        guard previewItems.indices.contains(index),
              let outputDirectory = generatedPreviewDirectory else { return }
        let item = previewItems[index]
        guard item.isFolder,
              item.previewItemURL?.pathExtension != FolderQuickLookPreview.filenameExtension else { return }

        folderHydrationTask?.cancel()
        let generation = previewGeneration
        let previewAppearance = SettingsManager.shared.settings.theme.rawValue
        let access = PermissionCenter.shared.beginAccess(to: item.sourceURL)
        let readableURL = access?.url ?? item.sourceURL
        folderHydrationTask = Task { [weak self, weak panel] in
            let previewURL = await Self.buildFolderPreviewDocument(
                for: readableURL,
                in: outputDirectory,
                previewSessionID: self?.folderPreviewSessionID,
                appearance: previewAppearance
            )
            access?.stop()
            guard let self,
                  let panel,
                  !Task.isCancelled,
                  previewGeneration == generation,
                  currentIndex == index,
                  let previewURL,
                  previewItems.indices.contains(index),
                  previewItems[index].sourceURL == item.sourceURL else { return }

            previewItems[index] = ManagedQuickLookItem(
                sourceURL: item.sourceURL,
                previewURL: previewURL,
                title: item.previewItemTitle ?? item.sourceURL.lastPathComponent,
                isFolder: true
            )
            folderHydrationTask = nil
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        }
    }

    private func removeGeneratedPreviews() {
        guard let directory = generatedPreviewDirectory else { return }
        removeGeneratedPreviews(at: directory)
        generatedPreviewDirectory = nil
    }

    private func removeGeneratedPreviews(at directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated private static func sourceURL(for item: QLPreviewItem?) -> URL? {
        if let managedItem = item as? ManagedQuickLookItem { return managedItem.sourceURL }
        return item as? URL
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return MainActor.assumeIsolated {
            guard index >= 0 && index < previewItems.count else { return nil }
            return previewItems[index]
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           Self.navigationDirection(forKeyCode: event.keyCode) != nil {
            let keyCode = event.keyCode
            return MainActor.assumeIsolated {
                handleNavigationKey(keyCode)
            }
        }

        guard event.type == .scrollWheel else { return false }
        let input = PreviewScrollInput(
            horizontal: event.scrollingDeltaX,
            vertical: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            began: event.phase == .began || event.momentumPhase == .began
        )
        return MainActor.assumeIsolated {
            handlePreviewScroll(input, panel: panel)
        }
    }

    private func handlePreviewScroll(_ event: PreviewScrollInput, panel: QLPreviewPanel) -> Bool {
        let horizontal = event.horizontal
        let vertical = event.vertical
        let delta = abs(horizontal) > abs(vertical) ? horizontal : vertical
        guard abs(delta) > 0.01 else { return false }

        if event.began {
            scrollAccumulator = 0
            lastScrollDirection = 0
        }

        let direction = delta < 0 ? 1 : -1
        if lastScrollDirection != 0, lastScrollDirection != direction {
            scrollAccumulator = 0
        }
        lastScrollDirection = direction
        scrollAccumulator += abs(delta)

        let threshold: CGFloat = event.hasPreciseDeltas ? 24 : 1
        guard scrollAccumulator >= threshold else { return true }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollNavigationTime >= 0.12 else { return true }
        scrollAccumulator = 0
        lastScrollNavigationTime = now

        _ = movePreview(in: panel, direction: direction)
        return true
    }

    private func movePreview(in panel: QLPreviewPanel, direction: Int) -> Bool {
        guard let target = Self.previewIndex(
            after: panel.currentPreviewItemIndex,
            itemCount: previewItems.count,
            direction: direction
        ) else {
            return true
        }

        selectPreview(at: target, in: panel, notifySelection: true)
        return true
    }

    private func selectPreview(at index: Int, in panel: QLPreviewPanel, notifySelection: Bool) {
        folderHydrationTask?.cancel()
        folderHydrationTask = nil
        currentIndex = index
        updatePreviewContentSize(in: panel, for: previewItems[index])
        panel.currentPreviewItemIndex = index
        if notifySelection {
            selectionDidChange?(index)
        }
        hydrateFolderPreviewIfNeeded(at: index, in: panel)
    }

    /// Folder previews need a spacious, consistent list viewport. Regular
    /// Quick Look files keep the user's normal Preview geometry. Apply this
    /// whenever the current item changes—not only when the panel first opens.
    /// Finder keeps an untouched Quick Look panel visually centered as its
    /// content changes; once the user drags it, preserve that chosen position.
    private func updatePreviewContentSize(in panel: QLPreviewPanel, for item: ManagedQuickLookItem) {
        let targetSize = item.isFolder ? Self.finderPreviewContentSize : standardPreviewContentSize
        isApplyingPreviewPanelGeometry = true
        pendingProgrammaticPreviewContentSizes.append(targetSize)
        // Resizes are delivered asynchronously by QLPreviewPanel. Retain a
        // short history so a delayed folder resize cannot be mistaken for a
        // manual resize of the file selected immediately afterwards.
        if pendingProgrammaticPreviewContentSizes.count > 4 {
            pendingProgrammaticPreviewContentSizes.removeFirst(
                pendingProgrammaticPreviewContentSizes.count - 4
            )
        }
        panel.setContentSize(targetSize)
        if !previewPanelWasMovedByUser {
            panel.center()
            automaticallyPositionedPreviewFrame = panel.frame
        }
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingPreviewPanelGeometry = false
        }
    }

    nonisolated static func navigationDirection(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 123, 126: return -1 // Left / Up
        case 124, 125: return 1  // Right / Down
        default: return nil
        }
    }

    nonisolated static func browserTargetIndex(
        current: Int,
        itemCount: Int,
        keyCode: UInt16,
        columnsPerRow: Int,
        isGrid: Bool
    ) -> Int? {
        guard itemCount > 0, current >= 0, current < itemCount else { return nil }
        let columns = max(columnsPerRow, 1)
        let offset: Int

        switch keyCode {
        case 123: offset = -1
        case 124: offset = 1
        case 126: offset = isGrid ? -columns : -1
        case 125: offset = isGrid ? columns : 1
        default: return nil
        }

        return min(max(current + offset, 0), itemCount - 1)
    }

    nonisolated static func previewIndex(after current: Int, itemCount: Int, direction: Int) -> Int? {
        guard itemCount > 0, direction != 0 else { return nil }
        let target = current + (direction > 0 ? 1 : -1)
        guard target >= 0, target < itemCount else { return nil }
        return target
    }

    nonisolated static func clampedPreviewIndex(_ requestedIndex: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(max(requestedIndex, 0), itemCount - 1)
    }

    nonisolated private static func warmNativeQuickLookCache(
        for urls: [URL],
        maximumConcurrentRequests: Int = 2
    ) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        let concurrency = min(maximumConcurrentRequests, urls.count)

        return await withTaskGroup(of: URL.self, returning: [URL].self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<concurrency {
                if let url = iterator.next() {
                    group.addTask {
                        await warmNativeQuickLookCache(for: url)
                    }
                }
            }

            var completed: [URL] = []
            while let preview = await group.next() {
                completed.append(preview)
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let nextURL = iterator.next() {
                    group.addTask {
                        await warmNativeQuickLookCache(for: nextURL)
                    }
                }
            }
            return completed
        }
    }

    nonisolated private static func warmNativeQuickLookCache(for url: URL) async -> URL {
        guard !Task.isCancelled else { return url }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 1_024, height: 1_024),
            scale: 2,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { _, _ in
                continuation.resume(returning: url)
            }
        }
    }

    nonisolated static func startingPreviewIndex(
        itemIDs: [UUID],
        selectedIDs: Set<UUID>,
        activeID: UUID?
    ) -> Int? {
        guard !selectedIDs.isEmpty else { return nil }
        if let activeID,
           selectedIDs.contains(activeID),
           let index = itemIDs.firstIndex(of: activeID) {
            return index
        }
        return itemIDs.firstIndex(where: { selectedIDs.contains($0) })
    }

    /// Folder entries are generated before opening Quick Look so the initial
    /// preview renders the folder's contents instead of a temporary fallback.
    nonisolated static func eagerFolderEnumerationCount(itemCount: Int) -> Int {
        itemCount
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            previewGeneration = UUID()
            folderHydrationTask?.cancel()
            folderHydrationTask = nil
            selectionDidChange = nil
            navigationTargetForKeyCode = nil
            folderPreviewSessionID = nil
            previewPanelWasMovedByUser = false
            automaticallyPositionedPreviewFrame = nil
            pendingProgrammaticPreviewContentSizes = []
            removeGeneratedPreviews()
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = Self.sourceURL(for: item) else { return .zero }
        return MainActor.assumeIsolated {
            if let frame = sources[url.standardizedFileURL]?.frame {
                return frame
            }
            // Kein bekanntes Ziel: die Datei liegt gerade nicht sichtbar im
            // Fenster. `.zero` liesse die Vorschau in die Bildschirmecke
            // zusammenfallen — sie klappt stattdessen in die Mitte des
            // Browserfensters zusammen, also dorthin, wo die Datei liegt.
            return fallbackSourceFrame()
        }
    }

    /// Ein Ersatzziel für die Schliess-Bewegung, wenn die Kachel der Datei
    /// gerade nicht sichtbar ist.
    private func fallbackSourceFrame() -> NSRect {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && !($0 is QLPreviewPanel)
        }) else { return .zero }

        let mitte = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return NSRect(x: mitte.x - 32, y: mitte.y - 32, width: 64, height: 64)
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = Self.sourceURL(for: item) else { return nil }
        let transition: SendableTransitionImage? = MainActor.assumeIsolated {
            guard let source = sources[url.standardizedFileURL] else { return nil }
            return SendableTransitionImage(image: source.image, contentRect: source.contentRect)
        }
        if let transition, let contentRect {
            contentRect.pointee = transition.contentRect
        }
        return transition?.image
    }

    // MARK: - Separate preview geometries

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel else { return }
        let mainThreadPanel = MainThreadPreviewPanel(panel: panel)
        MainActor.assumeIsolated {
            let size = mainThreadPanel.panel.contentRect(forFrameRect: mainThreadPanel.panel.frame).size
            if let index = pendingProgrammaticPreviewContentSizes.firstIndex(where: {
                Self.contentSizesMatch($0, size)
            }) {
                pendingProgrammaticPreviewContentSizes.remove(at: index)
                return
            }
            guard previewItems.indices.contains(currentIndex),
                  !previewItems[currentIndex].isFolder else { return }

            guard size.width >= 480, size.height >= 360 else { return }
            standardPreviewContentSize = size
            ConfigStore.shared.set(size.width, forKey: Self.standardPreviewWidthKey)
            ConfigStore.shared.set(size.height, forKey: Self.standardPreviewHeightKey)
        }
    }

    nonisolated private static func contentSizesMatch(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel else { return }
        let mainThreadPanel = MainThreadPreviewPanel(panel: panel)
        MainActor.assumeIsolated {
            guard !isApplyingPreviewPanelGeometry else { return }
            if let automaticFrame = automaticallyPositionedPreviewFrame,
               mainThreadPanel.panel.frame.equalTo(automaticFrame) {
                return
            }
            previewPanelWasMovedByUser = true
            automaticallyPositionedPreviewFrame = nil
        }
    }

    @objc private func previewFolderEntry(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionID = userInfo["sessionID"] as? String,
              sessionID == folderPreviewSessionID,
              let folderPath = userInfo["folderPath"] as? String,
              let entryPath = userInfo["entryPath"] as? String,
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              previewItems.indices.contains(currentIndex) else { return }

        let current = previewItems[currentIndex]
        let folderURL = URL(fileURLWithPath: folderPath).standardizedFileURL
        let entryURL = URL(fileURLWithPath: entryPath).standardizedFileURL
        guard current.isFolder,
              current.sourceURL.standardizedFileURL == folderURL,
              entryURL.deletingLastPathComponent().standardizedFileURL == folderURL,
              FileManager.default.fileExists(atPath: entryURL.path),
              let entry = try? FileSystemItem(from: entryURL) else { return }

        folderHydrationTask?.cancel()
        folderHydrationTask = nil
        previewGeneration = UUID()
        removeGeneratedPreviews()
        let prepared = preparePreviewItems([entry], folderPreviewSessionID: folderPreviewSessionID)
        previewItems = prepared.items
        generatedPreviewDirectory = prepared.generatedDirectory
        currentIndex = 0
        updatePreviewContentSize(in: panel, for: previewItems[0])
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        hydrateFolderPreviewIfNeeded(at: 0, in: panel)
    }
}
