//
//  CTRKRadioStationFavIconManager.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 28.08.2025.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor public final class CTRKRadioStationFavIconManager: ObservableObject {
    public static let shared = CTRKRadioStationFavIconManager()

    // Memory management configuration
    private static let maxPublishedCacheSize = 100  // Limit published dictionary to 100 images
    private static let maxMemoryCacheSize = 200     // NSCache can hold up to 200 images
    private static let memoryCacheByteLimit = 50 * 1024 * 1024  // 50 MB total memory limit

    // LRU tracking for published cache
    private var accessOrder: [String] = []  // Tracks access order for LRU eviction

    public init() {
        // Configure NSCache limits
        Self.memoryCache.countLimit = Self.maxMemoryCacheSize
        Self.memoryCache.totalCostLimit = Self.memoryCacheByteLimit
        // NSCache will automatically evict objects based on count/cost limits

        // Register for memory warnings
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryWarning()
            }
        }
        #endif
    }

    // Custom cache directory support (for database-relative caching)
    private static var customCacheDirectory: URL?

    #if os(macOS)
    // Security-scoped bookmark for custom cache directory (macOS only)
    private static var cacheDirectoryBookmark: Data?
    private static var securityScopeAccessCount = 0  // Reference counting for nested access
    private static var securityScopeURL: URL?  // Track the URL we're accessing
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
        trackAccess(for: stationID)
        evictLRUIfNeeded()

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
        guard cachedImages[stationID] == nil else {
            trackAccess(for: stationID)
            return
        }

        await Task.detached {
            let url = await Self.fileURL(for: stationID)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return }

            await MainActor.run {
                self.cachedImages[stationID] = image
                self.trackAccess(for: stationID)
                self.evictLRUIfNeeded()

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
        trackAccess(for: stationID)
        evictLRUIfNeeded()

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
        trackAccess(for: stationID)
        evictLRUIfNeeded()

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

        // RAII Pattern: Start security-scoped access if needed
        if let bookmark = Self.cacheDirectoryBookmark {
            Self.startAccessingCacheDirectory(bookmark: bookmark)
        }

        // Always stop in defer to ensure cleanup (RAII pattern)
        defer {
            if Self.cacheDirectoryBookmark != nil {
                Self.stopAccessingCacheDirectory()
            }
        }

        // Perform the write operation
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
            // Log the error
            print("❌ Failed to write favicon to \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Triggers an async disk load if the image is not in memory yet.
    /// Call from `.task`/`onAppear` (NOT from inside `body`) together with `imageInMemory(for:)`.
    public func loadCachedImageIfNeededAsync(for stationID: String) async {
        guard cachedImages[stationID] == nil else {
            trackAccess(for: stationID)
            return
        }

        await Task.detached {
            let url = await Self.fileURL(for: stationID)
            guard let data = try? Data(contentsOf: url) else { return }

            await MainActor.run {
                if let image = NSImage(data: data) {
                    self.cachedImages[stationID] = image
                    self.trackAccess(for: stationID)
                    self.evictLRUIfNeeded()

                    let key = stationID as NSString
                    Self.memoryCache.setObject(image, forKey: key)
                    Self.memoryCacheKeySet.insert(stationID)
                }
            }
        }.value
    }
    #endif

    // MARK: - Favicon Loading with Download Support

    /// Loads a favicon for a station, downloading from URL if not in cache.
    /// This method handles the complete lifecycle:
    /// 1. Check memory cache
    /// 2. Check disk cache
    /// 3. Download from faviconURL if needed
    /// 4. Process image (make square with aspect-fit, extend not crop)
    /// 5. Save to cache
    ///
    /// - Parameters:
    ///   - stationID: The unique station identifier
    ///   - faviconURL: The URL to download the favicon from if not cached
    ///   - targetSize: Target size for the square favicon (default: 180)
    /// - Returns: True if favicon is available after this call, false otherwise
    @discardableResult
    public func loadFavicon(for stationID: String, from faviconURL: String, targetSize: CGFloat = 180) async -> Bool {
        // Step 1: Check if already in memory
        if imageInMemory(for: stationID) != nil {
            trackAccess(for: stationID)
            return true
        }

        // Step 2: Try loading from disk cache
        await loadCachedImageIfNeededAsync(for: stationID)
        if imageInMemory(for: stationID) != nil {
            return true
        }

        // Step 3: Download from URL if not in cache
        guard let url = URL(string: faviconURL),
              faviconURL.starts(with: "http") else {
            return false
        }

        return await downloadAndCacheFavicon(stationID: stationID, url: url, targetSize: targetSize)
    }

    /// Downloads a favicon from a URL and caches it
    private func downloadAndCacheFavicon(stationID: String, url: URL, targetSize: CGFloat) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            #if os(iOS)
            guard let downloadedImage = UIImage(data: data) else {
                return false
            }

            // Process: Make square with aspect-fit (extend, not crop)
            let processedImage = makeSquareExtended(image: downloadedImage, targetSize: targetSize)

            // Save to cache (both memory and disk)
            await MainActor.run {
                saveImage(processedImage, for: stationID)
            }

            return true

            #elseif os(macOS)
            guard let downloadedImage = NSImage(data: data) else {
                return false
            }

            // Process: Make square with aspect-fit (extend, not crop)
            let processedImage = makeSquareExtended(image: downloadedImage, targetSize: targetSize)

            // Save to cache (both memory and disk)
            await MainActor.run {
                let _ = saveImage(processedImage, for: stationID)
            }

            return true
            #endif

        } catch {
            print("❌ Failed to download favicon from \(url.absoluteString): \(error.localizedDescription)")
            return false
        }
    }

    #if os(iOS)
    /// Makes an image square by extending (not cropping) with transparent background.
    /// Preserves aspect ratio and centers the original image.
    private func makeSquareExtended(image: UIImage, targetSize: CGFloat) -> UIImage {
        let imageSize = image.size

        // If already square and correct size, return as-is
        if imageSize.width == imageSize.height && imageSize.width == targetSize {
            return image
        }

        // Calculate dimensions to fit original image into square
        let canvasSize = CGSize(width: targetSize, height: targetSize)
        let widthRatio = targetSize / imageSize.width
        let heightRatio = targetSize / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the image in the square canvas
        let x = (targetSize - scaledWidth) / 2
        let y = (targetSize - scaledHeight) / 2
        let drawRect = CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)

        // Create square image with transparent background
        UIGraphicsBeginImageContextWithOptions(canvasSize, false, 0.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: drawRect)
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    #elseif os(macOS)
    /// Makes an image square by extending (not cropping) with transparent background.
    /// Preserves aspect ratio and centers the original image.
    private func makeSquareExtended(image: NSImage, targetSize: CGFloat) -> NSImage {
        let imageSize = image.size

        // If already square and correct size, return as-is
        if imageSize.width == imageSize.height && imageSize.width == targetSize {
            return image
        }

        // Calculate dimensions to fit original image into square
        let canvasSize = NSSize(width: targetSize, height: targetSize)
        let widthRatio = targetSize / imageSize.width
        let heightRatio = targetSize / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the image in the square canvas
        let x = (targetSize - scaledWidth) / 2
        let y = (targetSize - scaledHeight) / 2
        let drawRect = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)

        // Create square image with transparent background
        let target = NSImage(size: canvasSize)
        target.lockFocus()
        defer { target.unlockFocus() }

        image.draw(in: drawRect,
                   from: NSRect(origin: .zero, size: imageSize),
                   operation: .sourceOver,
                   fraction: 1.0)

        return target
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
    /// Start accessing security-scoped resource with reference counting (macOS only)
    private static func startAccessingCacheDirectory(bookmark: Data) {
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

            // If this is the first access, start the security scope
            if securityScopeAccessCount == 0 {
                if url.startAccessingSecurityScopedResource() {
                    securityScopeURL = url
                    securityScopeAccessCount = 1
                    print("🔓 Started accessing security-scoped cache directory (count: \(securityScopeAccessCount))")
                } else {
                    print("❌ Failed to start accessing security-scoped cache directory")
                    return
                }
            } else {
                // Already accessing, just increment reference count
                securityScopeAccessCount += 1
                print("🔓 Incremented security scope access count: \(securityScopeAccessCount)")
            }
        } catch {
            print("❌ Error resolving cache bookmark: \(error.localizedDescription)")
        }
    }

    /// Stop accessing security-scoped resource with reference counting (macOS only)
    private static func stopAccessingCacheDirectory() {
        guard securityScopeAccessCount > 0 else {
            print("⚠️ Attempted to stop security scope access but count is already 0")
            return
        }

        securityScopeAccessCount -= 1
        print("🔒 Decremented security scope access count: \(securityScopeAccessCount)")

        // Only actually stop when count reaches zero
        if securityScopeAccessCount == 0, let url = securityScopeURL {
            url.stopAccessingSecurityScopedResource()
            securityScopeURL = nil
            print("✅ Stopped accessing security-scoped cache directory")
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
        cachedImages.removeAll()
        accessOrder.removeAll()
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
    /// Hilfsmethode, um ein Bild quadratisch einzupassen mit Aspect-Ratio-Erhaltung (iOS).
    private func squareFit(image: UIImage, canvas: CGFloat) -> UIImage {
        let canvasSize = CGSize(width: canvas, height: canvas)
        let imageSize = image.size

        // Calculate aspect-fit dimensions
        let widthRatio = canvas / imageSize.width
        let heightRatio = canvas / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the image in the canvas
        let x = (canvas - scaledWidth) / 2
        let y = (canvas - scaledHeight) / 2
        let drawRect = CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)

        UIGraphicsBeginImageContextWithOptions(canvasSize, false, 0.0)
        image.draw(in: drawRect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage ?? image
    }
    #elseif os(macOS)
    /// Hilfsmethode, um ein Bild quadratisch einzupassen mit Aspect-Ratio-Erhaltung (macOS).
    private func squareFit(image: NSImage, canvas: CGFloat) -> NSImage {
        let canvasSize = NSSize(width: canvas, height: canvas)
        let imageSize = image.size

        // Calculate aspect-fit dimensions
        let widthRatio = canvas / imageSize.width
        let heightRatio = canvas / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the image in the canvas
        let x = (canvas - scaledWidth) / 2
        let y = (canvas - scaledHeight) / 2
        let drawRect = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)

        let target = NSImage(size: canvasSize)
        target.lockFocus()
        defer { target.unlockFocus() }
        image.draw(in: drawRect,
                   from: NSRect(origin: .zero, size: imageSize),
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

    // MARK: - Memory Management

    /// Tracks access to an image for LRU eviction
    private func trackAccess(for stationID: String) {
        // Remove existing entry to update position
        accessOrder.removeAll { $0 == stationID }
        // Add to end (most recently used)
        accessOrder.append(stationID)
    }

    /// Evicts least recently used images from published cache if over limit
    private func evictLRUIfNeeded() {
        guard cachedImages.count > Self.maxPublishedCacheSize else { return }

        let countToRemove = cachedImages.count - Self.maxPublishedCacheSize
        let idsToEvict = accessOrder.prefix(countToRemove)

        for id in idsToEvict {
            cachedImages.removeValue(forKey: id)
        }

        accessOrder.removeFirst(countToRemove)
    }

    /// Called on memory warnings to aggressively free memory
    private func handleMemoryWarning() {
        // Clear published cache completely
        cachedImages.removeAll()
        accessOrder.removeAll()

        // Reduce NSCache to 50% capacity
        let halfLimit = Self.maxMemoryCacheSize / 2
        Self.memoryCache.countLimit = halfLimit
        // Restore full limit after clearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Self.memoryCache.countLimit = Self.maxMemoryCacheSize
        }

        print("⚠️ Memory warning: Cleared favicon cache (published: \(cachedImages.count), NSCache: \(Self.memoryCacheKeySet.count))")
    }

    // MARK: - Package Support

    /// Updates the favicon cache path to a new location (e.g., extracted from .radiopack)
    /// - Parameter url: New cache directory URL
    public func updateCachePath(_ url: URL) {
        Self.setCacheDirectory(url, bookmark: nil)
    }

    /// Returns the current cache path being used
    public var currentCachePath: URL {
        if let customDir = Self.customCacheDirectory {
            return customDir
        }

        // Return default system cache path
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent("FavIcons")
    }
}
