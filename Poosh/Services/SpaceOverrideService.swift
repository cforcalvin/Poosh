import AppKit
import Carbon
import os

/// Registers an unmodified Space Carbon hotkey while Finder is frontmost,
/// so Space opens Poosh instead of Quick Look. Unregisters in other apps
/// so Space still types normally elsewhere.
final class SpaceOverrideService {
  private static let logger = Logger(subsystem: "com.poosh.Poosh", category: "SpaceOverride")
  private static let hotKeySignature: OSType = 0x504F_5350 // 'POSP'
  private static let hotKeyCarbonID: UInt32 = 1

  private static var eventHandlerRef: EventHandlerRef?
  private static var registeredService: SpaceOverrideService?

  private var spaceHotKeyRef: EventHotKeyRef?
  private var activationObserver: NSObjectProtocol?

  /// Called on the main queue when Space should open or dismiss Poosh.
  var onSpace: (() -> Void)?

  func start() {
    stop()
    Self.registeredService = self
    Self.installEventHandlerIfNeeded()

    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.updateRegistration(for: notification)
    }

    updateRegistrationForFrontmostApp()
  }

  func stop() {
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
      self.activationObserver = nil
    }
    unregisterSpaceHotKey()
    if Self.registeredService === self {
      Self.registeredService = nil
    }
  }

  deinit {
    stop()
  }

  private func updateRegistration(for notification: Notification) {
    let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
      .bundleIdentifier
    setSpaceHotKeyRegistered(bundleID == "com.apple.finder")
  }

  private func updateRegistrationForFrontmostApp() {
    let isFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    setSpaceHotKeyRegistered(isFinder)
  }

  private func setSpaceHotKeyRegistered(_ shouldRegister: Bool) {
    if shouldRegister {
      registerSpaceHotKey()
    } else {
      unregisterSpaceHotKey()
    }
  }

  private func registerSpaceHotKey() {
    guard spaceHotKeyRef == nil else { return }

    var hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyCarbonID)
    let status = RegisterEventHotKey(
      UInt32(kVK_Space),
      0,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &spaceHotKeyRef
    )

    guard status == noErr, spaceHotKeyRef != nil else {
      Self.logger.error("RegisterEventHotKey(Space) failed with status \(status)")
      spaceHotKeyRef = nil
      return
    }

    Self.logger.info("Registered Finder Space override hotkey")
  }

  private func unregisterSpaceHotKey() {
    if let spaceHotKeyRef {
      UnregisterEventHotKey(spaceHotKeyRef)
      self.spaceHotKeyRef = nil
      Self.logger.info("Unregistered Finder Space override hotkey")
    }
  }

  fileprivate static func handleSpacePressed() {
    guard let service = registeredService else { return }
    DispatchQueue.main.async {
      service.onSpace?()
    }
  }

  private static func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }

    var eventTypes = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    ]

    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      spaceOverrideEventHandler,
      1,
      &eventTypes,
      nil,
      &eventHandlerRef
    )

    guard status == noErr else {
      logger.error("InstallEventHandler failed with status \(status)")
      eventHandlerRef = nil
      return
    }
  }
}

private func spaceOverrideEventHandler(
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

  guard hotKeyID.signature == 0x504F_5350,
        hotKeyID.id == 1,
        GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
    return OSStatus(eventNotHandledErr)
  }

  SpaceOverrideService.handleSpacePressed()
  return noErr
}
