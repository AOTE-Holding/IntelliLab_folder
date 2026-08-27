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
    @Published private(set) var progress: FileOperationProgress?
    @Published var pendingConflict: PendingConflict?
    @Published var presentedReport: PresentedReport?
    @Published var pendingTrash: PendingTrash?

    private let service: FileOperationService
    private let clipboard: ClipboardManager
    private var operationTask: Task<Void, Never>?

    init(
        service: FileOperationService = .shared,
        clipboard: ClipboardManager? = nil
    ) {
        self.service = service
        self.clipboard = clipboard ?? .shared
    }

    func paste(to destination: URL) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            do {
                let result = try await self.clipboard.paste(to: destination)
                if result.hasConflicts {
                    let resolved = try await self.clipboard.pasteWithResolution(
                        to: destination,
                        conflictResolution: .keepBoth
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
                    conflictResolution: resolution
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

    func rotateCopy(_ source: URL, quarterTurns: Int) {
        guard FileOperationPolicy.isEnabled else { return }
        start {
            let access = PermissionCenter.shared.beginAccess(to: source)
            defer { access?.stop() }
            self.finish(await self.service.rotateCopy(source, quarterTurns: quarterTurns))
        }
    }

    func rename(_ source: URL, to newName: String) {
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
        operationTask?.cancel()
    }

    func reveal(_ result: FileOperationItemResult) {
        let url = result.destination ?? result.source
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var progressHandler: FileOperationService.ProgressHandler {
        { value in
            await MainActor.run { FileOperationCoordinator.shared.progress = value }
        }
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        progress = nil
        operationTask = Task { [weak self] in
            await operation()
            guard let self else { return }
            self.isProcessing = false
            self.progress = nil
            self.operationTask = nil
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
        finish(FileOperationReport(
            kind: result.actionType == .cut ? .move : .copy,
            results: successes + failures + skipped
        ))
    }

    private func present(error: Error, kind: FileOperationKind) {
        finish(FileOperationReport(kind: kind, results: [
            FileOperationItemResult(
                source: URL(fileURLWithPath: "/"),
                destination: nil,
                outcome: .failed,
                message: error.localizedDescription,
                replacedItemInTrash: nil
            )
        ]))
    }

    private func finish(_ report: FileOperationReport) {
        presentedReport = PresentedReport(report: report)
        NotificationCenter.default.post(name: .fileOperationDidFinish, object: report)
    }
}
