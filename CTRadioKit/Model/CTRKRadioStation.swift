//
//  CTRKRadioStation.swift
//  Pladio
//
//  Created by Patrick @ DIEZIs on 27.06.2025.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Foundation
import CryptoKit
import CTSwiftLogger

// MARK: - Location Source

public enum LocationSource: String, Codable, Sendable {
    case claudeAPI = "Claude AI"
    case homepage = "Homepage"
    case geocoding = "Geocoding"
    case manual = "Manual"
}

// MARK: - Radio Station Model

public struct CTRKRadioStation: Codable, Identifiable, Equatable, Sendable {
    // Namespace for UUIDv5 generation. Generate once and keep constant for the app.
    private static let idNamespace = UUID(uuidString: "9C5B1E63-6C9E-4C5B-A2B6-0E8B8D6D2EAF")!

    // Internal storage for unique ID (for new stations without streamURL)
    private var _uniqueID: String?

    // V3: Persistent ID storage - set once at creation, stays stable even if streamURL changes
    public var persistentID: String?

    /// Canonicalize the stream URL so that logically identical URLs yield the same ID.
    /// IMPORTANT: The ID is protocol-independent (HTTP/HTTPS normalized to HTTPS).
    /// This ensures that changing only the protocol doesn't change the station's identity.
    /// Optionally includes country code, codec, and bitrate for disambiguating streams.
    /// V10: Added codec and bitrate to distinguish different quality streams of the same station.
    private static func canonicalStreamKey(from urlString: String, country: String? = nil, codec: String? = nil, bitrate: Int? = nil) -> String {
        guard var comp = URLComponents(string: urlString) else { return urlString }

        // PROTOCOL-INDEPENDENT: Always use HTTPS for ID generation
        // This makes the ID stable when switching between HTTP and HTTPS
        // (same stream, different protocol = same station identity)
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

        // Append country code if provided (for disambiguating identical streams in different countries)
        if let country = country, !country.isEmpty {
            result += "|country:\(country.uppercased())"
        }

        // V10: Append codec if provided (for disambiguating different encodings)
        if let codec = codec, !codec.isEmpty {
            result += "|codec:\(codec.uppercased())"
        }

        // V10: Append bitrate if provided and > 0 (for disambiguating different qualities)
        if let bitrate = bitrate, bitrate > 0 {
            result += "|bitrate:\(bitrate)"
        }

        return result
    }

