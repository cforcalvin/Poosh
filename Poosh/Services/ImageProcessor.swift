import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageProcessorError: Error, LocalizedError {
  case renderFailed
  case unsupportedFormat
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .renderFailed: return "Could not render the adjusted image."
    case .unsupportedFormat: return "Unsupported image format for export."
    case .writeFailed: return "Could not write the image to disk."
    }
  }
}

final class ImageProcessor {
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private let context = CIContext(options: [.useSoftwareRenderer: false])
  private var sourceImage: CIImage?
  private var renderExtent: CGRect = .zero
  private var cachedCurveData: Data?
  private var cachedLUTSignature: [Float] = []

  var sourcePixelSize: CGSize {
    CGSize(width: renderExtent.width, height: renderExtent.height)
  }

  static func pixelSize(for url: URL) -> CGSize {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
          width > 0, height > 0 else {
      return CGSize(width: 800, height: 600)
    }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    // Match Finder: orientations 5–8 display with width/height swapped.
    if [5, 6, 7, 8].contains(orientation) {
      return CGSize(width: height, height: width)
    }
    return CGSize(width: width, height: height)
  }

  static func displayedPixelSize(for nativeSize: CGSize, rotationQuarterTurns: Int) -> CGSize {
    let turns = normalizedQuarterTurns(rotationQuarterTurns)
    if turns % 2 == 1 {
      return CGSize(width: nativeSize.height, height: nativeSize.width)
    }
    return nativeSize
  }

  static func normalizedQuarterTurns(_ turns: Int) -> Int {
    ((turns % 4) + 4) % 4
  }

  func loadPreviewSource(url: URL) -> CGImage? {
    guard let cgImage = loadImage(url: url, maxPixelSize: PreviewWindowLayout.maxPreviewPixels) else {
      return nil
    }
    let ciImage = CIImage(cgImage: cgImage)
    sourceImage = ciImage
    renderExtent = ciImage.extent.integral
    cachedCurveData = nil
    cachedLUTSignature = []
    return cgImage
  }

  func loadFullSource(url: URL) {
    guard let cgImage = loadImage(url: url, maxPixelSize: nil) else { return }
    let image = CIImage(cgImage: cgImage)
    sourceImage = image
    renderExtent = image.extent.integral
    cachedCurveData = nil
    cachedLUTSignature = []
  }

  /// Loads image pixels as Finder displays them (EXIF/TIFF orientation applied).
  private func loadImage(url: URL, maxPixelSize: CGFloat?) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let exifOrientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

    if let maxPixelSize {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    let options: [CFString: Any] = [
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldAllowFloat: true,
    ]
    guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return applyingExifOrientation(decoded, orientation: exifOrientation)
  }

  private func applyingExifOrientation(_ image: CGImage, orientation: Int) -> CGImage {
    guard orientation != 1 else { return image }
    let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
    let extent = ciImage.extent.integral
    return context.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace) ?? image
  }

  func applyCurve(lut: [Float], rotationQuarterTurns: Int = 0) -> CGImage? {
    guard let sourceImage else { return nil }

    let curved: CIImage
    if isIdentityLUT(lut) {
      curved = sourceImage
    } else {
      let curveData = curvesData(for: lut)
      guard let filter = CIFilter(name: "CIColorCurves") else { return nil }
      filter.setValue(sourceImage, forKey: kCIInputImageKey)
      filter.setValue(curveData, forKey: "inputCurvesData")
      filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
      filter.setValue(sourceImage.colorSpace ?? colorSpace, forKey: "inputColorSpace")
      guard let output = filter.outputImage else { return nil }
      curved = output
    }

    let finalImage = rotated(curved, quarterTurns: rotationQuarterTurns)
    return render(finalImage)
  }

  func exportProcessedImage(lut: [Float], rotationQuarterTurns: Int = 0, to url: URL) throws {
    guard let image = applyCurve(lut: lut, rotationQuarterTurns: rotationQuarterTurns) else {
      throw ImageProcessorError.renderFailed
    }
    try write(image: image, to: url)
  }

  private func rotated(_ image: CIImage, quarterTurns: Int) -> CIImage {
    let turns = Self.normalizedQuarterTurns(quarterTurns)
    guard turns != 0 else { return image }

    let orientation: CGImagePropertyOrientation
    switch turns {
    case 1: orientation = .right
    case 2: orientation = .down
    case 3: orientation = .left
    default: return image
    }

    return image.oriented(orientation)
  }

  private func render(_ image: CIImage) -> CGImage? {
    let extent = image.extent.integral
    return context.createCGImage(
      image,
      from: extent,
      format: .RGBA8,
      colorSpace: colorSpace
    )
  }

  private func isIdentityLUT(_ lut: [Float]) -> Bool {
    guard lut.count > 1 else { return true }
    for (index, value) in lut.enumerated() {
      let expected = Float(index) / Float(lut.count - 1)
      if abs(value - expected) > 0.002 { return false }
    }
    return true
  }

  private func curvesData(for lut: [Float]) -> Data {
    if lut == cachedLUTSignature, let cachedCurveData {
      return cachedCurveData
    }

    var curveFloats = [Float]()
    curveFloats.reserveCapacity(lut.count * 3)
    for value in lut {
      let channel = Float(min(max(value, 0), 1))
      curveFloats.append(channel)
      curveFloats.append(channel)
      curveFloats.append(channel)
    }

    let data = curveFloats.withUnsafeBufferPointer { Data(buffer: $0) }
    cachedCurveData = data
    cachedLUTSignature = lut
    return data
  }

  private func write(image: CGImage, to url: URL) throws {
    let type = utType(for: url) ?? .jpeg
    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent(".poosh-\(UUID().uuidString)")
      .appendingPathExtension(url.pathExtension)

    guard let destination = CGImageDestinationCreateWithURL(
      tempURL as CFURL,
      type.identifier as CFString,
      1,
      nil
    ) else {
      throw ImageProcessorError.writeFailed
    }

    var properties: [CFString: Any] = [:]
    if type == .jpeg {
      properties[kCGImageDestinationLossyCompressionQuality] = 0.92
    }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: tempURL)
      throw ImageProcessorError.writeFailed
    }

    do {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      throw ImageProcessorError.writeFailed
    }
  }

  private func utType(for url: URL) -> UTType? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return .jpeg
    case "png": return .png
    case "heic": return .heic
    case "webp": return .webP
    default: return nil
    }
  }
}
