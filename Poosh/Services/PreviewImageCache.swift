import CoreGraphics
import Foundation

/// Small in-memory cache so arrow browsing can paint the next image immediately
/// when we've already decoded it (prefetch / prior visit).
enum PreviewImageCache {
  struct Entry {
    let image: CGImage
    let pixelSize: CGSize
  }

  private static let cache: NSCache<NSURL, Box> = {
    let c = NSCache<NSURL, Box>()
    c.countLimit = 48
    return c
  }()

  static func entry(for url: URL) -> Entry? {
    cache.object(forKey: url.standardizedFileURL as NSURL).map {
      Entry(image: $0.image, pixelSize: $0.pixelSize)
    }
  }

  static func image(for url: URL) -> CGImage? {
    entry(for: url)?.image
  }

  static func store(_ image: CGImage, for url: URL, pixelSize: CGSize? = nil) {
    let size = pixelSize ?? CGSize(width: image.width, height: image.height)
    cache.setObject(Box(image: image, pixelSize: size), forKey: url.standardizedFileURL as NSURL)
  }

  static func remove(for url: URL) {
    cache.removeObject(forKey: url.standardizedFileURL as NSURL)
  }

  private final class Box: NSObject {
    let image: CGImage
    let pixelSize: CGSize
    init(image: CGImage, pixelSize: CGSize) {
      self.image = image
      self.pixelSize = pixelSize
    }
  }
}
