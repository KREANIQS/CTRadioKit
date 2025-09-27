//
//  CTRKRadioStationStreamHealthStatus.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 09.09.2025.
//


public enum CTRKRadioStationStreamHealthStatus: String, Codable, CaseIterable, Identifiable {
    case unknown, valid, invalid
    public var id: String { rawValue }
}
