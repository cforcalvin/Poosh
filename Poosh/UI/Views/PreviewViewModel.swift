import Combine
import CoreGraphics
import Foundation

enum PreviewContentMode {
  case editableImage
  case quickLook
  case avMedia
  case pdf
}

enum PreviewZoomCommand {
  case zoomIn
  case zoomOut
  case reset
}

final class PreviewViewModel: ObservableObject {
  @Published var processedImage: CGImage?
  @Published var toneCurve = ToneCurve()
  @Published private(set) var sourceURL: URL
  @Published private(set) var imagePixelSize: CGSize
  @Published private(set) var rotationQuarterTurns = 0
  @Published private(set) var contentMode: PreviewContentMode
  @Published private(set) var cropRect: EditRecipe.CropRect?
  @Published var isCropping = false
  /// Draft crop while the overlay is open (normalized, top-left origin).
  @Published var draftCrop = EditRecipe.CropRect.full
  @Published private(set) var isBlackAndWhite = false
  /// Fine straighten in degrees (−45…45), edited during crop.
  @Published private(set) var straightenDegrees: Double = 0
  /// Color-adjust session (eyedropper + hue band shift).
  @Published var isColorAdjusting = false
  /// True while waiting for the user to click a color on the image.
  @Published private(set) var isEyedropping = false
  /// Center of the soft hue band (0…360). `nil` until sampled / loaded.
  @Published private(set) var hueCenterDegrees: Double?
  /// Live hue shift for the soft band (−180…180).
  @Published private(set) var hueShiftDegrees: Double = 0
  /// Saturation change for the soft band (−1…1).
  @Published private(set) var hueSaturationAmount: Double = 0
  /// Live zoom/pan for the editable image preview (Quick Look–style).
  @Published private(set) var imageScale: CGFloat = 1
  @Published private(set) var imageOffset: CGSize = .zero

  var onNeedsLayout: (() -> Void)?

  private let minImageScale: CGFloat = 1
  private let maxImageScale: CGFloat = 8
  private let imageZoomStep: CGFloat = 1.25
  private var imageLastScale: CGFloat = 1
  private var imageLastOffset: CGSize = .zero
  /// GeometryReader size of the editable preview; used to edge-clamp pan.
  private var previewViewportSize: CGSize = .zero

  private let processor = ImageProcessor()
  private var nativePixelSize: CGSize
  private var masterURL: URL
  private var libraryEntry: EditLibraryEntry?
  private var initialPoints: [CurvePoint]
  private var baselineRotation = 0
  private var baselineCrop: EditRecipe.CropRect?
  private var baselineBlackAndWhite = false
  private var baselineStraightenDegrees: Double = 0
  private var baselineHueCenterDegrees: Double?
  private var baselineHueShiftDegrees: Double = 0
  private var baselineHueSaturationAmount: Double = 0
  /// Straighten angle when the current crop session started (restored on Cancel).
  private var straightenDegreesAtCropStart: Double = 0
  /// Hue state when the current color-adjust session started (restored on Cancel).
  private var hueCenterAtColorAdjustStart: Double?
  private var hueShiftAtColorAdjustStart: Double = 0
  private var hueSaturationAtColorAdjustStart: Double = 0
  private var cancellables = Set<AnyCancellable>()
  private var processingGeneration = 0
  private var loadGeneration = 0
  private var previewLoadTask: Task<Void, Never>?
  private var idleUpgradeTask: Task<Void, Never>?
  private var suppressCurveBinding = false
  /// True when first paint already applied recipe edits (crop/rotate/curve) to `processedImage`.
  private var displayAlreadyHasRecipeEdits = false

  var hasUnsavedChanges: Bool {
    guard contentMode == .editableImage else { return false }
    return hasCurveChanges
      || rotationQuarterTurns != baselineRotation
      || !Self.cropsEqual(cropRect, baselineCrop)
      || isBlackAndWhite != baselineBlackAndWhite
      || abs(straightenDegrees - baselineStraightenDegrees) > 0.01
      || !Self.huesEqual(hueCenterDegrees, baselineHueCenterDegrees)
      || abs(hueShiftDegrees - baselineHueShiftDegrees) > 0.5
      || abs(hueSaturationAmount - baselineHueSaturationAmount) > 0.01
  }

  /// Soft band is active when a center is set and hue or sat differs from identity.
  private var hasHueEdit: Bool {
    guard hueCenterDegrees != nil else { return false }
    return abs(hueShiftDegrees) > 0.5 || abs(hueSaturationAmount) > 0.01
  }

  private var hasCurveChanges: Bool {
    curveValues(toneCurve.sortedPoints) != curveValues(initialPoints.sorted { $0.x < $1.x })
  }

  var showsCurveTool: Bool {
    contentMode == .editableImage
  }

  var showsRotateControls: Bool {
    contentMode == .editableImage
  }

  var showsCropControls: Bool {
    contentMode == .editableImage
  }

