// macOS-specific import for NSBitmapImageRep
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
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

        CTRKRadioStationFavIconManager.shared.$cachedImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Autofill missing favicons as soon as they land in memory
                for i in self.recentlyPlayed.indices {
                    if self.recentlyPlayed[i].faviconImage == nil,
                       let img = CTRKRadioStationFavIconManager.shared.imageInMemory(for: self.recentlyPlayed[i].id) {
                        #if os(macOS)
                        if let tiffData = img.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiffData),
                           let pngData = bitmap.representation(using: .png, properties: [:]) {
                            self.recentlyPlayed[i].faviconImage = pngData
                        }
                        #else
                        if let pngData = img.pngData() {
                            self.recentlyPlayed[i].faviconImage = pngData
                        }
                        #endif
                    }
                }
            }
            .store(in: &cancellables)
    }

    public func addRecent(_ station: CTRKRadioStation) {
        var recent = loadRecents().filter { $0.id != station.id }
        recent.insert(station, at: 0)
        // Set favicon immediately if it is already in memory and prewarm async
        if let img = CTRKRadioStationFavIconManager.shared.imageInMemory(for: station.id) {
            #if os(macOS)
            if let tiffData = img.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                recent[0].faviconImage = pngData
            }
            #else
            if let pngData = img.pngData() {
                recent[0].faviconImage = pngData
            }
            #endif
        }
        Task { @MainActor in
            await CTRKRadioStationFavIconManager.shared.loadCachedImageIfNeededAsync(for: station.id)
        }
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
                if let img = CTRKRadioStationFavIconManager.shared.imageInMemory(for: stationID) {
                    #if os(macOS)
                    if let tiff = img.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        decoded[idx].faviconImage = png
                    }
                    #else
                    if let png = img.pngData() {
                        decoded[idx].faviconImage = png
                    }
                    #endif
                }
                // Prewarm disk cache asynchronously if needed
                await CTRKRadioStationFavIconManager.shared.loadCachedImageIfNeededAsync(for: stationID)
            }
        }
        self.recentlyPlayed = decoded
        return decoded
    }

    private func saveRecents(_ stations: [CTRKRadioStation]) {
        for station in stations {
            if let image = station.faviconImage,
               CTRKRadioStationFavIconManager.shared.imageInMemory(for: station.id) == nil {
                Task { @MainActor in
                    #if os(macOS)
                    if let nsImage = NSImage(data: image) {
                        CTRKRadioStationFavIconManager.shared.saveImage(nsImage, for: station.id)
                    }
                    #else
                    if let uiImage = UIImage(data: image) {
                        CTRKRadioStationFavIconManager.shared.saveImage(uiImage, for: station.id)
                    }
                    #endif
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
