//
//  RadioBrowserStation.swift
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
import CTSwiftLogger

struct RadioStation: Codable, Identifiable, Equatable {
    static func == (lhs: RadioStation, rhs: RadioStation) -> Bool {
        return lhs.id == rhs.id
    }
    var id: String {
        return "\(name)-\(urlResolved)"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? urlResolved
    }
    let name: String
    let urlResolved: String
    let favicon: String
    let tags: String
    let codec: String
    let bitrate: Int
    let country: String
    var supportsMetadata: Bool? = nil
    var lastPlayedDate: Date?

    #if os(iOS)
    var faviconImage: UIImage?
    #elseif os(macOS)
    var faviconImage: NSImage?
    #endif

    enum CodingKeys: String, CodingKey {
        case name
        case urlResolved = "url_resolved"
        case favicon
        case tags
        case codec
        case bitrate
        case country
        case lastPlayedDate
    }

    #if os(iOS)
    func squareFavicon(canvas: CGFloat) -> UIImage? {
        guard let image = faviconImage else { return nil }
        return RadioStation.squareFit(image: image, canvas: canvas)
    }

    func downscaledFavicon(maxDimension: CGFloat) -> UIImage? {
        guard let image = faviconImage else { return nil }
        return RadioStation.downscale(image: image, maxDimension: maxDimension)
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
}

class RadioBrowserCarPlayController {
    private var service = RadioBrowserService()

    func loadStations(forCountry country: String = "Switzerland", completion: @escaping ([RadioStation]) -> Void) {
        service.loadStations(forCountry: country)

        // Warten bis die Daten geladen sind (kurz pollend, da URLSession async ist)
        DispatchQueue.global().async {
            var attempts = 0
            while self.service.stations.isEmpty && attempts < 50 {
                Thread.sleep(forTimeInterval: 0.1)
                attempts += 1
            }

            DispatchQueue.main.async {
                completion(self.service.stations)
            }
        }
    }
}

class RadioBrowserService: ObservableObject {
    @Published var stations: [RadioStation] = []
    
    func loadStations(forCountry country: String) {
        let baseURL = "https://de1.api.radio-browser.info/json/stations"
        let urlString: String
        
        if country == "All" {
            urlString = baseURL
        } else {
            let encoded = country.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            urlString = "\(baseURL)/bycountry/\(encoded)"
        }
        
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                CTSwiftLogger.shared.info("❌ Fehler beim Laden: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                CTSwiftLogger.shared.info("⚠️ Keine Daten erhalten")
                return
            }
            
            do {
                let decoded = try JSONDecoder().decode([RadioStation].self, from: data)
                
                let uniqueStations = Dictionary(grouping: decoded, by: \.urlResolved)
                    .compactMap { $0.value.first }
                
                let httpsStations = uniqueStations.filter { $0.urlResolved.hasPrefix("https") }
                
                DispatchQueue.main.async {
                    let formattedStations = httpsStations.map { station in
                        RadioStation(
                            name: station.name,
                            urlResolved: station.urlResolved,
                            favicon: station.favicon,
                            tags: station.tags.replacingOccurrences(of: ",", with: ", ").uppercased(),
                            codec: station.codec,
                            bitrate: station.bitrate,
                            country: station.country
                        )
                    }
                    
                    self.stations = formattedStations.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    
                    CTSwiftLogger.shared.info("✅ \(self.stations.count) Sender geladen (\(country))")
                }
            } catch {
                CTSwiftLogger.shared.info("❌ Fehler beim Dekodieren: \(error)")
            }
        }.resume()
    }
}
