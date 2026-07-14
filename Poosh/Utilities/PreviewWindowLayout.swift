import AppKit
import CoreGraphics

enum PreviewWindowLayout {
  static let padding: CGFloat = 32
  static let maxLongEdge: CGFloat = 1200
  static let screenFillRatio: CGFloat = 0.85
  static let maxPreviewPixels: CGFloat = 1280
  /// First paint / arrow browsing — keep this low so HEIC opens feel instant.
  static let fastPreviewPixels: CGFloat = 512
  /// Prefetch radius while browsing (±N neighbors).
  static let prefetchNeighborCount = 3
  static let rotateToolbarHeight: CGFloat = 48
  static let rotateToolbarSpacing: CGFloat = 8
  static let pdfThumbnailStripWidth: CGFloat = 120

  struct CombinedLayout {
    let imagePanelFrame: NSRect
    let curvePanelFrame: NSRect?
  }

  static func combinedLayout(
    imagePixelSize: CGSize,
    showsCurvePanel: Bool,
    curvePanelSize: NSSize = NSSize(width: 320, height: 300),
    curveGap: CGFloat = 16,
    rotateToolbarHeight: CGFloat = rotateToolbarHeight,
    on screen: NSScreen? = NSScreen.main
  ) -> CombinedLayout {
    let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let maxCombinedWidth = min(visibleFrame.width * screenFillRatio, maxLongEdge)
    let maxCombinedHeight = min(visibleFrame.height * screenFillRatio, maxLongEdge)

    let curveWidth = showsCurvePanel ? curvePanelSize.width + curveGap : 0
    let toolbarSpacing = rotateToolbarHeight > 0 ? rotateToolbarSpacing : 0
    let maxImageWidth = max(maxCombinedWidth - curveWidth - padding * 2, 120)
    let maxImageHeight = max(
      maxCombinedHeight - padding * 2 - rotateToolbarHeight - toolbarSpacing,
      120
    )

    let fittedImageSize = fittedSize(
      for: imagePixelSize,
      maxWidth: maxImageWidth,
      maxHeight: maxImageHeight
    )

    let imagePanelSize = NSSize(
      width: fittedImageSize.width + padding * 2,
      height: fittedImageSize.height + padding * 2 + rotateToolbarHeight + toolbarSpacing
    )

    let combinedWidth = imagePanelSize.width + curveWidth
    let combinedHeight = max(imagePanelSize.height, showsCurvePanel ? curvePanelSize.height : 0)

    let combinedOrigin = NSPoint(
      x: visibleFrame.midX - combinedWidth / 2,
      y: visibleFrame.midY - combinedHeight / 2
    )

    let imageOrigin = NSPoint(
      x: combinedOrigin.x,
      y: combinedOrigin.y + (combinedHeight - imagePanelSize.height) / 2
    )
    let imagePanelFrame = NSRect(origin: imageOrigin, size: imagePanelSize)

    let curvePanelFrame: NSRect?
    if showsCurvePanel {
      let curveOrigin = NSPoint(
        x: imagePanelFrame.maxX + curveGap,
        y: visibleFrame.midY - curvePanelSize.height / 2
      )
      curvePanelFrame = NSRect(origin: curveOrigin, size: curvePanelSize)
    } else {
      curvePanelFrame = nil
    }

    return CombinedLayout(imagePanelFrame: imagePanelFrame, curvePanelFrame: curvePanelFrame)
  }

  static func panelSize(for imageSize: CGSize, padding: CGFloat = padding) -> NSSize {
    let fitted = fittedSize(
      for: imageSize,
      maxWidth: 1200,
      maxHeight: 1200
    )
    return NSSize(width: fitted.width + padding * 2, height: fitted.height + padding * 2)
  }

  private static func fittedSize(for imageSize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return CGSize(width: 640, height: 480)
    }

    let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
    return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
  }
}
