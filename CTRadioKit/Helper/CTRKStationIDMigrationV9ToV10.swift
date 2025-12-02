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
/// The ID generation algorithm changed in V10 to include country, codec and bitrate:
/// - **V9**: `UUIDv5(canonicalURL)` - URL only (no country, codec, or bitrate!)
/// - **V10**: `UUIDv5(canonicalURL + "|country:" + country + "|codec:" + codec + "|bitrate:" + bitrate)`
///
/// IMPORTANT: V9 init() did NOT include country in the persistent ID generation!
/// The country parameter was only used in the `id` computed property fallback for V1/V2 databases,
/// but V3+ databases stored persistentID which was generated WITHOUT country.
///
/// This helper computes the old V9 IDs to create a mapping for migrating user favorites and recents.
public struct CTRKStationIDMigrationV9ToV10 {

    // MARK: - Namespace

    /// Same namespace as CTRKRadioStation uses for ID generation
    private static let idNamespace = UUID(uuidString: "9C5B1E63-6C9E-4C5B-A2B6-0E8B8D6D2EAF")!

    // MARK: - Public API

    /// Computes the old V9 station ID from stream URL.
    ///
    /// V9 IDs were computed from URL only - no country, codec, or bitrate!
    /// This uses URLComponents normalization (NOT simple string manipulation).
    ///
    /// - Parameter streamURL: The radio station's stream URL
    /// - Returns: The V9 station ID as a lowercase UUID string
    public static func computeV9StationID(streamURL: String) -> String {
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            return UUID().uuidString.lowercased()
        }

        // Use same canonicalization as V9 CTRKRadioStation init() - URL only!
        let key = canonicalStreamKeyV9(from: streamURL)
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

            let v9ID = computeV9StationID(streamURL: station.streamURL)

            // First station wins (bei Duplikaten mit unterschiedlichem Codec/Bitrate)
            if mapping[v9ID] == nil {
                mapping[v9ID] = station.id
            }
        }

        return mapping
    }

    // MARK: - Private Helpers

    /// Canonicalizes a URL using the same algorithm as V9 CTRKRadioStation init().
    ///
    /// IMPORTANT: V9 init() did NOT append country! Only the computed `id` property
    /// used country as fallback for V1/V2 databases. V3+ stored persistentID without country.
    ///
    /// - PROTOCOL-INDEPENDENT: HTTP/HTTPS normalized to HTTPS
    /// - Host lowercased
    /// - Default ports (80, 443) removed
    /// - Query/Fragment removed
    /// - Path lowercased, trailing slash removed
    /// - NO country, codec, or bitrate appended
    private static func canonicalStreamKeyV9(from urlString: String) -> String {
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

        // V9 init() returned here - NO country, codec, or bitrate!
        return comp.string ?? urlString
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
