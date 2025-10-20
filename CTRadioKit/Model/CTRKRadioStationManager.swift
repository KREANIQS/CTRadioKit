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
            // Use the database loader which supports both formats
            let database = try CTRKRadioStationDatabaseLoader.load(from: data)
            self.allStations = database.stations
            self.indexStations(database.stations)
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

    // MARK: - Package Loading (.radiopack files)

    /// Loads a bundled .radiopack file and extracts database + favicon cache
    /// - Parameters:
    ///   - packageName: Name of the .radiopack file (without extension)
    ///   - forceReExtract: If true, re-extracts even if already extracted
    ///   - progressHandler: Optional progress callback (0.0 to 1.0)
    /// - Returns: Package info with paths to extracted files
    @discardableResult
    public func loadBundledPackage(
        named packageName: String,
        forceReExtract: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> CTRKRadioStationDatabasePackager.PackageInfo {

        // Load and extract package
        let packageInfo = try await CTRKRadioStationDatabasePackager.loadBundledPackage(
            named: packageName,
            forceReExtract: forceReExtract,
            progressHandler: progressHandler
        )

        // Load database from extracted location
        try loadStations(from: packageInfo.databaseURL)

        // Update favicon cache to use extracted favicons
        faviconCache.updateCachePath(packageInfo.faviconCacheURL)

        // Store last opened URL
        lastOpenedURL = packageInfo.databaseURL

        return packageInfo
    }

    // MARK: - Package Export (.radiopack creation)

    /// Creates a .radiopack file from current database and favicon cache
    /// Useful for PladioManager to export databases for Pladio app
    /// - Parameters:
    ///   - outputURL: Where to save the .radiopack file
    ///   - version: Version string for the package
    ///   - progressHandler: Optional progress callback (0.0 to 1.0)
    public func createPackage(
        at outputURL: URL,
        version: String,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {

        guard let databaseURL = lastOpenedURL else {
            throw NSError(
                domain: "CTRKRadioStationManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No database loaded. Load a database first."]
            )
        }

        let faviconCacheURL = faviconCache.currentCachePath

        try await CTRKRadioStationDatabasePackager.createPackage(
            databaseURL: databaseURL,
            faviconCacheURL: faviconCacheURL,
            outputURL: outputURL,
            version: version,
            progressHandler: progressHandler
        )
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

    /// Setup favicon cache directory relative to database file
    /// Supports both bundle-relative caches (read-only) and writable caches
    public func setupFaviconCacheDirectory(for databaseURL: URL) {
        #if os(macOS)
        setupFaviconCacheDirectoryMacOS(for: databaseURL)
        #else
        setupFaviconCacheDirectoryIOS(for: databaseURL)
        #endif
    }

    #if !os(macOS)
    private func setupFaviconCacheDirectoryIOS(for databaseURL: URL) {
        // Check if database is in app bundle
        let isInBundle = databaseURL.path.contains(Bundle.main.bundlePath)

        #if DEBUG
        print("📂 [FavIcon] Database URL: \(databaseURL.path)")
        print("📂 [FavIcon] Bundle path: \(Bundle.main.bundlePath)")
        print("📂 [FavIcon] Is in bundle: \(isInBundle)")
        #endif

        if isInBundle {
            // For bundle databases, use flat bundle resources structure
            // Favicons are copied flat into the bundle (persistentIDs are unique across databases)
            if let resourceURL = Bundle.main.resourceURL {
                CTRKRadioStationFavIconCacheManager.setCacheDirectory(resourceURL, bookmark: nil)
                #if DEBUG
                print("✅ [FavIcon] Using flat bundle favicon cache: \(resourceURL.path)")
                #endif
                return
            }
        }

        // Fallback: Use system cache directory (writable)
        CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
        #if DEBUG
        let systemCacheDir = CTRKRadioStationFavIconCacheManager.currentCacheDirectoryPath()
        print("ℹ️ [FavIcon] Using system favicon cache directory: \(systemCacheDir)")
        #endif
    }
    #endif

    #if os(macOS)
    private func setupFaviconCacheDirectoryMacOS(for databaseURL: URL) {
        // Check if database is in app bundle (read-only)
        let isInBundle = databaseURL.path.contains(Bundle.main.bundlePath)

        #if DEBUG
        print("📂 [FavIcon] Database URL: \(databaseURL.path)")
        print("📂 [FavIcon] Bundle path: \(Bundle.main.bundlePath)")
        print("📂 [FavIcon] Is in bundle: \(isInBundle)")
        #endif

        if isInBundle {
            // For bundle databases, use flat bundle resources structure (same as iOS)
            // Favicons are copied flat into the bundle (persistentIDs are unique across databases)
            if let resourceURL = Bundle.main.resourceURL {
                CTRKRadioStationFavIconCacheManager.setCacheDirectory(resourceURL, bookmark: nil)
                #if DEBUG
                print("✅ [FavIcon] Using flat bundle favicon cache: \(resourceURL.path)")
                #endif
                return
            } else {
                // Fallback to system cache
                CTRKRadioStationFavIconCacheManager.resetToSystemCacheDirectory()
                #if DEBUG
                print("⚠️ [FavIcon] Could not get bundle resourceURL, using system cache")
                #endif
                return
            }
        }

        // For external databases (not in bundle), use directory-based cache with security-scoped bookmarks
        let dbName = databaseURL.deletingPathExtension().lastPathComponent
        let cacheDirectoryName = "\(dbName)_FavIconCache"
        let parentDirectory = databaseURL.deletingLastPathComponent()
        let cacheURL = parentDirectory.appendingPathComponent(cacheDirectoryName)

        #if DEBUG
        print("📂 [FavIcon] External database, looking for cache at: \(cacheURL.path)")
        #endif

        // Try to load bookmark from UserDefaults
        let bookmarkKey = faviconCacheBookmarkKey(for: databaseURL)
        if let savedBookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            if resolveFaviconCacheBookmark(savedBookmark, cacheURL: cacheURL) {
                #if DEBUG
                print("✅ [FavIcon] Restored cache from bookmark: \(cacheURL.path)")
                #endif
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
                        // WICHTIG: Ohne .securityScopeAllowOnlyReadAccess für Schreibzugriff!
                        let bookmark = try selectedDir.bookmarkData(
                            options: [.withSecurityScope],
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

                    do {
                        // Create directory if it doesn't exist
                        if !FileManager.default.fileExists(atPath: finalCacheURL.path) {
                            try FileManager.default.createDirectory(at: finalCacheURL, withIntermediateDirectories: true)
                            print("✅ Created favicon cache directory: \(finalCacheURL.path)")
                        }

                        // Create bookmark for the cache directory
                        // WICHTIG: Ohne .securityScopeAllowOnlyReadAccess für Schreibzugriff!
                        let bookmark = try finalCacheURL.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        saveFaviconCacheBookmark(bookmark, for: databaseURL)
                        CTRKRadioStationFavIconCacheManager.setCacheDirectory(finalCacheURL, bookmark: bookmark)
                        print("✅ Favicon cache setup complete: \(finalCacheURL.lastPathComponent)")
                    } catch {
                        print("⚠️ Failed to create cache directory or bookmark: \(error.localizedDescription)")
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

            // Test if bookmark has write permissions by attempting to access
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }

                // Try to create a test file to verify write permissions
                let testFile = url.appendingPathComponent(".write_test_\(UUID().uuidString)")
                let testData = Data("test".utf8)

                do {
                    try testData.write(to: testFile)
                    try? FileManager.default.removeItem(at: testFile)
                    print("✅ Cache bookmark has write permissions")
                } catch {
                    print("⚠️ Cache bookmark is READ-ONLY, needs to be recreated")
                    print("   Error: \(error.localizedDescription)")
                    return false // Force recreation with write permissions
                }
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

    // MARK: - Database Migration (Version 1 → Version 2)

    /// Migration result containing statistics about the migration
    public struct MigrationResult {
        public let stationsChanged: Int
        public let faviconsCopied: Int
        public let faviconsFailed: Int
        public let idMapping: [String: String] // oldID -> newID

        public var totalStations: Int {
            stationsChanged + (idMapping.count - stationsChanged)
        }
    }

    /// Migrates a database from version 1 to version 2 (protocol-independent IDs)
    /// - Parameters:
    ///   - oldStations: Stations from version 1 database
    ///   - cacheDirectory: Directory containing favicon cache files
    ///   - progressCallback: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: Migration result with statistics
    public func migrateDatabase(
        from oldStations: [CTRKRadioStation],
        cacheDirectory: URL,
        progressCallback: ((Double, String) -> Void)? = nil
    ) -> MigrationResult {
        print("🔄 Starting database migration from Version 1 to Version 2")
        print("   Stations to check: \(oldStations.count)")
        print("   Cache directory: \(cacheDirectory.path)")

        var idMapping: [String: String] = [:] // oldID -> newID
        var changedStations = 0

        // Phase 1: Build ID mapping
        progressCallback?(0.1, "Analyzing station IDs...")

        for (index, station) in oldStations.enumerated() {
            // Calculate what the new ID would be with protocol-independent logic
            let oldID = station.id
            let newID = CTRKRadioStation.generateID(for: station.streamURL)

            if oldID != newID {
                idMapping[oldID] = newID
                changedStations += 1
            }

            // Progress update every 10 stations
            if index % 10 == 0 {
                let progress = 0.1 + (Double(index) / Double(oldStations.count)) * 0.3
                progressCallback?(progress, "Analyzing station \(index + 1)/\(oldStations.count)")
            }
        }

        print("   Found \(changedStations) stations with changed IDs")

        // Phase 2: Migrate favicon cache files
        progressCallback?(0.4, "Migrating favicon cache...")
        let (copied, failed) = migrateFaviconCache(
            idMapping: idMapping,
            cacheDirectory: cacheDirectory,
            progressCallback: { subProgress, detail in
                let totalProgress = 0.4 + (subProgress * 0.6)
                progressCallback?(totalProgress, detail)
            }
        )

        progressCallback?(1.0, "Migration complete")

        let result = MigrationResult(
            stationsChanged: changedStations,
            faviconsCopied: copied,
            faviconsFailed: failed,
            idMapping: idMapping
        )

        print("✅ Migration complete:")
        print("   Stations with changed IDs: \(result.stationsChanged)")
        print("   Favicons copied: \(result.faviconsCopied)")
        print("   Favicons failed: \(result.faviconsFailed)")

        return result
    }

    /// Migrates favicon cache files by renaming them from old IDs to new IDs
    /// - Parameters:
    ///   - idMapping: Dictionary mapping old IDs to new IDs
    ///   - cacheDirectory: Directory containing favicon PNG files
    ///   - progressCallback: Optional callback for progress updates
    /// - Returns: Tuple of (successful copies, failed copies)
    private func migrateFaviconCache(
        idMapping: [String: String],
        cacheDirectory: URL,
        progressCallback: ((Double, String) -> Void)?
    ) -> (copied: Int, failed: Int) {
        let fileManager = FileManager.default
        var successCount = 0
        var failCount = 0
        let totalMappings = idMapping.count

        print("📁 Migrating favicon cache files...")

        for (index, (oldID, newID)) in idMapping.enumerated() {
            let oldFileName = CTRKRadioStationFavIconCacheManager.sanitizedFileName(for: oldID)
            let newFileName = CTRKRadioStationFavIconCacheManager.sanitizedFileName(for: newID)

            let oldFileURL = cacheDirectory.appendingPathComponent("\(oldFileName).png")
            let newFileURL = cacheDirectory.appendingPathComponent("\(newFileName).png")

            // Check if old file exists
            guard fileManager.fileExists(atPath: oldFileURL.path) else {
                continue // No favicon for this station
            }

            do {
                // If new file already exists, this is a conflict
                // This can happen if multiple HTTP stations map to the same HTTPS ID
                if fileManager.fileExists(atPath: newFileURL.path) {
                    print("   ⚠️ Favicon conflict: \(oldFileName).png already exists as \(newFileName).png")
                    print("      Keeping existing file, removing duplicate")
                    try? fileManager.removeItem(at: oldFileURL)
                    continue
                }

                // Copy file to new location (don't move, in case we need to rollback)
                try fileManager.copyItem(at: oldFileURL, to: newFileURL)
                successCount += 1
                print("   ✅ Copied: \(oldFileName).png → \(newFileName).png")

                // After successful copy, remove old file
                try? fileManager.removeItem(at: oldFileURL)

            } catch {
                failCount += 1
                print("   ❌ Failed to copy \(oldFileName).png: \(error.localizedDescription)")
            }

            // Progress update
            if index % 5 == 0 {
                let progress = Double(index) / Double(totalMappings)
                progressCallback?(progress, "Migrating favicons \(index + 1)/\(totalMappings)")
            }
        }

        print("📁 Favicon cache migration: \(successCount) copied, \(failCount) failed")
        return (successCount, failCount)
    }

    /// Returns the favicon cache directory for a given database URL
    /// - Parameter databaseURL: URL of the database file
    /// - Returns: URL of the favicon cache directory
    public func faviconCacheDirectory(for databaseURL: URL) -> URL {
        #if os(macOS)
        let dbName = databaseURL.deletingPathExtension().lastPathComponent
        let cacheDirectoryName = "\(dbName)_FavIconCache"

        // Check if database is in app bundle (read-only)
        let isInBundle = databaseURL.path.contains(Bundle.main.bundlePath)

        if isInBundle {
            let fileManager = FileManager.default
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let bundleID = Bundle.main.bundleIdentifier ?? "com.Kreaniqs.Pladio"
                let parentDirectory = appSupport.appendingPathComponent(bundleID)
                return parentDirectory.appendingPathComponent(cacheDirectoryName)
            }
        } else {
            let parentDirectory = databaseURL.deletingLastPathComponent()
            return parentDirectory.appendingPathComponent(cacheDirectoryName)
        }
        #endif

        // Fallback to system cache directory
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
