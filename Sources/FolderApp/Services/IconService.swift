//
//  IconService.swift
//  Folder
//
//  Service for loading and caching file icons
//

import Foundation
import AppKit
import SwiftUI

@MainActor
class IconService: ObservableObject {
    static let shared = IconService()

    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        imageCache.countLimit = 500
        imageCache.totalCostLimit = 50 * 1024 * 1024
    }

    /// Get icon synchronously (from cache or workspace). Fast for local drives.
    func icon(for item: FileSystemItem, size: CGFloat = 64) -> NSImage {
        let cacheKey = "\(item.path.path)-\(Int(size))" as NSString

        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let icon = NSWorkspace.shared.icon(forFile: item.path.path)
        let resizedIcon = resizeImage(icon, to: NSSize(width: size, height: size))
        imageCache.setObject(resizedIcon, forKey: cacheKey)
        return resizedIcon
    }

    /// Get icon as SwiftUI Image (uses cache, falls back to generic icon if not cached yet)
    func swiftUIIcon(for item: FileSystemItem, size: CGFloat = 64) -> Image {
        let cacheKey = "\(item.path.path)-\(Int(size))" as NSString

        // If cached, return immediately
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return Image(nsImage: cachedImage)
        }

        // Return a generic icon immediately, load real one in background
        let genericIcon: NSImage
        switch item.type {
        case .folder:
            genericIcon = NSWorkspace.shared.icon(for: .folder)
        case .symlink:
            genericIcon = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case .file:
            genericIcon = NSWorkspace.shared.icon(for: .item)
        }

        let resized = resizeImage(genericIcon, to: NSSize(width: size, height: size))

        // Load real icon in background for next render
        Task.detached(priority: .utility) { [weak self] in
            guard let strongSelf = self else { return }
            let realIcon = NSWorkspace.shared.icon(forFile: item.path.path)
            await MainActor.run {
                let resizedReal = strongSelf.resizeImage(realIcon, to: NSSize(width: size, height: size))
                strongSelf.imageCache.setObject(resizedReal, forKey: cacheKey)
                strongSelf.objectWillChange.send()
            }
        }

        return Image(nsImage: resized)
    }

    /// Preload icons for an array of items
    func preloadIcons(for items: [FileSystemItem], size: CGFloat = 64) {
        Task.detached(priority: .background) {
            for item in items {
                let cacheKey = "\(item.path.path)-\(Int(size))" as NSString

                if await self.imageCache.object(forKey: cacheKey) != nil {
                    continue
                }

                let icon = NSWorkspace.shared.icon(forFile: item.path.path)
                await MainActor.run {
                    let resized = self.resizeImage(icon, to: NSSize(width: size, height: size))
                    self.imageCache.setObject(resized, forKey: cacheKey)
                }
            }
        }
    }

    func clearCache() {
        imageCache.removeAllObjects()
    }

    // MARK: - Private

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}
