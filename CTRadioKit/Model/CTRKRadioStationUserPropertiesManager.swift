//
//  CTRKRadioStationUserPropertiesManager.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 19.10.2025.
//

import Foundation
import Combine
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Manages user-specific properties for radio stations (favorites, play counts, etc.)
/// Synchronizes data across devices via iCloud Key-Value Store
@MainActor
public final class CTRKRadioStationUserPropertiesManager: ObservableObject {
    // MARK: - Published Properties

    /// All user properties, keyed by station ID
    @Published public private(set) var userProperties: [String: CTRKRadioStation.UserProperties] = [:]

    // MARK: - Storage Keys

    private let userDefaultsKey = "ctrk.userProperties.local.v1"
    private let iCloudKey = "ctrk.userProperties.icloud.v1"

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init() {
        loadFromStorage()
        setupiCloudSync()
    }

    // MARK: - Public API

    /// Gets user properties for a station (returns default if not found)
    public func properties(for stationID: String) -> CTRKRadioStation.UserProperties {
        return userProperties[stationID] ?? CTRKRadioStation.UserProperties(stationID: stationID)
    }

    /// Updates user properties for a station
    public func updateProperties(_ properties: CTRKRadioStation.UserProperties) {
        userProperties[properties.stationID] = properties.withUpdatedSync()
        persist()
    }

    /// Toggles favorite status for a station
    public func toggleFavorite(for stationID: String) {
        let current = properties(for: stationID)
        let wasAlreadyFavorite = current.isFavorite
        userProperties[stationID] = current.withToggledFavorite()
        persist()

        // Post notification for UI updates (e.g., CarPlay)
        NotificationCenter.default.post(name: .favoritesDidChange, object: nil)

        // Post notification for analytics tracking
        if wasAlreadyFavorite {
            NotificationCenter.default.post(name: .favoriteRemoved, object: stationID)
        } else {
            NotificationCenter.default.post(name: .favoriteAdded, object: stationID)
        }
    }

    /// Increments play count for a station
    public func incrementPlayCount(for stationID: String) {
        let current = properties(for: stationID)
        userProperties[stationID] = current.withIncrementedPlayCount()
        persist()

        // Post notification for UI updates (e.g., CarPlay)
        NotificationCenter.default.post(name: .recentStationsDidChange, object: nil)
    }

    /// Adds listening duration (in seconds) for a station
    public func addListeningDuration(_ duration: TimeInterval, for stationID: String) {
        guard duration > 0 else { return }
        let current = properties(for: stationID)
        userProperties[stationID] = current.withAddedListeningDuration(duration)
        persist()
    }

    /// Checks if a station is marked as favorite
    public func isFavorite(_ stationID: String) -> Bool {
        return userProperties[stationID]?.isFavorite ?? false
    }

    /// Gets all favorite station IDs, sorted by last played date (newest first)
    public func favoriteStationIDs() -> [String] {
        return userProperties.values
            .filter { $0.isFavorite }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
            .map { $0.stationID }
    }

    /// Gets recently played station IDs, sorted by last played date (newest first)
    public func recentStationIDs(limit: Int = 30) -> [String] {
        return userProperties.values
            .filter { $0.playCount > 0 }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
            .prefix(limit)
            .map { $0.stationID }
    }

    /// Removes user properties for a station
    public func removeProperties(for stationID: String) {
        userProperties.removeValue(forKey: stationID)
        persist()
    }

    /// Clears all user properties (use with caution!)
    public func clearAll() {
        userProperties.removeAll()
        persist()
    }

    /// Debug info about current state
    public struct SyncDebugInfo {
        public let localCount: Int
        public let iCloudCount: Int
        public let mergedCount: Int
        public let localFavoriteCount: Int
        public let iCloudFavoriteCount: Int
        public let mergedFavoriteCount: Int
        public let localIDs: [String]
        public let iCloudIDs: [String]
    }

    /// Forces reload from iCloud and returns debug information
    /// - Returns: Debug info showing local vs iCloud vs merged state
    public func forceReloadFromiCloud() -> SyncDebugInfo {
        #if os(iOS) || os(tvOS)
        NSUbiquitousKeyValueStore.default.synchronize()
        #endif

        var localProperties: [CTRKRadioStation.UserProperties] = []
        var iCloudProperties: [CTRKRadioStation.UserProperties] = []

        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([CTRKRadioStation.UserProperties].self, from: data) {
            localProperties = decoded
        }

        // Load from iCloud KVS
        #if os(iOS) || os(tvOS)
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let decoded = try? JSONDecoder().decode([CTRKRadioStation.UserProperties].self, from: data) {
            iCloudProperties = decoded
        }
        #endif

        // Merge both sources with conflict resolution
        let merged = mergeProperties(local: localProperties, iCloud: iCloudProperties)
        self.userProperties = Dictionary(uniqueKeysWithValues: merged.map { ($0.stationID, $0) })

        // Create debug info
        let debugInfo = SyncDebugInfo(
            localCount: localProperties.count,
            iCloudCount: iCloudProperties.count,
            mergedCount: merged.count,
            localFavoriteCount: localProperties.filter { $0.isFavorite }.count,
            iCloudFavoriteCount: iCloudProperties.filter { $0.isFavorite }.count,
            mergedFavoriteCount: merged.filter { $0.isFavorite }.count,
            localIDs: localProperties.filter { $0.isFavorite }.map { $0.stationID },
            iCloudIDs: iCloudProperties.filter { $0.isFavorite }.map { $0.stationID }
        )

        print("🔄 iCloud Sync Debug:")
        print("   Local: \(debugInfo.localCount) properties, \(debugInfo.localFavoriteCount) favorites")
        print("   iCloud: \(debugInfo.iCloudCount) properties, \(debugInfo.iCloudFavoriteCount) favorites")
        print("   Merged: \(debugInfo.mergedCount) properties, \(debugInfo.mergedFavoriteCount) favorites")

        return debugInfo
    }

