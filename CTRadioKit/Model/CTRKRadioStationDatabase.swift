//
//  CTRKRadioStationDatabase.swift
//  CTRadioKit
//
//  Created by Claude Code on 11.10.2025.
//

import Foundation

/// Database wrapper for radio stations with versioning support
/// This enables migration of database formats and schema changes
public struct CTRKRadioStationDatabase: Codable, Sendable {
    /// Current database version
    /// Version 1: Original format (array of stations without version field)
    /// Version 2: Protocol-independent IDs (HTTP/HTTPS normalized)
    /// Version 3: Persistent IDs (stored in JSON, stable across streamURL changes)
    /// Version 4: Homepage health status tracking (homepageHTTP/HTTPS fields added)
    /// Version 5: Database metadata with name and description
    public static let currentVersion = 5

    /// Database format version
    public var version: Int

    /// Radio stations in this database
    public var stations: [CTRKRadioStation]

    /// Metadata about the database (optional, for future use)
    public var metadata: DatabaseMetadata?

    /// Initialize a new database with stations
    /// - Parameters:
    ///   - stations: Array of radio stations
    ///   - version: Database version (defaults to current version)
    ///   - metadata: Optional metadata
    public init(stations: [CTRKRadioStation], version: Int = currentVersion, metadata: DatabaseMetadata? = nil) {
        self.version = version
        self.stations = stations
        self.metadata = metadata
    }

    /// Decodes a database from JSON data
    /// Supports both old format (array of stations) and new format (with version)
    /// - Parameter decoder: The decoder to read data from
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try to decode version field (new format)
        if let version = try? container.decode(Int.self, forKey: .version) {
            // New format with version field
            self.version = version
            self.stations = try container.decode([CTRKRadioStation].self, forKey: .stations)
            self.metadata = try? container.decodeIfPresent(DatabaseMetadata.self, forKey: .metadata)
        } else {
            // Old format (just an array of stations) - assume version 1
            // This should not happen when decoding from CTRKRadioStationDatabase,
            // but we keep it for completeness
            self.version = 1
            self.stations = []
            self.metadata = nil
        }
    }

    /// Encodes the database to JSON
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(stations, forKey: .stations)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case stations
        case metadata
    }

    /// Checks if this database needs migration
    /// - Returns: True if the database version is older than current version
    public func needsMigration() -> Bool {
        return version < Self.currentVersion
    }

    /// Returns a description of the database version
    public func versionDescription() -> String {
        switch version {
        case 1:
            return "Version 1 (Original format)"
        case 2:
            return "Version 2 (Protocol-independent IDs)"
        case 3:
            return "Version 3 (Persistent IDs)"
        case 4:
            return "Version 4 (Homepage health tracking)"
        case 5:
            return "Version 5 (Database metadata)"
        default:
            return "Version \(version) (Unknown)"
        }
    }

    /// Migrates stations from V2 to V3 by storing their current IDs as persistent IDs
    /// This ensures IDs remain stable even if streamURL changes later
    /// - Returns: New stations array with persistent IDs
    public func migrateToV3() -> [CTRKRadioStation] {
        guard version == 2 else { return stations }

        // For each station, capture its current computed ID and store it as persistentID
        return stations.map { station in
            // The station's current ID (computed from streamURL)
            let currentID = station.id

            // Create a new station with the same data but with persistentID set
            // We need to use a mirror/reflection approach since CTRKRadioStation is a struct
            // and we can't directly modify the private persistentID field after creation.
            // Instead, we'll encode and re-decode with the persistentID added.

            // Encode station to dictionary
            if let data = try? JSONEncoder().encode(station),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // Add persistentID field with current ID
                json["persistentID"] = currentID

                // Re-encode and decode
                if let newData = try? JSONSerialization.data(withJSONObject: json),
                   let migratedStation = try? JSONDecoder().decode(CTRKRadioStation.self, from: newData) {
                    return migratedStation
                }
            }

            // Fallback: return original station (shouldn't happen)
            return station
        }
    }

    /// Migrates stations from V3 to V4 by ensuring homepage health fields exist
    /// V4 adds homepageHTTP and homepageHTTPS health tracking fields
    /// - Returns: New stations array with homepage health fields initialized
    public func migrateToV4() -> [CTRKRadioStation] {
        guard version == 3 else { return stations }

        // For each station, ensure health.homepageHTTP and health.homepageHTTPS exist
        // If the JSON doesn't have these fields, they'll be initialized to .unknown by the decoder
        return stations.map { station in
            // Encode and re-decode to ensure all fields are properly initialized
            if let data = try? JSONEncoder().encode(station),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var healthJson = json["health"] as? [String: Any] {

                // Add homepage health fields if they don't exist
                if healthJson["homepageHTTP"] == nil {
                    healthJson["homepageHTTP"] = "unknown"
                }
                if healthJson["homepageHTTPS"] == nil {
                    healthJson["homepageHTTPS"] = "unknown"
                }

                json["health"] = healthJson

                // Re-encode and decode
                if let newData = try? JSONSerialization.data(withJSONObject: json),
                   let migratedStation = try? JSONDecoder().decode(CTRKRadioStation.self, from: newData) {
                    return migratedStation
                }
            }

            // Fallback: return original station (decoder should handle missing fields)
            return station
        }
    }

    /// Migrates from V4 to V5 by ensuring metadata with name and description exists
    /// V5 adds structured metadata fields to the database
    /// - Returns: Database with proper metadata structure
    public func migrateToV5() -> CTRKRadioStationDatabase {
        guard version == 4 else { return self }

        // Ensure metadata exists with name and description fields
        let updatedMetadata: DatabaseMetadata
        if let existingMetadata = metadata {
            // Preserve existing metadata, ensure all fields are accessible
            updatedMetadata = DatabaseMetadata(
                createdAt: existingMetadata.createdAt,
                lastModified: Date(),
                name: existingMetadata.name,
                description: existingMetadata.description,
                customFields: existingMetadata.customFields
            )
        } else {
            // Create new metadata
            updatedMetadata = DatabaseMetadata(
                createdAt: nil,
                lastModified: Date(),
                name: nil,
                description: nil
            )
        }

        return CTRKRadioStationDatabase(
            stations: stations,
            version: 5,
            metadata: updatedMetadata
        )
    }
}

