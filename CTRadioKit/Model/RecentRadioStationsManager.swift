import Foundation
import CTSwiftLogger
import Combine

@MainActor
final class RecentRadioStationsManager: ObservableObject {
    @Published var recentlyPlayed: [RadioStation] = []
    private var cancellables = Set<AnyCancellable>()
    private let key = "recentRadioStations"
    private let maxCount = 10

    init() {
        _ = loadRecents()

        RadioStationFavIconCacheManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Autofill missing favicons as soon as they land in memory
                for i in self.recentlyPlayed.indices {
                    if self.recentlyPlayed[i].faviconImage == nil,
                       let img = RadioStationFavIconCacheManager.shared.imageInMemory(for: self.recentlyPlayed[i].id) {
                        self.recentlyPlayed[i].faviconImage = img
                    }
                }
            }
            .store(in: &cancellables)
    }

    func addRecent(_ station: RadioStation) {
        var recent = loadRecents().filter { $0.id != station.id }
        recent.insert(station, at: 0)
        // Set favicon immediately if it is already in memory and prewarm async
        if let img = RadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) {
            recent[0].faviconImage = img
        }
        RadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        if recent.count > maxCount {
            recent = Array(recent.prefix(maxCount))
        }
        saveRecents(recent)
        self.recentlyPlayed = recent
    }

    func loadRecents() -> [RadioStation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var decoded = try? JSONDecoder().decode([RadioStation].self, from: data) else {
            return []
        }
        for (idx, station) in decoded.enumerated() {
            let stationID = station.id
            Task { @MainActor in
                // Read-only in-memory lookup (no disk I/O, no state mutation during render)
                decoded[idx].faviconImage = RadioStationFavIconCacheManager.shared.imageInMemory(for: stationID)
                // Prewarm disk cache asynchronously if needed
                RadioStationFavIconCacheManager.shared.loadCachedImageIfNeededAsync(for: stationID)
            }
        }
        self.recentlyPlayed = decoded
        return decoded
    }

    private func saveRecents(_ stations: [RadioStation]) {
        for station in stations {
            if let image = station.faviconImage,
               RadioStationFavIconCacheManager.shared.imageInMemory(for: station.id) == nil {
                Task { @MainActor in
                    RadioStationFavIconCacheManager.shared.saveImage(image, for: station.id)
                }
            }
        }
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    func contains(_ station: RadioStation) -> Bool {
        recentlyPlayed.contains { $0.id == station.id }
    }
}
