import Foundation
import AppKit

@MainActor
class VolumeManager: ObservableObject {
    static let shared = VolumeManager()

    @Published var mountedVolumes: [VolumeInfo] = []
    /// Emitted after macOS has actually removed a mounted volume. Consumers
    /// use this to leave any directory that belonged to the ejected device.
    @Published private(set) var lastUnmountedVolumeURL: URL?

    private init() {
        setupNotifications()
        reloadMountedVolumes()
    }

    private func setupNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func volumeDidMount(_ notification: Notification) {
        reloadMountedVolumes()
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        lastUnmountedVolumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        reloadMountedVolumes()
    }

    private func reloadMountedVolumes() {
        Task { [weak self] in
            let volumes = await Task.detached(priority: .utility) {
                Self.discoverMountedVolumes()
            }.value
            self?.mountedVolumes = volumes
        }
    }

    nonisolated private static func discoverMountedVolumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey,
                .volumeIsLocalKey,
                .volumeIsRootFileSystemKey
            ],
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var volumes: [VolumeInfo] = []

        for url in urls {
            do {
                let resourceValues = try url.resourceValues(forKeys: [
                    .volumeNameKey,
                    .volumeIsRemovableKey,
                    .volumeIsEjectableKey,
                    .volumeLocalizedNameKey,
                    .volumeIsInternalKey,
                    .volumeIsLocalKey,
                    .volumeIsRootFileSystemKey
                ])

                // Skip the root filesystem and non-local volumes
                let isRootFS = resourceValues.volumeIsRootFileSystem ?? false
                let isLocal = resourceValues.volumeIsLocal ?? true

                // Skip root filesystem
                if isRootFS || !isLocal {
                    continue
                }

                // Include volumes that are:
                // 1. Removable (USB drives, SD cards)
                // 2. Ejectable (external drives including SSDs)
                // 3. External (not internal) and local
                let isRemovable = resourceValues.volumeIsRemovable ?? false
                let isEjectable = resourceValues.volumeIsEjectable ?? false
                let isInternal = resourceValues.volumeIsInternal ?? true

                // Show external drives: removable, ejectable, or explicitly external
                if isRemovable || isEjectable || !isInternal {
                    let volumeName = resourceValues.volumeLocalizedName ?? resourceValues.volumeName ?? url.lastPathComponent

                    volumes.append(VolumeInfo(
                        url: url,
                        name: volumeName,
                        isRemovable: isRemovable,
                        isEjectable: isEjectable,
                        isLocal: isLocal
                    ))
                }
            } catch {
                // Skip volumes we can't read
            }
        }

        return volumes.sorted { $0.name < $1.name }
    }

    func ejectVolume(_ volume: VolumeInfo) {
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

struct VolumeInfo: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isRemovable: Bool
    let isEjectable: Bool
    let isLocal: Bool
}
