import AppKit
import SwiftUI

final class ToneCurvePanel: NSPanel {
  var allowsKeyboardFocus = true
  var onKeyEvent: ((NSEvent) -> Bool)?

  init(contentRect: NSRect, isMovableByBackground: Bool = false) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = isMovableByBackground
    titlebarAppearsTransparent = true
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { allowsKeyboardFocus }
  override var canBecomeMain: Bool { allowsKeyboardFocus }
  override var acceptsFirstResponder: Bool { allowsKeyboardFocus }

  override func keyDown(with event: NSEvent) {
    if onKeyEvent?(event) == true { return }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if onKeyEvent?(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func becomeKey() {
    super.becomeKey()
    makeFirstResponder(self)
  }
}

/// Transparent AppKit view that starts a window drag on mouseDown.
struct WindowDragRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowDragNSView {
    WindowDragNSView()
  }

  func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}

/// Hosting view for the image preview. Pinch/pan are handled by PanelController
/// (magnify events + scroll) so Finder can stay key for arrow navigation.
final class TrackpadHostingView<Content: View>: NSHostingView<Content> {
  required init(rootView: Content) {
    super.init(rootView: rootView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
