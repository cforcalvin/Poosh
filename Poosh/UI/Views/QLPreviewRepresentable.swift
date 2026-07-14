import AppKit
import QuickLookUI
import SwiftUI

/// Hosts ``QLPreviewView`` and forces it to fill the proposed SwiftUI size.
/// Without this, QLPreviewView’s tiny intrinsic size collapses the preview to a thumbnail.
final class QLPreviewHostView: NSView {
  private let previewView: QLPreviewView
  private var pendingURL: URL?
  private var appliedURL: URL?

  override init(frame frameRect: NSRect) {
    previewView = QLPreviewView(frame: frameRect, style: .normal) ?? QLPreviewView(frame: frameRect)
    previewView.autostarts = true
    previewView.shouldCloseWithWindow = false
    previewView.autoresizingMask = [.width, .height]
    super.init(frame: frameRect)
    addSubview(previewView)
    previewView.frame = bounds
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Ignore QL’s thumbnail intrinsic size so SwiftUI expands us to the panel.
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  func setPreviewURL(_ url: URL) {
    pendingURL = url
    applyPreviewIfReady()
  }

  override func layout() {
    super.layout()
    previewView.frame = bounds
    // Only assign previewItem once we have a real size — never refresh on resize.
    // refreshPreviewItem() reloads the whole file and stalls large media.
    applyPreviewIfReady()
  }

  private func applyPreviewIfReady() {
    guard let url = pendingURL, bounds.width > 2, bounds.height > 2 else { return }
    let standardized = url.standardizedFileURL
    guard appliedURL?.standardizedFileURL != standardized else { return }
    previewView.previewItem = url as QLPreviewItem
    appliedURL = url
  }
}

struct QLPreviewRepresentable: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> QLPreviewHostView {
    let host = QLPreviewHostView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
    host.setPreviewURL(url)
    return host
  }

  func updateNSView(_ nsView: QLPreviewHostView, context: Context) {
    nsView.setPreviewURL(url)
  }

  @available(macOS 13.0, *)
  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: QLPreviewHostView,
    context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 960, height: 720))
  }
}