  init(url: URL) {
    sourceURL = url
    let mode = Self.mode(for: url)
    contentMode = mode
    masterURL = url
    // Keep init disk/ImageIO-free so present() can orderFront immediately.
    let size = Self.defaultPanelSize(for: mode, url: url)
    nativePixelSize = size
    imagePixelSize = size
    initialPoints = [
      CurvePoint(x: 0, y: 0),
      CurvePoint(x: 1, y: 1),
    ]
    bindCurveUpdates()
  }

  /// Synchronous first paint for `present()` — path-only recipe lookup, no fingerprint.
  /// Call before `orderFront` so the panel is not empty on first frame.
  /// Recipe edits (crop/curve/rotate) are scheduled off the main thread so first open
  /// stays responsive; browsing (`load(url:)`) still applies them synchronously.
  func paintInitialContent() {
    assert(Thread.isMainThread)
    guard contentMode == .editableImage else { return }
    applyLibraryStateIfAvailable(for: sourceURL)
    updateLayoutSizeFromMaster(masterURL)
    paintEditableImageSynchronously(finderURL: sourceURL, master: masterURL)
    if let display = processedImage {
      processor.setSource(cgImage: display)
    }
    displayAlreadyHasRecipeEdits = false
    scheduleRecipeEditsIfNeeded()
  }

  /// After first paint: deferred fingerprint (relocated files) + idle upgrade.
  @MainActor
  func loadContent() async {
    guard contentMode == .editableImage else { return }
    if processedImage == nil {
      paintInitialContent()
    }

    let generation = loadGeneration
    let source = sourceURL
    let pathOnlyEntryID = libraryEntry?.id
    let paintedMaster = masterURL
    let display = processedImage

    previewLoadTask = Task { [weak self] in
      guard let self else { return }

      // Fingerprint / resourceValues can stall (esp. iCloud) — never on the paint path.
      let fingerprintEntry = await Task.detached(priority: .utility) {
        EditLibrary.entryResolvingFingerprint(for: source)
      }.value

      guard !Task.isCancelled else { return }

      var master = paintedMaster
      var currentDisplay = display

      if let entry = fingerprintEntry, entry.id != pathOnlyEntryID {
        let reapplied = await MainActor.run { () -> (URL, CGImage?)? in
          guard self.loadGeneration == generation, self.sourceURL == source else { return nil }
          self.applyLibraryEntry(entry)
          self.paintEditableImageSynchronously(finderURL: source, master: self.masterURL)
          if let img = self.processedImage {
            self.processor.setSource(cgImage: img)
          }
          self.displayAlreadyHasRecipeEdits = false
          self.scheduleRecipeEditsIfNeeded()
          return (self.masterURL, self.processedImage)
        }
        if let reapplied {
          master = reapplied.0
          currentDisplay = reapplied.1
        }
      }

      guard !Task.isCancelled else { return }
      await self.finishLoadAfterPaint(
        for: source,
        master: master,
        display: currentDisplay,
        generation: generation
      )
    }
  }

  func load(url: URL) {
    assert(Thread.isMainThread)
    previewLoadTask?.cancel()
    idleUpgradeTask?.cancel()
    processingGeneration += 1
    loadGeneration += 1
    let generation = loadGeneration

    let previousMode = contentMode
    let mode = Self.mode(for: url)

    processor.releaseSource()

    sourceURL = url
    contentMode = mode
    libraryEntry = nil
    masterURL = url
    rotationQuarterTurns = 0
    baselineRotation = 0
    cropRect = nil
    baselineCrop = nil
    isCropping = false
    isColorAdjusting = false
    isEyedropping = false
    isBlackAndWhite = false
    baselineBlackAndWhite = false
    straightenDegrees = 0
    baselineStraightenDegrees = 0
    hueCenterDegrees = nil
    baselineHueCenterDegrees = nil
    hueShiftDegrees = 0
    baselineHueShiftDegrees = 0
    hueSaturationAmount = 0
    baselineHueSaturationAmount = 0
    displayAlreadyHasRecipeEdits = false
    resetImageZoom()

    // Mutate points in place — never replace `toneCurve` or the live-preview sink dies.
    suppressCurveBinding = true
    toneCurve.reset()
    initialPoints = toneCurve.points
    suppressCurveBinding = false

    if mode != .editableImage {
      processedImage = nil
    }

    if mode == .editableImage {
      // Path-only recipe lookup — never fingerprint/resourceValues on arrows.
      applyLibraryStateIfAvailable(for: url)
      updateLayoutSizeFromMaster(masterURL)
      paintEditableImageSynchronously(finderURL: url, master: masterURL)
      let master = masterURL
      if let display = processedImage {
        processor.setSource(cgImage: display)
      }
      displayAlreadyHasRecipeEdits = applyRecipeEditsSynchronouslyIfNeeded()
      let display = processedImage
      previewLoadTask = Task { [weak self] in
        await self?.finishLoadAfterPaint(
          for: url,
          master: master,
          display: display,
          generation: generation
        )
      }
    } else {
      imagePixelSize = Self.defaultPanelSize(for: mode, url: url)
      nativePixelSize = imagePixelSize
    }

    if previousMode != mode {
      onNeedsLayout?()
    }
  }

