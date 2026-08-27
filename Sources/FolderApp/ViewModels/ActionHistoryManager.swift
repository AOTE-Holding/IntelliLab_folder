import Foundation

@MainActor
final class ActionHistoryManager: ObservableObject {
    static let shared = ActionHistoryManager()

    struct FileAction: Sendable {
        enum ActionType: Sendable, Equatable {
            case trash
            case copy
            case move
        }

        let type: ActionType
        let sourceURLs: [URL]
        var destinationURLs: [URL]

        var isEmpty: Bool { sourceURLs.isEmpty }

        func subset(indices: [Int], replacementDestinations: [URL]? = nil) -> FileAction {
            FileAction(
                type: type,
                sourceURLs: indices.map { sourceURLs[$0] },
                destinationURLs: replacementDestinations ?? indices.map { destinationURLs[$0] }
            )
        }
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isProcessing = false

    private var undoStack: [FileAction] = []
    private var redoStack: [FileAction] = []
    private let maxHistory = 25
    private let service = FileOperationService.shared
    private let settingsManager = SettingsManager.shared

    private init() {}

    func record(_ action: FileAction) {
        guard FileOperationPolicy.isEnabled, settingsManager.settings.undoRedoEnabled, !action.isEmpty else { return }
        undoStack.append(action)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        updateState()
    }

    func undo() {
        guard FileOperationPolicy.isEnabled,
              settingsManager.settings.undoRedoEnabled,
              !isProcessing,
              let action = undoStack.popLast() else { return }
        isProcessing = true
        Task {
            let execution = await execute(action, reversing: true)
            if let succeeded = execution.succeeded { redoStack.append(succeeded) }
            if let failed = execution.failed { undoStack.append(failed) }
            finish(execution.report)
        }
    }

    func redo() {
        guard FileOperationPolicy.isEnabled,
              settingsManager.settings.undoRedoEnabled,
              !isProcessing,
              let action = redoStack.popLast() else { return }
        isProcessing = true
        Task {
            let execution = await execute(action, reversing: false)
            if let succeeded = execution.succeeded { undoStack.append(succeeded) }
            if let failed = execution.failed { redoStack.append(failed) }
            finish(execution.report)
        }
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    private func finish(_ report: FileOperationReport) {
        isProcessing = false
        updateState()
        FileOperationCoordinator.shared.presentedReport = .init(report: report)
        NotificationCenter.default.post(name: .fileOperationDidFinish, object: report)
    }

    private func updateState() {
        canUndo = !undoStack.isEmpty && settingsManager.settings.undoRedoEnabled
        canRedo = !redoStack.isEmpty && settingsManager.settings.undoRedoEnabled
    }

    private func execute(
        _ action: FileAction,
        reversing: Bool
    ) async -> (succeeded: FileAction?, failed: FileAction?, report: FileOperationReport) {
        let accessTokens = (action.sourceURLs + action.destinationURLs)
            .compactMap { PermissionCenter.shared.beginAccess(to: $0) }
        defer { accessTokens.forEach { $0.stop() } }

        let report: FileOperationReport
        let operationSources: [URL]

        switch (action.type, reversing) {
        case (.trash, true):
            let pairs = zip(action.destinationURLs, action.sourceURLs).map { FileRelocation(source: $0, destination: $1) }
            operationSources = action.destinationURLs
            report = await service.relocateExactly(pairs, kind: .move)
        case (.trash, false):
            operationSources = action.sourceURLs
            report = await service.moveToTrash(action.sourceURLs)
        case (.copy, true):
            operationSources = action.destinationURLs
            report = await service.moveToTrash(action.destinationURLs)
        case (.copy, false):
            operationSources = action.sourceURLs
            let pairs = zip(action.sourceURLs, action.destinationURLs).map { FileRelocation(source: $0, destination: $1) }
            report = await service.relocateExactly(pairs, kind: .copy)
        case (.move, true):
            operationSources = action.destinationURLs
            let pairs = zip(action.destinationURLs, action.sourceURLs).map { FileRelocation(source: $0, destination: $1) }
            report = await service.relocateExactly(pairs, kind: .move)
        case (.move, false):
            operationSources = action.sourceURLs
            let pairs = zip(action.sourceURLs, action.destinationURLs).map { FileRelocation(source: $0, destination: $1) }
            report = await service.relocateExactly(pairs, kind: .move)
        }

        let successfulSourceSet = Set(report.succeeded.map(\.source))
        let successfulIndices = operationSources.indices.filter { successfulSourceSet.contains(operationSources[$0]) }
        let failedIndices = operationSources.indices.filter { !successfulSourceSet.contains(operationSources[$0]) }

        var succeededAction: FileAction?
        if !successfulIndices.isEmpty {
            if action.type == .trash && !reversing {
                let trashBySource = Dictionary(uniqueKeysWithValues: report.succeeded.compactMap { result in
                    result.destination.map { (result.source, $0) }
                })
                let newDestinations = successfulIndices.compactMap { trashBySource[action.sourceURLs[$0]] }
                succeededAction = action.subset(indices: successfulIndices, replacementDestinations: newDestinations)
            } else {
                succeededAction = action.subset(indices: successfulIndices)
            }
        }
        let failedAction = failedIndices.isEmpty ? nil : action.subset(indices: failedIndices)
        return (succeededAction, failedAction, report)
    }
}
