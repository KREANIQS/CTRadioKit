//
//  CTRKQualityCheckStatus.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 25.09.2025.
//

public enum CTRKQualityCheckStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case open = "OPEN"
    case done = "DONE"

    public var id: String { rawValue }
}