    // MARK: - Persistence

    private func persist() {
        // Convert to array for encoding
        let propertiesArray = Array(userProperties.values)

        // Save to UserDefaults (local backup)
        do {
            let data = try JSONEncoder().encode(propertiesArray)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("❌ Failed to encode user properties (local): \(error)")
        }

        // Save to iCloud KVS (sync)
        #if os(iOS) || os(tvOS)
        do {
            let data = try JSONEncoder().encode(propertiesArray)
            NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        } catch {
            print("❌ Failed to encode user properties (iCloud): \(error)")
        }
        #endif
    }

    private func loadFromStorage() {
        var localProperties: [CTRKRadioStation.UserProperties] = []
        var iCloudProperties: [CTRKRadioStation.UserProperties] = []

        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([CTRKRadioStation.UserProperties].self, from: data) {
            localProperties = decoded
        }

        // Load from iCloud KVS
        #if os(iOS) || os(tvOS)
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let decoded = try? JSONDecoder().decode([CTRKRadioStation.UserProperties].self, from: data) {
            iCloudProperties = decoded
        }
        #endif

        // Merge both sources with conflict resolution
        let merged = mergeProperties(local: localProperties, iCloud: iCloudProperties)
        self.userProperties = Dictionary(uniqueKeysWithValues: merged.map { ($0.stationID, $0) })
    }

    /// Merges local and iCloud properties, keeping the newest version based on syncTimestamp
    private func mergeProperties(
        local: [CTRKRadioStation.UserProperties],
        iCloud: [CTRKRadioStation.UserProperties]
    ) -> [CTRKRadioStation.UserProperties] {
        var merged: [String: CTRKRadioStation.UserProperties] = [:]

        // Add local properties
        for prop in local {
            merged[prop.stationID] = prop
        }

        // Merge iCloud properties, keeping newer ones
        for prop in iCloud {
            if let existing = merged[prop.stationID] {
                // Conflict: keep the one with newer syncTimestamp
                if prop.syncTimestamp > existing.syncTimestamp {
                    merged[prop.stationID] = prop
                }
            } else {
                // No conflict, add it
                merged[prop.stationID] = prop
            }
        }

        return Array(merged.values)
    }

    // MARK: - iCloud Sync

    private func setupiCloudSync() {
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleiCloudChange(notification)
            }
            .store(in: &cancellables)

        NSUbiquitousKeyValueStore.default.synchronize()
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              reason == NSUbiquitousKeyValueStoreServerChange ||
              reason == NSUbiquitousKeyValueStoreInitialSyncChange,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              changedKeys.contains(iCloudKey) else {
            return
        }

        print("🔄 iCloud change detected for user properties - merging...")
        loadFromStorage()
    }
    #endif
}

// MARK: - Migration Helper

extension CTRKRadioStationUserPropertiesManager {
    /// Migrates data from old FavoriteRadioStationsManager and RecentRadioStationsManager
    /// This is called once during app upgrade
    ///
    /// **v1**: Initial migration (had a bug - was called with empty arrays)
    /// **v2**: Fixed to actually receive data from legacy managers
    public func migrateFromLegacyManagers(
        favorites: [CTRKRadioStation],
        recents: [CTRKRadioStation]
    ) {
        let migrationKey = "ctrk.userProperties.didMigrate.v4"  // v4: Reset V9→V10 flag after legacy migration
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            print("ℹ️ User properties already migrated (v4), skipping...")
            return
        }

