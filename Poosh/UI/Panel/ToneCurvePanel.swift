import AppKit

final class ToneCurvePanel: NSPanel {
  var allowsKeyboardFocus = true
  var onKeyEvent: ((NSEvent) -> Bool)?

  init(contentRect: NSRect, isMovableByBackground: Bool = true) {
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
