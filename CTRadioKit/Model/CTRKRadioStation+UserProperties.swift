//
//  CTRKRadioStation+UserProperties.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 19.10.2025.
//

import Foundation

// MARK: - User Properties Extension

extension CTRKRadioStation {
    /// User-specific properties that are synchronized across devices via iCloud KVS.
    /// These properties are NOT part of the station database but are stored separately
    /// and linked to stations via their persistentID.
    public struct UserProperties: Codable, Sendable, Equatable {
        /// The station ID this property belongs to (links to CTRKRadioStation.id)
        public let stationID: String

        /// Whether the user has marked this station as a favorite
        public var isFavorite: Bool

        /// Number of times the user has played this station
        public var playCount: Int

        /// Last time the user played this station
        public var lastPlayedDate: Date?

        /// User's personal notes about this station (for future features)
        public var userNotes: String?

        /// Custom user-defined tags/labels (for future features)
        public var customTags: [String]

        // MARK: - Sync Metadata

        /// Timestamp when these properties were last modified (for conflict resolution)
        public var syncTimestamp: Date

        /// Device ID that last modified these properties (for debugging sync issues)
        public var deviceID: String

        // MARK: - Initializer

        public init(
            stationID: String,
            isFavorite: Bool = false,
            playCount: Int = 0,
            lastPlayedDate: Date? = nil,
            userNotes: String? = nil,
            customTags: [String] = [],
            syncTimestamp: Date = Date(),
            deviceID: String = Self.currentDeviceID()
        ) {
            self.stationID = stationID
            self.isFavorite = isFavorite
            self.playCount = playCount
            self.lastPlayedDate = lastPlayedDate
            self.userNotes = userNotes
            self.customTags = customTags
            self.syncTimestamp = syncTimestamp
            self.deviceID = deviceID
        }

        // MARK: - Device ID Helper

        /// Returns a stable device identifier for sync conflict resolution
        public static func currentDeviceID() -> String {
            #if os(iOS) || os(tvOS)
            return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            #elseif os(macOS)
            // On macOS, use a persistent identifier stored in UserDefaults
            let key = "com.pladio.deviceIdentifier"
            if let stored = UserDefaults.standard.string(forKey: key) {
                return stored
            }
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: key)
            return newID
            #else
            return UUID().uuidString
            #endif
        }

        // MARK: - Convenience Methods

        /// Creates a copy with updated syncTimestamp and deviceID
        public func withUpdatedSync() -> UserProperties {
            var copy = self
            copy.syncTimestamp = Date()
            copy.deviceID = Self.currentDeviceID()
            return copy
        }

        /// Increments play count and updates last played date
        public func withIncrementedPlayCount() -> UserProperties {
            var copy = self
            copy.playCount += 1
            copy.lastPlayedDate = Date()
            copy.syncTimestamp = Date()
            copy.deviceID = Self.currentDeviceID()
            return copy
        }

        /// Toggles favorite status
        public func withToggledFavorite() -> UserProperties {
            var copy = self
            copy.isFavorite.toggle()
            copy.syncTimestamp = Date()
            copy.deviceID = Self.currentDeviceID()
            return copy
        }
    }
}

// MARK: - Convenience Extensions

extension CTRKRadioStation {
    /// Returns a default UserProperties object for this station
    public func defaultUserProperties() -> UserProperties {
        return UserProperties(stationID: self.id)
    }
}

#if os(iOS) || os(tvOS)
import UIKit
#endif
