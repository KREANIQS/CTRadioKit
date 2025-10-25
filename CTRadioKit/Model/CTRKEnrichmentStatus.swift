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

    /// Initialize with default values (all not started)
    public init(
        healthCheck: EnrichmentState = .notStarted,
        location: EnrichmentState = .notStarted,
        genre: EnrichmentState = .notStarted
    ) {
        self.healthCheck = healthCheck
        self.location = location
        self.genre = genre
    }
}