    /// Minimal UUIDv5 (SHA-1, name-based) implementation per RFC 4122.
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
            return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        }
        return UUID(uuid: uuid)
    }
    public static func == (lhs: CTRKRadioStation, rhs: CTRKRadioStation) -> Bool {
        return lhs.id == rhs.id
    }

    /// Generates an ID for a given stream URL without creating a full station object.
    /// Useful for testing, migration, and debugging.
    /// V10: Now includes country, codec, and bitrate for complete ID generation.
    /// - Parameters:
    ///   - streamURL: The stream URL to generate an ID for
    ///   - country: Optional country code
    ///   - codec: Optional codec (e.g., "MP3", "AAC")
    ///   - bitrate: Optional bitrate in kbps
    /// - Returns: The generated station ID (protocol-independent, quality-aware)
    public static func generateID(for streamURL: String, country: String? = nil, codec: String? = nil, bitrate: Int? = nil) -> String {
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            return UUID().uuidString.lowercased()
        }

        let key = CTRKRadioStation.canonicalStreamKey(from: streamURL, country: country, codec: codec, bitrate: bitrate)
        let uuid = CTRKRadioStation.uuidV5(namespace: CTRKRadioStation.idNamespace, name: Data(key.utf8))
        return uuid.uuidString.lowercased()
    }

    /// Regenerates the persistent ID using the V10 algorithm (includes country, codec, bitrate).
    /// Use this method to fix stations with duplicate IDs from older database versions.
    /// - Returns: A new station with the regenerated persistent ID
    public func withRegeneratedID() -> CTRKRadioStation {
        var copy = self
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedURL.isEmpty {
            // For stations without streamURL, generate new unique ID
            copy.persistentID = UUID().uuidString.lowercased()
            copy._uniqueID = copy.persistentID
        } else {
            // V10: Generate ID from streamURL + country + codec + bitrate
            let key = CTRKRadioStation.canonicalStreamKey(from: streamURL, country: country, codec: codec, bitrate: bitrate)
            let uuid = CTRKRadioStation.uuidV5(namespace: CTRKRadioStation.idNamespace, name: Data(key.utf8))
            copy.persistentID = uuid.uuidString.lowercased()
            copy._uniqueID = nil
        }

        return copy
    }

    /// Verifies that two URLs generate the same ID (useful for testing protocol-independence)
    /// - Parameters:
    ///   - url1: First URL to compare
    ///   - url2: Second URL to compare
    /// - Returns: True if both URLs generate the same station ID
    public static func haveSameID(_ url1: String, _ url2: String) -> Bool {
        return generateID(for: url1) == generateID(for: url2)
    }

    /// Test method to verify protocol-independent ID generation
    /// This can be called from the app to verify the implementation
    public static func testProtocolIndependence() {
        let testCases: [(String, String, String)] = [
            ("http://example.com/stream", "https://example.com/stream", "Protocol switch"),
            ("http://example.com:80/stream", "https://example.com/stream", "HTTP with default port"),
            ("https://example.com:443/stream", "https://example.com/stream", "HTTPS with default port"),
            ("http://EXAMPLE.COM/Stream", "https://example.com/stream", "Case insensitive"),
            ("http://example.com/stream/", "https://example.com/stream", "Trailing slash"),
        ]

        print("🧪 Testing Protocol-Independent ID Generation")
        print(String(repeating: "=", count: 60))

        var allPassed = true
        for (url1, url2, description) in testCases {
            let id1 = generateID(for: url1)
            let id2 = generateID(for: url2)
            let passed = id1 == id2

            if passed {
                print("✅ PASS: \(description)")
                print("   \(url1)")
                print("   \(url2)")
                print("   → Same ID: \(id1)")
            } else {
                print("❌ FAIL: \(description)")
                print("   \(url1) → \(id1)")
                print("   \(url2) → \(id2)")
                allPassed = false
            }
            print("")
        }

        print(String(repeating: "=", count: 60))
        if allPassed {
            print("✅ All tests passed! Protocol-independent IDs working correctly.")
        } else {
            print("❌ Some tests failed. Please review the implementation.")
        }
    }
    public var id: String {
        // V3: If we have a persistent ID, use it (stable across streamURL changes)
        if let persistentID = persistentID {
            return persistentID
        }

        // Legacy behavior: If streamURL is empty or whitespace-only, use stored unique ID or generate new one
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            // Return stored unique ID or generate a new UUID
            return _uniqueID ?? UUID().uuidString.lowercased()
        }

        // Legacy fallback: derive ID from streamURL + country + codec + bitrate (for V1/V2 databases)
        // V10: Include codec and bitrate to disambiguate different quality streams
        let key = CTRKRadioStation.canonicalStreamKey(from: streamURL, country: country, codec: codec, bitrate: bitrate)
        let uuid = CTRKRadioStation.uuidV5(namespace: CTRKRadioStation.idNamespace, name: Data(key.utf8))
        return uuid.uuidString.lowercased()
    }
    public var name: String
    public var streamURL: String
    public var homepageURL: String
    public var faviconURL: String
    public var tags: [String]
    public var codec: String
    public var bitrate: Int
    public var country: String
    public var supportsMetadata: Bool? = nil
    public var lastPlayedDate: Date?
    public var health: CTRKRadioStationHealth
    public var labels: [String]
    public var curated: Bool
    public var qualityCheck: CTRKQualityCheckStatus

    // Location information for "Nearest" and "Local Radio Stations" search
    public var locationName: String?
    public var locationLatitude: Double?
    public var locationLongitude: Double?
    public var locationSource: LocationSource?

    // Enrichment status tracking (Version 7+)
    public var enrichmentStatus: CTRKEnrichmentStatus

    // Credits for station contribution (Version 11+)
    // Used to attribute manual station submissions to contributors
    public var credits: String

    public var faviconImage: Data?
    
    enum CodingKeys: String, CodingKey {
        case _uniqueID
        case persistentID // V3: Persistent ID field
        case name
        case streamURL
        case homepageURL
        case faviconURL
        case tags
        case codec
        case bitrate
        case country
        case supportsMetadata
        case lastPlayedDate
        case faviconImage
        case health
        case labels
        case curated
        case qualityCheck
        case locationName
        case locationLatitude
        case locationLongitude
        case locationSource
        case enrichmentStatus // V7: Enrichment status tracking
        case credits // V11: Contribution credits
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._uniqueID = try container.decodeIfPresent(String.self, forKey: ._uniqueID)
        self.persistentID = try container.decodeIfPresent(String.self, forKey: .persistentID)
        self.name = try container.decode(String.self, forKey: .name)
        self.streamURL = try container.decode(String.self, forKey: .streamURL)
        self.homepageURL = try container.decodeIfPresent(String.self, forKey: .homepageURL) ?? ""
        self.faviconURL = try container.decodeIfPresent(String.self, forKey: .faviconURL) ?? ""
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? ""
        self.bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        self.country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
        self.supportsMetadata = try container.decodeIfPresent(Bool.self, forKey: .supportsMetadata)
        self.lastPlayedDate = try container.decodeIfPresent(Date.self, forKey: .lastPlayedDate)
        self.health = try container.decodeIfPresent(CTRKRadioStationHealth.self, forKey: .health) ?? CTRKRadioStationHealth()
        self.labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.curated = try container.decodeIfPresent(Bool.self, forKey: .curated) ?? false
        self.qualityCheck = try container.decodeIfPresent(CTRKQualityCheckStatus.self, forKey: .qualityCheck) ?? .open
        self.locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        self.locationLatitude = try container.decodeIfPresent(Double.self, forKey: .locationLatitude)
        self.locationLongitude = try container.decodeIfPresent(Double.self, forKey: .locationLongitude)
        self.locationSource = try container.decodeIfPresent(LocationSource.self, forKey: .locationSource)
        // V7: Enrichment status (defaults to .notStarted for backward compatibility)
        self.enrichmentStatus = try container.decodeIfPresent(CTRKEnrichmentStatus.self, forKey: .enrichmentStatus) ?? CTRKEnrichmentStatus()
        // V11: Credits (defaults to empty string for backward compatibility)
        self.credits = try container.decodeIfPresent(String.self, forKey: .credits) ?? ""
        #if os(iOS)
        self.faviconImage = nil
        #elseif os(macOS)
        self.faviconImage = nil
        #endif
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_uniqueID, forKey: ._uniqueID)
        try container.encodeIfPresent(persistentID, forKey: .persistentID)
        try container.encode(name, forKey: .name)
        try container.encode(streamURL, forKey: .streamURL)
        try container.encode(homepageURL, forKey: .homepageURL)
        try container.encode(faviconURL, forKey: .faviconURL)
        try container.encode(tags, forKey: .tags)
        try container.encode(codec, forKey: .codec)
        try container.encode(bitrate, forKey: .bitrate)
        try container.encode(country, forKey: .country)
        try container.encodeIfPresent(supportsMetadata, forKey: .supportsMetadata)
        try container.encodeIfPresent(lastPlayedDate, forKey: .lastPlayedDate)
        try container.encodeIfPresent(faviconImage, forKey: .faviconImage)
        try container.encode(health, forKey: .health)
        try container.encode(labels, forKey: .labels)
        try container.encode(curated, forKey: .curated)
        try container.encode(qualityCheck, forKey: .qualityCheck)
        try container.encodeIfPresent(locationName, forKey: .locationName)
        try container.encodeIfPresent(locationLatitude, forKey: .locationLatitude)
        try container.encodeIfPresent(locationLongitude, forKey: .locationLongitude)
        try container.encodeIfPresent(locationSource, forKey: .locationSource)
        try container.encode(enrichmentStatus, forKey: .enrichmentStatus)
        try container.encode(credits, forKey: .credits)
    }
    
    public init(
        name: String,
        streamURL: String,
        homepageURL: String,
        faviconURL: String,
        tags: [String],
        codec: String,
        bitrate: Int,
        country: String,
        supportsMetadata: Bool? = nil,
        lastPlayedDate: Date? = nil,
        faviconImage: /* UIImage? | NSImage? */ Any? = nil, // oder per #if auflösen
        health: CTRKRadioStationHealth = .init(),
        labels: [String],
        curated: Bool = false,
        qualityCheck: CTRKQualityCheckStatus = .open,
        locationName: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        locationSource: LocationSource? = nil,
        enrichmentStatus: CTRKEnrichmentStatus = .init(),
        credits: String = ""
    ) {
        // V3/V10: Generate persistent ID at creation time
        // V10: Now includes country, codec, and bitrate for unique identification
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedURL.isEmpty {
            // For stations without streamURL, generate unique ID
            self._uniqueID = UUID().uuidString.lowercased()
            self.persistentID = self._uniqueID
        } else {
            // V10: Generate ID from streamURL + country + codec + bitrate
            // This ensures different quality streams of the same station get unique IDs
            let key = CTRKRadioStation.canonicalStreamKey(from: streamURL, country: country, codec: codec, bitrate: bitrate)
            let uuid = CTRKRadioStation.uuidV5(namespace: CTRKRadioStation.idNamespace, name: Data(key.utf8))
            self.persistentID = uuid.uuidString.lowercased()
            self._uniqueID = nil
        }

        self.name = name
        self.streamURL = streamURL
        self.homepageURL = homepageURL
        self.faviconURL = faviconURL
        self.tags = tags
        self.labels = labels
        self.codec = codec
        self.bitrate = bitrate
        self.country = country
        self.supportsMetadata = supportsMetadata
        self.lastPlayedDate = lastPlayedDate
        self.health = health
        self.curated = curated
        self.qualityCheck = qualityCheck
        self.locationName = locationName
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.locationSource = locationSource
        self.enrichmentStatus = enrichmentStatus
        self.credits = credits
        #if os(iOS)
        if let image = faviconImage as? UIImage {
            self.faviconImage = image.pngData()
        } else {
            self.faviconImage = nil
        }
        #elseif os(macOS)
        if let image = faviconImage as? NSImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            self.faviconImage = png
        } else {
            self.faviconImage = nil
        }
        #endif
    }
    
    #if os(iOS)
    func squareFavicon(canvas: CGFloat) -> UIImage? {
        guard let imageData = faviconImage,
              let image = UIImage(data: imageData) else { return nil }
        return CTRKRadioStation.squareFit(image: image, canvas: canvas)
    }

    func downscaledFavicon(maxDimension: CGFloat) -> UIImage? {
        guard let imageData = faviconImage,
              let image = UIImage(data: imageData) else { return nil }
        return CTRKRadioStation.downscale(image: image, maxDimension: maxDimension)
    }

    private static func squareFit(image: UIImage, canvas: CGFloat) -> UIImage {
        let size = CGSize(width: canvas, height: canvas)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let origin = CGPoint(
            x: (canvas - image.size.width) / 2,
            y: (canvas - image.size.height) / 2
        )
        image.draw(in: CGRect(origin: origin, size: image.size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return newImage
    }

    private static func downscale(image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let aspectRatio = image.size.width / image.size.height
        var targetSize = CGSize(width: maxDimension, height: maxDimension)

        if aspectRatio > 1 {
            targetSize.height = maxDimension / aspectRatio
        } else {
            targetSize.width = maxDimension * aspectRatio
        }

        UIGraphicsBeginImageContextWithOptions(targetSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
    #endif
    
    private struct ManualWrapper: Codable {
        var isManual: Bool
    }

    public var isManual: Bool {
        get {
            guard let base64 = self.tags.first,
                  let data = Data(base64Encoded: base64),
                  let wrapper = try? JSONDecoder().decode(ManualWrapper.self, from: data)
            else { return false }
            return wrapper.isManual
        }
        set {
            let wrapper = ManualWrapper(isManual: newValue)
            if let data = try? JSONEncoder().encode(wrapper) {
                let base64 = data.base64EncodedString()

                // Preserve existing user tags (everything after the first marker, if present)
                var preservedTags: [String] = []
                if let firstTag = self.tags.first,
                   let testData = Data(base64Encoded: firstTag),
                   (try? JSONDecoder().decode(ManualWrapper.self, from: testData)) != nil {
                    // First element is already a marker, preserve the rest
                    preservedTags = Array(self.tags.dropFirst())
                } else {
                    // No marker yet, preserve all existing tags
                    preservedTags = self.tags
                }

                // Build new tags array: marker + preserved user tags
                var newTags = [base64]
                newTags.append(contentsOf: preservedTags)

                self = CTRKRadioStation(
                    name: self.name,
                    streamURL: self.streamURL,
                    homepageURL: self.homepageURL,
                    faviconURL: self.faviconURL,
                    tags: newTags,
                    codec: self.codec,
                    bitrate: self.bitrate,
                    country: self.country,
                    supportsMetadata: self.supportsMetadata,
                    lastPlayedDate: self.lastPlayedDate,
                    faviconImage: self.faviconImage,
                    health: self.health,
                    labels: self.labels,
                    curated: self.curated,
                    qualityCheck: self.qualityCheck,
                    locationName: self.locationName,
                    locationLatitude: self.locationLatitude,
                    locationLongitude: self.locationLongitude,
                    locationSource: self.locationSource,
                    enrichmentStatus: self.enrichmentStatus,
                    credits: self.credits
                )
            }
        }
    }

    /// Returns the user-visible tags (excluding the internal isManual marker)
    public var userTags: [String] {
        if let firstTag = self.tags.first,
           let testData = Data(base64Encoded: firstTag),
           (try? JSONDecoder().decode(ManualWrapper.self, from: testData)) != nil {
            // First element is a marker, return the rest
            return Array(self.tags.dropFirst())
        }
        // No marker, return all tags
        return self.tags
    }
}
