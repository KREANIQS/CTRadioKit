//
//  CTRKRadioStationFavIconCacheManager.swift
//  Pladio
//
//  Created by Patrick @ DIEZIs on 28.08.2025.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor public final class CTRKRadioStationFavIconCacheManager: ObservableObject {
    public static let shared = CTRKRadioStationFavIconCacheManager()
    public init() {}

    // Custom cache directory support (for database-relative caching)
    private static var customCacheDirectory: URL?

    #if os(macOS)
    // Security-scoped bookmark for custom cache directory (macOS only)
    private static var cacheDirectoryBookmark: Data?
    private static var isAccessingSecurityScopedResource = false
    #endif

    #if os(iOS)
    @Published public private(set) var cachedImages: [String: UIImage] = [:]

    /// Returns an image from the in-memory cache only. No disk I/O. No state mutation.
    /// Safe to call from SwiftUI `body`.
    public func imageInMemory(for stationID: String) -> UIImage? {
        cachedImages[stationID]
    }

    @available(*, deprecated, message: "Avoid calling from SwiftUI body; use imageInMemory(for:) + loadCachedImageIfNeededAsync(for:) instead.")
    public func loadCachedImage(for stationID: String) -> UIImage? {
        if let image = cachedImages[stationID] {
            return image
        }
        let url = Self.fileURL(for: stationID)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        cachedImages[stationID] = image
        let key = stationID as NSString
        Self.memoryCache.setObject(image, forKey: key)
        Self.memoryCacheKeySet.insert(stationID)
        return image
    }

    public func saveImage(_ image: UIImage, for stationID: String) {
        cachedImages[stationID] = image
        let key = stationID as NSString
        Self.memoryCache.setObject(image, forKey: key)
        Self.memoryCacheKeySet.insert(stationID)
        let url = Self.fileURL(for: stationID)
        guard let data = image.pngData() else { return }
        try? data.write(to: url)
    }

    /// Triggers an async disk load if the image is not in memory yet.
    /// Call from `.task`/`onAppear` (NOT from inside `body`) together with `imageInMemory(for:)`.
    public func loadCachedImageIfNeededAsync(for stationID: String) async {
        guard cachedImages[stationID] == nil else { return }

        await Task.detached {
            let url = await Self.fileURL(for: stationID)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return }

            await MainActor.run {
                self.cachedImages[stationID] = image
                let key = stationID as NSString
                Self.memoryCache.setObject(image, forKey: key)
                Self.memoryCacheKeySet.insert(stationID)
            }
        }.value
    }
    #elseif os(macOS)
    @Published public private(set) var cachedImages: [String: NSImage] = [:]

    /// Returns an image from the in-memory cache only. No disk I/O. No state mutation.
    /// Safe to call from SwiftUI `body`.
    public func imageInMemory(for stationID: String) -> NSImage? {
        cachedImages[stationID]
    }

    @available(*, deprecated, message: "Avoid calling from SwiftUI body; use imageInMemory(for:) + loadCachedImageIfNeededAsync(for:) instead.")
    public func loadCachedImage(for stationID: String) -> NSImage? {
        if let image = cachedImages[stationID] {
            return image
        }
        let url = Self.fileURL(for: stationID)
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        cachedImages[stationID] = image
        let key = stationID as NSString
        Self.memoryCache.setObject(image, forKey: key)
        Self.memoryCacheKeySet.insert(stationID)
        return image
    }

    @discardableResult
    public func saveImage(_ image: NSImage, for stationID: String) -> Bool {
        cachedImages[stationID] = image
        let key = stationID as NSString
        Self.memoryCache.setObject(image, forKey: key)
        Self.memoryCacheKeySet.insert(stationID)
        let url = Self.fileURL(for: stationID)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }

        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// Updates an existing favicon in the cache with security-scoped access.
    /// This method ensures proper access to the cache directory before writing.
    /// Use this when updating a favicon that was loaded from a custom cache directory.
    /// - Parameters:
    ///   - image: The new image to save
    ///   - stationID: The station ID
    /// - Returns: True if successful, false otherwise
    @discardableResult
    public func updateImageWithSecurityScope(_ image: NSImage, for stationID: String) -> Bool {
        // Update memory caches first
        cachedImages[stationID] = image
        let key = stationID as NSString
        Self.memoryCache.setObject(image, forKey: key)
        Self.memoryCacheKeySet.insert(stationID)

        // Convert image to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        let url = Self.fileURL(for: stationID)

        // WICHTIG: Ensure security-scoped access is active
        var needsToStop = false
        if !Self.isAccessingSecurityScopedResource {
            // Try to start access using the stored bookmark
            if let bookmark = Self.cacheDirectoryBookmark {
                Self.startAccessingCacheDirectory(bookmark: bookmark)
                needsToStop = true
            }
        }

        defer {
            if needsToStop {
                Self.stopAccessingCacheDirectory()
            }
        }

        // If we have security-scoped access, we can write directly
        if Self.isAccessingSecurityScopedResource {
            do {
                // First, delete the old file if it exists
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }

                // Write the new file
                try data.write(to: url, options: [])

                // Verify the file was written
                if FileManager.default.fileExists(atPath: url.path),
                   let _ = try? Data(contentsOf: url) {
                    return true
                }
                return false
            } catch {
                return false
            }
        } else {
            // Fallback: Try to write without security-scoped access
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    /// Triggers an async disk load if the image is not in memory yet.
    /// Call from `.task`/`onAppear` (NOT from inside `body`) together with `imageInMemory(for:)`.
    public func loadCachedImageIfNeededAsync(for stationID: String) async {
        guard cachedImages[stationID] == nil else { return }

        await Task.detached {
            let url = await Self.fileURL(for: stationID)
            guard let data = try? Data(contentsOf: url) else { return }

            await MainActor.run {
                if let image = NSImage(data: data) {
                    self.cachedImages[stationID] = image
                    let key = stationID as NSString
                    Self.memoryCache.setObject(image, forKey: key)
                    Self.memoryCacheKeySet.insert(stationID)
                }
            }
        }.value
    }
    #endif

    /// Number of images in the published SwiftUI-reactive dictionary
    public func publishedCacheCount() -> Int {
        cachedImages.count
    }

    /// Number of images currently tracked in NSCache via memoryCacheKeySet
    public func memoryCacheCount() -> Int {
        Self.memoryCacheKeySet.count
    }

    /// Union of both caches (unique stationIDs across published and NSCache)
    public func totalUniqueCachedCount() -> Int {
        Set(cachedImages.keys).union(Self.memoryCacheKeySet).count
    }
    
    public static func cacheDirectory() -> URL {
        if let customDir = customCacheDirectory {
            return customDir
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Sets a custom cache directory (e.g., next to a database file)
    /// - Parameter url: The directory URL where favicon cache should be stored
    /// - Parameter bookmark: Optional security-scoped bookmark for macOS
    public static func setCacheDirectory(_ url: URL, bookmark: Data? = nil) {
        #if os(macOS)
        // Stop accessing previous security-scoped resource
        stopAccessingCacheDirectory()

        customCacheDirectory = url
        cacheDirectoryBookmark = bookmark

        // Start accessing new security-scoped resource if bookmark provided
        if let bookmark = bookmark {
            startAccessingCacheDirectory(bookmark: bookmark)
        }
        #else
        customCacheDirectory = url
        #endif

        // Create directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create favicon cache directory: \(error.localizedDescription)")
        }
    }

    /// Resets to using the system cache directory
    public static func resetToSystemCacheDirectory() {
        #if os(macOS)
        stopAccessingCacheDirectory()
        cacheDirectoryBookmark = nil
        #endif
        customCacheDirectory = nil
    }

    #if os(macOS)
    /// Start accessing security-scoped resource (macOS only)
    private static func startAccessingCacheDirectory(bookmark: Data) {
        guard !isAccessingSecurityScopedResource else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("⚠️ Cache directory bookmark is stale")
                return
            }

            if url.startAccessingSecurityScopedResource() {
                isAccessingSecurityScopedResource = true
            } else {
                print("❌ Failed to start accessing security-scoped cache directory")
            }
        } catch {
            print("❌ Error resolving cache bookmark: \(error.localizedDescription)")
        }
    }

    /// Stop accessing security-scoped resource (macOS only)
    private static func stopAccessingCacheDirectory() {
        guard isAccessingSecurityScopedResource else { return }
        guard let bookmark = cacheDirectoryBookmark else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedResource = false
            print("✅ Stopped accessing security-scoped cache directory")
        } catch {
            print("❌ Error resolving cache bookmark for stop: \(error.localizedDescription)")
        }
    }
    #endif

    /// Returns the currently active cache directory path (for debugging/UI)
    public static func currentCacheDirectoryPath() -> String {
        cacheDirectory().path
    }

    public static func sanitizedFileName(for stationID: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>#")
        return stationID
            .components(separatedBy: invalidCharacters)
            .joined()
            .replacingOccurrences(of: " ", with: "_")
    }

    public static func fileURL(for stationID: String) -> URL {
        let safeFileName = sanitizedFileName(for: stationID)
        return cacheDirectory().appendingPathComponent("\(safeFileName).png")
    }

    public func deleteImage(for stationID: String) {
        let key = stationID as NSString
        #if os(iOS)
        cachedImages.removeValue(forKey: stationID)
        #elseif os(macOS)
        cachedImages.removeValue(forKey: stationID)
        #endif
        Self.memoryCache.removeObject(forKey: key)
        Self.memoryCacheKeySet.remove(stationID)
        let url = Self.fileURL(for: stationID)
        try? FileManager.default.removeItem(at: url)
    }
    
    public func clearMemoryCache() {
        Self.memoryCache.removeAllObjects()
        Self.memoryCacheKeySet.removeAll()
        #if os(iOS)
        cachedImages.removeAll()
        #elseif os(macOS)
        cachedImages.removeAll()
        #endif
    }
    
    public func clearAllCachedImages() {
        let directory = Self.cacheDirectory()
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }

        for file in contents where file.pathExtension == "png" {
            try? fileManager.removeItem(at: file)
        }
    }

    public func allCachedStationIDs() -> [String] {
        let directory = Self.cacheDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }

        return contents
            .filter { $0.pathExtension == "png" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    #if os(iOS)
    /// Gibt ein Platzhalter-Image zurück, falls kein FavIcon verfügbar ist (iOS).
    /// - Parameter canvas: Zielgröße (optional, Default: 200)
    public func placeholderImage(canvas: CGFloat = 200) -> UIImage {
        if let img = UIImage(named: "Placeholder") {
            return squareFit(image: img, canvas: canvas)
        }
        let symbol = UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage()
        return squareFit(image: symbol, canvas: canvas)
    }
    #elseif os(macOS)
    /// Gibt ein Platzhalter-Image zurück, falls kein FavIcon verfügbar ist (macOS).
    /// - Parameter canvas: Zielgröße (optional, Default: 200)
    public func placeholderImage(canvas: CGFloat = 200) -> NSImage {
        if let img = NSImage(named: NSImage.Name("Placeholder")) {
            return squareFit(image: img, canvas: canvas)
        }
        let symbol = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
                    ?? NSImage(size: NSSize(width: canvas, height: canvas))
        return squareFit(image: symbol, canvas: canvas)
    }
    #endif

    #if os(iOS)
    /// Hilfsmethode, um ein Bild quadratisch einzupassen (iOS).
    private func squareFit(image: UIImage, canvas: CGFloat) -> UIImage {
        let size = CGSize(width: canvas, height: canvas)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage ?? image
    }
    #elseif os(macOS)
    /// Hilfsmethode, um ein Bild quadratisch einzupassen (macOS).
    private func squareFit(image: NSImage, canvas: CGFloat) -> NSImage {
        let size = NSSize(width: canvas, height: canvas)
        let target = NSImage(size: size)
        target.lockFocus()
        defer { target.unlockFocus() }
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        return target
    }
    #endif
    
    #if os(iOS)
    private static var memoryCache = NSCache<NSString, UIImage>()
    #elseif os(macOS)
    private static var memoryCache = NSCache<NSString, NSImage>()
    #endif
    private static var memoryCacheKeySet = Set<String>()
}
