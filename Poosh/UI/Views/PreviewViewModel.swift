import Combine
import CoreGraphics
import Foundation

final class PreviewViewModel: ObservableObject {
  @Published var processedImage: CGImage?
  @Published var toneCurve = ToneCurve()
  @Published private(set) var sourceURL: URL
  @Published private(set) var imagePixelSize: CGSize
  @Published private(set) var rotationQuarterTurns = 0

  var onNeedsLayout: (() -> Void)?

  private let processor = ImageProcessor()
  private var nativePixelSize: CGSize
  private var initialPoints: [CurvePoint]
  private var cancellables = Set<AnyCancellable>()
  private var processingGeneration = 0
  private var fullSourceTask: Task<Void, Never>?

  var hasUnsavedChanges: Bool {
    hasCurveChanges || rotationQuarterTurns != 0
  }

  private var hasCurveChanges: Bool {
    curveValues(toneCurve.sortedPoints) != curveValues(initialPoints.sorted { $0.x < $1.x })
  }

  var showsCurveTool: Bool {
    ImageFormatValidator.isSupportedImage(url: sourceURL)
  }

  init(url: URL) {
    sourceURL = url
    let size = ImageProcessor.pixelSize(for: url)
    nativePixelSize = size
    imagePixelSize = size
    initialPoints = [
      CurvePoint(x: 0, y: 0),
      CurvePoint(x: 1, y: 1),
    ]
    bindCurveUpdates()
  }

  func loadContent() async {
    let url = sourceURL
    let preview = await Task.detached(priority: .userInitiated) { [processor] in
      processor.loadPreviewSource(url: url)
    }.value

    guard sourceURL == url else { return }
    await MainActor.run {
      guard self.sourceURL == url else { return }
      self.processedImage = preview
      self.reprocessCurrentEdits()
      self.loadFullSourceInBackground()
    }
  }

  func load(url: URL) {
    fullSourceTask?.cancel()
    processingGeneration += 1

    sourceURL = url
    let size = ImageProcessor.pixelSize(for: url)
    nativePixelSize = size
    imagePixelSize = size
    rotationQuarterTurns = 0
    toneCurve.reset()
    initialPoints = toneCurve.points
    processedImage = nil

    Task { await loadContent() }
  }

  func resetCurve() {
    toneCurve.reset()
    processEdits(points: toneCurve.points, rotationQuarterTurns: rotationQuarterTurns)
  }

  func rotateLeft() {
    applyRotationDelta(-1)
  }

  func rotateRight() {
    applyRotationDelta(1)
  }

  func commitToDisk() async throws {
    guard hasUnsavedChanges else { return }

    let lut = toneCurve.generateLUT()
    let url = sourceURL
    let turns = rotationQuarterTurns

    try await Task.detached(priority: .userInitiated) { [processor] in
      try processor.exportProcessedImage(lut: lut, rotationQuarterTurns: turns, to: url)
    }.value

    initialPoints = toneCurve.points
    nativePixelSize = ImageProcessor.displayedPixelSize(
      for: nativePixelSize,
      rotationQuarterTurns: turns
    )
    rotationQuarterTurns = 0
    imagePixelSize = nativePixelSize
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

  private func loadFullSourceInBackground() {
    let url = sourceURL
    fullSourceTask = Task.detached(priority: .userInitiated) { [weak self, processor] in
      processor.loadFullSource(url: url)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.sourceURL == url else { return }
        self.reprocessCurrentEdits()
      }
    }
  }

  private func bindCurveUpdates() {
    toneCurve.$points
      .dropFirst()
      .sink { [weak self] points in
        guard let self else { return }
        self.processEdits(points: points, rotationQuarterTurns: self.rotationQuarterTurns)
      }
      .store(in: &cancellables)
  }

  private func processEdits(points: [CurvePoint], rotationQuarterTurns: Int) {
    guard processedImage != nil else { return }
    processingGeneration += 1
    let generation = processingGeneration
    let lut = ToneCurve(points: points).generateLUT()
    let turns = rotationQuarterTurns

    Task.detached(priority: .userInteractive) { [weak self] in
      guard let self else { return }
      let image = self.processor.applyCurve(lut: lut, rotationQuarterTurns: turns)
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
}
