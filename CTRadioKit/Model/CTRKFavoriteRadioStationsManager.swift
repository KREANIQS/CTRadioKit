#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Combine
import CTSwiftLogger
import Foundation

@MainActor public final class CTRKFavoriteRadioStationsManager: ObservableObject {
    private let key = "favoriteRadioStations"
    private let timestampsKey = "favoriteRadioStationsTimestamps"  // Track add/remove timestamps
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    @Published public private(set) var favorites: [CTRKRadioStation] = []
    /// Lightweight, reactive lookup for favorite status (fast Set instead of scanning the array)
    @Published public private(set) var favoriteIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    // Timestamp tracking for conflict resolution
    private var stationTimestamps: [String: Date] = [:]  // StationID -> Last modified date

    public init() {
        loadFavorites()
        favoriteIDs = Set(favorites.map { $0.id })

        // Use block-based observer with explicit main queue to ensure @MainActor isolation
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.iCloudDidChange()
            }
        }

        iCloudStore.synchronize()

        CTRKRadioStationFavIconCacheManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Update only entries that don't yet have an in-memory image
                for i in self.favorites.indices {
                    if self.favorites[i].faviconImage == nil,
                       let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: self.favorites[i].id) {
                        #if os(macOS)
                        if let tiff = img.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiff),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            self.favorites[i].faviconImage = png
                        }
                        #else
                        if let png = img.pngData() {
                            self.favorites[i].faviconImage = png
                        }
                        #endif
                    }
                }
            }
            .store(in: &cancellables)
    }

    public func isFavorite(_ station: CTRKRadioStation) -> Bool {
        favorites.contains(where: { $0.id == station.id })
    }
    public func isFavoriteID(_ id: String) -> Bool { favoriteIDs.contains(id) }

    public func toggleFavorite(_ station: CTRKRadioStation) {
        objectWillChange.send() // zusätzliche Sicherheit, dass Views sofort refreshen
        let now = Date()

        if let index = favorites.firstIndex(where: { $0.id == station.id }) {
            // Remove from favorites
            favorites.remove(at: index)
            favoriteIDs.remove(station.id)
            stationTimestamps[station.id] = now  // Track removal time
        } else {
            // Add to favorites
            favorites.append(station)
            favoriteIDs.insert(station.id)
            stationTimestamps[station.id] = now  // Track addition time
            // set in-memory icon immediately if available & prewarm async
            if let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
                #if os(macOS)
                if let tiff = img.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    favorites[favorites.endIndex - 1].faviconImage = png
                }
                #else
                if let png = img.pngData() {
                    favorites[favorites.endIndex - 1].faviconImage = png
                }
                #endif
            }
            Task { @MainActor in
                await CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
            }
        }
        saveFavorites()
        
        // Notify across scenes (iPhone <-> CarPlay): favorite status changed
        let isFavNow = favoriteIDs.contains(station.id)
        NotificationCenter.default.post(
            name: .favoriteDidChange,
            object: station,
            userInfo: [
                "stationID": station.id,
                "isFavorite": isFavNow
            ]
        )

        // Erzwinge neue Werte, damit @Published sicher feuert – sowohl Liste als auch Set
        favorites = Array(favorites)
        favoriteIDs = Set(favoriteIDs)
    }

    public func addManualFavorite(name: String, streamURL: String, homepageURL: String, faviconURL: String, tags: [String], codec: String = "MP3", bitrate: Int = 128, country: String = "Custom", labels: [String]) {
        var station = CTRKRadioStation(
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            faviconURL: faviconURL,
            tags: tags,
            codec: codec,
            bitrate: bitrate,
            country: country,
            labels: labels
        )
        station.isManual = true
        favorites.append(station)
        favoriteIDs.insert(station.id)
        stationTimestamps[station.id] = Date()  // Track addition time
        if let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
            #if os(macOS)
            if let tiff = img.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                favorites[favorites.endIndex - 1].faviconImage = png
            }
            #else
            if let png = img.pngData() {
                favorites[favorites.endIndex - 1].faviconImage = png
            }
            #endif
        }
        Task { @MainActor in
            await CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        }
        saveFavorites()
        favoriteIDs = Set(favoriteIDs)
    }

    public func removeManualFavorite(_ station: CTRKRadioStation) {
        let oldCount = favorites.count
        favorites.removeAll { $0.id == station.id && $0.isManual }
        favoriteIDs.remove(station.id)
        stationTimestamps[station.id] = Date()  // Track removal time
        if favorites.count != oldCount { saveFavorites() }
        favoriteIDs = Set(favoriteIDs)
    }

    private func loadFavorites() {
        // Load timestamps
        if let timestampsData = iCloudStore.data(forKey: timestampsKey),
           let timestamps = try? JSONDecoder().decode([String: Date].self, from: timestampsData) {
            stationTimestamps = timestamps
        }

        // Load favorites
        guard let data = iCloudStore.data(forKey: key) else {
#if DEBUG
            CTSwiftLogger.shared.info("📭 [iCloud] No data found for key: \(key)")
#endif
            favorites = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([CTRKRadioStation].self, from: data)
            favorites = decoded
            favoriteIDs = Set(decoded.map { $0.id })

            // Initialize timestamps for stations that don't have one
            let now = Date()
            for station in favorites where stationTimestamps[station.id] == nil {
                stationTimestamps[station.id] = now
            }

            // Load favicons
            for (idx, station) in favorites.enumerated() {
                let stationID = station.id
                Task { @MainActor in
                    if let image = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: stationID) {
                        #if os(macOS)
                        if let tiff = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiff),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            favorites[idx].faviconImage = png
                        }
                        #else
                        if let png = image.pngData() {
                            favorites[idx].faviconImage = png
                        }
                        #endif
                    }
                    await CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: stationID)
                }
            }
