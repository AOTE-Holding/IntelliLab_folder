import Foundation
import AppKit

extension Notification.Name {
    static let fileOperationDidFinish = Notification.Name("FileOperationDidFinish")
}

/// Folder is currently a read-only browser. Keeping this policy at the
/// coordinator boundary makes every mutating operation inert, including an
/// action that might be triggered by an old shortcut or a drag session.
enum FileOperationPolicy {
    static let isEnabled = true
}

/// Synchronous preflight for AppKit/SwiftUI drag destinations. File mutation
/// stays in `FileOperationService`; this only decides whether a drop is even a
/// meaningful and permitted operation, so macOS can show its blocked cursor
/// before the user releases the mouse.
@MainActor
enum FileDropValidation {
    static func operation(
        for sources: [URL],
        into destination: URL,
        forceCopy: Bool
    ) -> NSDragOperation {
        // The empty AppKit operation set is the documented instruction to
        // show the system forbidden-drop cursor instead of a green badge.
        guard canAccept(sources, into: destination, forceCopy: forceCopy) else { return [] }
        guard !forceCopy else { return .copy }

        let destinationVolume = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let crossesVolume = sources.contains {
            let sourceVolume = try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
            return String(describing: sourceVolume) != String(describing: destinationVolume)
        }
        return crossesVolume ? .copy : .move
    }

    static func canWrite(to destination: URL) -> Bool {
        let access = PermissionCenter.shared.beginAccess(to: destination)
        defer { access?.stop() }
        let readableDestination = access?.url ?? destination
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: readableDestination.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: readableDestination.path)
    }

    static func canAccept(_ sources: [URL], into destination: URL, forceCopy: Bool) -> Bool {
        guard FileOperationPolicy.isEnabled, !sources.isEmpty, canWrite(to: destination) else {
            return false
        }

        let accessTokens = sources.compactMap { PermissionCenter.shared.beginAccess(to: $0) }
        defer { accessTokens.forEach { $0.stop() } }

        return sources.allSatisfy { source in
            FileManager.default.fileExists(atPath: source.path)
                && FileManager.default.isReadableFile(atPath: source.path)
                && !isInvalidContainment(source: source, destination: destination)
                && (forceCopy || source.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL)
        }
    }

    nonisolated static func isInvalidContainment(source: URL, destination: URL) -> Bool {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        guard destinationComponents.count >= sourceComponents.count else { return false }
        return Array(destinationComponents.prefix(sourceComponents.count)) == sourceComponents
    }
}

@MainActor
final class FileOperationCoordinator: ObservableObject {
    static let shared = FileOperationCoordinator()

    struct TransferProgressSample: Identifiable {
        let id = UUID()
        let timestamp: Date
        let itemsPerSecond: Double
    }

    struct PendingConflict: Identifiable {
        let id = UUID()
        let destination: URL
        let count: Int
    }

    struct PresentedReport: Identifiable {
        let id = UUID()
        let report: FileOperationReport
    }

    struct PendingTrash: Identifiable {
        let id = UUID()
        let sources: [URL]
    }

    @Published private(set) var isProcessing = false
    @Published private(set) var isProgressPresentationVisible = false
    @Published private(set) var isProgressPresentationMinimized = false
    @Published private(set) var isCancellationRequested = false
    @Published private(set) var progress: FileOperationProgress?
    @Published private(set) var transferProgressSamples: [TransferProgressSample] = []
    @Published private(set) var operationStartedAt: Date?
    @Published private(set) var progressPresentationOffset = CGSize.zero
    @Published var pendingConflict: PendingConflict?
    @Published var presentedReport: PresentedReport?
    @Published var pendingTrash: PendingTrash?

    private let service: FileOperationService
    private let clipboard: ClipboardManager
    private var operationTask: Task<Void, Never>?
    private var progressPresentationTask: Task<Void, Never>?
    private let progressPresentationDelay: UInt64 = 600_000_000
    private var lastProgressSampleAt: Date?
    private var lastProgressSampleCompleted = 0
    private let transferGraphWindow: TimeInterval = 10
    private let minimumSampleInterval: TimeInterval = 0.12