/// Metadata about the database (for future extensions)
public struct DatabaseMetadata: Codable, Sendable {
    /// When the database was created
    public var createdAt: Date?

    /// When the database was last modified
    public var lastModified: Date?

    /// Name of the database
    public var name: String?

    /// Optional description of the database
    public var description: String?

    /// Custom metadata fields (extensible)
    public var customFields: [String: String]?

    public init(createdAt: Date? = nil,
                lastModified: Date? = nil,
                name: String? = nil,
                description: String? = nil,
                customFields: [String: String]? = nil) {
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.name = name
        self.description = description
        self.customFields = customFields
    }
}

/// Helper for loading databases from different formats
public struct CTRKRadioStationDatabaseLoader {
    /// Loads a database from JSON data, supporting both old and new formats
    /// - Parameter data: JSON data to decode
    /// - Returns: A database structure (with version 1 if old format detected)
    /// - Throws: Decoding errors
    public static func load(from data: Data) throws -> CTRKRadioStationDatabase {
        let decoder = JSONDecoder()

        // Try to decode as new format (with version)
        if let database = try? decoder.decode(CTRKRadioStationDatabase.self, from: data) {
            return database
        }

        // Fall back to old format (just an array of stations)
        let stations = try decoder.decode([CTRKRadioStation].self, from: data)

        // Return as version 1 database
        return CTRKRadioStationDatabase(
            stations: stations,
            version: 1,
            metadata: DatabaseMetadata(
                createdAt: nil,
                lastModified: nil,
                description: "Migrated from legacy format"
            )
        )
    }

    /// Saves a database to JSON data
    /// - Parameter database: The database to save
    /// - Returns: JSON data
    /// - Throws: Encoding errors
    public static func save(_ database: CTRKRadioStationDatabase) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(database)
    }
}
