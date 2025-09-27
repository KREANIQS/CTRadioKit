//
//  CTRKRadioStationHealthChecker.swift
//  CTRadioKit
//
//  Created by Claude Code on 26.09.2025.
//

import Foundation
import CoreGraphics
import ImageIO

public final class CTRKRadioStationHealthChecker: @unchecked Sendable {
    public static let shared = CTRKRadioStationHealthChecker()

    private let urlSession: URLSession
    private let timeout: TimeInterval = 10.0

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        urlSession = URLSession(configuration: config)
    }

    public func performHealthCheck(
        for stations: [CTRKRadioStation],
        onProgress: @escaping (Double, String, String) -> Void,
        onStationUpdated: @escaping (CTRKRadioStation) -> Void
    ) async {

        let totalStations = stations.count
        onProgress(0.0, "Starting health checks...", "Preparing to check \(totalStations) stations")

        for (index, station) in stations.enumerated() {
            // Check if cancelled
            if Task.isCancelled { break }

            let progress = Double(index) / Double(totalStations)
            onProgress(progress, "Checking station \(index + 1) of \(totalStations)", station.name)

            var updatedStation = station
            await checkStreamHealth(for: &updatedStation)
            await checkFaviconHealth(for: &updatedStation)

            // Call update callback for real-time UI updates, even if partially completed
            onStationUpdated(updatedStation)

            // Check for cancellation before sleep to be more responsive
            if Task.isCancelled { break }

            // Small delay to prevent overwhelming the servers
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        onProgress(1.0, "Health check completed", "Checked \(totalStations) stations")
    }

    private func checkStreamHealth(for station: inout CTRKRadioStation) async {
        let streamURL = station.streamURL

        // Always set the timestamp at the beginning to indicate we attempted a check
        station.health.lastCheck = Date()

        // Test HTTP version
        if let httpURL = convertToHTTP(streamURL) {
            station.health.streamHTTP = await testStreamURL(httpURL)
        } else {
            // If URL conversion fails, mark as invalid
            station.health.streamHTTP = .invalid
        }

        // Check if task was cancelled before testing HTTPS
        if Task.isCancelled {
            return
        }

        // Test HTTPS version
        if let httpsURL = convertToHTTPS(streamURL) {
            station.health.streamHTTPS = await testStreamURL(httpsURL)
        } else {
            // If URL conversion fails, mark as invalid
            station.health.streamHTTPS = .invalid
        }
    }

    private func testStreamURL(_ urlString: String) async -> CTRKRadioStationStreamHealthStatus {
        guard let url = URL(string: urlString) else {
            return .invalid
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.setValue("PladioManager/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            let (_, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                // Check HTTP status code
                guard (200...299).contains(httpResponse.statusCode) else {
                    return .invalid
                }

                // Verify it's actually an audio stream
                return isAudioStream(response: httpResponse) ? .valid : .invalid
            }

            return .invalid
        } catch {
            return .invalid
        }
    }

    private func isAudioStream(response: HTTPURLResponse) -> Bool {
        let headers = response.allHeaderFields

        // Check Content-Type header for audio formats
        if let contentType = headers["Content-Type"] as? String {
            let audioTypes = [
                "audio/",           // General audio prefix
                "application/ogg",  // OGG streams
                "video/mp2t",       // MPEG-TS streams (often audio-only)
                "application/octet-stream" // Generic binary (many streams use this)
            ]

            let lowerContentType = contentType.lowercased()
            if audioTypes.contains(where: { lowerContentType.contains($0) }) {
                return true
            }
        }

        // Check for streaming indicators
        if let server = headers["Server"] as? String {
            let streamingServers = ["icecast", "shoutcast", "wowza", "nginx-rtmp"]
            if streamingServers.contains(where: { server.lowercased().contains($0) }) {
                return true
            }
        }

        // Check for ICY headers (SHOUTcast/Icecast)
        if headers["icy-name"] != nil ||
           headers["ICY-Name"] != nil ||
           headers["icy-metaint"] != nil ||
           headers["ICY-MetaInt"] != nil ||
           headers["icy-br"] != nil ||
           headers["ICY-BR"] != nil {
            return true
        }

        // Check for streaming-specific headers
        if headers["Cache-Control"] as? String == "no-cache" &&
           headers["Connection"] as? String == "close" {
            return true
        }

        // If no clear indicators, assume it might be a stream
        // (Some servers don't set proper headers)
        return true
    }

    private func checkFaviconHealth(for station: inout CTRKRadioStation) async {
        let faviconURL = station.faviconURL

        // Test HTTP version
        if let httpURL = convertToHTTP(faviconURL) {
            station.health.faviconHTTP = await testFaviconURL(httpURL)
        } else {
            // If URL conversion fails, mark as failed
            station.health.faviconHTTP = .failed
        }

        // Check if task was cancelled before testing HTTPS
        if Task.isCancelled {
            return
        }

        // Test HTTPS version
        if let httpsURL = convertToHTTPS(faviconURL) {
            station.health.faviconHTTPS = await testFaviconURL(httpsURL)
        } else {
            // If URL conversion fails, mark as failed
            station.health.faviconHTTPS = .failed
        }
    }

    private func testFaviconURL(_ urlString: String) async -> CTRKRadioStationFaviconHealthStatus {
        guard let url = URL(string: urlString) else {
            return .failed
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("PladioManager/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("image/*", forHTTPHeaderField: "Accept")

            let (data, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                // Check HTTP status code
                guard (200...299).contains(httpResponse.statusCode) else {
                    return .failed
                }

                // Check if it's actually an image and get dimensions
                return await getFaviconQuality(from: data)
            }

            return .failed
        } catch {
            return .failed
        }
    }

    private func getFaviconQuality(from data: Data) async -> CTRKRadioStationFaviconHealthStatus {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = imageProperties[kCGImagePropertyPixelHeight as String] as? Int else {
            return .failed
        }

        // Use the smaller dimension to categorize the favicon quality
        let minDimension = min(width, height)

        switch minDimension {
        case 0..<200:
            return .low
        case 200..<400:
            return .medium
        case 400...:
            return .big
        default:
            return .failed
        }
    }

    private func convertToHTTP(_ url: String) -> String? {
        if url.hasPrefix("https://") {
            return url.replacingOccurrences(of: "https://", with: "http://")
        } else if url.hasPrefix("http://") {
            return url
        }
        return "http://" + url
    }

    private func convertToHTTPS(_ url: String) -> String? {
        if url.hasPrefix("http://") {
            return url.replacingOccurrences(of: "http://", with: "https://")
        } else if url.hasPrefix("https://") {
            return url
        }
        return "https://" + url
    }
}
