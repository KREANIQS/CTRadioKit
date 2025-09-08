//
//  ArtworkCacheManager.swift
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

@MainActor
final class RadioStationFavIconCacheManager: ObservableObject {
    static let shared = RadioStationFavIconCacheManager()
    private init() {}

    #if os(iOS)
    @Published private(set) var cachedImages: [String: UIImage] = [:]

    /// Returns an image from the in-memory cache only. No disk I/O. No state mutation.
    /// Safe to call from SwiftUI `body`.
    func imageInMemory(for stationID: String) -> UIImage? {
        cachedImages[stationID]
    }

    @available(*, deprecated, message: "Avoid calling from SwiftUI body; use imageInMemory(for:) + loadCachedImageIfNeededAsync(for:) instead.")
    func loadCachedImage(for stationID: String) -> UIImage? {
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

    func saveImage(_ image: UIImage, for stationID: String) {
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
    func loadCachedImageIfNeededAsync(for stationID: String) {
        guard cachedImages[stationID] == nil else { return }

        Task.detached {
            let url = await Self.fileURL(for: stationID)
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return }

            await MainActor.run {
                self.cachedImages[stationID] = image
                let key = stationID as NSString
                Self.memoryCache.setObject(image, forKey: key)
                Self.memoryCacheKeySet.insert(stationID)
            }
        }
    }
    #elseif os(macOS)
    @Published private(set) var cachedImages: [String: NSImage] = [:]

    /// Returns an image from the in-memory cache only. No disk I/O. No state mutation.
    /// Safe to call from SwiftUI `body`.
    func imageInMemory(for stationID: String) -> NSImage? {
        cachedImages[stationID]
    }

    @available(*, deprecated, message: "Avoid calling from SwiftUI body; use imageInMemory(for:) + loadCachedImageIfNeededAsync(for:) instead.")
    func loadCachedImage(for stationID: String) -> NSImage? {
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
    func saveImage(_ image: NSImage, for stationID: String) -> Bool {
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

    /// Triggers an async disk load if the image is not in memory yet.
    /// Call from `.task`/`onAppear` (NOT from inside `body`) together with `imageInMemory(for:)`.
    func loadCachedImageIfNeededAsync(for stationID: String) {
        guard cachedImages[stationID] == nil else { return }

        Task.detached {
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
        }
    }
    #endif

    /// Number of images in the published SwiftUI-reactive dictionary
    func publishedCacheCount() -> Int {
        cachedImages.count
    }

    /// Number of images currently tracked in NSCache via memoryCacheKeySet
    func memoryCacheCount() -> Int {
        Self.memoryCacheKeySet.count
    }

    /// Union of both caches (unique stationIDs across published and NSCache)
    func totalUniqueCachedCount() -> Int {
        Set(cachedImages.keys).union(Self.memoryCacheKeySet).count
    }
    
    static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func sanitizedFileName(for stationID: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>#")
        return stationID
            .components(separatedBy: invalidCharacters)
            .joined()
            .replacingOccurrences(of: " ", with: "_")
    }

    static func fileURL(for stationID: String) -> URL {
        let safeFileName = sanitizedFileName(for: stationID)
        return cacheDirectory().appendingPathComponent("\(safeFileName).png")
    }

    func deleteImage(for stationID: String) {
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
    
    func clearMemoryCache() {
        Self.memoryCache.removeAllObjects()
        Self.memoryCacheKeySet.removeAll()
        #if os(iOS)
        cachedImages.removeAll()
        #elseif os(macOS)
        cachedImages.removeAll()
        #endif
    }
    
    func clearAllCachedImages() {
        let directory = Self.cacheDirectory()
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }

        for file in contents where file.pathExtension == "png" {
            try? fileManager.removeItem(at: file)
        }
    }

    func allCachedStationIDs() -> [String] {
        let directory = Self.cacheDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }

        return contents
            .filter { $0.pathExtension == "png" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    #if os(iOS)
    /// Gibt ein Platzhalter-Image zurück, falls kein FavIcon verfügbar ist (iOS).
    /// - Parameter canvas: Zielgröße (optional, Default: 200)
    func placeholderImage(canvas: CGFloat = 200) -> UIImage {
        if let img = UIImage(named: "Placeholder") {
            return squareFit(image: img, canvas: canvas)
        }
        let symbol = UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage()
        return squareFit(image: symbol, canvas: canvas)
    }
    #elseif os(macOS)
    /// Gibt ein Platzhalter-Image zurück, falls kein FavIcon verfügbar ist (macOS).
    /// - Parameter canvas: Zielgröße (optional, Default: 200)
    func placeholderImage(canvas: CGFloat = 200) -> NSImage {
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
