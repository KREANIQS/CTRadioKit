//
//  CTRKRadioStationDatabasePackager.swift
//  CTRadioKit
//
//  Created by Patrick @ DIEZIs on 19.10.2025.
//

import Foundation
import ZIPFoundation
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Handles packaging and unpackaging of radio station databases with favicon caches
/// Format: .radiopack (ZIP archive containing database.json + favicons/)
@MainActor
public final class CTRKRadioStationDatabasePackager {

    // MARK: - Public Types

    public struct PackageInfo {
        public let databaseURL: URL
        public let faviconCacheURL: URL
        public let version: String
        public let stationCount: Int
        public let createdDate: Date

        public init(databaseURL: URL, faviconCacheURL: URL, version: String, stationCount: Int, createdDate: Date = Date()) {
            self.databaseURL = databaseURL
            self.faviconCacheURL = faviconCacheURL
            self.version = version
            self.stationCount = stationCount
            self.createdDate = createdDate
        }
    }

    public enum PackagerError: LocalizedError {
        case packageNotFound(String)
        case invalidPackageStructure(String)
        case unzipFailed(Error)
        case zipFailed(Error)
        case databaseNotFound(URL)
        case faviconCacheNotFound(URL)

        public var errorDescription: String? {
            switch self {
            case .packageNotFound(let name):
                return "Radio package '\(name)' not found in bundle"
            case .invalidPackageStructure(let detail):
                return "Invalid package structure: \(detail)"
            case .unzipFailed(let error):
                return "Failed to unzip package: \(error.localizedDescription)"
            case .zipFailed(let error):
                return "Failed to create zip package: \(error.localizedDescription)"
            case .databaseNotFound(let url):
                return "Database file not found at \(url.path)"
            case .faviconCacheNotFound(let url):
                return "Favicon cache directory not found at \(url.path)"
            }
        }
    }

    // MARK: - Public Methods - Unzipping (for Pladio App)

    /// Loads a bundled .radiopack file and extracts it to Application Support
    /// - Parameters:
    ///   - packageName: Name of the .radiopack file (without extension)
    ///   - forceReExtract: If true, deletes existing extracted data and re-extracts
    ///   - progressHandler: Optional closure called with progress updates (0.0 to 1.0)
    /// - Returns: PackageInfo with paths to extracted database and favicon cache
    public static func loadBundledPackage(
        named packageName: String,
        forceReExtract: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> PackageInfo {

        progressHandler?(0.0, "Locating package '\(packageName)'...")

        // 1. Find package in bundle
        guard let packageURL = Bundle.main.url(forResource: packageName, withExtension: "radiopack") else {
            throw PackagerError.packageNotFound(packageName)
        }

        // 2. Determine destination directory
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destinationURL = appSupportURL
            .appendingPathComponent("RadioDatabase")
            .appendingPathComponent(packageName)

        // 3. Check if already extracted
        let databaseURL = destinationURL.appendingPathComponent("database.json")
        let faviconCacheURL = destinationURL.appendingPathComponent("favicons")

        if !forceReExtract && fileManager.fileExists(atPath: databaseURL.path) {
            progressHandler?(1.0, "Package already extracted")

            // Load metadata
            let metadata = try loadMetadata(from: destinationURL)
            return PackageInfo(
                databaseURL: databaseURL,
                faviconCacheURL: faviconCacheURL,
                version: metadata.version,
                stationCount: metadata.stationCount,
                createdDate: metadata.createdDate
            )
        }

        progressHandler?(0.1, "Preparing extraction...")

        // 4. Clean destination if forcing re-extract
        if forceReExtract && fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        // 5. Create destination directory
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        progressHandler?(0.2, "Extracting package...")

        // 6. Unzip package
        do {
            // ZIPFoundation doesn't support progress callback, so we just unzip
            try fileManager.unzipItem(at: packageURL, to: destinationURL)
            progressHandler?(0.8, "Extraction complete")
        } catch {
            throw PackagerError.unzipFailed(error)
        }

        progressHandler?(0.9, "Verifying package structure...")

        // 7. Verify package structure
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw PackagerError.invalidPackageStructure("database.json not found")
        }

        guard fileManager.fileExists(atPath: faviconCacheURL.path) else {
            throw PackagerError.invalidPackageStructure("favicons/ directory not found")
        }

        progressHandler?(1.0, "Package loaded successfully")

        // 8. Load metadata
        let metadata = try loadMetadata(from: destinationURL)

        return PackageInfo(
            databaseURL: databaseURL,
            faviconCacheURL: faviconCacheURL,
            version: metadata.version,
            stationCount: metadata.stationCount,
            createdDate: metadata.createdDate
        )
    }

