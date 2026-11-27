import Foundation
import UIKit
import ImageIO

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private static let byteLimit = 24 * 1024 * 1024
    init() {
        cache.totalCostLimit = Self.byteLimit
        cache.countLimit = 128
    }

    func image(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard !Task.isCancelled, maxPixelSize > 0, maxPixelSize <= 4096 else { return nil }
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        guard !Task.isCancelled else { return nil }
        let result = UIImage(cgImage: image)
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        if !overflow, cost <= Self.byteLimit {
            cache.setObject(result, forKey: key, cost: cost)
        }
        return result
    }
}
