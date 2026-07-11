import AppKit
import SwiftUI
import CoreGraphics

final class PanelController {
  private static let curveGap: CGFloat = 16
  private static let curvePanelSize = NSSize(width: 320, height: 300)
  private static let selectionPollInterval: TimeInterval = 0.08

  private var imagePanel: ToneCurvePanel?
  private var curvePanel: ToneCurvePanel?
  private var viewModel: PreviewViewModel?
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var globalMouseMonitor: Any?
  private var finderSelectionTimer: Timer?
  private var previousKeyStates: [CGKeyCode: Bool] = [:]
  private var isFollowingSelection = false
  private var isNavigating = false
  private var isDismissing = false

  func present(url: URL) {
    dismissMonitors()
    dismissPanels()

    let viewModel = PreviewViewModel(url: url)
    viewModel.onNeedsLayout = { [weak self] in
      self?.applyLayout(animated: true)
    }
    self.viewModel = viewModel

    let layout = layout(for: viewModel)
    let imagePanel = makePanel(
      size: layout.imagePanelFrame.size,
      rootView: ImagePanelView(viewModel: viewModel),
      canBecomeKey: false,
      isMovableByBackground: true
    )
    imagePanel.setFrame(layout.imagePanelFrame, display: false)
    self.imagePanel = imagePanel

    if viewModel.showsCurveTool, let curveFrame = layout.curvePanelFrame {
      let curvePanel = makePanel(
        size: curveFrame.size,
        rootView: CurvePanelView(viewModel: viewModel),
        canBecomeKey: false,
        isMovableByBackground: false
      )
      curvePanel.setFrame(curveFrame, display: false)
      self.curvePanel = curvePanel
    }

    attachCurvePanelIfNeeded()

    installMonitors()
    _ = FinderService.activateFinder()
    imagePanel.orderFront(nil)

    Task {
      await viewModel.loadContent()
    }
  }

  func dismiss(saving: Bool = true) {
    guard !isDismissing else { return }
    isDismissing = true

    Task { @MainActor in
      defer { isDismissing = false }
      if saving {
        guard await commitCurrentImage() else { return }
      }
      dismissMonitors()
      dismissPanels()
      viewModel = nil
    }
  }

  private func handleArrowKey(direction: FinderNavigationDirection) {
    if shouldHandleGlobalNavigationKeys {
      return
    }
    navigateManually(direction: direction)
  }

