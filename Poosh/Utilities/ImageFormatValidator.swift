import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFormatValidator {
  static let editableImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

  private static let mediaExtensions: Set<String> = [
    "mov", "mp4", "m4v", "avi", "mkv", "mpeg", "mpg", "m4a", "mp3",
    "wav", "aiff", "aif", "aac", "flac", "caf",
  ]

  /// Extension-only check for folder browsing — never hits the filesystem metadata server.
  private static let browseExtensions: Set<String> = editableImageExtensions
    .union(mediaExtensions)
    .union([
      "pdf", "txt", "rtf", "html", "htm", "csv",
      "doc", "docx", "xls", "xlsx", "ppt", "pptx",
      "pages", "numbers", "key", "gif", "tif", "tiff", "bmp",
    ])

  /// Images Poosh can tone-curve / rotate.
  static func isEditableImage(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return editableImageExtensions.contains(url.pathExtension.lowercased())
  }

  /// Video / audio that should stream via AVPlayer instead of Quick Look.
  static func isAVMedia(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    if isPDF(url: url) { return false }
    return mediaExtensions.contains(url.pathExtension.lowercased())
  }

  static func isPDF(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return url.pathExtension.lowercased() == "pdf"
  }

  /// Fast extension allowlist for arrow-key folder indexing (no resourceValues / iCloud hits).
  static func isBrowsablePreview(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty else { return false }
    return browseExtensions.contains(ext)
  }

  /// Gate for opening a selected Finder item.
  static func canPreview(url: URL) -> Bool {
    guard url.isFileURL else { return false }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      return false
    }

    if isBrowsablePreview(url: url) { return true }

    // Rare unknown extensions — cheap UTType from extension string only (no disk metadata).
    guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
      return false
    }
    if type.conforms(to: .application)
      || type.conforms(to: .executable)
      || type.conforms(to: .directory)
      || type.conforms(to: .folder) {
      return false
    }
    return type.conforms(to: .content) || type.conforms(to: .data)
  }

  static func isSupportedImage(url: URL) -> Bool {
    isEditableImage(url: url)
  }

  static func canLoadImage(url: URL) -> Bool {
    guard isEditableImage(url: url) else { return false }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
  }
}
