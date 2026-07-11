import CoreImage
import Foundation
import ImageIO

enum ImageFormatValidator {
  static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

  static func isSupportedImage(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return supportedExtensions.contains(url.pathExtension.lowercased())
  }

  static func canLoadImage(url: URL) -> Bool {
    guard isSupportedImage(url: url) else { return false }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
  }
}