    init(
        service: FileOperationService = .shared,
        clipboard: ClipboardManager? = nil
    ) {
        self.service = service
        self.clipboard = clipboard ?? .shared
    }

    /// Minimiert ausschliesslich das Fortschrittsfenster. Die Dateioperation
    /// läuft weiter und bleibt über die kleine Fortschrittsanzeige erreichbar.
    func minimizeProgressPresentation() {
        guard isProcessing else { return }
        isProgressPresentationMinimized = true
    }

    func restoreProgressPresentation() {
        guard isProcessing else { return }
        isProgressPresentationMinimized = false
    }

    /// Speichert die Position erst nach Ende des Ziehens. Dadurch bleibt das
    /// Fenster nach dem Minimieren an derselben Stelle, ohne beim Ziehen die
    /// Ansicht bei jedem Pointer-Update neu zu zeichnen.
    func moveProgressPresentation(by translation: CGSize) {
        progressPresentationOffset = CGSize(
            width: progressPresentationOffset.width + translation.width,
            height: progressPresentationOffset.height + translation.height
        )
    }

    func paste(to destination: URL) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            do {
                let result = try await self.clipboard.paste(to: destination, progress: self.progressHandler)
                if result.hasConflicts {
                    let resolved = try await self.clipboard.pasteWithResolution(
                        to: destination,
                        conflictResolution: .keepBoth,
                        progress: self.progressHandler
                    )
                    self.present(result: resolved)
                    return
                }
                self.present(result: result)
            } catch {
                self.present(error: error, kind: .copy)
            }
        }
    }

    func resolvePendingPaste(with resolution: FileConflictResolution) {
        guard FileOperationPolicy.isEnabled else { return }
        guard let pending = pendingConflict else { return }
        pendingConflict = nil
        guard resolution != .cancel else { return }
        start {
            do {
                let result = try await self.clipboard.pasteWithResolution(
                    to: pending.destination,
                    conflictResolution: resolution,
                    progress: self.progressHandler
                )
                self.present(result: result)
            } catch {
                self.present(error: error, kind: .copy)
            }
        }
    }

    func moveToTrash(_ sources: [URL]) {
        guard FileOperationPolicy.isEnabled else { return }
        guard !sources.isEmpty else { return }
        pendingTrash = PendingTrash(sources: sources)
        confirmPendingTrash()
    }

    func confirmPendingTrash() {
        guard FileOperationPolicy.isEnabled else { return }
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        start {
            let accessTokens = request.sources.compactMap { PermissionCenter.shared.beginAccess(to: $0) }
            defer { accessTokens.forEach { $0.stop() } }
            let report = await self.service.moveToTrash(request.sources, progress: self.progressHandler)
            let succeeded = report.succeeded
            if !succeeded.isEmpty {
                ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                    type: .trash,
                    sourceURLs: succeeded.map(\.source),
                    destinationURLs: succeeded.compactMap(\.destination)
                ))
            }
            self.finish(report)
        }
    }

    func cancelPendingTrash() {
        pendingTrash = nil
    }

    func drop(_ sources: [URL], into destination: URL, forceCopy: Bool = false) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let accessTokens = (sources + [destination]).compactMap { PermissionCenter.shared.beginAccess(to: $0) }
            defer { accessTokens.forEach { $0.stop() } }
            let kinds = await withTaskGroup(of: (URL, FileOperationKind).self) { group in
                for source in sources {
                    group.addTask {
                        let kind = forceCopy
                            ? FileOperationKind.copy
                            : await self.service.recommendedDropOperation(from: source, to: destination)
                        return (source, kind)
                    }
                }
                var output: [(URL, FileOperationKind)] = []
                for await value in group { output.append(value) }
                return output
            }

            var combined: [FileOperationItemResult] = []
            for kind in [FileOperationKind.move, .copy] {
                let batch = kinds.filter { $0.1 == kind }.map(\.0)
                guard !batch.isEmpty else { continue }
                let preview = await self.service.previewTransfer(batch, to: destination, kind: kind)
                if !preview.conflicts.isEmpty {
                    combined.append(contentsOf: batch.map {
                        FileOperationItemResult(
                            source: $0,
                            destination: destination.appendingPathComponent($0.lastPathComponent),
                            outcome: .skipped,
                            message: "An item with this name already exists. Use Copy/Paste to choose a conflict action.",
                            replacedItemInTrash: nil
                        )
                    })
                    continue
                }
                let report = await self.service.transfer(
                    batch,
                    to: destination,
                    kind: kind,
                    conflictResolution: .skip,
                    progress: self.progressHandler
                )
                combined.append(contentsOf: report.results)
                let succeeded = report.succeeded
                if !succeeded.isEmpty {
                    ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                        type: kind == .move ? .move : .copy,
                        sourceURLs: succeeded.map(\.source),
                        destinationURLs: succeeded.compactMap(\.destination)
                    ))
                }
            }
            self.finish(FileOperationReport(kind: .move, results: combined))
        }
    }

    func duplicate(_ sources: [URL]) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let accessTokens = sources.compactMap { PermissionCenter.shared.beginAccess(to: $0) }
            defer { accessTokens.forEach { $0.stop() } }
            let report = await self.service.duplicate(sources, progress: self.progressHandler)
            let succeeded = report.succeeded
            if !succeeded.isEmpty {
                ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                    type: .copy,
                    sourceURLs: succeeded.map(\.source),
                    destinationURLs: succeeded.compactMap(\.destination)
                ))
            }
            self.finish(report)
        }
    }

    func compress(_ sources: [URL]) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let accessTokens = sources.compactMap { PermissionCenter.shared.beginAccess(to: $0) }
            defer { accessTokens.forEach { $0.stop() } }
            self.finish(await self.service.compress(sources, progress: self.progressHandler))
        }
    }

    func rotate(_ source: URL, quarterTurns: Int) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let access = PermissionCenter.shared.beginAccess(to: source)
            defer { access?.stop() }
            let report = await self.service.rotate(source, quarterTurns: quarterTurns)

            // Die Datei bleibt am gleichen Pfad. Thumbnails sind ebenfalls
            // nach Pfad gepuffert und würden sonst das Bild vor der Rotation
            // zeigen, obwohl die neue Datei bereits auf der Platte liegt.
            if !report.succeeded.isEmpty {
                ThumbnailService.shared.invalidateThumbnail(for: source.path)
                QuickLookManager.shared.refreshPreview(for: source)
            }
            self.finish(report)
        }
    }

    func rename(_ source: URL, to newName: String, completion: ((URL?) -> Void)? = nil) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let access = PermissionCenter.shared.beginAccess(to: source)
            defer { access?.stop() }
            let report = await self.service.rename(source, to: newName)
            let succeeded = report.succeeded
            if let item = succeeded.first, let destination = item.destination {
                ActionHistoryManager.shared.record(ActionHistoryManager.FileAction(
                    type: .move,
                    sourceURLs: [source],
                    destinationURLs: [destination]
                ))
            }
            self.finish(report)
            completion?(succeeded.first?.destination)
        }
    }

    func createFolder(in parent: URL, named name: String, completion: ((URL?) -> Void)? = nil) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let access = PermissionCenter.shared.beginAccess(to: parent)
            defer { access?.stop() }
            let report = await self.service.createFolder(in: parent, named: name)
            completion?(report.succeeded.first?.destination)
            self.finish(report)
        }
    }

    func cancel() {
        guard isProcessing else { return }
        isCancellationRequested = true
        operationTask?.cancel()
    }

    func reveal(_ result: FileOperationItemResult) {
        let url = result.destination ?? result.source
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var progressHandler: FileOperationService.ProgressHandler {
        { [weak self] value in
            await self?.setProgress(value)
        }
    }

    private func setProgress(_ value: FileOperationProgress) {
        progress = value
        let now = Date()
        guard let lastSampleAt = lastProgressSampleAt else {
            lastProgressSampleAt = now
            lastProgressSampleCompleted = value.completed
            return
        }

        let elapsed = now.timeIntervalSince(lastSampleAt)
        let completedSinceLastSample = value.completed - lastProgressSampleCompleted
        guard elapsed >= minimumSampleInterval, completedSinceLastSample > 0 else { return }
        transferProgressSamples.append(
            TransferProgressSample(
                timestamp: now,
                itemsPerSecond: Double(completedSinceLastSample) / elapsed
            )
        )
        lastProgressSampleAt = now
        lastProgressSampleCompleted = value.completed
        transferProgressSamples.removeAll { now.timeIntervalSince($0.timestamp) > transferGraphWindow }
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        isProgressPresentationVisible = false
        isProgressPresentationMinimized = false
        isCancellationRequested = false
        progress = nil
        transferProgressSamples = []
        operationStartedAt = Date()
        progressPresentationOffset = .zero
        lastProgressSampleAt = nil
        lastProgressSampleCompleted = 0
        progressPresentationTask?.cancel()
        progressPresentationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.progressPresentationDelay ?? 600_000_000)
            } catch {
                return
            }
            guard let self, self.isProcessing, !Task.isCancelled else { return }
            self.isProgressPresentationVisible = true
        }
        operationTask = Task { [weak self] in
            await operation()
            guard let self else { return }
            self.isProcessing = false
            self.isProgressPresentationVisible = false
            self.isProgressPresentationMinimized = false
            self.isCancellationRequested = false
            self.progress = nil
            self.operationStartedAt = nil
            self.progressPresentationOffset = .zero
            self.lastProgressSampleAt = nil
            self.lastProgressSampleCompleted = 0
            self.operationTask = nil
            self.progressPresentationTask?.cancel()
            self.progressPresentationTask = nil
        }
    }

    private func present(result: PasteResult) {
        let successes = zip(result.sourceURLsForHistory, result.succeeded).map { source, destination in
            FileOperationItemResult(
                source: source,
                destination: destination,
                outcome: .succeeded,
                message: nil,
                replacedItemInTrash: nil
            )
        }
        let failures = result.failed.map {
            FileOperationItemResult(
                source: $0.url,
                destination: nil,
                outcome: .failed,
                message: $0.message,
                replacedItemInTrash: nil
            )
        }
        let skipped = result.conflicts.map {
            FileOperationItemResult(
                source: $0,
                destination: nil,
                outcome: .skipped,
                message: "Skipped because an item with this name exists.",
                replacedItemInTrash: nil
            )
        }
        let cancelled = result.cancelled.map {
            FileOperationItemResult(
                source: $0,
                destination: nil,
                outcome: .cancelled,
                message: "Operation cancelled.",
                replacedItemInTrash: nil
            )
        }
        finish(FileOperationReport(
            kind: result.actionType == .cut ? .move : .copy,
            results: successes + failures + skipped + cancelled
        ))
    }

    private func present(error: Error, kind: FileOperationKind) {
        let cancelled = error is CancellationError || Task.isCancelled
        finish(FileOperationReport(kind: kind, results: [
            FileOperationItemResult(
                source: URL(fileURLWithPath: "/"),
                destination: nil,
                outcome: cancelled ? .cancelled : .failed,
                message: cancelled ? "Operation cancelled." : error.localizedDescription,
                replacedItemInTrash: nil
            )
        ]))
    }

    private func finish(_ report: FileOperationReport) {
        // A completed operation is reflected by the refreshed file browser.
        // Reserve the modal result view for actual failures, where the user
        // needs the per-item error and a way to reveal the affected item.
        presentedReport = report.failed.isEmpty ? nil : PresentedReport(report: report)
        NotificationCenter.default.post(name: .fileOperationDidFinish, object: report)
    }
}
