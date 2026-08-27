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

        let icon = NSWorkspace.shared.icon(forFile: item.path.path)
        let resized = resizeImage(icon, to: NSSize(width: size, height: size))
        imageCache.setObject(resized, forKey: cacheKey)
        return Image(nsImage: resized)
    }

    /// Preload icons for an array of items
    func preloadIcons(for items: [FileSystemItem], size: CGFloat = 64) {
        for item in items {
            let cacheKey = "\(item.path.path)-\(Int(size))" as NSString
            guard imageCache.object(forKey: cacheKey) == nil else { continue }
            let icon = NSWorkspace.shared.icon(forFile: item.path.path)
            let resized = resizeImage(icon, to: NSSize(width: size, height: size))
            imageCache.setObject(resized, forKey: cacheKey)
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
