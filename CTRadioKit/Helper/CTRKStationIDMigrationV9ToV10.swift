//
//  CTRKStationIDMigrationV9ToV10.swift
//  CTRadioKit
//
//  Created by Claude Code on 02.12.2025.
//

import Foundation
import CryptoKit

/// Handles one-time migration of radio station IDs from V9 to V10 format.
///
/// The ID generation algorithm changed in V10 to include codec and bitrate:
/// - **V9**: `UUIDv5(canonicalURL + "|country:" + country)` - URL + Country only
/// - **V10**: `UUIDv5(canonicalURL + "|country:" + country + "|codec:" + codec + "|bitrate:" + bitrate)`
///
/// IMPORTANT: Both V9 and V10 use the same URL canonicalization (URLComponents with HTTPS normalization).
/// The only difference is that V10 appends codec and bitrate to the canonical key.
///
/// This helper computes the old V9 IDs to create a mapping for migrating user favorites and recents.
public struct CTRKStationIDMigrationV9ToV10 {

    // MARK: - Namespace

    /// Same namespace as CTRKRadioStation uses for ID generation
    private static let idNamespace = UUID(uuidString: "9C5B1E63-6C9E-4C5B-A2B6-0E8B8D6D2EAF")!

    // MARK: - Public API

    /// Computes the old V9 station ID from stream URL and country.
    ///
    /// V9 IDs were computed using the same canonicalization as V10, but without codec and bitrate.
    /// This uses URLComponents normalization (NOT simple string manipulation).
    ///
    /// - Parameters:
    ///   - streamURL: The radio station's stream URL
    ///   - country: The station's country code (ISO 3166-1 alpha-2)
    /// - Returns: The V9 station ID as a lowercase UUID string
    public static func computeV9StationID(streamURL: String, country: String?) -> String {
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            return UUID().uuidString.lowercased()
        }

        // Use same canonicalization as V9 CTRKRadioStation (WITHOUT codec/bitrate)
        let key = canonicalStreamKeyV9(from: streamURL, country: country)
        let uuid = uuidV5(namespace: idNamespace, name: Data(key.utf8))
        return uuid.uuidString.lowercased()
    }

    /// Creates a mapping from old V9 IDs to new V10 IDs for all stations.
    /// - Parameter stations: Array of stations with V10 IDs
    /// - Returns: Dictionary mapping V9 ID → V10 ID
    public static func createV9toV10Mapping(stations: [CTRKRadioStation]) -> [String: String] {
        var mapping: [String: String] = [:]

        for station in stations {
            guard !station.streamURL.isEmpty else { continue }

            let v9ID = computeV9StationID(streamURL: station.streamURL, country: station.country)

            // First station wins (bei Duplikaten mit unterschiedlichem Codec/Bitrate)
            if mapping[v9ID] == nil {
                mapping[v9ID] = station.id
            }
        }

        return mapping
    }

    // MARK: - Private Helpers

    /// Canonicalizes a URL using the same algorithm as V9 CTRKRadioStation.
    /// This is identical to V10's canonicalization, just without codec and bitrate appended.
    ///
    /// - PROTOCOL-INDEPENDENT: HTTP/HTTPS normalized to HTTPS
    /// - Host lowercased
    /// - Default ports (80, 443) removed
    /// - Query/Fragment removed
    /// - Path lowercased, trailing slash removed
    /// - Country appended as "|country:XX"
    private static func canonicalStreamKeyV9(from urlString: String, country: String?) -> String {
        guard var comp = URLComponents(string: urlString) else { return urlString }

        // PROTOCOL-INDEPENDENT: Always use HTTPS for ID generation
        // This makes the ID stable when switching between HTTP and HTTPS
        if comp.scheme == "http" || comp.scheme == "https" {
            comp.scheme = "https"
        } else {
            comp.scheme = comp.scheme?.lowercased()
        }

        comp.host = comp.host?.lowercased()

        // Remove default HTTPS port (we normalized to HTTPS above)
        if comp.port == 443 { comp.port = nil }
        // Also remove port 80 in case someone uses https://example.com:80
        if comp.port == 80 { comp.port = nil }

        // We intentionally ignore query/fragment to avoid unstable IDs across CDNs
        comp.query = nil
        comp.fragment = nil

        // Normalize path: lowercase and remove trailing slash
        var path = comp.path.lowercased()
        if path.hasSuffix("/") { path.removeLast() }
        comp.path = path.isEmpty ? "/" : path

        var result = comp.string ?? urlString

        // Append country code if provided (for disambiguating identical streams)
        if let country = country, !country.isEmpty {
            result += "|country:\(country.uppercased())"
        }

        // V9 stops here - no codec or bitrate appended
        return result
    }

    /// Minimal UUIDv5 (SHA-1, name-based) implementation per RFC 4122.
    /// Same implementation as CTRKRadioStation.uuidV5()
    private static func uuidV5(namespace: UUID, name: Data) -> UUID {
        var ns = namespace.uuid
        var bytes = withUnsafeBytes(of: &ns) { Data($0) }
        bytes.append(name)
        let hash = Insecure.SHA1.hash(data: bytes)
        var result = Data(hash.prefix(16))
        // Set RFC 4122 variant
        result[8] = (result[8] & 0x3F) | 0x80
        // Set version to 5
        result[6] = (result[6] & 0x0F) | 0x50
        let uuid = result.withUnsafeBytes { ptr -> uuid_t in
            let b = ptr.bindMemory(to: UInt8.self)
            return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                    b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        }
        return UUID(uuid: uuid)
    }
}
