import AppKit
import SwiftUI
import CoreGraphics
import Carbon
import os

final class PanelController {
  private static let logger = Logger(subsystem: "com.poosh.Poosh", category: "Panel")
  private static let curveGap: CGFloat = 16
  private static let curvePanelSize = NSSize(width: 320, height: 300)
  /// Arrow / Esc polling — must stay snappy; do NOT run AppleScript on this interval.
  private static let keyPollInterval: TimeInterval = 0.05
  /// How often we may ask Finder what is selected (expensive AppleScript).
  private static let finderFollowInterval: TimeInterval = 5.0
  private static let zoomHotKeySignature: OSType = 0x504F_5A4D // 'POZM'

  private var imagePanel: ToneCurvePanel?
  private var curvePanel: ToneCurvePanel?
  private var viewModel: PreviewViewModel?
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var globalMouseMonitor: Any?
  private var localScrollMonitor: Any?
  private var globalScrollMonitor: Any?
  private var localMagnifyMonitor: Any?
  private var globalMagnifyMonitor: Any?
  private var magnifyEventTap: CFMachPort?
  private var magnifyRunLoopSource: CFRunLoopSource?
  private var didPromptAccessibility = false
  private var didPromptListenEvent = false
  private var zoomHotKeyRefs: [EventHotKeyRef] = []
  private var zoomHotKeyHandlerRef: EventHandlerRef?
  private var zoomActivationObserver: NSObjectProtocol?
  private static weak var zoomHotKeyOwner: PanelController?
  private static weak var magnifyTapOwner: PanelController?
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
    // Stay "presented" through async dismiss so a lagged Space hotkey cannot reopen.
    isDismissing || imagePanel?.isVisible == true
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
      // Upgrade to Finder's spatial icon layout when Automation allows it.
      let around = url
      Task.detached(priority: .utility) { [weak self] in
        let result = FinderService.browseLayout(around: around)
        await MainActor.run {
          guard let self, case .success(let layout) = result else { return }
          guard self.imagePanel?.isVisible == true else { return }
          self.browseLayout = layout
        }
      }
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
      isMovableByBackground: false,
      enableTrackpadZoom: viewModel.contentMode == .editableImage
    )
    imagePanel.setFrame(layout.imagePanelFrame, display: false)
    self.imagePanel = imagePanel

    if viewModel.showsCurveTool, let curveFrame = layout.curvePanelFrame {
      let curvePanel = makePanel(
        size: curveFrame.size,
        rootView: CurvePanelView(viewModel: viewModel),
        canBecomeKey: false,
        isMovableByBackground: false,
        enableTrackpadZoom: false
      )
      curvePanel.setFrame(curveFrame, display: false)
      self.curvePanel = curvePanel
    }

    attachCurvePanelIfNeeded()

    // Paint before the panel appears — matches arrow-path sync paint; avoids empty first frame.
    viewModel.paintInitialContent()
    applyLayout(animated: false)

    // Never makeKey — Finder must keep arrows for spatial selection.
    imagePanel.orderFront(nil)
    // Monitors after first frame so Space/Esc can run before event-tap setup finishes.
    DispatchQueue.main.async { [weak self] in
      self?.installMonitors()
    }
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
    // Finder already moves selection spatially. Follow that — never steal key focus.
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
    // Esc: cancel crop / color-adjust, or dismiss without saving in normal mode.
    if event.keyCode == 53 {
      if viewModel?.isCropping == true {
        viewModel?.cancelCropping()
      } else if viewModel?.isColorAdjusting == true {
        viewModel?.cancelColorAdjusting()
      } else {
        dismiss(saving: false)
      }
      return true
    }

    // Quick Look–style zoom: ⌘+ / ⌘= / ⌘− / ⌘0
    // (Carbon hotkeys also register these while Finder is frontmost so Finder never zooms icons.)
    if handleZoomKeyEvent(event) {
      return true
    }

    if handleEditToolKeyEvent(
      modifiers: event.modifierFlags,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    ) {
      return true
    }

    // Crop / color-adjust: Enter applies; all other keys (except Esc above) are swallowed.
    if viewModel?.isCropping == true {
      if event.keyCode == 36 || event.keyCode == 76 {
        viewModel?.applyDraftCrop()
      }
      return true
    }
    if viewModel?.isColorAdjusting == true {
      if event.keyCode == 36 || event.keyCode == 76 {
        viewModel?.applyColorAdjust()
      }
      return true
    }

    switch event.keyCode {
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

  /// Unmodified letter shortcuts: B = black & white, C = crop.
  private func handleEditToolKeyEvent(
    modifiers: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    let mods = modifiers.intersection(.deviceIndependentFlagsMask)
    guard !mods.contains(.command),
          !mods.contains(.option),
          !mods.contains(.control),
          viewModel?.contentMode == .editableImage else {
      return false
    }

    switch charactersIgnoringModifiers?.lowercased() {
    case "c":
      guard viewModel?.isCropping != true, viewModel?.isColorAdjusting != true else { return true }
      viewModel?.beginCropping()
      return true
    case "b":
      guard viewModel?.isCropping != true, viewModel?.isColorAdjusting != true else { return false }
      viewModel?.toggleBlackAndWhite()
      return true
    default:
      return false
    }
  }

  private func handleZoomKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.contains(.command),
          !modifiers.contains(.option),
          !modifiers.contains(.control),
          viewModel?.contentMode == .editableImage,
          viewModel?.isCropping != true,
          viewModel?.isColorAdjusting != true else {
      return false
    }

    switch event.keyCode {
    case 24, 69: // = / keypad +
      viewModel?.requestZoom(.zoomIn)
      return true
    case 27, 78: // - / keypad -
      viewModel?.requestZoom(.zoomOut)
      return true
    case 29: // 0
      viewModel?.requestZoom(.reset)
      return true
    default:
      break
    }

    if let chars = event.charactersIgnoringModifiers {
      switch chars {
      case "+", "=":
        viewModel?.requestZoom(.zoomIn)
        return true
      case "-", "−":
        viewModel?.requestZoom(.zoomOut)
        return true
      case "0":
        viewModel?.requestZoom(.reset)
        return true
      default:
        break
      }
    }
    return false
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

    imagePanel?.isMovableByWindowBackground = false
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
    let targetPixels = PreviewWindowLayout.maxPreviewPixels

    // Do not cancel prior prefetches — overlapping work just hits the cache and returns.
    Task.detached(priority: .utility) {
      for neighbor in neighbors {
        // Warm iCloud without blocking paint on the current image.
        try? FileManager.default.startDownloadingUbiquitousItem(at: neighbor)
        if let existing = PreviewImageCache.entry(for: neighbor) {
          let longEdge = max(existing.image.width, existing.image.height)
          if CGFloat(longEdge) >= targetPixels - 1 { continue }
        }
        let master: URL = {
          if let entry = EditLibrary.entry(for: neighbor) { return entry.originalURL }
          return neighbor
        }()
        if let image = ImageProcessor.loadThumbnail(
          url: master,
          maxPixelSize: targetPixels
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
          isMovableByBackground: false,
          enableTrackpadZoom: false
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
    isMovableByBackground: Bool,
    enableTrackpadZoom: Bool
  ) -> ToneCurvePanel {
    let hostingView: NSView = enableTrackpadZoom
      ? TrackpadHostingView(rootView: rootView)
      : NSHostingView(rootView: rootView)
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
      let keyCode = event.keyCode
      let modifiers = event.modifierFlags
      let characters = event.charactersIgnoringModifiers
      DispatchQueue.main.async {
        self.handlePreviewKeyEventCaptured(
          keyCode: keyCode,
          modifiers: modifiers,
          charactersIgnoringModifiers: characters
        )
      }
    }

    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      guard let self else { return }
      let screenPoint = NSEvent.mouseLocation
      DispatchQueue.main.async {
        if !self.containsPanel(at: screenPoint) {
          self.dismiss(saving: true)
        }
      }
    }

    // Two-finger slide → pan when zoomed. Never scroll-zoom.
    localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      let mouse = NSEvent.mouseLocation
      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY
      guard let imagePanel,
            imagePanel.isVisible,
            self.isTrackpadZoomContext(at: mouse),
            self.viewModel?.contentMode == .editableImage,
            self.viewModel?.isCropping != true,
            self.viewModel?.isColorAdjusting != true else {
        return event
      }
      guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return event }
      let handled = self.handleTrackpadScrollCaptured(
        deltaX: dx,
        deltaY: dy,
        mouseLocation: mouse
      )
      return handled ? nil : event
    }

    globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY
      let mouse = NSEvent.mouseLocation
      DispatchQueue.main.async {
        guard let self else { return }
        _ = self.handleTrackpadScrollCaptured(
          deltaX: dx,
          deltaY: dy,
          mouseLocation: mouse
        )
      }
    }

    // Thumb+index only: NSEventTypeMagnify. No touch-distance (index+middle) zoom.
    localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
      guard let self else { return event }
      let mag = event.magnification
      self.handleTrackpadMagnifyCaptured(
        magnification: mag,
        mouseLocation: NSEvent.mouseLocation
      )
      return event
    }

    globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
      let mag = event.magnification
      let mouse = NSEvent.mouseLocation
      DispatchQueue.main.async {
        guard let self else { return }
        self.handleTrackpadMagnifyCaptured(magnification: mag, mouseLocation: mouse)
      }
    }

    installTrackpadEventTap()
    installZoomHotKeys()
    startFinderSelectionObservation()
  }

  /// Two-finger slide pans while zoomed. Scroll never zooms.
  @discardableResult
  private func handleTrackpadScrollCaptured(
    deltaX: CGFloat,
    deltaY: CGFloat,
    mouseLocation: NSPoint
  ) -> Bool {
    guard isTrackpadZoomContext(at: mouseLocation) else {
      return false
    }

    let scale = viewModel?.imageScale ?? 1
    guard scale > 1.01 else {
      return false
    }

    guard abs(deltaX) > 0.001 || abs(deltaY) > 0.001 else { return false }
    let dx = deltaX
    let dy = deltaY
    DispatchQueue.main.async { [weak self] in
      self?.viewModel?.applyTrackpadPan(deltaX: dx, deltaY: dy)
    }
    return true
  }

  private func handleTrackpadMagnifyCaptured(magnification: CGFloat, mouseLocation: NSPoint) {
    let apply = { [weak self] in
      guard let self else { return }
      guard self.isTrackpadZoomContext(at: mouseLocation) else { return }
      guard abs(magnification) > 0.0001 else { return }
      let mag = min(max(magnification, -0.95), 0.95)
      self.viewModel?.applyPinchMagnification(mag)
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  /// True when the pointer is over the image panel (not the curve HUD).
  private func isTrackpadZoomContext(at mouseLocation: NSPoint) -> Bool {
    guard imagePanelFrameContains(mouseLocation) else { return false }
    guard viewModel?.contentMode == .editableImage else { return false }
    guard viewModel?.isCropping != true else { return false }
    guard viewModel?.isColorAdjusting != true else { return false }
    return true
  }

  private func imagePanelFrameContains(_ point: NSPoint) -> Bool {
    guard let imagePanel, imagePanel.isVisible else { return false }
    return imagePanel.frame.contains(point)
  }

  static func handleMagnifyFromView(
    magnification: CGFloat,
    mouseLocation: NSPoint
  ) {
    magnifyTapOwner?.handleTrackpadMagnifyCaptured(
      magnification: magnification,
      mouseLocation: mouseLocation
    )
  }

  static func handleScrollFromView(
    deltaX: CGFloat,
    deltaY: CGFloat,
    mouseLocation: NSPoint
  ) -> Bool {
    guard let owner = magnifyTapOwner else { return false }
    return owner.handleTrackpadScrollCaptured(
      deltaX: deltaX,
      deltaY: deltaY,
      mouseLocation: mouseLocation
    )
  }

  private static func imagePanelContainsMouse(_ point: NSPoint) -> Bool {
    magnifyTapOwner?.imagePanelFrameContains(point) ?? false
  }

  private static func handleMagnifyFromCGEvent(magnification: CGFloat, mouseLocation: NSPoint) {
    let apply: () -> Void = {
      magnifyTapOwner?.handleTrackpadMagnifyCaptured(
        magnification: magnification,
        mouseLocation: mouseLocation
      )
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  private static func handleScrollFromCGEvent(_ cgEvent: CGEvent) {
    DispatchQueue.main.async {
      let mouse = NSEvent.mouseLocation
      let nsEvent = NSEvent(cgEvent: cgEvent)
      let pointDY = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
      let pointDX = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
      let lineDY = cgEvent.getDoubleValueField(.scrollWheelEventDeltaAxis1)
      let lineDX = cgEvent.getDoubleValueField(.scrollWheelEventDeltaAxis2)
      let dx = nsEvent?.scrollingDeltaX ?? (abs(pointDX) > 0 ? CGFloat(pointDX) : CGFloat(lineDX))
      let dy = nsEvent?.scrollingDeltaY ?? (abs(pointDY) > 0 ? CGFloat(pointDY) : CGFloat(lineDY))
      _ = magnifyTapOwner?.handleTrackpadScrollCaptured(
        deltaX: dx,
        deltaY: dy,
        mouseLocation: mouse
      )
    }
  }

  /// Swallow magnify/scroll over the image panel so Finder doesn't consume the gesture.
  private static func trackpadCGEventCallback(
    _ type: CGEventType,
    _ cgEvent: CGEvent
  ) -> Unmanaged<CGEvent>? {
    // Gesture packets often have a zero or top-left location. The live cursor is
    // in the same bottom-left space as the panel frame (click-outside uses this).
    let mouse = NSEvent.mouseLocation
    let overPanel = imagePanelContainsMouse(mouse)

    let zoomField = CGEventField(rawValue: 113)!
    let kindField = CGEventField(rawValue: 110)!
    // 8 = trackpad pinch. 6 = scroll companion, which must not zoom.
    let kind = cgEvent.getIntegerValueField(kindField)
    let zoom = CGFloat(cgEvent.getDoubleValueField(zoomField))

    if type.rawValue == 30 || (type.rawValue == 29 && kind == 8) {
      let ns = NSEvent(cgEvent: cgEvent)
      let mag = (ns?.type == .magnify && abs(ns?.magnification ?? 0) > 0.0001)
        ? ns!.magnification
        : zoom
      if overPanel, abs(mag) > 0.0001 {
        handleMagnifyFromCGEvent(magnification: mag, mouseLocation: mouse)
        return nil
      }
    } else if type.rawValue == 29 {
      if overPanel, kind != 6, abs(zoom) > 0.00001 {
        handleMagnifyFromCGEvent(magnification: zoom, mouseLocation: mouse)
        return nil
      }
    } else if type == .scrollWheel, overPanel {
      let scale = magnifyTapOwner?.viewModel?.imageScale ?? 1
      if scale > 1.01 {
        handleScrollFromCGEvent(cgEvent)
        return nil
      }
    }

    return Unmanaged.passUnretained(cgEvent)
  }

  /// Applies zoom / edit-tool keys from an event captured off-thread (global monitor).
  private func handlePreviewKeyEventCaptured(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) {
    if handleEditToolKeyEvent(
      modifiers: modifiers,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    ) {
      return
    }

    let mods = modifiers.intersection(.deviceIndependentFlagsMask)
    guard mods.contains(.command),
          !mods.contains(.option),
          !mods.contains(.control),
          viewModel?.contentMode == .editableImage,
          viewModel?.isCropping != true,
          viewModel?.isColorAdjusting != true else {
      return
    }

    switch keyCode {
    case 24, 69:
      viewModel?.requestZoom(.zoomIn)
    case 27, 78:
      viewModel?.requestZoom(.zoomOut)
    case 29:
      viewModel?.requestZoom(.reset)
    default:
      if let chars = charactersIgnoringModifiers {
        switch chars {
        case "+", "=": viewModel?.requestZoom(.zoomIn)
        case "-", "−": viewModel?.requestZoom(.zoomOut)
        case "0": viewModel?.requestZoom(.reset)
        default: break
        }
      }
    }
  }

  private func installTrackpadEventTap() {
    uninstallMagnifyEventTap()
    Self.magnifyTapOwner = self

    let gestureType = CGEventType(rawValue: 29)! // NSEventTypeGesture
    let magnifyType = CGEventType(rawValue: 30)! // NSEventTypeMagnify
    let mask =
      CGEventMask(1 << gestureType.rawValue)
      | CGEventMask(1 << magnifyType.rawValue)
      | CGEventMask(1 << CGEventType.scrollWheel.rawValue)

    // Prefer HID-level tap so trackpad packets are visible even when Finder is key.
    let tapLocation: CGEventTapLocation = .cghidEventTap
    guard let tap = CGEvent.tapCreate(
      tap: tapLocation,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, cgEvent, _ -> Unmanaged<CGEvent>? in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          if let tap = PanelController.magnifyTapOwner?.magnifyEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
          }
          return Unmanaged.passUnretained(cgEvent)
        }

        return PanelController.trackpadCGEventCallback(type, cgEvent)
      },
      userInfo: nil
    ) else {
      // Fallback to session tap if HID tap is unavailable.
      Self.logger.error("HID trackpad tap failed; trying session tap")
      installTrackpadSessionEventTap(mask: mask)
      return
    }

    magnifyEventTap = tap
    magnifyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let magnifyRunLoopSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), magnifyRunLoopSource, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
    // CGEvent taps need Accessibility (and Input Monitoring for the HID tap).
    // Finder stays key, so pinch is intercepted via the tap while the cursor is over the panel.
    let trusted = AXIsProcessTrusted()
    let listenAccess = CGPreflightListenEventAccess()
    if !listenAccess {
      if !didPromptListenEvent {
        didPromptListenEvent = true
        _ = CGRequestListenEventAccess()
        DispatchQueue.main.async {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      startEventTapPermissionPolling()
    }
    if !trusted {
      if !didPromptAccessibility {
        didPromptAccessibility = true
        // Defer prompt/Settings so they never race the first paint frame.
        DispatchQueue.main.async {
          let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
          _ = AXIsProcessTrustedWithOptions(opts)
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      startEventTapPermissionPolling()
    }
    Self.logger.info("Installed HID trackpad CGEvent tap")
  }

  private var accessibilityPollTimer: Timer?

  private func startEventTapPermissionPolling() {
    accessibilityPollTimer?.invalidate()
    accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      guard self.imagePanel?.isVisible == true else { return }
      let trusted = AXIsProcessTrusted()
      let listenOK = CGPreflightListenEventAccess()
      // Reinstall once Accessibility is granted (session tap); HID tap also needs Input Monitoring.
      if trusted {
        timer.invalidate()
        self.accessibilityPollTimer = nil
        self.uninstallMagnifyEventTap()
        self.installTrackpadEventTap()
      }
    }
  }

  private func installTrackpadSessionEventTap(mask: CGEventMask) {
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, cgEvent, _ -> Unmanaged<CGEvent>? in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          if let tap = PanelController.magnifyTapOwner?.magnifyEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
          }
          return Unmanaged.passUnretained(cgEvent)
        }
        return PanelController.trackpadCGEventCallback(type, cgEvent)
      },
      userInfo: nil
    ) else {
      Self.logger.error("Session trackpad tap also failed")
      return
    }
    magnifyEventTap = tap
    magnifyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let magnifyRunLoopSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), magnifyRunLoopSource, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func uninstallMagnifyEventTap() {
    if let magnifyEventTap {
      CGEvent.tapEnable(tap: magnifyEventTap, enable: false)
    }
    if let magnifyRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), magnifyRunLoopSource, .commonModes)
    }
    magnifyRunLoopSource = nil
    magnifyEventTap = nil
    if Self.magnifyTapOwner === self {
      Self.magnifyTapOwner = nil
    }
  }

  private func installZoomHotKeys() {
    uninstallZoomHotKeys()
    Self.zoomHotKeyOwner = self
    installZoomHotKeyHandlerIfNeeded()

    zoomActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateZoomHotKeyRegistration()
    }
    updateZoomHotKeyRegistration()
  }

  private func updateZoomHotKeyRegistration() {
    guard imagePanel?.isVisible == true else {
      unregisterZoomHotKeyRefs()
      return
    }
    // While preview is open and Finder is frontmost, claim keys so Finder
    // (type-select / zoom icons) never receives them.
    let isFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    if isFinder {
      registerZoomHotKeyRefs()
    } else {
      unregisterZoomHotKeyRefs()
    }
  }

  private func installZoomHotKeyHandlerIfNeeded() {
    guard zoomHotKeyHandlerRef == nil else { return }
    var eventTypes = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    ]
    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      panelZoomHotKeyEventHandler,
      1,
      &eventTypes,
      nil,
      &zoomHotKeyHandlerRef
    )
    if status != noErr {
      Self.logger.error("InstallEventHandler(zoom) failed with status \(status)")
      zoomHotKeyHandlerRef = nil
    }
  }

  private func registerZoomHotKeyRefs() {
    guard zoomHotKeyRefs.isEmpty else { return }

    // id 1 = zoom in, 2 = zoom out, 3 = reset, 4 = B&W, 5 = crop
    let specs: [(UInt32, UInt32, UInt32)] = [
      (UInt32(kVK_ANSI_Equal), UInt32(cmdKey), 1),
      (UInt32(kVK_ANSI_Equal), UInt32(cmdKey) | UInt32(shiftKey), 1),
      (UInt32(kVK_ANSI_Minus), UInt32(cmdKey), 2),
      (UInt32(kVK_ANSI_0), UInt32(cmdKey), 3),
      (UInt32(kVK_ANSI_KeypadPlus), UInt32(cmdKey), 1),
      (UInt32(kVK_ANSI_KeypadMinus), UInt32(cmdKey), 2),
      (UInt32(kVK_ANSI_B), 0, 4),
      (UInt32(kVK_ANSI_C), 0, 5),
    ]

    for (keyCode, modifiers, id) in specs {
      var hotKeyID = EventHotKeyID(signature: Self.zoomHotKeySignature, id: id)
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        keyCode,
        modifiers,
        hotKeyID,
        GetEventDispatcherTarget(),
        0,
        &ref
      )
      if status == noErr, let ref {
        zoomHotKeyRefs.append(ref)
      } else {
        Self.logger.error("RegisterEventHotKey(zoom \(id)) failed with status \(status)")
      }
    }
  }

  private func unregisterZoomHotKeyRefs() {
    for ref in zoomHotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    zoomHotKeyRefs.removeAll()
  }

  private func uninstallZoomHotKeys() {
    unregisterZoomHotKeyRefs()
    if let zoomActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(zoomActivationObserver)
      self.zoomActivationObserver = nil
    }
    if let zoomHotKeyHandlerRef {
      RemoveEventHandler(zoomHotKeyHandlerRef)
      self.zoomHotKeyHandlerRef = nil
    }
    if Self.zoomHotKeyOwner === self {
      Self.zoomHotKeyOwner = nil
    }
  }

  fileprivate func handleZoomHotKey(id: UInt32) {
    guard imagePanel?.isVisible == true else { return }
    switch id {
    case 1: viewModel?.requestZoom(.zoomIn)
    case 2: viewModel?.requestZoom(.zoomOut)
    case 3: viewModel?.requestZoom(.reset)
    case 4:
      _ = handleEditToolKeyEvent(modifiers: [], charactersIgnoringModifiers: "b")
    case 5:
      _ = handleEditToolKeyEvent(modifiers: [], charactersIgnoringModifiers: "c")
    default: break
    }
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
    refreshIfCurrentFileMissing()
    followFinderSelectionIfNeeded()
  }

  /// When the open file is deleted in Finder, adopt the new selection immediately
  /// (ignores suppressFinderFollowUntil). Dismiss if nothing previewable remains.
  private func refreshIfCurrentFileMissing() {
    guard !isDismissing, !isFollowingSelection, !isNavigating else { return }
    guard imagePanel?.isVisible == true, let viewModel else { return }

    let currentURL = viewModel.sourceURL
    guard !FileManager.default.fileExists(atPath: currentURL.path) else { return }

    isFollowingSelection = true
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = FinderService.selectedFileURL()
      await MainActor.run {
        guard let self else { return }
        defer { self.isFollowingSelection = false }
        guard !self.isDismissing, self.imagePanel?.isVisible == true else { return }

        if case .success(let url) = result,
           ImageFormatValidator.canPreview(url: url) {
          let selectedPath = url.standardizedFileURL.path
          let missingPath = currentURL.standardizedFileURL.path
          if selectedPath != missingPath {
            self.browseLayout = FinderService.browseLayoutFromDisk(around: url)
            // File is gone — do not attempt to save edits.
            self.showURL(url)
            return
          }
        }

        self.dismiss(saving: false)
      }
    }
  }

  private func pollDismissKeys() {
    guard shouldHandleGlobalNavigationKeys else { return }

    if keyDidPress(53) {
      if viewModel?.isCropping == true {
        viewModel?.cancelCropping()
      } else if viewModel?.isColorAdjusting == true {
        viewModel?.cancelColorAdjusting()
      } else {
        dismiss(saving: false)
      }
      return
    }

    // Space is owned by SpaceOverrideService (open/dismiss toggle). Handling it
    // here races: poll dismisses, then the hotkey sees isPresented==false and reopens.
    let pressedReturn = keyDidPress(36)
    let pressedKeypadEnter = keyDidPress(76)
    if pressedReturn || pressedKeypadEnter {
      if viewModel?.isCropping == true {
        viewModel?.applyDraftCrop()
      } else if viewModel?.isColorAdjusting == true {
        viewModel?.applyColorAdjust()
      } else {
        dismiss(saving: true)
      }
    }
  }

  private func pollArrowKeys() {
    guard imagePanel?.isVisible == true else { return }
    guard viewModel?.isCropping != true else { return }
    guard viewModel?.isColorAdjusting != true else { return }
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
    accessibilityPollTimer?.invalidate()
    accessibilityPollTimer = nil
    previousKeyStates = [:]
    uninstallZoomHotKeys()
    uninstallMagnifyEventTap()

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
    if let localScrollMonitor {
      NSEvent.removeMonitor(localScrollMonitor)
      self.localScrollMonitor = nil
    }
    if let globalScrollMonitor {
      NSEvent.removeMonitor(globalScrollMonitor)
      self.globalScrollMonitor = nil
    }
    if let localMagnifyMonitor {
      NSEvent.removeMonitor(localMagnifyMonitor)
      self.localMagnifyMonitor = nil
    }
    if let globalMagnifyMonitor {
      NSEvent.removeMonitor(globalMagnifyMonitor)
      self.globalMagnifyMonitor = nil
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

private func panelZoomHotKeyEventHandler(
  _ callRef: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }

  var hotKeyID = EventHotKeyID()
  let paramStatus = GetEventParameter(
    event,
    UInt32(kEventParamDirectObject),
    UInt32(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard paramStatus == noErr else { return paramStatus }

  guard hotKeyID.signature == 0x504F_5A4D,
        GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
    return OSStatus(eventNotHandledErr)
  }

  DispatchQueue.main.async {
    PanelController.handleZoomHotKeyFromCarbon(id: hotKeyID.id)
  }
  return noErr
}

extension PanelController {
  fileprivate static func handleZoomHotKeyFromCarbon(id: UInt32) {
    zoomHotKeyOwner?.handleZoomHotKey(id: id)
  }
}
