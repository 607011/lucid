import Carbon.HIToolbox
import Foundation

/// Registers a single **global** keyboard shortcut using the classic
/// Carbon Event Manager (`RegisterEventHotKey`). Unlike
/// `NSEvent.addGlobalMonitorForEvents`, this works regardless of which
/// app is frontmost and does not require the user to grant Accessibility
/// / Input Monitoring permission.
final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void

    private static let signature: OSType = {
        // Four-character code identifying this app's hot keys ("LcdS").
        let bytes: [UInt8] = Array("LcdS".utf8)
        return bytes.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    /// - Parameters:
    ///   - keyCode: A Carbon virtual key code, e.g. `kVK_ANSI_L`.
    ///   - modifiers: A combination of Carbon modifier flags, e.g.
    ///     `UInt32(controlKey | optionKey | cmdKey)`.
    ///   - handler: Called on the main thread whenever the shortcut fires.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handler()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
