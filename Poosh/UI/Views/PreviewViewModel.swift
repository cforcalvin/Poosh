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
  private var cancellables = Set<AnyCancellable>()
  private var processingGeneration = 0
  private var loadGeneration = 0
  private var previewLoadTask: Task<Void, Never>?
  private var idleUpgradeTask: Task<Void, Never>?
  private var suppressCurveBinding = false

  var hasUnsavedChanges: Bool {
    guard contentMode == .editableImage else { return false }
    return hasCurveChanges
      || rotationQuarterTurns != baselineRotation
      || !Self.cropsEqual(cropRect, baselineCrop)
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
  func paintInitialContent() {
    assert(Thread.isMainThread)
    guard contentMode == .editableImage else { return }
    applyLibraryStateIfAvailable(for: sourceURL)
    updateLayoutSizeFromMaster(masterURL)
    paintEditableImageSynchronously(finderURL: sourceURL, master: masterURL)
    if let display = processedImage {
      processor.setSource(cgImage: display)
    }
  }

  /// After first paint: deferred fingerprint (relocated files) + idle upgrade.
  func loadContent() async {
    assert(Thread.isMainThread)
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
      let display = processedImage
      if let display {
        processor.setSource(cgImage: display)
      }
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
    let points = await MainActor.run {
      (self.toneCurve.points, self.rotationQuarterTurns, self.cropRect)
    }
    let turns = points.1
    let curvePoints = points.0
    let crop = points.2
    let needsEditPass =
      turns != 0 || !Self.isIdentityCurve(curvePoints) || (crop != nil && !(crop?.isIdentity ?? true))
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
        }
      }
    }

    guard !Task.isCancelled else { return }
    if needsEditPass {
      await MainActor.run {
        guard self.loadGeneration == generation, self.sourceURL == source else { return }
        self.processEdits(points: curvePoints, rotationQuarterTurns: turns, cropRect: crop)
        self.scheduleIdleUpgrade(for: source, master: master, generation: generation)
      }
    } else {
      await MainActor.run {
        self.scheduleIdleUpgrade(for: source, master: master, generation: generation)
      }
    }

    Task.detached(priority: .utility) {
      Self.requestUbiquitousDownloadIfNeeded(for: master)
    }
  }

  private func scheduleIdleUpgrade(for source: URL, master: URL, generation: Int) {
    idleUpgradeTask?.cancel()
    let processor = self.processor
    idleUpgradeTask = Task { [weak self] in
      // Stay out of the way while the user is still arrowing.
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      let stillCurrent = await MainActor.run {
        self.loadGeneration == generation && self.sourceURL == source
      }
      guard stillCurrent else { return }

      let sharper = await Task.detached(priority: .utility) {
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
    guard contentMode == .editableImage else { return }
    toneCurve.reset()
    reprocessCurrentEdits()
  }

  func rotateLeft() {
    guard contentMode == .editableImage else { return }
    applyRotationDelta(-1)
  }

  func rotateRight() {
    guard contentMode == .editableImage else { return }
    applyRotationDelta(1)
  }

  func beginCropping() {
    guard contentMode == .editableImage else { return }
    isCropping = true
  }

  @discardableResult
  func cancelCropping() -> Bool {
    guard isCropping else { return false }
    isCropping = false
    return true
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

  func requestZoom(_ command: PreviewZoomCommand) {
    guard contentMode == .editableImage, !isCropping else { return }
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
    guard contentMode == .editableImage, !isCropping else { return }
    guard abs(delta) > 0.0001, abs(delta) < 1.0 else { return }
    let next = min(max(imageScale * (1 + delta), minImageScale), maxImageScale)
    if next <= 1.01 {
      resetImageZoom()
    } else {
      setImageScale(next)
    }
  }

  func applyTrackpadPan(deltaX: CGFloat, deltaY: CGFloat) {
    guard contentMode == .editableImage, !isCropping else { return }
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
    let lut = ToneCurve(points: points).generateLUT()
    let existing = libraryEntry

    let recipe = EditRecipe(
      curvePoints: points.map { EditRecipe.Point(x: $0.x, y: $0.y) },
      rotationQuarterTurns: turns,
      cropRect: crop,
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
        to: finderURL
      )
    }.value

    PreviewImageCache.remove(for: finderURL)

    libraryEntry = entry
    masterURL = entry.originalURL
    initialPoints = toneCurve.points
    baselineRotation = turns
    baselineCrop = crop
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
    updateLayoutSizeFromMaster(masterURL)
  }

  private func applyRotationDelta(_ delta: Int) {
    rotationQuarterTurns = ImageProcessor.normalizedQuarterTurns(rotationQuarterTurns + delta)
    updateLayoutSizeFromMaster(masterURL)
    reprocessCurrentEdits()
    onNeedsLayout?()
  }

  private func reprocessCurrentEdits() {
    processEdits(
      points: toneCurve.points,
      rotationQuarterTurns: rotationQuarterTurns,
      cropRect: cropRect
    )
  }

  private func bindCurveUpdates() {
    toneCurve.$points
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] points in
        guard let self, !self.suppressCurveBinding else { return }
        // Live preview uses whatever preview pixels are loaded — never kick a full-res
        // decode mid-drag (that was saturating ImageIO and killing arrow-key speed).
        self.processEdits(
          points: points,
          rotationQuarterTurns: self.rotationQuarterTurns,
          cropRect: self.cropRect
        )
      }
      .store(in: &cancellables)
  }

  private func processEdits(
    points: [CurvePoint],
    rotationQuarterTurns: Int,
    cropRect: EditRecipe.CropRect?
  ) {
    guard contentMode == .editableImage else { return }
    processingGeneration += 1
    let generation = processingGeneration
    let lut = ToneCurve(points: points).generateLUT()
    let turns = rotationQuarterTurns
    let crop = cropRect
    let processor = self.processor

    Task.detached(priority: .userInitiated) {
      let image = processor.applyCurve(
        lut: lut,
        rotationQuarterTurns: turns,
        cropRect: crop
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
    let displayed: CGSize
    if let crop = cropRect, !crop.isIdentity {
      displayed = CGSize(
        width: max(rotated.width * crop.width, 1),
        height: max(rotated.height * crop.height, 1)
      )
    } else {
      displayed = rotated
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
}
