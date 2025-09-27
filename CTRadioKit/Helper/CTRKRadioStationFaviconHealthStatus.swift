//
//  CTRKRadioStationFaviconHealthStatus.swift
//  CTRadioKit
//
//  Created by Patrick Diezi on 27.09.2025.
//

public enum CTRKRadioStationFaviconHealthStatus: String, Codable, CaseIterable, Identifiable {
    case unknown, failed, low, medium, big
    public var id: String { rawValue }
}