  /// Paint on the calling thread (must be MainActor) using cache or a small ImageIO thumb.
  /// Never clears the previous frame unless we immediately have a replacement.
  private func paintEditableImageSynchronously(finderURL: URL, master: URL) {
    if let cached = PreviewImageCache.entry(for: finderURL) {
      processedImage = cached.image
      return
    }

    if let thumb = ImageProcessor.loadThumbnail(
      url: master,
      maxPixelSize: PreviewWindowLayout.fastPreviewPixels
    ) {
      let size = CGSize(width: thumb.width, height: thumb.height)
      processedImage = thumb
      PreviewImageCache.store(thumb, for: finderURL, pixelSize: size)
      return
    }

    // Keep showing the previous image rather than flashing empty for 1–2s.
  }

  /// Panel layout uses full file dimensions — never the decoded preview pixel size,
  /// so the window does not resize when the idle high-res upgrade lands.
  private func updateLayoutSizeFromMaster(_ master: URL) {
    let size = ImageProcessor.pixelSize(for: master)
    applyLayoutNativeSize(size)
  }

  /// After pixels are on screen: handle missing paint, edits, deferred upgrade. Never blocks browse.
  private func finishLoadAfterPaint(
    for source: URL,
    master: URL,
    display: CGImage?,
    generation: Int
  ) async {
    let snapshot = await MainActor.run {
      (
        self.toneCurve.points,
        self.rotationQuarterTurns,
        self.cropRect,
        self.displayAlreadyHasRecipeEdits,
        self.straightenDegrees,
        self.isBlackAndWhite,
        self.hueCenterDegrees,
        self.hueShiftDegrees,
        self.hueSaturationAmount
      )
    }
    let turns = snapshot.1
    let curvePoints = snapshot.0
    let crop = snapshot.2
    let alreadyEdited = snapshot.3
    let straighten = snapshot.4
    let mono = snapshot.5
    let hueCenter = snapshot.6
    let hueShift = snapshot.7
    let hueSat = snapshot.8
    let needsEditPass =
      turns != 0
      || !Self.isIdentityCurve(curvePoints)
      || (crop != nil && !(crop?.isIdentity ?? true))
      || mono
      || abs(straighten) > 0.01
      || (hueCenter != nil && (abs(hueShift) > 0.5 || abs(hueSat) > 0.01))
    let processor = self.processor

    if display == nil {
      let loaded = await Task.detached(priority: .userInitiated) {
        processor.loadPreviewSource(url: master, maxPixelSize: PreviewWindowLayout.fastPreviewPixels)
      }.value
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard self.loadGeneration == generation, self.sourceURL == source else { return }
        if let loaded {
          self.processedImage = loaded
          PreviewImageCache.store(loaded, for: source)
          processor.setSource(cgImage: loaded)
          self.displayAlreadyHasRecipeEdits = self.applyRecipeEditsSynchronouslyIfNeeded()
        }
      }
    }

    guard !Task.isCancelled else { return }
    await MainActor.run {
      guard self.loadGeneration == generation, self.sourceURL == source else { return }
      // First paint may already show crop/rotate/curve — avoid a duplicate pass that flashes.
      if needsEditPass, !alreadyEdited, !self.displayAlreadyHasRecipeEdits {
        self.processEdits(
          points: curvePoints,
          rotationQuarterTurns: turns,
          cropRect: crop,
          straightenDegrees: straighten,
          isBlackAndWhite: mono,
          hueCenterDegrees: hueCenter,
          hueShiftDegrees: hueShift,
          hueSaturationAmount: hueSat
        )
      }
      self.scheduleIdleUpgrade(for: source, master: master, generation: generation)
    }

