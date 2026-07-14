import AppKit
import SwiftUI
import CoreGraphics

final class PanelController {
  private static let curveGap: CGFloat = 16
  private static let curvePanelSize = NSSize(width: 320, height: 300)
  /// Arrow / Esc polling — must stay snappy; do NOT run AppleScript on this interval.
  private static let keyPollInterval: TimeInterval = 0.05
  /// How often we may ask Finder what is selected (expensive AppleScript).
  private static let finderFollowInterval: TimeInterval = 5.0

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
  private var pendingNavigationDirection: FinderNavigationDirection?
  private var suppressFinderFollowUntil = Date.distantPast
  private var lastFinderFollowCheck = Date.distantPast
  private var lastArrowHandledAt = Date.distantPast
  private var finderSelectTask: Task<Void, Never>?
  private var arrowFollowTask: Task<Void, Never>?
  private static let arrowDebounce: TimeInterval = 0.09

  /// In-memory neighbor list — arrows never call AppleScript once this is loaded.
  private var browseLayout: FinderBrowseLayout?

  var isPresented: Bool {
    imagePanel?.isVisible == true
  }

  func present(url: URL) {
    present(url: url, preserveBrowseLayout: false, activateFinder: true)
  }

  /// Fresh panel present — Space / hotkey open path.
  private func present(
    url: URL,
    preserveBrowseLayout: Bool,
    activateFinder: Bool
  ) {
    dismissMonitors()
    dismissPanels()
    pendingNavigationDirection = nil
    viewModel = nil

    if !preserveBrowseLayout || browseLayout == nil || browseLayout?.contains(url) != true {
      browseLayout = FinderService.browseLayoutFromDisk(around: url)
    }

    let viewModel = PreviewViewModel(url: url)
    viewModel.onNeedsLayout = { [weak self] in
      // Instant frame change — animating aspect-ratio shifts felt sluggish when browsing.
      // AppKit window frames must be updated on the main thread.
      if Thread.isMainThread {
        self?.applyLayout(animated: false)
      } else {
        DispatchQueue.main.async { self?.applyLayout(animated: false) }
      }
    }
    self.viewModel = viewModel

    let layout = layout(for: viewModel)
    let imagePanel = makePanel(
      size: layout.imagePanelFrame.size,
      rootView: ImagePanelView(viewModel: viewModel),
      canBecomeKey: false,
      isMovableByBackground: viewModel.contentMode == .editableImage
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

    // Show panel first — do not block on Finder AppleScript.
    imagePanel.orderFront(nil)
    Task { @MainActor in await viewModel.loadContent() }
    prefetchNeighbors(around: url)

    if activateFinder {
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = FinderService.activateFinder()
      }
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
      finderSelectTask?.cancel()
      arrowFollowTask?.cancel()
      browseLayout = nil
      dismissMonitors()
      dismissPanels()
      viewModel = nil
    }
  }

  private func handleArrowKey(direction: FinderNavigationDirection) {
    let now = Date()
    // Global monitors often miss arrows (Finder eats them); key-state polling catches them.
    // Debounce so monitor + poll never double-advance.
    guard now.timeIntervalSince(lastArrowHandledAt) >= Self.arrowDebounce else { return }
    lastArrowHandledAt = now
    // Finder already moves selection spatially (real up/down). Follow that so
    // preview stays matched to Finder instead of inventing filename-order neighbors.
    adoptFinderSelectionAfterArrow(direction: direction)
  }

