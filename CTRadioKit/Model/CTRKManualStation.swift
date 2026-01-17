//
//  CTRKManualStation.swift
//  CTRadioKit
//
//  Created by Claude Code on 17.01.2026.
//

import Foundation

/// A wrapper combining a radio station with its manual station metadata.
/// Used for user-created stations that are stored separately from the official database.
public struct CTRKManualStation: Codable, Identifiable, Sendable, Equatable {
    /// The radio station data
    public var station: CTRKRadioStation

    /// Metadata tracking creation, modification, validation, and submission
    public var metadata: CTRKManualStationMetadata

    /// Timestamp for iCloud sync conflict resolution (newest wins)
    public var syncTimestamp: Date

    // MARK: - Identifiable

    /// The unique identifier (delegates to station.id)
    public var id: String { station.id }

    // MARK: - Initialization

    /// Creates a new manual station wrapper
    /// - Parameters:
    ///   - station: The radio station data (will have isManual set to true)
    ///   - metadata: The metadata (defaults to new metadata)
    ///   - syncTimestamp: Timestamp for sync (defaults to now)
    public init(
        station: CTRKRadioStation,
        metadata: CTRKManualStationMetadata = CTRKManualStationMetadata(),
        syncTimestamp: Date = Date()
    ) {
        // Ensure the station has isManual = true
        var mutableStation = station
        mutableStation.isManual = true
        self.station = mutableStation
        self.metadata = metadata
        self.syncTimestamp = syncTimestamp
    }

    /// Creates a new manual station from raw parameters
    /// - Parameters:
    ///   - name: Station name (required)
    ///   - streamURL: Stream URL (required)
    ///   - homepageURL: Homepage URL (optional)
    ///   - faviconURL: Favicon URL (optional)
    ///   - country: Country code (optional)
    ///   - codec: Audio codec (optional, e.g., "MP3", "AAC")
    ///   - bitrate: Bitrate in kbps (optional)
    ///   - tags: Station tags (optional)
    public init(
        name: String,
        streamURL: String,
        homepageURL: String = "",
        faviconURL: String = "",
        country: String = "",
        codec: String = "",
        bitrate: Int = 0,
        tags: [String] = []
    ) {
        // Generate station ID with manual- prefix
        let stationID = CTRKManualStation.generateManualStationID(
            streamURL: streamURL,
            country: country,
            codec: codec,
            bitrate: bitrate
        )

        var station = CTRKRadioStation(
            name: name,
            streamURL: streamURL,
            homepageURL: homepageURL,
            faviconURL: faviconURL,
            tags: tags,
            codec: codec,
            bitrate: bitrate,
            country: country,
            labels: []
        )
        station.isManual = true

        self.station = station
        self.metadata = CTRKManualStationMetadata()
        self.syncTimestamp = Date()
    }

    // MARK: - Mutation Helpers

    /// Returns a copy with updated station data and refreshed timestamps
    /// Note: Preserves the original station ID to ensure update works correctly
    public func withUpdatedStation(_ newStation: CTRKRadioStation) -> CTRKManualStation {
        var copy = self
        var mutableStation = newStation
        mutableStation.isManual = true
        // Preserve the original station ID (use computed id if persistentID is nil)
        mutableStation.persistentID = station.id
        copy.station = mutableStation
        copy.metadata = metadata.withUpdatedModification()
        copy.syncTimestamp = Date()
        return copy
    }

    /// Returns a copy with updated sync timestamp (for persistence)
    public func withUpdatedSyncTimestamp() -> CTRKManualStation {
        var copy = self
        copy.syncTimestamp = Date()
        return copy
    }

    // MARK: - ID Generation

    /// Prefix for manual station IDs to prevent collision with official database
    public static let manualIDPrefix = "manual-"

    /// Generates a manual station ID with the manual- prefix
    /// - Parameters:
    ///   - streamURL: The stream URL
    ///   - country: Country code
    ///   - codec: Audio codec
    ///   - bitrate: Bitrate in kbps
    /// - Returns: ID with manual- prefix
    public static func generateManualStationID(
        streamURL: String,
        country: String = "",
        codec: String = "",
        bitrate: Int = 0
    ) -> String {
        let baseID = CTRKRadioStation.generateID(
            for: streamURL,
            country: country,
            codec: codec,
            bitrate: bitrate
        )
        return manualIDPrefix + baseID
    }

    /// Checks if a station ID is a manual station ID
    public static func isManualStationID(_ id: String) -> Bool {
        return id.hasPrefix(manualIDPrefix)
    }

    // MARK: - Convenience Properties

    /// Whether the station's stream has been validated
    public var isValidated: Bool { metadata.isValidated }

    /// Whether the station has been submitted for official database inclusion
    public var isSubmitted: Bool { metadata.submittedForReview }

    /// Human-readable creation date
    public var createdDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: metadata.createdDate)
    }

    /// Human-readable modification date
    public var modifiedDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: metadata.modifiedDate)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the list of manual stations changes (add, update, delete)
    public static let manualStationsDidChange = Notification.Name("manualStationsDidChange")
}