        // Skip if no legacy data to migrate
        guard !favorites.isEmpty || !recents.isEmpty else {
            print("ℹ️ No legacy data to migrate, marking as done")
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        print("🔄 Migrating user properties from legacy managers...")

        // Migrate favorites
        print("📋 Migrating \(favorites.count) favorites:")
        for station in favorites {
            print("   → '\(station.name)' (ID: \(station.id))")
            print("     Country: \(station.country), Codec: \(station.codec), Bitrate: \(station.bitrate)")
            print("     persistentID: \(station.persistentID ?? "nil")")
            var props = properties(for: station.id)
            props.isFavorite = true
            if let lastPlayed = station.lastPlayedDate {
                props.lastPlayedDate = lastPlayed
                props.playCount = max(1, props.playCount) // At least 1 if there's a play date
            }
            userProperties[station.id] = props.withUpdatedSync()
        }

        // Migrate recents (only update play count/date, don't override favorites)
        print("📋 Migrating \(recents.count) recents:")
        for station in recents {
            print("   → '\(station.name)' (ID: \(station.id))")
            var props = properties(for: station.id)
            if let lastPlayed = station.lastPlayedDate {
                props.lastPlayedDate = lastPlayed
                props.playCount = max(1, props.playCount)
            }
            userProperties[station.id] = props.withUpdatedSync()
        }

        persist()
        UserDefaults.standard.set(true, forKey: migrationKey)

        // IMPORTANT: Reset V9→V10 migration flag so it runs after legacy migration
        // The legacy favorites may have V9-style IDs that need to be mapped to V10-style
        let v9ToV10MigrationKey = "ctrk.userProperties.migratedV9ToV10"
        if UserDefaults.standard.bool(forKey: v9ToV10MigrationKey) {
            print("🔄 Resetting V9→V10 migration flag (legacy data was just migrated)")
            UserDefaults.standard.set(false, forKey: v9ToV10MigrationKey)
        }

        print("✅ Migration complete: \(favorites.count) favorites, \(recents.count) recents")
    }
}

// MARK: - V9 to V10 Station ID Migration

extension CTRKRadioStationUserPropertiesManager {

    /// Result of V9 to V10 station ID migration containing statistics
    public struct V9ToV10MigrationResult {
        public let migratedCount: Int
        public let lostFavoriteCount: Int
        public let lostRecentCount: Int

        public var hasLostFavorites: Bool { lostFavoriteCount > 0 }
        public var hasLostRecents: Bool { lostRecentCount > 0 }
        public var hasLostStations: Bool { hasLostFavorites || hasLostRecents }
    }

    /// Migrates station IDs from V9 to V10 format using the provided mapping.
    ///
    /// **ID Algorithm Versions** (independent from Database Format Version!):
    /// - V9-style: `UUIDv5(canonicalURL)` - URL only
    /// - V10-style: `UUIDv5(canonicalURL + "|country:" + country + "|codec:" + codec + "|bitrate:" + bitrate)`
    ///
    /// This migration handles favorites that may have been created with V9-style IDs,
    /// mapping them to their corresponding V10-style IDs in the current database.
    ///
    /// - Parameters:
    ///   - mapping: Dictionary mapping V9 station IDs to V10 station IDs
    ///   - currentStationIDs: Set of all current station IDs in the database
    /// - Returns: Migration statistics for user feedback
    public func migrateStationIDsV9ToV10(
        using mapping: [String: String],
        currentStationIDs: Set<String>
    ) -> V9ToV10MigrationResult {
        let migrationKey = "ctrk.userProperties.migratedV9ToV10"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            print("ℹ️ V9→V10 migration already completed, skipping...")
            return V9ToV10MigrationResult(migratedCount: 0, lostFavoriteCount: 0, lostRecentCount: 0)
        }

        print("🔄 Migrating station IDs from V9 to V10...")

        var migratedCount = 0
        var lostFavoriteCount = 0
        var lostRecentCount = 0
        var newUserProperties: [String: CTRKRadioStation.UserProperties] = [:]

        for (stationID, props) in userProperties {
            // Case 1: ID already exists in V10 database (no migration needed)
            if currentStationIDs.contains(stationID) {
                newUserProperties[stationID] = props
                continue
            }

            // Case 2: Try to map V9 ID to V10 ID
            if let newID = mapping[stationID] {
                // Create new UserProperties with the V10 ID (stationID is immutable)
                let migratedProps = CTRKRadioStation.UserProperties(
                    stationID: newID,
                    isFavorite: props.isFavorite,
                    playCount: props.playCount,
                    lastPlayedDate: props.lastPlayedDate,
                    userNotes: props.userNotes,
                    customTags: props.customTags,
                    totalListeningDuration: props.totalListeningDuration
                )
                newUserProperties[newID] = migratedProps.withUpdatedSync()
                migratedCount += 1
                print("  ✓ Migrated: \(stationID) → \(newID)")
                continue
            }

            // Case 3: ID not found in mapping - station might be removed from database
            if props.isFavorite {
                lostFavoriteCount += 1
                print("  ⚠️ Lost favorite: \(stationID)")
            }
            if props.playCount > 0 {
                lostRecentCount += 1
            }
            // Don't keep orphaned properties
        }

        userProperties = newUserProperties
        persist()

        UserDefaults.standard.set(true, forKey: migrationKey)
        print("✅ V9→V10 migration completed: \(migratedCount) migrated, \(lostFavoriteCount) favorites lost")

        return V9ToV10MigrationResult(
            migratedCount: migratedCount,
            lostFavoriteCount: lostFavoriteCount,
            lostRecentCount: lostRecentCount
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    public static let favoritesDidChange = Notification.Name("favoritesDidChange")
    public static let recentStationsDidChange = Notification.Name("recentStationsDidChange")
    public static let favoriteAdded = Notification.Name("favoriteAdded")
    public static let favoriteRemoved = Notification.Name("favoriteRemoved")
}
