import Combine
import CTSwiftLogger
import Foundation

extension RadioStation {
    var isManual: Bool {
        get { return (try? JSONDecoder().decode(ManualWrapper.self, from: Data(base64Encoded: self.tags) ?? Data()))?.isManual ?? false }
        set {
            if newValue {
                let wrapper = ManualWrapper(isManual: true)
                if let data = try? JSONEncoder().encode(wrapper) {
                    let base64 = data.base64EncodedString()
                    self = RadioStation(
                        name: self.name,
                        urlResolved: self.urlResolved,
                        favicon: self.favicon,
                        tags: base64,
                        codec: self.codec,
                        bitrate: self.bitrate,
                        country: self.country
                    )
                }
            }
        }
    }
}

private struct ManualWrapper: Codable {
    let isManual: Bool
}

@MainActor
final class FavoriteRadioStationsManager: ObservableObject {
    private let key = "favoriteRadioStations"
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    @Published private(set) var favorites: [RadioStation] = []
    /// Lightweight, reactive lookup for favorite status (fast Set instead of scanning the array)
    @Published private(set) var favoriteIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadFavorites()
        favoriteIDs = Set(favorites.map { $0.id })

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )

        iCloudStore.synchronize()

        RadioStationFavIconCacheManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Update only entries that don't yet have an in-memory image
                for i in self.favorites.indices {
                    if self.favorites[i].faviconImage == nil,
                       let img = RadioStationFavIconCacheManager.shared.imageInMemory(for: self.favorites[i].id) {
                        self.favorites[i].faviconImage = img
                    }
                }
            }
            .store(in: &cancellables)
    }

    func isFavorite(_ station: RadioStation) -> Bool {
        favorites.contains(where: { $0.id == station.id })
    }
    func isFavoriteID(_ id: String) -> Bool { favoriteIDs.contains(id) }

    func toggleFavorite(_ station: RadioStation) {
        objectWillChange.send() // zusätzliche Sicherheit, dass Views sofort refreshen
        if let index = favorites.firstIndex(where: { $0.id == station.id }) {
            favorites.remove(at: index)
            favoriteIDs.remove(station.id)
        } else {
            favorites.append(station)
            favoriteIDs.insert(station.id)
            // set in-memory icon immediately if available & prewarm async
            if let img = RadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
                favorites[favorites.endIndex - 1].faviconImage = img
            }
            RadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
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

    func addManualFavorite(name: String, url: String, favicon: String, tags: String, codec: String = "MP3", bitrate: Int = 128, country: String = "Custom") {
        var station = RadioStation(
            name: name,
            urlResolved: url,
            favicon: favicon,
            tags: tags,
            codec: codec,
            bitrate: bitrate,
            country: country
        )
        station.isManual = true
        favorites.append(station)
        favoriteIDs.insert(station.id)
        if let img = RadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
            favorites[favorites.endIndex - 1].faviconImage = img
        }
        RadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        saveFavorites()
        favoriteIDs = Set(favoriteIDs)
    }

    func removeManualFavorite(_ station: RadioStation) {
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
            let decoded = try JSONDecoder().decode([RadioStation].self, from: data)
            favorites = decoded
            favoriteIDs = Set(decoded.map { $0.id })
            for (idx, station) in favorites.enumerated() {
                let stationID = station.id
                Task { @MainActor in
                    favorites[idx].faviconImage = RadioStationFavIconCacheManager.shared.imageInMemory(for: stationID)
                    RadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: stationID)
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
                if RadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) == nil {
                    Task { @MainActor in
                        RadioStationFavIconCacheManager.shared.saveImage(image, for: station.id)
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
    
    func previousFavorite(currentStation: RadioStation) -> RadioStation? {
        guard !favorites.isEmpty else { return nil }
        guard let currentIndex = favorites.firstIndex(of: currentStation) else {
            return favorites.last
        }

        let prevIndex = (currentIndex - 1 + favorites.count) % favorites.count
        return favorites[prevIndex]
    }

    func nextFavorite(currentStation: RadioStation) -> RadioStation? {
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
    static let favoriteDidChange = Notification.Name("favoriteDidChange")
}
