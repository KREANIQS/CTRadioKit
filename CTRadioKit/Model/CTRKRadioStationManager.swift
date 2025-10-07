//
//  CTRKRadioStationManager.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 16.09.2025.
//

import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// Zentrale Verwaltung aller bekannten Radiostationen
/// Einschliesslich Favoriten, Recents und Favicon Cache
@MainActor
public final class CTRKRadioStationManager: ObservableObject {

    // MARK: - Singleton
    public static let shared = CTRKRadioStationManager()

    // MARK: - Radiostationen
    @Published public var allStations: [CTRKRadioStation] = [] {
        didSet {
            indexStations(allStations)
        }
    }

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(allStations)
        try data.write(to: url)
    }

    /// Exportiert ausgewählte Radiostationen in eine JSON-Datei
    public func exportStations(_ stations: [CTRKRadioStation], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stations)
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
    }

    public func removeStation(_ station: CTRKRadioStation) {
        allStations.removeAll { $0.id == station.id }
    }

    public func deleteStations(ids: [String]) {
        allStations.removeAll { ids.contains($0.id) }
    }

    public func updateStation(_ station: CTRKRadioStation) {
        if let index = allStations.firstIndex(where: { $0.id == station.id }) {
            allStations[index] = station
        }
    }

    // MARK: - FavIcon Cache Directory Management

    /// Setup favicon cache directory relative to database file (macOS only)
    /// On other platforms, uses default system cache directory
    public func setupFaviconCacheDirectory(for databaseURL: URL) {
        #if os(macOS)
        setupFaviconCacheDirectoryMacOS(for: databaseURL)
        #else
        // iOS/iPadOS/tvOS: Use default system cache
        CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
        #endif
    }

    #if os(macOS)
    private func setupFaviconCacheDirectoryMacOS(for databaseURL: URL) {
        let dbName = databaseURL.deletingPathExtension().lastPathComponent
        let cacheDirectoryName = "\(dbName)_FavIconCache"
        let parentDirectory = databaseURL.deletingLastPathComponent()
        let cacheURL = parentDirectory.appendingPathComponent(cacheDirectoryName)

        // Try to load bookmark from UserDefaults
        let bookmarkKey = faviconCacheBookmarkKey(for: databaseURL)
        if let savedBookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            if resolveFaviconCacheBookmark(savedBookmark, cacheURL: cacheURL) {
                return
            }
        }

        // Check if directory exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: cacheURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Directory exists - request access
            requestAccessToExistingCache(cacheURL: cacheURL, databaseURL: databaseURL, cacheDirectoryName: cacheDirectoryName)
        } else {
            // Directory doesn't exist - request permission to create
            requestPermissionToCreateCache(parentDirectory: parentDirectory, cacheDirectoryName: cacheDirectoryName, databaseURL: databaseURL)
        }
    }

    private func requestAccessToExistingCache(cacheURL: URL, databaseURL: URL, cacheDirectoryName: String) {
        let alert = NSAlert()
        alert.messageText = "Grant Access to Favicon Cache"
        alert.informativeText = "PladioManager needs permission to access the existing favicon cache:\n\n\(cacheDirectoryName)"
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.message = "Select the favicon cache directory"
            panel.prompt = "Grant Access"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = cacheURL

            if panel.runModal() == .OK, let selectedDir = panel.url {
                if selectedDir.startAccessingSecurityScopedResource() {
                    defer { selectedDir.stopAccessingSecurityScopedResource() }

                    do {
                        let bookmark = try selectedDir.bookmarkData(
                            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        saveFaviconCacheBookmark(bookmark, for: databaseURL)
                        CTRKRadioStationFavIconCacheManager.setCacheDirectory(selectedDir, bookmark: bookmark)
                    } catch {
                        print("⚠️ Failed to create bookmark: \(error.localizedDescription)")
                        CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
                    }
                }
            } else {
                CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
            }
        } else {
            CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
        }
    }

    private func requestPermissionToCreateCache(parentDirectory: URL, cacheDirectoryName: String, databaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Create Favicon Cache?"
        alert.informativeText = "PladioManager would like to create a favicon cache directory next to your database:\n\n\(cacheDirectoryName)\n\nThis allows favicons to be stored locally and distributed with your database."
        alert.addButton(withTitle: "Create Cache")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.message = "Grant permission to create favicon cache in this folder"
            panel.prompt = "Grant Access"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = parentDirectory

            if panel.runModal() == .OK, let selectedDir = panel.url {
                if selectedDir.startAccessingSecurityScopedResource() {
                    defer { selectedDir.stopAccessingSecurityScopedResource() }

                    let finalCacheURL = selectedDir.appendingPathComponent(cacheDirectoryName)

                    if FileManager.default.fileExists(atPath: finalCacheURL.path) {
                        do {
                            let bookmark = try finalCacheURL.bookmarkData(
                                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                            saveFaviconCacheBookmark(bookmark, for: databaseURL)
                            CTRKRadioStationFavIconCacheManager.setCacheDirectory(finalCacheURL, bookmark: bookmark)
                        } catch {
                            print("⚠️ Failed to create bookmark: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
            }
        } else {
            CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
        }
    }

    private func resolveFaviconCacheBookmark(_ bookmark: Data, cacheURL: URL) -> Bool {
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
                return false
            }

            // Pass bookmark to FavIconCacheManager for security-scoped access
            CTRKRadioStationFavIconCacheManager.setCacheDirectory(url, bookmark: bookmark)
            return true
        } catch {
            print("❌ Error resolving cache bookmark: \(error.localizedDescription)")
            return false
        }
    }

    private func faviconCacheBookmarkKey(for databaseURL: URL) -> String {
        return "FaviconCacheBookmark_\(databaseURL.path)"
    }

    private func saveFaviconCacheBookmark(_ bookmark: Data, for databaseURL: URL) {
        let key = faviconCacheBookmarkKey(for: databaseURL)
        UserDefaults.standard.set(bookmark, forKey: key)
    }
    #endif

    /// Reset favicon cache to system directory
    public func resetFaviconCacheToSystemDirectory() {
        CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
    }
}
