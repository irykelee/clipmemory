import AppKit
import Carbon.HIToolbox
import os.log

class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var showWindowHandler: (() -> Void)?
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "HotKeyManager")

    init() {}

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.showWindowHandler?()
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
        if handlerStatus != noErr {
            logger.error("Failed to install keyboard event handler: \(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5050), id: 1)
        let keyCode: UInt32 = UInt32(kVK_ANSI_V)
        let modifiers: UInt32 = UInt32(cmdKey | controlKey)

        let hotKeyStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if hotKeyStatus != noErr {
            logger.error("Failed to register hotkey Cmd+Ctrl+V: \(hotKeyStatus)")
        }
    }

    func setShowWindowHandler(_ handler: @escaping () -> Void) {
        self.showWindowHandler = handler
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
