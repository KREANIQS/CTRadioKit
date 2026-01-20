//
//  CTRKEnrichmentStatus.swift
//  CTRadioKit
//
//  Created by Claude Code on 2025-10-25.
//

import Foundation

// MARK: - EnrichmentState

/// State of an enrichment operation (Health Check, Location, Genre)
public enum EnrichmentState: String, Codable, Sendable {
    /// Not yet started or attempted (never been part of any enrichment job)
    case notStarted = "not_started"

    /// Planned for enrichment (queued but not yet started)
    case planned = "planned"

    /// Currently in progress (should only be temporary during processing)
    case inProgress = "in_progress"

    /// Successfully completed
    case completed = "completed"

    /// Failed (for retry later)
    case failed = "failed"

    /// Manually skipped by user
    case skipped = "skipped"
}

// MARK: - CTRKEnrichmentStatus

/// Tracks the enrichment status for a radio station
/// Used to resume enrichment operations and track progress
public struct CTRKEnrichmentStatus: Codable, Sendable, Equatable {
    /// Health check status
    public var healthCheck: EnrichmentState

    /// Location enrichment status
    public var location: EnrichmentState

    /// Genre enrichment status
    public var genre: EnrichmentState

    /// Favicon download status
    public var favicon: EnrichmentState

    /// Copyright check status
    public var copyrightCheck: EnrichmentState

    /// Homepage enrichment status
    public var homepage: EnrichmentState

    /// Metadata enrichment status (V10+)
    public var metadata: EnrichmentState

    /// Coding keys for JSON encoding/decoding
    private enum CodingKeys: String, CodingKey {
        case healthCheck
        case location
        case genre
        case favicon
        case copyrightCheck
        case homepage
        case metadata
    }

    /// Initialize with default values (all not started)
    public init(
        healthCheck: EnrichmentState = .notStarted,
        location: EnrichmentState = .notStarted,
        genre: EnrichmentState = .notStarted,
        favicon: EnrichmentState = .notStarted,
        copyrightCheck: EnrichmentState = .notStarted,
        homepage: EnrichmentState = .notStarted,
        metadata: EnrichmentState = .notStarted
    ) {
        self.healthCheck = healthCheck
        self.location = location
        self.genre = genre
        self.favicon = favicon
        self.copyrightCheck = copyrightCheck
        self.homepage = homepage
        self.metadata = metadata
    }

    /// Custom decoder to handle missing fields in older databases
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.healthCheck = try container.decodeIfPresent(EnrichmentState.self, forKey: .healthCheck) ?? .notStarted
        self.location = try container.decodeIfPresent(EnrichmentState.self, forKey: .location) ?? .notStarted
        self.genre = try container.decodeIfPresent(EnrichmentState.self, forKey: .genre) ?? .notStarted
        // favicon is new in V9 - default to .notStarted if missing
        self.favicon = try container.decodeIfPresent(EnrichmentState.self, forKey: .favicon) ?? .notStarted
        // copyrightCheck is new - default to .notStarted if missing
        self.copyrightCheck = try container.decodeIfPresent(EnrichmentState.self, forKey: .copyrightCheck) ?? .notStarted
        // homepage is new - default to .notStarted if missing
        self.homepage = try container.decodeIfPresent(EnrichmentState.self, forKey: .homepage) ?? .notStarted
        // metadata is new in V10 - default to .notStarted if missing
        self.metadata = try container.decodeIfPresent(EnrichmentState.self, forKey: .metadata) ?? .notStarted
    }
}
