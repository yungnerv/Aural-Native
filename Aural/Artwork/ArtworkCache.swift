import Foundation
import UIKit
import ImageIO

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    init() {
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 128
    }

    func image(at url: URL, maxPixelSize: Int) -> UIImage? {
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
        let result = UIImage(cgImage: image)
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}
