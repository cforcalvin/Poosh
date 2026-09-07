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

/// All access is serialized — concurrent ImageIO/CI work was racing and making
/// every arrow-key switch after the first one progressively slower.
final class ImageProcessor: @unchecked Sendable {
  /// Shared — creating a CIContext costs hundreds of ms; warm once at launch.
  private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
  private static let warmLock = NSLock()
  private static var didWarmSharedContext = false

  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private var context: CIContext { Self.sharedContext }
  private let lock = NSLock()
  private var sourceImage: CIImage?
  private var renderExtent: CGRect = .zero
  private var cachedCurveData: Data?
  private var cachedLUTSignature: [Float] = []
  /// Bumped on each load/release so in-flight cancelled decodes discard their result.
  private var epoch = 0

  /// Force Metal/CI pipeline creation off the first-preview critical path.
  static func warmSharedContextIfNeeded() {
    warmLock.lock()
    if didWarmSharedContext {
      warmLock.unlock()
      return
    }
    didWarmSharedContext = true
    warmLock.unlock()

    let context = sharedContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Tiny render so the GPU pipeline is actually compiled before the user opens a file.
    let image = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    _ = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
  }

  var sourcePixelSize: CGSize {
    lock.lock()
    defer { lock.unlock() }
    return CGSize(width: renderExtent.width, height: renderExtent.height)
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

  func setSource(cgImage: CGImage) {
    lock.lock()
    defer { lock.unlock() }
    epoch += 1
    let ciImage = CIImage(cgImage: cgImage)
    sourceImage = ciImage
    renderExtent = ciImage.extent.integral
    cachedCurveData = nil
    cachedLUTSignature = []
  }

  @discardableResult
  /// Lightweight ImageIO thumbnail — no CIContext. Safe for prefetch on a background queue.
  static func loadThumbnail(url: URL, maxPixelSize: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  func loadPreviewSource(url: URL, maxPixelSize: CGFloat = PreviewWindowLayout.maxPreviewPixels) -> CGImage? {
    let myEpoch: Int = {
      lock.lock()
      epoch += 1
      let e = epoch
      lock.unlock()
      return e
    }()

    guard let cgImage = loadImage(url: url, maxPixelSize: maxPixelSize) else { return nil }

    lock.lock()
    defer { lock.unlock() }
    guard myEpoch == epoch else { return nil }
    let ciImage = CIImage(cgImage: cgImage)
    sourceImage = ciImage
    renderExtent = ciImage.extent.integral
    cachedCurveData = nil
    cachedLUTSignature = []
    return cgImage
  }

  func loadFullSource(url: URL) {
    let myEpoch: Int = {
      lock.lock()
      epoch += 1
      let e = epoch
      lock.unlock()
      return e
    }()

    guard let cgImage = loadImage(url: url, maxPixelSize: nil) else { return }

    lock.lock()
    defer { lock.unlock() }
    guard myEpoch == epoch else { return }
    let image = CIImage(cgImage: cgImage)
    sourceImage = image
    renderExtent = image.extent.integral
    cachedCurveData = nil
    cachedLUTSignature = []
  }

  func releaseSource() {
    lock.lock()
    defer { lock.unlock() }
    epoch += 1
    sourceImage = nil
    renderExtent = .zero
    cachedCurveData = nil
    cachedLUTSignature = []
  }

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

  func applyCurve(
    lut: [Float],
    rotationQuarterTurns: Int = 0,
    cropRect: EditRecipe.CropRect? = nil,
    straightenDegrees: Double = 0,
    isBlackAndWhite: Bool = false,
    hueCenterDegrees: Double? = nil,
    hueShiftDegrees: Double = 0,
    hueSaturationAmount: Double = 0
  ) -> CGImage? {
    lock.lock()
    guard let sourceImage else {
      lock.unlock()
      return nil
    }
    let source = sourceImage
    let colorSpace = source.colorSpace ?? self.colorSpace
    let curveData: Data?
    let identity = isIdentityLUT(lut)
    if identity {
      curveData = nil
    } else {
      curveData = curvesDataLocked(for: lut)
    }
    lock.unlock()

    let curved: CIImage
    if identity {
      curved = source
    } else {
      guard let curveData,
            let filter = CIFilter(name: "CIColorCurves") else { return nil }
      filter.setValue(source, forKey: kCIInputImageKey)
      filter.setValue(curveData, forKey: "inputCurvesData")
      filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
      filter.setValue(colorSpace, forKey: "inputColorSpace")
      guard let output = filter.outputImage else { return nil }
      curved = output
    }

    let hued = shiftedHue(
      curved,
      centerDegrees: hueCenterDegrees,
      shiftDegrees: hueShiftDegrees,
      saturationAmount: hueSaturationAmount
    )
    let mono = isBlackAndWhite ? blackAndWhite(hued) : hued
    let rotatedImage = rotated(mono, quarterTurns: rotationQuarterTurns)
    let straightenedImage = straightened(rotatedImage, degrees: straightenDegrees)
    let finalImage = cropped(straightenedImage, cropRect: cropRect)
    return render(finalImage)
  }

  func exportProcessedImage(
    lut: [Float],
    rotationQuarterTurns: Int = 0,
    cropRect: EditRecipe.CropRect? = nil,
    straightenDegrees: Double = 0,
    isBlackAndWhite: Bool = false,
    hueCenterDegrees: Double? = nil,
    hueShiftDegrees: Double = 0,
    hueSaturationAmount: Double = 0,
    to url: URL
  ) throws {
    guard let image = applyCurve(
      lut: lut,
      rotationQuarterTurns: rotationQuarterTurns,
      cropRect: cropRect,
      straightenDegrees: straightenDegrees,
      isBlackAndWhite: isBlackAndWhite,
      hueCenterDegrees: hueCenterDegrees,
      hueShiftDegrees: hueShiftDegrees,
      hueSaturationAmount: hueSaturationAmount
    ) else {
      throw ImageProcessorError.renderFailed
    }
    try write(image: image, to: url)
  }

  /// Soft ±35° band around `centerDegrees` with a feathered outer edge;
  /// shifts hue and scales saturation by the band weight.
  private func shiftedHue(
    _ image: CIImage,
    centerDegrees: Double?,
    shiftDegrees: Double,
    saturationAmount: Double
  ) -> CIImage {
    guard let center = centerDegrees else { return image }
    guard abs(shiftDegrees) > 0.5 || abs(saturationAmount) > 0.01 else { return image }
    guard let kernel = Self.hueShiftKernel else { return image }

    let halfWidth = EditRecipe.hueBandHalfWidthDegrees
    let coreWidth = halfWidth * EditRecipe.hueBandCoreFraction
    let arguments: [Any] = [
      image,
      Float(center),
      Float(shiftDegrees),
      Float(saturationAmount),
      Float(halfWidth),
      Float(coreWidth),
    ]
    guard let output = kernel.apply(extent: image.extent, arguments: arguments) else {
      return image
    }
    return output.cropped(to: image.extent)
  }

  private static let hueShiftKernel: CIColorKernel? = {
    let source = """
    kernel vec4 hueShiftBand(__sample s, float centerDeg, float shiftDeg, float satAmount, float halfWidthDeg, float coreWidthDeg) {
      float r = s.r;
      float g = s.g;
      float b = s.b;
      float maxc = max(r, max(g, b));
      float minc = min(r, min(g, b));
      float delta = maxc - minc;
      float v = maxc;
      float sat = (maxc > 1e-5) ? (delta / maxc) : 0.0;
      if (sat < 0.02 || delta < 1e-5) {
        return s;
      }

      float hue;
      if (maxc == r) {
        hue = 60.0 * mod((g - b) / delta, 6.0);
      } else if (maxc == g) {
        hue = 60.0 * ((b - r) / delta + 2.0);
      } else {
        hue = 60.0 * ((r - g) / delta + 4.0);
      }
      if (hue < 0.0) { hue += 360.0; }

      float d = abs(hue - centerDeg);
      d = min(d, 360.0 - d);
      if (d >= halfWidthDeg) {
        return s;
      }

      float weight;
      if (d <= coreWidthDeg) {
        weight = 1.0;
      } else {
        float t = 1.0 - ((d - coreWidthDeg) / max(halfWidthDeg - coreWidthDeg, 0.001));
        t = clamp(t, 0.0, 1.0);
        weight = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
      }

      float newHue = hue + shiftDeg * weight;
      newHue = mod(newHue, 360.0);
      if (newHue < 0.0) { newHue += 360.0; }

      float newSat = clamp(sat * (1.0 + satAmount * weight), 0.0, 1.0);

      float c = v * newSat;
      float x = c * (1.0 - abs(mod(newHue / 60.0, 2.0) - 1.0));
      float m = v - c;
      float rr, gg, bb;
      if (newHue < 60.0) { rr = c; gg = x; bb = 0.0; }
      else if (newHue < 120.0) { rr = x; gg = c; bb = 0.0; }
      else if (newHue < 180.0) { rr = 0.0; gg = c; bb = x; }
      else if (newHue < 240.0) { rr = 0.0; gg = x; bb = c; }
      else if (newHue < 300.0) { rr = x; gg = 0.0; bb = c; }
      else { rr = c; gg = 0.0; bb = x; }

      return vec4(rr + m, gg + m, bb + m, s.a);
    }
    """
    return CIColorKernel(source: source)
  }()

  private func blackAndWhite(_ image: CIImage) -> CIImage {
    guard let filter = CIFilter(name: "CIColorControls") else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(0.0, forKey: kCIInputSaturationKey)
    // Keep the exact source bounds — filter domains can inflate extent and look like a zoom.
    return (filter.outputImage ?? image).cropped(to: image.extent)
  }

  private func render(_ image: CIImage) -> CGImage? {
    let extent: CGRect
    if image.extent.isInfinite || image.extent.isNull || image.extent.isEmpty {
      lock.lock()
      extent = renderExtent
      lock.unlock()
    } else {
      extent = image.extent.integral
    }
    guard extent.width >= 1, extent.height >= 1 else { return nil }
    return context.createCGImage(
      image,
      from: extent,
      format: .RGBA8,
      colorSpace: colorSpace
    )
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

  /// Fine rotation around the image center; expands the canvas to fit.
  private func straightened(_ image: CIImage, degrees: Double) -> CIImage {
    let clamped = min(max(degrees, -45), 45)
    guard abs(clamped) > 0.01 else { return image }
    let radians = CGFloat(clamped * .pi / 180)
    let extent = image.extent
    let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
      .rotated(by: radians)
      .translatedBy(x: -extent.midX, y: -extent.midY)
    let rotated = image.transformed(by: transform)
    let bounds = rotated.extent.integral
    return rotated.transformed(
      by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
    ).cropped(to: CGRect(origin: .zero, size: bounds.size))
  }

  static func sizeAfterStraighten(_ size: CGSize, degrees: Double) -> CGSize {
    let clamped = abs(min(max(degrees, -45), 45))
    guard clamped > 0.01 else { return size }
    let radians = clamped * .pi / 180
    let cosA = cos(radians)
    let sinA = sin(radians)
    return CGSize(
      width: abs(size.width * cosA) + abs(size.height * sinA),
      height: abs(size.width * sinA) + abs(size.height * cosA)
    )
  }

  /// `cropRect` is normalized top-left origin (UI space); CIImage is bottom-left.
  private func cropped(_ image: CIImage, cropRect: EditRecipe.CropRect?) -> CIImage {
    guard let crop = cropRect?.clamped(), !crop.isIdentity else { return image }
    let extent = image.extent
    guard extent.width > 1, extent.height > 1 else { return image }

    let rect = CGRect(
      x: extent.minX + CGFloat(crop.x) * extent.width,
      y: extent.minY + CGFloat(1 - crop.y - crop.height) * extent.height,
      width: CGFloat(crop.width) * extent.width,
      height: CGFloat(crop.height) * extent.height
    ).integral

    guard rect.width >= 1, rect.height >= 1 else { return image }
    return image.cropped(to: rect).transformed(
      by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
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

  /// Caller must hold `lock`.
  private func curvesDataLocked(for lut: [Float]) -> Data {
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
