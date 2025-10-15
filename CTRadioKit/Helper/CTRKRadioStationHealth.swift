//
//  CTRKRadioStationHealth.swift
//  PladioManager
//
//  Created by Patrick @ DIEZIs on 07.09.2025.
//

import Foundation

public struct CTRKRadioStationHealth: Codable, Hashable, Sendable {
    public var streamHTTP: CTRKRadioStationStreamHealthStatus
    public var streamHTTPS: CTRKRadioStationStreamHealthStatus
    public var faviconHTTP: CTRKRadioStationFaviconHealthStatus
    public var faviconHTTPS: CTRKRadioStationFaviconHealthStatus
    public var homepageHTTP: CTRKRadioStationStreamHealthStatus
    public var homepageHTTPS: CTRKRadioStationStreamHealthStatus
    public var lastCheck: Date?

    public init(streamHTTP: CTRKRadioStationStreamHealthStatus = .unknown,
         streamHTTPS: CTRKRadioStationStreamHealthStatus = .unknown,
         faviconHTTP: CTRKRadioStationFaviconHealthStatus = .unknown,
         faviconHTTPS: CTRKRadioStationFaviconHealthStatus = .unknown,
         homepageHTTP: CTRKRadioStationStreamHealthStatus = .unknown,
         homepageHTTPS: CTRKRadioStationStreamHealthStatus = .unknown,
         lastCheck: Date? = nil) {
        self.streamHTTP = streamHTTP
        self.streamHTTPS = streamHTTPS
        self.faviconHTTP = faviconHTTP
        self.faviconHTTPS = faviconHTTPS
        self.homepageHTTP = homepageHTTP
        self.homepageHTTPS = homepageHTTPS
        self.lastCheck = lastCheck
    }

    // Custom decoder to handle missing fields in older database versions
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.streamHTTP = try container.decode(CTRKRadioStationStreamHealthStatus.self, forKey: .streamHTTP)
        self.streamHTTPS = try container.decode(CTRKRadioStationStreamHealthStatus.self, forKey: .streamHTTPS)
        self.faviconHTTP = try container.decode(CTRKRadioStationFaviconHealthStatus.self, forKey: .faviconHTTP)
        self.faviconHTTPS = try container.decode(CTRKRadioStationFaviconHealthStatus.self, forKey: .faviconHTTPS)

        // V4 fields: Use .unknown if not present (for backward compatibility)
        self.homepageHTTP = (try? container.decode(CTRKRadioStationStreamHealthStatus.self, forKey: .homepageHTTP)) ?? .unknown
        self.homepageHTTPS = (try? container.decode(CTRKRadioStationStreamHealthStatus.self, forKey: .homepageHTTPS)) ?? .unknown

        self.lastCheck = try? container.decodeIfPresent(Date.self, forKey: .lastCheck)
    }

    private enum CodingKeys: String, CodingKey {
        case streamHTTP, streamHTTPS, faviconHTTP, faviconHTTPS
        case homepageHTTP, homepageHTTPS
        case lastCheck
    }
}
