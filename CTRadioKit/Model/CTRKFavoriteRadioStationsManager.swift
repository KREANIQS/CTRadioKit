import Combine
import CTSwiftLogger
import Foundation

@MainActor public final class CTRKFavoriteRadioStationsManager: ObservableObject {
    private let key = "favoriteRadioStations"
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    @Published public private(set) var favorites: [CTRKRadioStation] = []
    /// Lightweight, reactive lookup for favorite status (fast Set instead of scanning the array)
    @Published public private(set) var favoriteIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    public init() {
        loadFavorites()
        favoriteIDs = Set(favorites.map { $0.id })

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )

        iCloudStore.synchronize()

        CTRKRadioStationFavIconCacheManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Update only entries that don't yet have an in-memory image
                for i in self.favorites.indices {
                    if self.favorites[i].faviconImage == nil,
                       let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: self.favorites[i].id) {
                        self.favorites[i].faviconImage = img
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
        if let index = favorites.firstIndex(where: { $0.id == station.id }) {
            favorites.remove(at: index)
            favoriteIDs.remove(station.id)
        } else {
            favorites.append(station)
            favoriteIDs.insert(station.id)
            // set in-memory icon immediately if available & prewarm async
            if let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
                favorites[favorites.endIndex - 1].faviconImage = img
            }
            CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
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

    public func addManualFavorite(name: String, streamURL: String, homepageURL: String, faviconURL: String, tags: [String], codec: String = "MP3", bitrate: Int = 128, country: String = "Custom") {
        var station = CTRKRadioStation(
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            faviconURL: faviconURL,
            tags: tags,
            codec: codec,
            bitrate: bitrate,
            country: country
        )
        station.isManual = true
        favorites.append(station)
        favoriteIDs.insert(station.id)
        if let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
            favorites[favorites.endIndex - 1].faviconImage = img
        }
        CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        saveFavorites()
        favoriteIDs = Set(favoriteIDs)
    }

    public func removeManualFavorite(_ station: CTRKRadioStation) {
        let oldCount = favorites.count
        favorites.removeAll { $0.id == station.id && $0.isManual }
        favoriteIDs.remove(station.id)
        if favorites.count != oldCount { saveFavorites() }
        favoriteIDs = Set(favoriteIDs)
    }

    private func loadFavorites() {
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
            for (idx, station) in favorites.enumerated() {
                let stationID = station.id
                Task { @MainActor in
                    favorites[idx].faviconImage = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: stationID)
                    CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: stationID)
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
                        CTRKRadioStationFavIconCacheManager.shared.saveImage(image, for: station.id)
                    }
                }
            }
        }
        do {
            let data = try JSONEncoder().encode(favorites)
            iCloudStore.set(data, forKey: key)
            let success = iCloudStore.synchronize()
#if DEBUG
            CTSwiftLogger.shared.info(success ? "✅ [iCloud] Favorites saved and synchronized" : "⚠️ [iCloud] Synchronization may have failed")
#endif
        } catch {
#if DEBUG
            CTSwiftLogger.shared.info("❌ [iCloud] Failed to encode favorites: \(error)")
#endif
        }
    }

    @objc private func iCloudDidChange(_ notification: Notification) {
#if DEBUG
        CTSwiftLogger.shared.info("🔄 [iCloud] Detected external change – reloading favorites")
#endif
        loadFavorites()
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