    Task.detached(priority: .utility) {
      Self.requestUbiquitousDownloadIfNeeded(for: master)
    }
  }

  private func scheduleIdleUpgrade(for source: URL, master: URL, generation: Int) {
    idleUpgradeTask?.cancel()

    // Skip second decode when the preview source is already upgrade-quality.
    let sourceSize = processor.sourcePixelSize
    if max(sourceSize.width, sourceSize.height) >= PreviewWindowLayout.maxPreviewPixels - 0.5 {
      return
    }

    let processor = self.processor
    idleUpgradeTask = Task { [weak self] in
      // Brief settle so fast arrow spam cancels before the heavy decode.
      try? await Task.sleep(nanoseconds: 100_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      let stillCurrent = await MainActor.run {
        self.loadGeneration == generation && self.sourceURL == source
      }
      guard stillCurrent else { return }

      let sharper = await Task.detached(priority: .userInitiated) {
        processor.loadPreviewSource(url: master, maxPixelSize: PreviewWindowLayout.maxPreviewPixels)
      }.value

      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard self.loadGeneration == generation, self.sourceURL == source else { return }
        guard let sharper else { return }
        let needsEditPass =
          self.rotationQuarterTurns != 0
          || !Self.isIdentityCurve(self.toneCurve.points)
          || (self.cropRect != nil && !(self.cropRect?.isIdentity ?? true))
          || self.isBlackAndWhite
          || abs(self.straightenDegrees) > 0.01
          || self.hasHueEdit
        if needsEditPass {
          // Processor already holds the sharper source — reprocess into display
          // without flashing the unedited master.
          self.reprocessCurrentEdits()
        } else {
          self.processedImage = sharper
          PreviewImageCache.store(sharper, for: source)
        }
      }
    }
  }

  /// Apply saved crop/rotation/curve on the current processor source for immediate display.
  /// Does not write the edited bitmap into the cache (cache stays the unedited master).
  @discardableResult
  private func applyRecipeEditsSynchronouslyIfNeeded() -> Bool {
    guard contentMode == .editableImage else { return false }
    guard needsRecipeEditPass else { return false }
    ImageProcessor.warmSharedContextIfNeeded()
    let lut = ToneCurve(points: toneCurve.points).generateLUT()
    guard let edited = processor.applyCurve(
      lut: lut,
      rotationQuarterTurns: rotationQuarterTurns,
      cropRect: cropRect,
      straightenDegrees: straightenDegrees,
      isBlackAndWhite: isBlackAndWhite,
      hueCenterDegrees: hueCenterDegrees,
      hueShiftDegrees: hueShiftDegrees,
      hueSaturationAmount: hueSaturationAmount
    ) else {
      return false
    }
    processedImage = edited
    return true
  }

  /// Off-main edit pass for first open — keeps Space/Esc responsive while CI runs.
  private func scheduleRecipeEditsIfNeeded() {
    guard contentMode == .editableImage else { return }
    guard needsRecipeEditPass else { return }
    let lut = ToneCurve(points: toneCurve.points).generateLUT()
    let turns = rotationQuarterTurns
    let crop = cropRect
    let straighten = straightenDegrees
    let mono = isBlackAndWhite
    let hueCenter = hueCenterDegrees
    let hueShift = hueShiftDegrees
    let hueSat = hueSaturationAmount
    let generation = loadGeneration
    let processor = self.processor
    Task.detached(priority: .userInitiated) {
      ImageProcessor.warmSharedContextIfNeeded()
      let edited = processor.applyCurve(
        lut: lut,
        rotationQuarterTurns: turns,
        cropRect: crop,
        straightenDegrees: straighten,
        isBlackAndWhite: mono,
        hueCenterDegrees: hueCenter,
        hueShiftDegrees: hueShift,
        hueSaturationAmount: hueSat
      )
      await MainActor.run {
        guard self.loadGeneration == generation else { return }
        guard let edited else { return }
        self.processedImage = edited
        self.displayAlreadyHasRecipeEdits = true
      }
    }
  }

  private var needsRecipeEditPass: Bool {
    rotationQuarterTurns != 0
      || !Self.isIdentityCurve(toneCurve.points)
      || (cropRect != nil && !(cropRect?.isIdentity ?? true))
      || isBlackAndWhite
      || abs(straightenDegrees) > 0.01
      || hasHueEdit
  }

  private static func requestUbiquitousDownloadIfNeeded(for url: URL) {
    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    guard values?.isUbiquitousItem == true else { return }
    if values?.ubiquitousItemDownloadingStatus == .current { return }
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
  }

  private static func mode(for url: URL) -> PreviewContentMode {
    if ImageFormatValidator.isEditableImage(url: url) { return .editableImage }
    if ImageFormatValidator.isPDF(url: url) { return .pdf }
    if ImageFormatValidator.isAVMedia(url: url) { return .avMedia }
    return .quickLook
  }

  private static func defaultPanelSize(for mode: PreviewContentMode, url: URL) -> CGSize {
    switch mode {
    case .editableImage:
      // Placeholder until prepareEditableImageState reads real pixels.
      return CGSize(width: 800, height: 600)
    case .avMedia:
      return CGSize(width: 960, height: 540)
    case .pdf:
      return CGSize(width: 900, height: 700)
    case .quickLook:
      return CGSize(width: 960, height: 720)
    }
  }

  func resetCurve() {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    toneCurve.reset()
    reprocessCurrentEdits()
  }

  func rotateLeft() {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    applyRotationDelta(-1)
  }

  func rotateRight() {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    applyRotationDelta(1)
  }

  func toggleBlackAndWhite() {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    isBlackAndWhite.toggle()
    reprocessCurrentEdits()
  }

  /// Set fine straighten while cropping. Clamped to ±45°.
  func setStraightenDegrees(_ degrees: Double) {
    guard contentMode == .editableImage, isCropping else { return }
    let next = min(max(degrees, -45), 45)
    guard abs(next - straightenDegrees) > 0.001 else { return }
    straightenDegrees = next
    reprocessForCroppingSession()
    updateLayoutSizeFromMaster(masterURL)
  }

  func beginCropping() {
    guard contentMode == .editableImage, !isColorAdjusting else { return }
    _ = cancelColorAdjusting()
    straightenDegreesAtCropStart = straightenDegrees
    if let existing = cropRect, !existing.isIdentity {
      draftCrop = existing.clamped()
    } else {
      draftCrop = .full
    }
    isCropping = true
    resetImageZoom()
    // Show full (uncropped) image so the overlay edits crop against the real frame.
    reprocessForCroppingSession()
    updateLayoutSizeFromMaster(masterURL)
  }

  @discardableResult
  func cancelCropping() -> Bool {
    guard isCropping else { return false }
    isCropping = false
    straightenDegrees = straightenDegreesAtCropStart
    updateLayoutSizeFromMaster(masterURL)
    reprocessCurrentEdits()
    return true
  }

  func applyDraftCrop() {
    applyCrop(draftCrop)
    resetImageZoom()
  }

  func applyCrop(_ rect: EditRecipe.CropRect) {
    guard contentMode == .editableImage else { return }
    let clamped = rect.clamped()
    cropRect = clamped.isIdentity ? nil : clamped
    isCropping = false
    updateLayoutSizeFromMaster(masterURL)
    reprocessCurrentEdits()
    onNeedsLayout?()
  }

  func beginColorAdjusting() {
    guard contentMode == .editableImage, !isCropping else { return }
    if isColorAdjusting {
      // Re-enter pick mode to sample a new center.
      isEyedropping = true
      return
    }
    hueCenterAtColorAdjustStart = hueCenterDegrees
    hueShiftAtColorAdjustStart = hueShiftDegrees
    hueSaturationAtColorAdjustStart = hueSaturationAmount
    isColorAdjusting = true
    isEyedropping = hueCenterDegrees == nil
    resetImageZoom()
  }

  @discardableResult
  func cancelColorAdjusting() -> Bool {
    guard isColorAdjusting else { return false }
    isColorAdjusting = false
    isEyedropping = false
    hueCenterDegrees = hueCenterAtColorAdjustStart
    hueShiftDegrees = hueShiftAtColorAdjustStart
    hueSaturationAmount = hueSaturationAtColorAdjustStart
    reprocessCurrentEdits()
    return true
  }

  func applyColorAdjust() {
    guard isColorAdjusting else { return }
    isColorAdjusting = false
    isEyedropping = false
    // Keep live values; clear center if both hue and sat are identity.
    if abs(hueShiftDegrees) <= 0.5, abs(hueSaturationAmount) <= 0.01 {
      hueCenterDegrees = nil
      hueShiftDegrees = 0
      hueSaturationAmount = 0
    }
    reprocessCurrentEdits()
  }

  func setHueShiftDegrees(_ degrees: Double) {
    guard contentMode == .editableImage, isColorAdjusting, hueCenterDegrees != nil else { return }
    let next = min(max(degrees, -180), 180)
    guard abs(next - hueShiftDegrees) > 0.001 else { return }
    hueShiftDegrees = next
    reprocessCurrentEdits()
  }

  func setHueSaturationAmount(_ amount: Double) {
    guard contentMode == .editableImage, isColorAdjusting, hueCenterDegrees != nil else { return }
    let next = min(max(amount, -1), 1)
    guard abs(next - hueSaturationAmount) > 0.001 else { return }
    hueSaturationAmount = next
    reprocessCurrentEdits()
  }

  /// Sample hue from `processedImage` at normalized top-left image coords (0…1).
  func sampleHue(atNormalized point: CGPoint) {
    guard contentMode == .editableImage, isColorAdjusting else { return }
    guard let image = processedImage else { return }
    guard let hue = Self.hueDegrees(in: image, atNormalized: point) else { return }
    hueCenterDegrees = hue
    hueShiftDegrees = 0
    hueSaturationAmount = 0
    isEyedropping = false
    reprocessCurrentEdits()
  }

  func requestZoom(_ command: PreviewZoomCommand) {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    switch command {
    case .zoomIn:
      setImageScale(min(imageScale * imageZoomStep, maxImageScale))
    case .zoomOut:
      let next = max(imageScale / imageZoomStep, minImageScale)
      if next <= 1.01 {
        resetImageZoom()
      } else {
        setImageScale(next)
      }
    case .reset:
      resetImageZoom()
    }
  }

  /// Incremental magnify (NSEvent type `.magnify` / true pinch). `delta` is a small fraction.
  func applyPinchMagnification(_ delta: CGFloat) {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    guard abs(delta) > 0.0001 else { return }
    let next = min(max(imageScale * (1 + delta), minImageScale), maxImageScale)
    if next <= 1.01 {
      resetImageZoom()
    } else {
      setImageScale(next)
    }
  }

  func applyTrackpadPan(deltaX: CGFloat, deltaY: CGFloat) {
    guard contentMode == .editableImage, !isCropping, !isColorAdjusting else { return }
    guard imageScale > 1.01 else { return }
    let next = CGSize(
      width: imageOffset.width + deltaX,
      height: imageOffset.height + deltaY
    )
    imageOffset = clampedOffset(next)
    imageLastOffset = imageOffset
  }

  /// Report the preview GeometryReader size so pan can be clamped to image edges.
  func updatePreviewLayout(viewport: CGSize) {
    guard viewport.width > 0, viewport.height > 0 else { return }
    let changed =
      abs(previewViewportSize.width - viewport.width) > 0.5
      || abs(previewViewportSize.height - viewport.height) > 0.5
    previewViewportSize = viewport
    if changed {
      clampImageOffset()
    }
  }

  func resetImageZoom() {
    imageScale = 1
    imageLastScale = 1
    imageOffset = .zero
    imageLastOffset = .zero
  }

  private func setImageScale(_ scale: CGFloat) {
    imageScale = scale
    imageLastScale = scale
    clampImageOffset()
  }

  private func clampImageOffset() {
    imageOffset = clampedOffset(imageOffset)
    imageLastOffset = imageOffset
  }

  /// Keep zoomed content covering the viewport; center when content fits on an axis.
  private func clampedOffset(_ proposed: CGSize) -> CGSize {
    let V = previewViewportSize
    guard V.width > 0, V.height > 0 else { return .zero }
    let pixels = imagePixelSize
    guard pixels.width > 0, pixels.height > 0 else { return .zero }

    let fit = min(V.width / pixels.width, V.height / pixels.height)
    let fitted = CGSize(width: pixels.width * fit, height: pixels.height * fit)
    let contentW = fitted.width * imageScale
    let contentH = fitted.height * imageScale
    let maxX = max(0, (contentW - V.width) / 2)
    let maxY = max(0, (contentH - V.height) / 2)
    return CGSize(
      width: min(max(proposed.width, -maxX), maxX),
      height: min(max(proposed.height, -maxY), maxY)
    )
  }

  func commitToDisk() async throws {
    guard contentMode == .editableImage else { return }
    guard hasUnsavedChanges else { return }

    let finderURL = sourceURL
    let points = toneCurve.sortedPoints
    let turns = rotationQuarterTurns
    let crop = cropRect
    let straighten = straightenDegrees
    let mono = isBlackAndWhite
    let hueCenter = hueCenterDegrees
    let hueShift = hueShiftDegrees
    let hueSat = hueSaturationAmount
    let lut = ToneCurve(points: points).generateLUT()
    let existing = libraryEntry

    let activeHue = hueCenter != nil && (abs(hueShift) > 0.5 || abs(hueSat) > 0.01)
    let recipe = EditRecipe(
      curvePoints: points.map { EditRecipe.Point(x: $0.x, y: $0.y) },
      rotationQuarterTurns: turns,
      cropRect: crop,
      straightenDegrees: straighten,
      isBlackAndWhite: mono,
      hueCenterDegrees: activeHue ? hueCenter : nil,
      hueShiftDegrees: activeHue ? hueShift : 0,
      hueSaturationAmount: activeHue ? hueSat : 0,
      sourcePath: finderURL.path,
      fingerprint: existing?.recipe.fingerprint ?? "",
      bookmarkData: existing?.recipe.bookmarkData
    )

    let entry = try EditLibrary.save(
      sourceURL: finderURL,
      recipe: recipe,
      existing: existing
    )

    // Bake from original at full resolution only at save time.
    try await Task.detached(priority: .userInitiated) { [processor] in
      processor.loadFullSource(url: entry.originalURL)
      try processor.exportProcessedImage(
        lut: lut,
        rotationQuarterTurns: turns,
        cropRect: crop,
        straightenDegrees: straighten,
        isBlackAndWhite: mono,
        hueCenterDegrees: recipe.hueCenterDegrees,
        hueShiftDegrees: recipe.hueShiftDegrees,
        hueSaturationAmount: recipe.hueSaturationAmount,
        to: finderURL
      )
    }.value

    PreviewImageCache.remove(for: finderURL)

    libraryEntry = entry
    masterURL = entry.originalURL
    initialPoints = toneCurve.points
    baselineRotation = turns
    baselineCrop = crop
    baselineStraightenDegrees = straighten
    baselineBlackAndWhite = mono
    baselineHueCenterDegrees = recipe.hueCenterDegrees
    baselineHueShiftDegrees = recipe.hueShiftDegrees
    baselineHueSaturationAmount = recipe.hueSaturationAmount
    hueCenterDegrees = recipe.hueCenterDegrees
    hueShiftDegrees = recipe.hueShiftDegrees
    hueSaturationAmount = recipe.hueSaturationAmount
  }

  private func applyLibraryStateIfAvailable(for url: URL) {
    guard let entry = EditLibrary.entry(for: url) else {
      libraryEntry = nil
      masterURL = url
      return
    }
    applyLibraryEntry(entry)
  }

  private func applyLibraryEntry(_ entry: EditLibraryEntry) {
    libraryEntry = entry
    masterURL = entry.originalURL

    let recipePoints = entry.recipe.curvePoints.map {
      CurvePoint(x: $0.x, y: $0.y)
    }
    // IMPORTANT: update points on the existing ToneCurve so Combine sink stays alive.
    suppressCurveBinding = true
    if recipePoints.isEmpty {
      toneCurve.reset()
    } else {
      toneCurve.points = recipePoints
    }
    initialPoints = toneCurve.points
    suppressCurveBinding = false
    rotationQuarterTurns = ImageProcessor.normalizedQuarterTurns(entry.recipe.rotationQuarterTurns)
    baselineRotation = rotationQuarterTurns
    let crop = entry.recipe.cropRect.flatMap { $0.isIdentity ? nil : $0.clamped() }
    cropRect = crop
    baselineCrop = crop
    straightenDegrees = entry.recipe.straightenDegrees
    baselineStraightenDegrees = straightenDegrees
    isBlackAndWhite = entry.recipe.isBlackAndWhite
    baselineBlackAndWhite = isBlackAndWhite
    hueCenterDegrees = entry.recipe.hueCenterDegrees
    baselineHueCenterDegrees = hueCenterDegrees
    hueShiftDegrees = entry.recipe.hueShiftDegrees
    baselineHueShiftDegrees = hueShiftDegrees
    hueSaturationAmount = entry.recipe.hueSaturationAmount
    baselineHueSaturationAmount = hueSaturationAmount
    updateLayoutSizeFromMaster(masterURL)
  }

  private func applyRotationDelta(_ delta: Int) {
    guard !isCropping, !isColorAdjusting else { return }
    rotationQuarterTurns = ImageProcessor.normalizedQuarterTurns(rotationQuarterTurns + delta)
    updateLayoutSizeFromMaster(masterURL)
    reprocessCurrentEdits()
    onNeedsLayout?()
  }

  private func reprocessCurrentEdits() {
    processEdits(
      points: toneCurve.points,
      rotationQuarterTurns: rotationQuarterTurns,
      cropRect: isCropping ? nil : cropRect,
      straightenDegrees: straightenDegrees,
      isBlackAndWhite: isBlackAndWhite,
      hueCenterDegrees: hueCenterDegrees,
      hueShiftDegrees: hueShiftDegrees,
      hueSaturationAmount: hueSaturationAmount
    )
  }

  /// While cropping, omit the saved crop so the overlay targets the full frame.
  private func reprocessForCroppingSession() {
    processEdits(
      points: toneCurve.points,
      rotationQuarterTurns: rotationQuarterTurns,
      cropRect: nil,
      straightenDegrees: straightenDegrees,
      isBlackAndWhite: isBlackAndWhite,
      hueCenterDegrees: hueCenterDegrees,
      hueShiftDegrees: hueShiftDegrees,
      hueSaturationAmount: hueSaturationAmount
    )
  }

  private func bindCurveUpdates() {
    toneCurve.$points
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] points in
        guard let self, !self.suppressCurveBinding else { return }
        guard !self.isColorAdjusting else { return }
        // Live preview uses whatever preview pixels are loaded — never kick a full-res
        // decode mid-drag (that was saturating ImageIO and killing arrow-key speed).
        self.processEdits(
          points: points,
          rotationQuarterTurns: self.rotationQuarterTurns,
          cropRect: self.isCropping ? nil : self.cropRect,
          straightenDegrees: self.straightenDegrees,
          isBlackAndWhite: self.isBlackAndWhite,
          hueCenterDegrees: self.hueCenterDegrees,
          hueShiftDegrees: self.hueShiftDegrees,
          hueSaturationAmount: self.hueSaturationAmount
        )
      }
      .store(in: &cancellables)
  }

  private func processEdits(
    points: [CurvePoint],
    rotationQuarterTurns: Int,
    cropRect: EditRecipe.CropRect?,
    straightenDegrees: Double,
    isBlackAndWhite: Bool,
    hueCenterDegrees: Double?,
    hueShiftDegrees: Double,
    hueSaturationAmount: Double
  ) {
    guard contentMode == .editableImage else { return }
    processingGeneration += 1
    let generation = processingGeneration
    let lut = ToneCurve(points: points).generateLUT()
    let turns = rotationQuarterTurns
    let crop = cropRect
    let straighten = straightenDegrees
    let mono = isBlackAndWhite
    let hueCenter = hueCenterDegrees
    let hueShift = hueShiftDegrees
    let hueSat = hueSaturationAmount
    let processor = self.processor

    Task.detached(priority: .userInitiated) {
      let image = processor.applyCurve(
        lut: lut,
        rotationQuarterTurns: turns,
        cropRect: crop,
        straightenDegrees: straighten,
        isBlackAndWhite: mono,
        hueCenterDegrees: hueCenter,
        hueShiftDegrees: hueShift,
        hueSaturationAmount: hueSat
      )
      await MainActor.run {
        guard self.processingGeneration == generation else { return }
        if let image {
          self.processedImage = image
        }
      }
    }
  }

  private func applyLayoutNativeSize(_ size: CGSize) {
    let rotated = ImageProcessor.displayedPixelSize(
      for: size,
      rotationQuarterTurns: rotationQuarterTurns
    )
    let straightened = ImageProcessor.sizeAfterStraighten(rotated, degrees: straightenDegrees)
    let displayed: CGSize
    // While cropping we show the uncropped frame.
    if !isCropping, let crop = cropRect, !crop.isIdentity {
      displayed = CGSize(
        width: max(straightened.width * crop.width, 1),
        height: max(straightened.height * crop.height, 1)
      )
    } else {
      displayed = straightened
    }
    let changed =
      abs(nativePixelSize.width - size.width) > 40
      || abs(nativePixelSize.height - size.height) > 40
      || abs(imagePixelSize.width - displayed.width) > 40
      || abs(imagePixelSize.height - displayed.height) > 40
    nativePixelSize = size
    imagePixelSize = displayed
    if changed {
      onNeedsLayout?()
    }
  }

  private func curveValues(_ points: [CurvePoint]) -> [String] {
    points.map { "\($0.x):\($0.y)" }
  }

  private static func isIdentityCurve(_ points: [CurvePoint]) -> Bool {
    let sorted = points.sorted { $0.x < $1.x }
    guard sorted.count == 2,
          abs(sorted[0].x) < 0.001, abs(sorted[0].y) < 0.001,
          abs(sorted[1].x - 1) < 0.001, abs(sorted[1].y - 1) < 0.001 else {
      return false
    }
    return true
  }

  private static func cropsEqual(_ a: EditRecipe.CropRect?, _ b: EditRecipe.CropRect?) -> Bool {
    switch (a, b) {
    case (nil, nil):
      return true
    case (nil, let b?):
      return b.isIdentity
    case (let a?, nil):
      return a.isIdentity
    case (let a?, let b?):
      return abs(a.x - b.x) < 0.002
        && abs(a.y - b.y) < 0.002
        && abs(a.width - b.width) < 0.002
        && abs(a.height - b.height) < 0.002
    }
  }

  private static func huesEqual(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil):
      return true
    case (nil, _), (_, nil):
      return false
    case (let a?, let b?):
      var d = abs(a - b)
      d = min(d, 360 - d)
      return d < 0.5
    }
  }

  /// Sample hue (0…360) at normalized top-left coords in image pixel space.
  static func hueDegrees(in image: CGImage, atNormalized point: CGPoint) -> Double? {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0 else { return nil }
    let x = min(max(Int(point.x * CGFloat(w)), 0), w - 1)
    let y = min(max(Int(point.y * CGFloat(h)), 0), h - 1)

    guard let data = image.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else {
      return nil
    }
    let bpp = image.bitsPerPixel / 8
    let bpr = image.bytesPerRow
    guard bpp >= 3 else { return nil }
    let offset = y * bpr + x * bpp
    let count = CFDataGetLength(data)
    guard offset + 2 < count else { return nil }

    // Prefer RGB order; handle BGRA bitmap info.
    let alphaInfo = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
    let byteOrder = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
    let isBGRA =
      (byteOrder == .byteOrder32Little || byteOrder == .byteOrder16Little)
      && (alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst)

    let r: Double
    let g: Double
    let b: Double
    if isBGRA {
      b = Double(ptr[offset]) / 255
      g = Double(ptr[offset + 1]) / 255
      r = Double(ptr[offset + 2]) / 255
    } else {
      r = Double(ptr[offset]) / 255
      g = Double(ptr[offset + 1]) / 255
      b = Double(ptr[offset + 2]) / 255
    }
    return rgbToHueDegrees(r: r, g: g, b: b)
  }

  private static func rgbToHueDegrees(r: Double, g: Double, b: Double) -> Double? {
    let maxc = max(r, max(g, b))
    let minc = min(r, min(g, b))
    let delta = maxc - minc
    guard delta > 1e-5, maxc > 1e-5 else { return nil }
    var hue: Double
    if maxc == r {
      hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
    } else if maxc == g {
      hue = 60 * ((b - r) / delta + 2)
    } else {
      hue = 60 * ((r - g) / delta + 4)
    }
    if hue < 0 { hue += 360 }
    return hue
  }
}
