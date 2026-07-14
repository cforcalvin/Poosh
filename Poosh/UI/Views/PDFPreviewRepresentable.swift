import AppKit
import PDFKit
import SwiftUI

/// PDF preview with a Quick Look–style page thumbnail strip on the right.
final class PDFPreviewHostView: NSView {
  private let pdfView = PDFView()
  private let thumbnailView = PDFThumbnailView()
  private let split = NSSplitView()
  private var currentURL: URL?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    split.isVertical = true
    split.dividerStyle = .thin
    split.autoresizingMask = [.width, .height]
    split.frame = bounds

    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.backgroundColor = .clear

    thumbnailView.pdfView = pdfView
    thumbnailView.thumbnailSize = NSSize(width: 80, height: 110)
    thumbnailView.backgroundColor = NSColor.black.withAlphaComponent(0.15)

    split.addSubview(pdfView)
    split.addSubview(thumbnailView)
    addSubview(split)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func layout() {
    super.layout()
    split.frame = bounds
    let strip = PreviewWindowLayout.pdfThumbnailStripWidth
    let mainWidth = max(bounds.width - strip, 120)
    // Keep thumbnail column pinned to the right.
    if split.subviews.count == 2 {
      split.setPosition(mainWidth, ofDividerAt: 0)
    }
  }

  func setPDFURL(_ url: URL) {
    let standardized = url.standardizedFileURL
    guard currentURL?.standardizedFileURL != standardized else { return }
    currentURL = url
    pdfView.document = PDFDocument(url: url)
  }
}

struct PDFPreviewRepresentable: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> PDFPreviewHostView {
    let host = PDFPreviewHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    host.setPDFURL(url)
    return host
  }

  func updateNSView(_ nsView: PDFPreviewHostView, context: Context) {
    nsView.setPDFURL(url)
  }

  @available(macOS 13.0, *)
  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: PDFPreviewHostView,
    context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 900, height: 700))
  }
}
