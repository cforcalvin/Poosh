import Combine
import CoreGraphics
import Foundation

enum PreviewContentMode {
  case editableImage
  case quickLook
  case avMedia
  case pdf
}

final class PreviewViewModel: ObservableObject {
  @Published var processedImage: CGImage?
  @Published var toneCurve = ToneCurve()
  @Published private(set) var sourceURL: URL
  @Published private(set) var imagePixelSize: CGSize
  @Published private(set) var rotationQuarterTurns = 0
  @Published private(set) var contentMode: PreviewContentMode

  var onNeedsLayout: (() -> Void)?

  private let processor = ImageProcessor()
  private var nativePixelSize: CGSize
  private var masterURL: URL
  private var libraryEntry: EditLibraryEntry?
  private var initialPoints: [CurvePoint]
  private var baselineRotation = 0
  private var cancellables = Set<AnyCancellable>()
  private var processingGeneration = 0
  private var loadGeneration = 0
  private var previewLoadTask: Task<Void, Never>?
  private var idleUpgradeTask: Task<Void, Never>?
  private var suppressCurveBinding = false

  var hasUnsavedChanges: Bool {
    guard contentMode == .editableImage else { return false }
    return hasCurveChanges || rotationQuarterTurns != baselineRotation
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

  func loadContent() async {
    assert(Thread.isMainThread)
    guard contentMode == .editableImage else { return }
    // First open may need fingerprint lookup (relocated files); arrows must not.
    if let entry = EditLibrary.entryResolvingFingerprint(for: sourceURL) {
      applyLibraryEntry(entry)
    }
    updateLayoutSizeFromMaster(masterURL)
    paintEditableImageSynchronously(finderURL: sourceURL, master: masterURL)
    let generation = loadGeneration
    let master = masterURL
    let display = processedImage
    if let display {
      processor.setSource(cgImage: display)
    }
    previewLoadTask = Task { [weak self] in
      await self?.finishLoadAfterPaint(
        for: sourceURL,
        master: master,
        display: display,
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

  private func applyLayoutNativeSize(_ size: CGSize) {
    let displayed = ImageProcessor.displayedPixelSize(
      for: size,
      rotationQuarterTurns: rotationQuarterTurns
    )
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

  /// After pixels are on screen: handle missing paint, edits, deferred upgrade. Never blocks browse.
  private func finishLoadAfterPaint(
    for source: URL,
    master: URL,
    display: CGImage?,
    generation: Int
  ) async {
    let points = await MainActor.run { (self.toneCurve.points, self.rotationQuarterTurns) }
    let turns = points.1
    let curvePoints = points.0
    let needsEditPass = turns != 0 || !Self.isIdentityCurve(curvePoints)
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
        self.processEdits(points: curvePoints, rotationQuarterTurns: turns)
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
          self.rotationQuarterTurns != 0 || !Self.isIdentityCurve(self.toneCurve.points)
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
    processEdits(points: toneCurve.points, rotationQuarterTurns: rotationQuarterTurns)
  }

  func rotateLeft() {
    guard contentMode == .editableImage else { return }
    applyRotationDelta(-1)
  }

  func rotateRight() {
    guard contentMode == .editableImage else { return }
    applyRotationDelta(1)
  }

  func commitToDisk() async throws {
    guard contentMode == .editableImage else { return }
    guard hasUnsavedChanges else { return }

    let finderURL = sourceURL
    let points = toneCurve.sortedPoints
    let turns = rotationQuarterTurns
    let lut = ToneCurve(points: points).generateLUT()
    let existing = libraryEntry

    let recipe = EditRecipe(
      curvePoints: points.map { EditRecipe.Point(x: $0.x, y: $0.y) },
      rotationQuarterTurns: turns,
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
        to: finderURL
      )
    }.value

    PreviewImageCache.remove(for: finderURL)

    libraryEntry = entry
    masterURL = entry.originalURL
    initialPoints = toneCurve.points
    baselineRotation = turns
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
    updateLayoutSizeFromMaster(masterURL)
  }

  private func applyRotationDelta(_ delta: Int) {
    rotationQuarterTurns = ImageProcessor.normalizedQuarterTurns(rotationQuarterTurns + delta)
    imagePixelSize = ImageProcessor.displayedPixelSize(
      for: nativePixelSize,
      rotationQuarterTurns: rotationQuarterTurns
    )
    reprocessCurrentEdits()
    onNeedsLayout?()
  }

  private func reprocessCurrentEdits() {
    processEdits(points: toneCurve.points, rotationQuarterTurns: rotationQuarterTurns)
  }

  private func bindCurveUpdates() {
    toneCurve.$points
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] points in
        guard let self, !self.suppressCurveBinding else { return }
        // Live preview uses whatever preview pixels are loaded — never kick a full-res
        // decode mid-drag (that was saturating ImageIO and killing arrow-key speed).
        self.processEdits(points: points, rotationQuarterTurns: self.rotationQuarterTurns)
      }
      .store(in: &cancellables)
  }

  private func processEdits(points: [CurvePoint], rotationQuarterTurns: Int) {
    guard contentMode == .editableImage else { return }
    processingGeneration += 1
    let generation = processingGeneration
    let lut = ToneCurve(points: points).generateLUT()
    let turns = rotationQuarterTurns
    let processor = self.processor

    Task.detached(priority: .userInitiated) {
      let image = processor.applyCurve(lut: lut, rotationQuarterTurns: turns)
      await MainActor.run {
        guard self.processingGeneration == generation else { return }
        if let image {
          self.processedImage = image
        }
      }
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
}
