//
//  CTRKRadioStationDatabase+Testing.swift
//  CTRadioKit
//
//  Created by Claude Code on 11.10.2025.
//

import Foundation

extension CTRKRadioStationDatabase {
    /// Test helper to verify database versioning works correctly
    /// Call this from the app to verify the implementation
    public static func testVersioning() {
        print("🧪 Testing Database Versioning")
        print(String(repeating: "=", count: 60))

        // Test 1: Create new database with current version
        let testStations = [
            CTRKRadioStation(
                name: "Test Station 1",
                streamURL: "http://example.com/stream1",
                homepageURL: "http://example.com",
                faviconURL: "http://example.com/favicon.ico",
                tags: ["TEST"],
                codec: "MP3",
                bitrate: 128,
                country: "US",
                labels: []
            ),
            CTRKRadioStation(
                name: "Test Station 2",
                streamURL: "https://example.com/stream2",
                homepageURL: "https://example.com",
                faviconURL: "https://example.com/favicon.ico",
                tags: ["TEST"],
                codec: "AAC",
                bitrate: 256,
                country: "UK",
                labels: []
            )
        ]

        // Test 1: Create and encode new database
        print("\n✅ Test 1: Create new database with version \(currentVersion)")
        let newDatabase = CTRKRadioStationDatabase(stations: testStations)
        print("   Created database with \(newDatabase.stations.count) stations")
        print("   Version: \(newDatabase.version)")
        print("   Needs migration: \(newDatabase.needsMigration())")

        // Test 2: Encode and decode
        print("\n✅ Test 2: Encode and decode database")
        do {
            let data = try CTRKRadioStationDatabaseLoader.save(newDatabase)
            let decoded = try CTRKRadioStationDatabaseLoader.load(from: data)
            print("   Encoded size: \(data.count) bytes")
            print("   Decoded version: \(decoded.version)")
            print("   Decoded stations: \(decoded.stations.count)")
            print("   Version matches: \(decoded.version == newDatabase.version)")
        } catch {
            print("   ❌ ERROR: \(error)")
        }

        // Test 3: Test old format (Version 1)
        print("\n✅ Test 3: Load old format (array of stations)")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let oldFormatData = try encoder.encode(testStations) // Just array, no version
            let loaded = try CTRKRadioStationDatabaseLoader.load(from: oldFormatData)
            print("   Loaded from old format")
            print("   Detected version: \(loaded.version)")
            print("   Stations count: \(loaded.stations.count)")
            print("   Needs migration: \(loaded.needsMigration())")
        } catch {
            print("   ❌ ERROR: \(error)")
        }

        // Test 4: Protocol-independent IDs
        print("\n✅ Test 4: Protocol-independent IDs in database")
        let httpStation = testStations[0] // http://example.com/stream1
        let httpsEquivalentURL = "https://example.com/stream1"
        let httpsID = CTRKRadioStation.generateID(for: httpsEquivalentURL)
        print("   HTTP station ID:  \(httpStation.id)")
        print("   HTTPS ID for same stream: \(httpsID)")
        print("   IDs match: \(httpStation.id == httpsID)")

        print("\n" + String(repeating: "=", count: 60))
        print("✅ All database versioning tests completed!")
    }

    /// Returns a sample database for testing
    public static func sampleDatabase() -> CTRKRadioStationDatabase {
        let stations = [
            CTRKRadioStation(
                name: "Sample Station 1",
                streamURL: "http://stream.example.com/radio1",
                homepageURL: "http://example.com",
                faviconURL: "http://example.com/favicon1.ico",
                tags: ["POP", "MUSIC"],
                codec: "MP3",
                bitrate: 128,
                country: "US",
                labels: ["Featured"]
            ),
            CTRKRadioStation(
                name: "Sample Station 2",
                streamURL: "https://stream.example.com/radio2",
                homepageURL: "https://example.com",
                faviconURL: "https://example.com/favicon2.ico",
                tags: ["ROCK", "MUSIC"],
                codec: "AAC",
                bitrate: 256,
                country: "UK",
                labels: ["Popular"]
            )
        ]

        return CTRKRadioStationDatabase(
            stations: stations,
            metadata: DatabaseMetadata(
                createdAt: Date(),
                lastModified: Date(),
                description: "Sample database for testing",
                customFields: ["testMode": "true"]
            )
        )
    }
}