  private func handlePreviewKeyEvent(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53:
      dismiss(saving: false)
      return true
    case 49, 36, 76:
      dismiss(saving: true)
      return true
    case 123:
      handleArrowKey(direction: .left)
      return !shouldHandleGlobalNavigationKeys
    case 126:
      handleArrowKey(direction: .up)
      return !shouldHandleGlobalNavigationKeys
    case 124:
      handleArrowKey(direction: .right)
      return !shouldHandleGlobalNavigationKeys
    case 125:
      handleArrowKey(direction: .down)
      return !shouldHandleGlobalNavigationKeys
    default:
      return false
    }
  }

  private func followFinderSelectionIfNeeded() {
    guard !isDismissing, !isFollowingSelection, !isNavigating else { return }
    guard imagePanel?.isVisible == true, let viewModel else { return }

    let currentPath = viewModel.sourceURL.standardizedFileURL.path

    Task.detached { [weak self] in
      guard let self else { return }
      guard case .success(let url) = FinderService.selectedFileURL() else { return }
      guard ImageFormatValidator.isSupportedImage(url: url) else { return }
      guard url.standardizedFileURL.path != currentPath else { return }
      await self.adoptFinderSelection(url)
    }
  }

  @MainActor
  private func adoptFinderSelection(_ url: URL) async {
    guard !isDismissing, let viewModel else { return }
    guard url.standardizedFileURL.path != viewModel.sourceURL.standardizedFileURL.path else { return }

    isFollowingSelection = true
    defer { isFollowingSelection = false }

    guard await commitCurrentImage() else { return }
    viewModel.load(url: url)
    applyLayout(animated: true)
    updateCurvePanelVisibility()
  }

  private func navigateManually(direction: FinderNavigationDirection) {
    guard let viewModel, !isNavigating else { return }
    let currentURL = viewModel.sourceURL

    Task { @MainActor in
      isNavigating = true
      defer { isNavigating = false }

      guard await commitCurrentImage() else { return }

      let neighborResult = await Task.detached {
        FinderService.spatialNeighbor(of: currentURL, direction: direction)
      }.value

      guard case .success(let nextURL) = neighborResult else { return }

      _ = await Task.detached {
        FinderService.selectItem(at: nextURL)
      }.value

      viewModel.load(url: nextURL)
      applyLayout(animated: true)
      updateCurvePanelVisibility()
    }
  }

  @MainActor
  private func commitCurrentImage() async -> Bool {
    guard let viewModel else { return true }
    guard viewModel.hasUnsavedChanges else { return true }

    do {
      try await viewModel.commitToDisk()
      return true
    } catch {
      presentAlert(
        title: "Could Not Save Image",
        message: error.localizedDescription
      )
      return false
    }
  }

  private func layout(for viewModel: PreviewViewModel) -> PreviewWindowLayout.CombinedLayout {
    PreviewWindowLayout.combinedLayout(
      imagePixelSize: viewModel.imagePixelSize,
      showsCurvePanel: viewModel.showsCurveTool,
      curvePanelSize: Self.curvePanelSize,
      curveGap: Self.curveGap,
      rotateToolbarHeight: PreviewWindowLayout.rotateToolbarHeight
    )
  }

  private func applyLayout(animated: Bool) {
    guard let viewModel, let imagePanel else { return }
    let layout = layout(for: viewModel)

    imagePanel.setFrame(layout.imagePanelFrame, display: true, animate: animated)

    if let curveFrame = layout.curvePanelFrame {
      if curvePanel == nil {
        curvePanel = makePanel(
          size: curveFrame.size,
          rootView: CurvePanelView(viewModel: viewModel),
          canBecomeKey: false,
          isMovableByBackground: false
        )
      }
      curvePanel?.setFrame(curveFrame, display: true, animate: animated)
      attachCurvePanelIfNeeded()
    } else {
      detachCurvePanel()
      curvePanel = nil
    }
  }

  private func makePanel<Content: View>(
    size: NSSize,
    rootView: Content,
    canBecomeKey: Bool,
    isMovableByBackground: Bool
  ) -> ToneCurvePanel {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)

    let visualEffect = NSVisualEffectView(frame: hostingView.bounds)
    visualEffect.material = .hudWindow
    visualEffect.blendingMode = .behindWindow
    visualEffect.state = .active
    visualEffect.wantsLayer = true
    visualEffect.layer?.cornerRadius = 12
    visualEffect.layer?.masksToBounds = true
    visualEffect.autoresizingMask = [.width, .height]
    visualEffect.addSubview(hostingView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
    ])

    let panel = ToneCurvePanel(
      contentRect: NSRect(origin: .zero, size: size),
      isMovableByBackground: isMovableByBackground
    )
    panel.allowsKeyboardFocus = canBecomeKey
    panel.onKeyEvent = { [weak self] event in
      self?.handlePreviewKeyEvent(event) == true
    }
    panel.contentView = visualEffect
    return panel
  }

  private func attachCurvePanelIfNeeded() {
    guard let imagePanel, let curvePanel, viewModel?.showsCurveTool == true else { return }
    if curvePanel.parent === imagePanel { return }
    imagePanel.addChildWindow(curvePanel, ordered: .above)
    curvePanel.orderFront(nil)
  }

  private func detachCurvePanel() {
    guard let imagePanel, let curvePanel else { return }
    if curvePanel.parent === imagePanel {
      imagePanel.removeChildWindow(curvePanel)
    }
    curvePanel.orderOut(nil)
  }

  private func updateCurvePanelVisibility() {
    guard let viewModel else { return }

    if viewModel.showsCurveTool {
      applyLayout(animated: true)
    } else {
      detachCurvePanel()
      curvePanel = nil
    }
  }

  private func installMonitors() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handlePreviewKeyEvent(event) ? nil : event
    }

    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return }
      guard self.imagePanel?.isVisible == true else { return }
      _ = self.handlePreviewKeyEvent(event)
    }

    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      guard let self else { return }
      let screenPoint = NSEvent.mouseLocation
      if !self.containsPanel(at: screenPoint) {
        self.dismiss(saving: true)
      }
    }

    startFinderSelectionObservation()
  }

  private func startFinderSelectionObservation() {
    finderSelectionTimer?.invalidate()
    previousKeyStates = [:]

    let timer = Timer(
      timeInterval: Self.selectionPollInterval,
      repeats: true
    ) { [weak self] _ in
      self?.pollFinderNavigation()
    }
    RunLoop.main.add(timer, forMode: .common)
    finderSelectionTimer = timer
  }

  private func pollFinderNavigation() {
    guard imagePanel?.isVisible == true else { return }

    pollDismissKeys()
    pollArrowKeys()
    followFinderSelectionIfNeeded()
  }

  private func pollDismissKeys() {
    guard shouldHandleGlobalNavigationKeys else { return }

    if keyDidPress(53) {
      dismiss(saving: false)
      return
    }

    let pressedSpace = keyDidPress(49)
    let pressedReturn = keyDidPress(36)
    let pressedKeypadEnter = keyDidPress(76)
    if pressedSpace || pressedReturn || pressedKeypadEnter {
      dismiss(saving: true)
    }
  }

  private func pollArrowKeys() {
    guard imagePanel?.isVisible == true else { return }

    let mappings: [(CGKeyCode, FinderNavigationDirection)] = [
      (123, .left),
      (124, .right),
      (125, .down),
      (126, .up),
    ]

    for (keyCode, direction) in mappings where keyDidPress(keyCode) {
      if shouldHandleGlobalNavigationKeys {
        followFinderSelectionIfNeeded()
      } else {
        handleArrowKey(direction: direction)
      }
      return
    }
  }

  private func keyDidPress(_ keyCode: CGKeyCode) -> Bool {
    let isPressed = CGEventSource.keyState(.combinedSessionState, key: keyCode)
    let wasPressed = previousKeyStates[keyCode] ?? false
    previousKeyStates[keyCode] = isPressed
    return isPressed && !wasPressed
  }

  private func containsPanel(at screenPoint: NSPoint) -> Bool {
    if let imagePanel, imagePanel.frame.contains(screenPoint) { return true }
    if let curvePanel, curvePanel.isVisible, curvePanel.frame.contains(screenPoint) { return true }
    return false
  }

  private var shouldHandleGlobalNavigationKeys: Bool {
    guard imagePanel?.isVisible == true else { return false }
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
  }

  private func presentAlert(title: String, message: String) {
    NSSound.beep()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func dismissMonitors() {
    finderSelectionTimer?.invalidate()
    finderSelectionTimer = nil
    previousKeyStates = [:]

    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
      self.globalKeyMonitor = nil
    }
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
  }

  private func dismissPanels() {
    detachCurvePanel()
    imagePanel?.orderOut(nil)
    curvePanel?.orderOut(nil)
    imagePanel = nil
    curvePanel = nil
  }
}
