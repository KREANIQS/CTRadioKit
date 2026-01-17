//
//  CTRKManualStationMetadata.swift
//  CTRadioKit
//
//  Created by Claude Code on 17.01.2026.
//

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Metadata for user-created manual radio stations.
/// Tracks creation, modification, validation state, and submission status.
public struct CTRKManualStationMetadata: Codable, Sendable, Equatable {
    // MARK: - Creation & Modification Tracking

    /// Date when the station was created
    public let createdDate: Date

    /// Date when the station was last modified
    public var modifiedDate: Date

    /// Device identifier where the station was created
    public let createdByDeviceID: String

    /// Device identifier where the station was last modified
    public var modifiedByDeviceID: String

    // MARK: - Validation Status

    /// Whether the stream URL has been validated as working
    public var isValidated: Bool

    /// Date of the last validation attempt
    public var lastValidationDate: Date?

    /// Error message from the last failed validation (nil if validation succeeded)
    public var validationError: String?

    // MARK: - Submission Status

    /// Whether this station has been submitted for inclusion in the official database
    public var submittedForReview: Bool

    /// Date when the station was submitted for review
    public var submissionDate: Date?

    // MARK: - Initialization

    /// Creates new metadata for a manual station
    /// - Parameters:
    ///   - createdDate: Creation date (defaults to now)
    ///   - deviceID: Device identifier for tracking
    public init(
        createdDate: Date = Date(),
        deviceID: String = CTRKManualStationMetadata.currentDeviceID
    ) {
        self.createdDate = createdDate
        self.modifiedDate = createdDate
        self.createdByDeviceID = deviceID
        self.modifiedByDeviceID = deviceID
        self.isValidated = false
        self.lastValidationDate = nil
        self.validationError = nil
        self.submittedForReview = false
        self.submissionDate = nil
    }

    // MARK: - Mutation Helpers

    /// Returns a copy with updated modification timestamp
    public func withUpdatedModification(deviceID: String = CTRKManualStationMetadata.currentDeviceID) -> CTRKManualStationMetadata {
        var copy = self
        copy.modifiedDate = Date()
        copy.modifiedByDeviceID = deviceID
        return copy
    }

    /// Returns a copy with validation result
    public func withValidation(success: Bool, error: String? = nil) -> CTRKManualStationMetadata {
        var copy = self
        copy.isValidated = success
        copy.lastValidationDate = Date()
        copy.validationError = success ? nil : error
        copy.modifiedDate = Date()
        return copy
    }

    /// Returns a copy marked as submitted for review
    public func withSubmission() -> CTRKManualStationMetadata {
        var copy = self
        copy.submittedForReview = true
        copy.submissionDate = Date()
        copy.modifiedDate = Date()
        return copy
    }

    // MARK: - Device Identification

    /// Current device identifier for tracking creation/modification
    public static var currentDeviceID: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #elseif os(macOS)
        // Use a persistent identifier stored in UserDefaults
        let key = "ctrk.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
        #else
        return UUID().uuidString
        #endif
    }
}
