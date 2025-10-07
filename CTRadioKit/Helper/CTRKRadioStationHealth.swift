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
    public var lastCheck: Date?

    public init(streamHTTP: CTRKRadioStationStreamHealthStatus = .unknown,
         streamHTTPS: CTRKRadioStationStreamHealthStatus = .unknown,
         faviconHTTP: CTRKRadioStationFaviconHealthStatus = .unknown,
         faviconHTTPS: CTRKRadioStationFaviconHealthStatus = .unknown,
         lastCheck: Date? = nil) {
        self.streamHTTP = streamHTTP
        self.streamHTTPS = streamHTTPS
        self.faviconHTTP = faviconHTTP
        self.faviconHTTPS = faviconHTTPS
        self.lastCheck = lastCheck
    }
}
