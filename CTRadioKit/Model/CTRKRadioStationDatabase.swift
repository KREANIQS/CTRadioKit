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
    public static let currentVersion = 2

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
        default:
            return "Version \(version) (Unknown)"
        }
    }
}

/// Metadata about the database (for future extensions)
public struct DatabaseMetadata: Codable, Sendable {
    /// When the database was created
    public var createdAt: Date?

    /// When the database was last modified
    public var lastModified: Date?

    /// Optional description of the database
    public var description: String?

    /// Custom metadata fields (extensible)
    public var customFields: [String: String]?

    public init(createdAt: Date? = nil,
                lastModified: Date? = nil,
                description: String? = nil,
                customFields: [String: String]? = nil) {
        self.createdAt = createdAt
        self.lastModified = lastModified
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
