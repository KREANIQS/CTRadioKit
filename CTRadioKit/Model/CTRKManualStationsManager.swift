//
//  CTRKManualStationsManager.swift
//  CTRadioKit
//
//  Created by Claude Code on 17.01.2026.
//

import Foundation
import Combine
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Manages user-created manual radio stations with iCloud sync support.
/// Provides CRUD operations, limit enforcement (max 15 stations), and sync conflict resolution.
@MainActor
public final class CTRKManualStationsManager: ObservableObject {
    // MARK: - Constants

    /// Maximum number of manual stations allowed per user
    public static let maxStations = 15

    // MARK: - Published Properties

    /// All manual stations, sorted by creation date (newest first)
    @Published public private(set) var manualStations: [CTRKManualStation] = []

    // MARK: - Storage Keys

    private let userDefaultsKey = "ctrk.manualStations.local.v1"
    private let iCloudKey = "ctrk.manualStations.icloud.v1"

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    /// Whether more stations can be added (under the limit)
    public var canAddMore: Bool {
        manualStations.count < Self.maxStations
    }

    /// Number of remaining slots available
    public var remainingSlots: Int {
        max(0, Self.maxStations - manualStations.count)
    }

    /// Current count of manual stations
    public var count: Int {
        manualStations.count
    }

    // MARK: - Initialization

    public init() {
        loadFromStorage()
        setupiCloudSync()
    }

    // MARK: - CRUD Operations

    /// Adds a new manual station
    /// - Parameter station: The radio station to add
    /// - Returns: The created manual station, or nil if limit reached or duplicate
    @discardableResult
    public func addStation(_ station: CTRKRadioStation) -> CTRKManualStation? {
        guard canAddMore else {
            print("⚠️ [ManualStations] Cannot add station: limit of \(Self.maxStations) reached")
            NotificationCenter.default.post(name: .manualStationsLimitReached, object: nil)
            return nil
        }

        // Check for duplicates by stream URL
        let normalizedURL = station.streamURL.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if manualStations.contains(where: { $0.station.streamURL.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedURL }) {
            print("⚠️ [ManualStations] Cannot add station: duplicate stream URL")
            return nil
        }

        let manualStation = CTRKManualStation(station: station)
        manualStations.insert(manualStation, at: 0) // Add at beginning (newest first)
        persist()

        print("✅ [ManualStations] Added '\(station.name)' - now \(count)/\(Self.maxStations)")
        NotificationCenter.default.post(name: .manualStationsDidChange, object: manualStation)

        return manualStation
    }

    /// Creates and adds a new manual station from parameters
    /// - Parameters:
    ///   - name: Station name
    ///   - streamURL: Stream URL
    ///   - homepageURL: Homepage URL
    ///   - faviconURL: Favicon URL
    ///   - country: Country code
    ///   - codec: Audio codec
    ///   - bitrate: Bitrate in kbps
    ///   - tags: Station tags
    /// - Returns: The created manual station, or nil if limit reached
    @discardableResult
    public func addStation(
        name: String,
        streamURL: String,
        homepageURL: String = "",
        faviconURL: String = "",
        country: String = "",
        codec: String = "",
        bitrate: Int = 0,
        tags: [String] = []
    ) -> CTRKManualStation? {
        let manualStation = CTRKManualStation(
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            faviconURL: faviconURL,
            country: country,
            codec: codec,
            bitrate: bitrate,
            tags: tags
        )

        guard canAddMore else {
            print("⚠️ [ManualStations] Cannot add station: limit of \(Self.maxStations) reached")
            NotificationCenter.default.post(name: .manualStationsLimitReached, object: nil)
            return nil
        }

        // Check for duplicates
        let normalizedURL = streamURL.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if manualStations.contains(where: { $0.station.streamURL.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedURL }) {
            print("⚠️ [ManualStations] Cannot add station: duplicate stream URL")
            return nil
        }

        manualStations.insert(manualStation, at: 0)
        persist()

        print("✅ [ManualStations] Added '\(name)' - now \(count)/\(Self.maxStations)")
        NotificationCenter.default.post(name: .manualStationsDidChange, object: manualStation)

        return manualStation
    }

    /// Updates an existing manual station
    /// - Parameter manualStation: The updated manual station
    public func updateStation(_ manualStation: CTRKManualStation) {
        guard let index = manualStations.firstIndex(where: { $0.id == manualStation.id }) else {
            print("⚠️ [ManualStations] Cannot update station: not found")
            return
        }

        let updated = manualStation.withUpdatedSyncTimestamp()
        manualStations[index] = updated
        persist()

        print("✅ [ManualStations] Updated '\(manualStation.station.name)'")
        NotificationCenter.default.post(name: .manualStationsDidChange, object: updated)
    }

    /// Removes a manual station by ID
    /// - Parameter id: The station ID to remove
    public func removeStation(id: String) {
        guard let index = manualStations.firstIndex(where: { $0.id == id }) else {
            print("⚠️ [ManualStations] Cannot remove station: not found")
            return
        }

        let removed = manualStations.remove(at: index)
        persist()

        print("✅ [ManualStations] Removed '\(removed.station.name)' - now \(count)/\(Self.maxStations)")
        NotificationCenter.default.post(name: .manualStationsDidChange, object: nil)
    }

    /// Gets a manual station by ID
    /// - Parameter id: The station ID
    /// - Returns: The manual station if found
    public func station(withID id: String) -> CTRKManualStation? {
        manualStations.first { $0.id == id }
    }

