import Foundation
import CTSwiftLogger
import Combine

@MainActor public final class CTRKRecentRadioStationsManager: ObservableObject {
    @Published public private(set) var recentlyPlayed: [CTRKRadioStation] = []
    private var cancellables = Set<AnyCancellable>()
    private let key = "recentRadioStations"
    private let maxCount = 10

    public init() {
        _ = loadRecents()

        CTRKRadioStationFavIconCacheManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Autofill missing favicons as soon as they land in memory
                for i in self.recentlyPlayed.indices {
                    if self.recentlyPlayed[i].faviconImage == nil,
                       let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: self.recentlyPlayed[i].id) {
                        self.recentlyPlayed[i].faviconImage = img
                    }
                }
            }
            .store(in: &cancellables)
    }

    public func addRecent(_ station: CTRKRadioStation) {
        var recent = loadRecents().filter { $0.id != station.id }
        recent.insert(station, at: 0)
        // Set favicon immediately if it is already in memory and prewarm async
        if let img = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
            recent[0].faviconImage = img
        }
        CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        if recent.count > maxCount {
            recent = Array(recent.prefix(maxCount))
        }
        saveRecents(recent)
        self.recentlyPlayed = recent
    }

    public func loadRecents() -> [CTRKRadioStation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var decoded = try? JSONDecoder().decode([CTRKRadioStation].self, from: data) else {
            return []
        }
        for (idx, station) in decoded.enumerated() {
            let stationID = station.id
            Task { @MainActor in
                // Read-only in-memory lookup (no disk I/O, no state mutation during render)
                decoded[idx].faviconImage = CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: stationID)
                // Prewarm disk cache asynchronously if needed
                CTRKRadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: stationID)
            }
        }
        self.recentlyPlayed = decoded
        return decoded
    }

    private func saveRecents(_ stations: [CTRKRadioStation]) {
        for station in stations {
            if let image = station.faviconImage,
               CTRKRadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) == nil {
                Task { @MainActor in
                    CTRKRadioStationFavIconCacheManager.shared.saveImage(image, for: station.id)
                }
            }
        }
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    public func contains(_ station: CTRKRadioStation) -> Bool {
        recentlyPlayed.contains { $0.id == station.id }
    }
}