    // MARK: - Public Methods - Zipping (for PladioManager)

    /// Creates a .radiopack file from a database and favicon cache directory
    /// - Parameters:
    ///   - databaseURL: URL to the database JSON file
    ///   - faviconCacheURL: URL to the favicon cache directory
    ///   - outputURL: URL where the .radiopack file should be created
    ///   - version: Version string for the package metadata
    ///   - progressHandler: Optional closure called with progress updates (0.0 to 1.0)
    public static func createPackage(
        databaseURL: URL,
        faviconCacheURL: URL,
        outputURL: URL,
        version: String,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {

        progressHandler?(0.0, "Preparing package creation...")

        let fileManager = FileManager.default

        // 1. Verify inputs exist
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw PackagerError.databaseNotFound(databaseURL)
        }

        guard fileManager.fileExists(atPath: faviconCacheURL.path) else {
            throw PackagerError.faviconCacheNotFound(faviconCacheURL)
        }

        progressHandler?(0.1, "Creating temporary package structure...")

        // 2. Create temporary directory for package contents
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // 3. Copy database to temp dir as "database.json"
        let tempDatabaseURL = tempDir.appendingPathComponent("database.json")
        try fileManager.copyItem(at: databaseURL, to: tempDatabaseURL)

        progressHandler?(0.2, "Copying favicon cache...")

        // 4. Copy favicon cache to temp dir as "favicons/"
        let tempFaviconsURL = tempDir.appendingPathComponent("favicons")
        try fileManager.copyItem(at: faviconCacheURL, to: tempFaviconsURL)

        progressHandler?(0.4, "Creating package metadata...")

        // 5. Count stations from database
        let stationCount = try countStationsInDatabase(at: tempDatabaseURL)

        // 6. Create metadata file
        let metadata = PackageMetadata(
            version: version,
            stationCount: stationCount,
            createdDate: Date(),
            format: "radiopack-v1"
        )
        try saveMetadata(metadata, to: tempDir)

        progressHandler?(0.5, "Creating ZIP archive...")

        // 7. Remove existing output file if present
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        // 8. Zip the temp directory
        do {
            // ZIPFoundation doesn't support progress callback, so we just zip
            try fileManager.zipItem(at: tempDir, to: outputURL, shouldKeepParent: false)
            progressHandler?(0.9, "Archive created")
        } catch {
            throw PackagerError.zipFailed(error)
        }

        progressHandler?(1.0, "Package created successfully")
    }

    // MARK: - Private Helpers

    private struct PackageMetadata: Codable {
        let version: String
        let stationCount: Int
        let createdDate: Date
        let format: String
    }

    private static func saveMetadata(_ metadata: PackageMetadata, to directory: URL) throws {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)
    }

    private static func loadMetadata(from directory: URL) throws -> PackageMetadata {
        let metadataURL = directory.appendingPathComponent("metadata.json")

        // If metadata file doesn't exist, return default
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return PackageMetadata(
                version: "unknown",
                stationCount: 0,
                createdDate: Date(),
                format: "radiopack-v1"
            )
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PackageMetadata.self, from: data)
    }

    private static func countStationsInDatabase(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = json["stations"] as? [[String: Any]] else {
            return 0
        }
        return stations.count
    }
}
