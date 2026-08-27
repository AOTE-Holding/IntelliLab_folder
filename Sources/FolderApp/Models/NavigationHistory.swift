import Foundation

/// Conventional browser-style history. The current location is always an
/// entry, so the first navigation immediately enables Back.
struct NavigationHistory: Equatable, Sendable {
    private(set) var entries: [URL]
    private(set) var currentIndex: Int

    init(initialURL: URL) {
        entries = [initialURL.standardizedFileURL]
        currentIndex = 0
    }

    var current: URL { entries[currentIndex] }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + 1 < entries.count }

    mutating func navigate(to url: URL) {
        let target = url.standardizedFileURL
        guard target != current else { return }

        if canGoForward {
            entries.removeSubrange((currentIndex + 1)...)
        }
        entries.append(target)
        currentIndex = entries.count - 1
    }

    mutating func goBack() -> URL? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return current
    }

    mutating func goForward() -> URL? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return current
    }

    /// Returns the most recently visited location before the current entry
    /// that is not on a volume which has just disappeared. This lets the UI
    /// leave an ejected drive without ever trying to render its stale path.
    func lastLocationOutsideVolume(_ volumeRoot: URL) -> URL? {
        let normalizedRoot = volumeRoot.standardizedFileURL.path
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"

        return entries[..<currentIndex].reversed().first { entry in
            let path = entry.standardizedFileURL.path
            return path != normalizedRoot && !path.hasPrefix(rootPrefix)
        }
    }
}
