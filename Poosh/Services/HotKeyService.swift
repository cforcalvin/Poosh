import AppKit
import Carbon
import os

final class HotKeyService {
    private static let logger = Logger(subsystem: "com.poosh.Poosh", category: "HotKey")
    private static let hotKeySignature: OSType = 0x504F_4F53 // 'POOS'
    private static let hotKeyCarbonID: UInt32 = 1

    private static var eventHandlerRef: EventHandlerRef?
    private static var registeredService: HotKeyService?

    private var hotKeyRef: EventHotKeyRef?

    var onHotKey: (() -> Void)?

    func register() {
        unregister()

        Self.registeredService = self
        Self.installEventHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyCarbonID)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey) | UInt32(shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, hotKeyRef != nil else {
            Self.logger.error("RegisterEventHotKey failed with status \(status)")
            unregister()
            return
        }

        Self.logger.info("Registered Cmd+Shift+Space global hotkey")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if Self.registeredService === self {
            Self.registeredService = nil
        }
    }

    deinit {
        unregister()
    }

    fileprivate static func handleHotKeyPressed() {
        guard let service = registeredService else { return }
        DispatchQueue.main.async {
            service.onHotKey?()
        }
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            2,
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

private func hotKeyEventHandler(
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

    guard hotKeyID.signature == 0x504F_4F53,
          hotKeyID.id == 1,
          GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
        return OSStatus(eventNotHandledErr)
    }

    HotKeyService.handleHotKeyPressed()
    return noErr
}
