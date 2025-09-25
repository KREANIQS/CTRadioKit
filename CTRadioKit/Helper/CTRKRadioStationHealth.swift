//
//  CTRKRadioStationHealth.swift
//  PladioManager
//
//  Created by Patrick @ DIEZIs on 07.09.2025.
//

import Foundation

public struct CTRKRadioStationHealth: Codable, Hashable {
    public var streamHTTP: CTRKRadioStationHealthStatus
    public var streamHTTPS: CTRKRadioStationHealthStatus
    public var faviconHTTP: CTRKRadioStationHealthStatus
    public var faviconHTTPS: CTRKRadioStationHealthStatus
    public var lastCheck: Date?

    public init(streamHTTP: CTRKRadioStationHealthStatus = .unknown,
         streamHTTPS: CTRKRadioStationHealthStatus = .unknown,
         faviconHTTP: CTRKRadioStationHealthStatus = .unknown,
         faviconHTTPS: CTRKRadioStationHealthStatus = .unknown,
         lastCheck: Date? = nil) {
        self.streamHTTP = streamHTTP
        self.streamHTTPS = streamHTTPS
        self.faviconHTTP = faviconHTTP
        self.faviconHTTPS = faviconHTTPS
        self.lastCheck = lastCheck
    }
}
