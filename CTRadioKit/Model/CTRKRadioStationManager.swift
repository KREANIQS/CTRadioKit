//
//  CTRKRadioStationManager.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 16.09.2025.
//

import Foundation
import Combine

/// Zentrale Verwaltung aller bekannten Radiostationen
/// Einschliesslich Favoriten, Recents und Favicon Cache
@MainActor
public final class CTRKRadioStationManager: ObservableObject {

    // MARK: - Singleton
    public static let shared = CTRKRadioStationManager()

    // MARK: - Radiostationen
    @Published public private(set) var allStations: [CTRKRadioStation] = []

    private var stationByID: [String: CTRKRadioStation] = [:]
    private var stationByCountry: [String: [CTRKRadioStation]] = [:]
    private var stationByTag: [String: [CTRKRadioStation]] = [:]

    // MARK: - Abhängige Manager
    public let favorites: CTRKFavoriteRadioStationsManager
    public let recents: CTRKRecentRadioStationsManager
    public let faviconCache: CTRKRadioStationFavIconCacheManager
    
    public var lastOpenedURL: URL?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    private init() {
        self.favorites = CTRKFavoriteRadioStationsManager()
        self.recents = CTRKRecentRadioStationsManager()
        self.faviconCache = CTRKRadioStationFavIconCacheManager()
    }

    // MARK: - Laden & Speichern

    /// Lädt Radiostationen aus einer JSON-Datei (z. B. im Bundle oder FileSystem)
    public func loadStations(from url: URL) throws {
        let data = try Data(contentsOf: url)
        do {
            let decoded = try JSONDecoder().decode([CTRKRadioStation].self, from: data)
            self.allStations = decoded
            self.indexStations(decoded)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let first = (json as? [Any])?.first {
                print("⚠️ JSON Entry Sample: \(first)")
            }
            throw error
        }
    }

    /// Schreibt Radiostationen als JSON-Datei
    public func saveStations(to url: URL) throws {
        let data = try JSONEncoder().encode(allStations)
        try data.write(to: url)
    }

    // MARK: - Interner Indexaufbau

    private func indexStations(_ stations: [CTRKRadioStation]) {
        var byID: [String: CTRKRadioStation] = [:]
        var byCountry: [String: [CTRKRadioStation]] = [:]
        var byTag: [String: [CTRKRadioStation]] = [:]

        for station in stations {
            byID[station.id] = station

            let countryKey = station.country.lowercased()
            byCountry[countryKey, default: []].append(station)

            for tag in station.tags.map({ $0.lowercased() }) {
                byTag[tag, default: []].append(station)
            }
        }

        self.stationByID = byID
        self.stationByCountry = byCountry
        self.stationByTag = byTag
    }

    // MARK: - Suche

    public func search(text: String? = nil, tags: [String] = [], countries: [String] = []) -> [CTRKRadioStation] {
        return allStations.filter { station in
            let matchesText = text.map {
                station.name.localizedCaseInsensitiveContains($0) ||
                station.tags.contains(where: { $0.localizedCaseInsensitiveContains($0) }) ||
                station.country.localizedCaseInsensitiveContains($0)
            } ?? true

            let matchesTags = tags.isEmpty || tags.contains(where: { tag in
                station.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
            })

            let matchesCountry = countries.isEmpty || countries.contains { country in
                station.country.caseInsensitiveCompare(country) == .orderedSame
            }

            return matchesText && matchesTags && matchesCountry
        }
    }

    public func station(withID id: String) -> CTRKRadioStation? {
        stationByID[id]
    }

    public func stations(forCountry country: String) -> [CTRKRadioStation] {
        stationByCountry[country.lowercased()] ?? []
    }

    public func stations(withTag tag: String) -> [CTRKRadioStation] {
        stationByTag[tag.lowercased()] ?? []
    }

    // MARK: - Manuelle Änderungen (z. B. durch PladioManager)

    public func addStation(_ station: CTRKRadioStation) {
        guard stationByID[station.id] == nil else { return } // Duplikat vermeiden
        allStations.append(station)
        indexStations(allStations)
    }

    public func removeStation(_ station: CTRKRadioStation) {
        allStations.removeAll { $0.id == station.id }
        indexStations(allStations)
    }
}