#if DEBUG
            CTSwiftLogger.shared.info("✅ [iCloud] Loaded \(favorites.count) favorite(s)")
#endif
        } catch {
#if DEBUG
            CTSwiftLogger.shared.info("❌ [iCloud] Failed to decode favorites: \(error)")
#endif
            favorites = []
        }
    }

    private func saveFavorites() {
        for station in favorites {
            if let image = station.faviconImage {
                // Only persist if not already present in the in-memory cache to avoid redundant publishes
                if CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) == nil {
                    Task { @MainActor in
                        #if os(macOS)
                        if let nsImage = NSImage(data: image) {
                            CTRKRadioStationFavIconCacheManager.shared.saveImage(nsImage, for: station.id)
                        }
                        #else
                        if let uiImage = UIImage(data: image) {
                            CTRKRadioStationFavIconCacheManager.shared.saveImage(uiImage, for: station.id)
                        }
                        #endif
                    }
                }
            }
        }

        // Save favorites
        do {
            let data = try JSONEncoder().encode(favorites)
            iCloudStore.set(data, forKey: key)

            // Save timestamps separately
            let timestampsData = try JSONEncoder().encode(stationTimestamps)
            iCloudStore.set(timestampsData, forKey: timestampsKey)

            let success = iCloudStore.synchronize()
#if DEBUG
            CTSwiftLogger.shared.info(success ? "✅ [iCloud] Favorites and timestamps saved" : "⚠️ [iCloud] Synchronization may have failed")
#endif
        } catch {
#if DEBUG
            CTSwiftLogger.shared.info("❌ [iCloud] Failed to encode favorites: \(error)")
#endif
        }
    }

    private func iCloudDidChange() {
#if DEBUG
        CTSwiftLogger.shared.info("🔄 [iCloud] Detected external change – merging favorites")
#endif

        // Save current local state
        let localFavorites = favorites
        let localTimestamps = stationTimestamps

        // Load iCloud state
        loadFavorites()
        let iCloudFavorites = favorites
        let iCloudTimestamps = stationTimestamps

        // Merge with conflict resolution
        let mergedFavorites = mergeFavorites(
            local: localFavorites,
            localTimestamps: localTimestamps,
            iCloud: iCloudFavorites,
            iCloudTimestamps: iCloudTimestamps
        )

        favorites = mergedFavorites
        favoriteIDs = Set(mergedFavorites.map { $0.id })

        // Persist merged result back to iCloud
        saveFavorites()

#if DEBUG
        CTSwiftLogger.shared.info("✅ [iCloud] Merged to \(favorites.count) favorite(s)")
#endif
    }

    /// Merges local and iCloud favorites with conflict resolution
    private func mergeFavorites(
        local: [CTRKRadioStation],
        localTimestamps: [String: Date],
        iCloud: [CTRKRadioStation],
        iCloudTimestamps: [String: Date]
    ) -> [CTRKRadioStation] {
        var merged: [String: CTRKRadioStation] = [:]
        var mergedTimestamps: [String: Date] = [:]

        // Add local favorites
        for station in local {
            merged[station.id] = station
            mergedTimestamps[station.id] = localTimestamps[station.id] ?? Date.distantPast
        }

        // Merge iCloud favorites
        for station in iCloud {
            let localTimestamp = localTimestamps[station.id] ?? Date.distantPast
            let iCloudTimestamp = iCloudTimestamps[station.id] ?? Date.distantPast

            if merged[station.id] != nil {
                // Conflict: Keep the one with newer timestamp
                if iCloudTimestamp > localTimestamp {
                    merged[station.id] = station
                    mergedTimestamps[station.id] = iCloudTimestamp
                }
            } else {
                // Not in local, add from iCloud
                merged[station.id] = station
                mergedTimestamps[station.id] = iCloudTimestamp
            }
        }

        // Check for deletions: If a station is missing but has a recent timestamp, it was deleted
        let allTimestampIDs = Set(localTimestamps.keys).union(iCloudTimestamps.keys)
        for stationID in allTimestampIDs {
            let localTimestamp = localTimestamps[stationID] ?? Date.distantPast
            let iCloudTimestamp = iCloudTimestamps[stationID] ?? Date.distantPast

            // If station was in local but not iCloud, and iCloud timestamp is newer → deleted on other device
            if local.contains(where: { $0.id == stationID }) &&
               !iCloud.contains(where: { $0.id == stationID }) &&
               iCloudTimestamp > localTimestamp {
                merged.removeValue(forKey: stationID)
            }

            // If station was in iCloud but not local, and local timestamp is newer → deleted here
            if iCloud.contains(where: { $0.id == stationID }) &&
               !local.contains(where: { $0.id == stationID }) &&
               localTimestamp > iCloudTimestamp {
                merged.removeValue(forKey: stationID)
            }
        }

        // Update our timestamps dict
        stationTimestamps = mergedTimestamps

        return Array(merged.values)
    }
    
    public func previousFavorite(currentStation: CTRKRadioStation) -> CTRKRadioStation? {
        guard !favorites.isEmpty else { return nil }
        guard let currentIndex = favorites.firstIndex(of: currentStation) else {
            return favorites.last
        }

        let prevIndex = (currentIndex - 1 + favorites.count) % favorites.count
        return favorites[prevIndex]
    }

    public func nextFavorite(currentStation: CTRKRadioStation) -> CTRKRadioStation? {
        guard !favorites.isEmpty else { return nil }
        guard let currentIndex = favorites.firstIndex(of: currentStation) else {
            return favorites.first
        }

        let nextIndex = (currentIndex + 1) % favorites.count
        return favorites[nextIndex]
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    public static let favoriteDidChange = Notification.Name("favoriteDidChange")
}
