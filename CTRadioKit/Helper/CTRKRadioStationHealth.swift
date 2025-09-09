//
//  CTRKRadioStationHealth.swift
//  PladioManager
//
//  Created by Patrick @ DIEZIs on 07.09.2025.
//

public struct CTRKRadioStationHealth: Codable, Hashable {
    public var streamHTTP: CTRKRadioStationHealthStatus
    public var streamHTTPS: CTRKRadioStationHealthStatus
    public var faviconHTTP: CTRKRadioStationHealthStatus
    public var faviconHTTPS: CTRKRadioStationHealthStatus

    public init(streamHTTP: CTRKRadioStationHealthStatus = .unknown,
         streamHTTPS: CTRKRadioStationHealthStatus = .unknown,
         faviconHTTP: CTRKRadioStationHealthStatus = .unknown,
         faviconHTTPS: CTRKRadioStationHealthStatus = .unknown) {
        self.streamHTTP = streamHTTP
        self.streamHTTPS = streamHTTPS
        self.faviconHTTP = faviconHTTP
        self.faviconHTTPS = faviconHTTPS
    }
}
