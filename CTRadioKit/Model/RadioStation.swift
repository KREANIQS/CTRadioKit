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




