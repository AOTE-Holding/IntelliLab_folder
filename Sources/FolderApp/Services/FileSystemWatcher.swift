import Foundation
import Combine

/// Service that monitors file system changes in a directory and notifies observers
final class FileSystemWatcher: ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties

    /// Published signal that fires when changes are detected
    @Published var didDetectChanges: Bool = false

    // MARK: - Private Properties

    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32?
    private var currentPath: URL?
    private var batchingTimer: DispatchWorkItem?
    private let batchingInterval: TimeInterval = 0.2 // 200ms batching window
    private let watchQueue = DispatchQueue(label: "com.folder.filewatcher", qos: .userInitiated)

    // MARK: - Public Methods

    /// Starts watching a directory for file system changes
    /// - Parameter url: The directory URL to watch
    func startWatching(url: URL) {
        let normalizedURL = url.standardizedFileURL
        if currentPath?.standardizedFileURL == normalizedURL,
           dispatchSource != nil {
            return
        }

        // Stop any existing watch
        stopWatching()

        // Ensure we're watching a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        currentPath = normalizedURL

        // Open file descriptor for the directory
        let path = normalizedURL.path
        let fd = open(path, O_EVTONLY)

        guard fd >= 0 else {
            return
        }

        fileDescriptor = fd

        // Create dispatch source to monitor file system events
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .extend, .rename],
            queue: watchQueue
        )

        // Set up event handler with smart batching
        source.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }

        // Set up cancellation handler
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.fileDescriptor == fd {
                self?.fileDescriptor = nil
            }
        }

        dispatchSource = source
        source.resume()
    }

    /// Stops watching the current directory
    func stopWatching() {
        // Cancel batching timer if active
        batchingTimer?.cancel()
        batchingTimer = nil

        // Cancel dispatch source
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = nil

        currentPath = nil
    }

    /// Resets the change detection flag
    func resetChangeFlag() {
        DispatchQueue.main.async {
            self.didDetectChanges = false
        }
    }

    // MARK: - Private Methods

    /// Handles file system events with smart batching
    private func handleFileSystemEvent() {
        // Cancel existing timer
        batchingTimer?.cancel()

        // Create new batching timer
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyChanges()
        }

        batchingTimer = workItem

        // Schedule notification after batching interval
        watchQueue.asyncAfter(deadline: .now() + batchingInterval, execute: workItem)
    }

    /// Notifies observers of detected changes
    private func notifyChanges() {
        guard let path = currentPath else { return }

        // Verify directory still exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            DispatchQueue.main.async {
                self.stopWatching()
            }
            return
        }

        // Notify on main thread
        DispatchQueue.main.async {
            self.didDetectChanges = true
        }
    }

    // MARK: - Deinitialization

    deinit {
        stopWatching()
    }
}
