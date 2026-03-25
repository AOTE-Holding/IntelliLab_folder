//
//  ActionHistoryManager.swift
//  Folder
//
//  Manages undo/redo history for file operations (trash, copy, move)
//

import Foundation
import AppKit

@MainActor
class ActionHistoryManager: ObservableObject {
    static let shared = ActionHistoryManager()

    struct FileAction {
        enum ActionType {
            case trash   // undo = restore from trash
            case copy    // undo = trash the copies
            case move    // undo = move back to source
        }

        let type: ActionType
        let sourceURLs: [URL]
        var destinationURLs: [URL]  // trash URLs for .trash, new paths for copy/move
    }

    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isProcessing = false

    private var undoStack: [FileAction] = []
    private var redoStack: [FileAction] = []
    private let maxHistory = 10
    private let settingsManager = SettingsManager.shared

    private init() {}

    func record(_ action: FileAction) {
        guard settingsManager.settings.undoRedoEnabled else { return }
        undoStack.append(action)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateState()
    }

    func undo() {
        guard settingsManager.settings.undoRedoEnabled,
              !isProcessing,
              let action = undoStack.popLast() else { return }

        isProcessing = true

        Task.detached(priority: .userInitiated) {
            let succeeded = Self.reverseAction(action)
            await MainActor.run {
                if succeeded {
                    self.redoStack.append(action)
                }
                self.isProcessing = false
                self.updateState()
            }
        }
    }

    func redo() {
        guard settingsManager.settings.undoRedoEnabled,
              !isProcessing,
              var action = redoStack.popLast() else { return }

        isProcessing = true

        Task.detached(priority: .userInitiated) {
            let succeeded = Self.reExecuteAction(&action)
            await MainActor.run {
                if succeeded {
                    self.undoStack.append(action)
                }
                self.isProcessing = false
                self.updateState()
            }
        }
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    private func updateState() {
        canUndo = !undoStack.isEmpty && settingsManager.settings.undoRedoEnabled
        canRedo = !redoStack.isEmpty && settingsManager.settings.undoRedoEnabled
    }

    /// Reverse an action (undo) - runs on background thread
    private nonisolated static func reverseAction(_ action: FileAction) -> Bool {
        var allSucceeded = true

        switch action.type {
        case .trash:
            for (source, trashDest) in zip(action.sourceURLs, action.destinationURLs) {
                do {
                    try FileManager.default.moveItem(at: trashDest, to: source)
                } catch {
                    allSucceeded = false
                }
            }

        case .copy:
            for dest in action.destinationURLs {
                do {
                    try FileManager.default.trashItem(at: dest, resultingItemURL: nil)
                } catch {
                    allSucceeded = false
                }
            }

        case .move:
            for (source, dest) in zip(action.sourceURLs, action.destinationURLs) {
                do {
                    try FileManager.default.moveItem(at: dest, to: source)
                } catch {
                    allSucceeded = false
                }
            }
        }

        return allSucceeded
    }

    /// Re-execute an action (redo) - runs on background thread
    private nonisolated static func reExecuteAction(_ action: inout FileAction) -> Bool {
        var allSucceeded = true

        switch action.type {
        case .trash:
            var newTrashURLs: [URL] = []
            for source in action.sourceURLs {
                do {
                    var trashNSURL: NSURL?
                    try FileManager.default.trashItem(at: source, resultingItemURL: &trashNSURL)
                    newTrashURLs.append(trashNSURL as URL? ?? source)
                } catch {
                    allSucceeded = false
                }
            }
            if allSucceeded {
                action.destinationURLs = newTrashURLs
            }

        case .copy:
            for (source, dest) in zip(action.sourceURLs, action.destinationURLs) {
                do {
                    try FileManager.default.copyItem(at: source, to: dest)
                } catch {
                    allSucceeded = false
                }
            }

        case .move:
            for (source, dest) in zip(action.sourceURLs, action.destinationURLs) {
                do {
                    try FileManager.default.moveItem(at: source, to: dest)
                } catch {
                    allSucceeded = false
                }
            }
        }

        return allSucceeded
    }
}