    /// Gets the underlying radio station by ID
    /// - Parameter id: The station ID
    /// - Returns: The radio station if found
    public func radioStation(withID id: String) -> CTRKRadioStation? {
        station(withID: id)?.station
    }

    /// Returns all radio stations from manual stations (for unified access)
    public func allRadioStations() -> [CTRKRadioStation] {
        manualStations.map { $0.station }
    }

    // MARK: - Validation & Submission

    /// Marks a station as validated (or not)
    /// - Parameters:
    ///   - stationID: The station ID
    ///   - success: Whether validation succeeded
    ///   - error: Error message if validation failed
    public func markValidated(stationID: String, success: Bool, error: String? = nil) {
        guard let index = manualStations.firstIndex(where: { $0.id == stationID }) else {
            return
        }

        var station = manualStations[index]
        station.metadata = station.metadata.withValidation(success: success, error: error)
        station.syncTimestamp = Date()
        manualStations[index] = station
        persist()

        print("✅ [ManualStations] Marked '\(station.station.name)' as \(success ? "validated" : "invalid")")
    }

    /// Marks a station as submitted for official database review
    /// - Parameter stationID: The station ID
    public func markSubmittedForReview(stationID: String) {
        guard let index = manualStations.firstIndex(where: { $0.id == stationID }) else {
            return
        }

        var station = manualStations[index]
        station.metadata = station.metadata.withSubmission()
        station.syncTimestamp = Date()
        manualStations[index] = station
        persist()

        print("✅ [ManualStations] Marked '\(station.station.name)' as submitted for review")
    }

    // MARK: - Bulk Operations

    /// Removes all manual stations (use with caution)
    public func clearAll() {
        manualStations.removeAll()
        persist()
        print("✅ [ManualStations] Cleared all manual stations")
        NotificationCenter.default.post(name: .manualStationsDidChange, object: nil)
    }

    // MARK: - Persistence

    private func persist() {
        // Save to UserDefaults (local backup)
        do {
            let data = try JSONEncoder().encode(manualStations)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("❌ [ManualStations] Failed to encode (local): \(error)")
        }

        // Save to iCloud KVS (sync)
        do {
            let data = try JSONEncoder().encode(manualStations)
            let dataSize = data.count
            let dataSizeKB = Double(dataSize) / 1024.0

            // iCloud KVS has a 1MB per-key limit, warn if approaching
            if dataSizeKB > 500 {
                print("⚠️ [ManualStations] Data size approaching iCloud limit: \(String(format: "%.2f", dataSizeKB)) KB")
            }

            NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        } catch {
            print("❌ [ManualStations] Failed to encode (iCloud): \(error)")
        }
    }

    private func loadFromStorage() {
        var localStations: [CTRKManualStation] = []
        var iCloudStations: [CTRKManualStation] = []

        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([CTRKManualStation].self, from: data) {
            localStations = decoded
        }

        // Load from iCloud KVS
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let decoded = try? JSONDecoder().decode([CTRKManualStation].self, from: data) {
            iCloudStations = decoded
        }

        // Merge both sources with conflict resolution
        let merged = mergeStations(local: localStations, iCloud: iCloudStations)
        self.manualStations = merged.sorted { $0.metadata.createdDate > $1.metadata.createdDate }

        print("✅ [ManualStations] Loaded \(manualStations.count) station(s)")
    }

    /// Merges local and iCloud stations, keeping the newest version based on syncTimestamp
    private func mergeStations(
        local: [CTRKManualStation],
        iCloud: [CTRKManualStation]
    ) -> [CTRKManualStation] {
        var merged: [String: CTRKManualStation] = [:]

        // Add local stations
        for station in local {
            merged[station.id] = station
        }

        // Merge iCloud stations, keeping newer ones
        for station in iCloud {
            if let existing = merged[station.id] {
                // Conflict: keep the one with newer syncTimestamp
                if station.syncTimestamp > existing.syncTimestamp {
                    merged[station.id] = station
                }
            } else {
                // No conflict, add it
                merged[station.id] = station
            }
        }

        return Array(merged.values)
    }

    // MARK: - iCloud Sync

    private func setupiCloudSync() {
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleiCloudChange(notification)
            }
            .store(in: &cancellables)

        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              reason == NSUbiquitousKeyValueStoreServerChange ||
              reason == NSUbiquitousKeyValueStoreInitialSyncChange,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              changedKeys.contains(iCloudKey) else {
            return
        }

        print("🔄 [ManualStations] iCloud change detected - merging...")
        performMerge()
    }

    private func performMerge() {
        // Save current local state
        let localStations = manualStations

        // Load iCloud state
        var iCloudStations: [CTRKManualStation] = []
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey),
           let decoded = try? JSONDecoder().decode([CTRKManualStation].self, from: data) {
            iCloudStations = decoded
        }

        // Merge
        let merged = mergeStations(local: localStations, iCloud: iCloudStations)
        let sortedMerged = merged.sorted { $0.metadata.createdDate > $1.metadata.createdDate }

        // Check for changes
        let localIDs = Set(manualStations.map { $0.id })
        let mergedIDs = Set(sortedMerged.map { $0.id })
        let hasChanges = localIDs != mergedIDs || manualStations.count != sortedMerged.count

        manualStations = sortedMerged

        if hasChanges {
            persist()
            NotificationCenter.default.post(name: .manualStationsDidChange, object: nil)
            print("✅ [ManualStations] Merged to \(count) station(s)")
        }
    }
}

// MARK: - Additional Notification Names

extension Notification.Name {
    /// Posted when the manual stations limit is reached
    public static let manualStationsLimitReached = Notification.Name("manualStationsLimitReached")
}