  /// After Finder processes the arrow, mirror its selection into the preview.
  private func adoptFinderSelectionAfterArrow(direction: FinderNavigationDirection) {
    suppressFinderFollowUntil = Date().addingTimeInterval(5.0)
    let previousPath = viewModel?.sourceURL.standardizedFileURL.path
    arrowFollowTask?.cancel()
    arrowFollowTask = Task { @MainActor [weak self] in
      // Brief pause so Finder can update selection before we ask.
      try? await Task.sleep(nanoseconds: 40_000_000)
      guard !Task.isCancelled, let self else { return }

      let selected = await Task.detached(priority: .userInitiated) {
        FinderService.selectedFileURL()
      }.value
      guard !Task.isCancelled else { return }

      if case .success(let url) = selected,
         ImageFormatValidator.canPreview(url: url),
         url.standardizedFileURL.path != previousPath {
        if self.viewModel?.hasUnsavedChanges == true {
          guard await self.commitCurrentImage() else { return }
        }
        self.showURL(url)
        return
      }

      self.navigateManually(direction: direction)
    }
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
      return true
    case 126:
      handleArrowKey(direction: .up)
      return true
    case 124:
      handleArrowKey(direction: .right)
      return true
    case 125:
      handleArrowKey(direction: .down)
      return true
    default:
      return false
    }
  }

  private func followFinderSelectionIfNeeded() {
    // AppleScript must never run on the main thread — it was freezing arrows for seconds.
    guard !isDismissing, !isFollowingSelection, !isNavigating else { return }
    guard Date() >= suppressFinderFollowUntil else { return }
    guard Date().timeIntervalSince(lastFinderFollowCheck) >= Self.finderFollowInterval else { return }
    lastFinderFollowCheck = Date()
    guard imagePanel?.isVisible == true, let viewModel else { return }

    let currentPath = viewModel.sourceURL.standardizedFileURL.path

    Task.detached(priority: .utility) { [weak self] in
      let result = FinderService.selectedFileURL()
      guard case .success(let url) = result else { return }
      await MainActor.run {
        guard let self else { return }
        guard !self.isDismissing, !self.isFollowingSelection, !self.isNavigating else { return }
        guard Date() >= self.suppressFinderFollowUntil else { return }
        guard ImageFormatValidator.canPreview(url: url) else { return }
        guard url.standardizedFileURL.path != currentPath else { return }
        Task { @MainActor in
          await self.adoptFinderSelection(url)
        }
      }
    }
  }

  @MainActor
  private func adoptFinderSelection(_ url: URL) async {
    guard !isDismissing, let viewModel else { return }
    guard url.standardizedFileURL.path != viewModel.sourceURL.standardizedFileURL.path else { return }

    isFollowingSelection = true
    defer { isFollowingSelection = false }

    guard await commitCurrentImage() else { return }
    suppressFinderFollowUntil = Date().addingTimeInterval(5.0)
    showURL(url)
  }

  private func navigateManually(direction: FinderNavigationDirection) {
    guard let viewModel else { return }


    if browseLayout == nil || browseLayout?.contains(viewModel.sourceURL) != true {
      browseLayout = FinderService.browseLayoutFromDisk(around: viewModel.sourceURL)
    }

    guard let nextURL = browseLayout?.neighbor(of: viewModel.sourceURL, direction: direction) else {
      return
    }

    // Dirty images must save first (async). Clean images swap in-place (no panel tear-down flicker).
    if viewModel.hasUnsavedChanges {
      if isNavigating {
        pendingNavigationDirection = direction
        return
      }
      isNavigating = true
      Task { @MainActor in
        defer {
          self.isNavigating = false
          if let pending = self.pendingNavigationDirection {
            self.pendingNavigationDirection = nil
            self.navigateManually(direction: pending)
          }
        }
        guard await self.commitCurrentImage() else { return }
        self.suppressFinderFollowUntil = Date().addingTimeInterval(5.0)
        self.showURL(nextURL)
        self.syncFinderSelection(to: nextURL)
      }
      return
    }

    suppressFinderFollowUntil = Date().addingTimeInterval(5.0)
    showURL(nextURL)
    syncFinderSelection(to: nextURL)
  }

  /// In-place image swap — keeps the same panels so arrow browse does not flicker.
  private func showURL(_ url: URL) {
    guard let viewModel else {
      present(url: url, preserveBrowseLayout: true, activateFinder: false)
      return
    }

    let previousMode = viewModel.contentMode
    viewModel.load(url: url)
    // Full chrome rebuild only when content kind changes (image ↔ PDF/media).
    if previousMode != viewModel.contentMode {
      present(url: url, preserveBrowseLayout: true, activateFinder: false)
      return
    }

    imagePanel?.isMovableByWindowBackground = viewModel.contentMode == .editableImage
    applyLayout(animated: false)
    updateCurvePanelVisibility()
    prefetchNeighbors(around: url)
  }

  /// Fallback path only: push Finder selection when we invented the neighbor ourselves.
  private func syncFinderSelection(to url: URL) {
    suppressFinderFollowUntil = Date().addingTimeInterval(5.0)
    finderSelectTask?.cancel()
    let path = url.lastPathComponent
    finderSelectTask = Task.detached(priority: .utility) {
      let result = FinderService.selectItem(at: url, reveal: false)
      let ok: Bool
      if case .success = result { ok = true } else { ok = false }
    }
  }

  private func prefetchNeighbors(around url: URL) {
    guard let browseLayout else { return }
    let count = PreviewWindowLayout.prefetchNeighborCount
    var urls: [URL] = []
    var cursor = url
    for direction in [FinderNavigationDirection.left, .right, .up, .down] {
      cursor = url
      for _ in 0..<count {
        guard let next = browseLayout.neighbor(of: cursor, direction: direction) else { break }
        urls.append(next)
        cursor = next
      }
    }
    let neighbors = Array(Set(urls.map { $0.standardizedFileURL })).filter {
      ImageFormatValidator.isEditableImage(url: $0)
    }

    // Do not cancel prior prefetches — overlapping work just hits the cache and returns.
    Task.detached(priority: .utility) {
      for neighbor in neighbors {
        // Warm iCloud without blocking paint on the current image.
        try? FileManager.default.startDownloadingUbiquitousItem(at: neighbor)
        if PreviewImageCache.image(for: neighbor) != nil { continue }
        let master: URL = {
          if let entry = EditLibrary.entry(for: neighbor) { return entry.originalURL }
          return neighbor
        }()
        if let image = ImageProcessor.loadThumbnail(
          url: master,
          maxPixelSize: PreviewWindowLayout.fastPreviewPixels
        ) {
          PreviewImageCache.store(
            image,
            for: neighbor,
            pixelSize: CGSize(width: image.width, height: image.height)
          )
        }
      }
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
      rotateToolbarHeight: viewModel.showsRotateControls
        ? PreviewWindowLayout.rotateToolbarHeight
        : 0
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
      applyLayout(animated: false)
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
      timeInterval: Self.keyPollInterval,
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
    // Arrows: CGEventSource polling — NSEvent global monitors never received arrows
    // in production (selection only updated via Finder follow every 5s).
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
    // When Finder is frontmost, arrows move Finder selection — we must navigate Poosh
    // on the same press via key-state, not wait for AppleScript follow.
    guard shouldHandleGlobalNavigationKeys else { return }

    let mappings: [(CGKeyCode, FinderNavigationDirection)] = [
      (123, .left),
      (124, .right),
      (125, .down),
      (126, .up),
    ]

    for (keyCode, direction) in mappings where keyDidPress(keyCode) {
      handleArrowKey(direction: direction)
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
