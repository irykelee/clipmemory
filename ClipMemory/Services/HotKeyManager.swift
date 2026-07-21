import AppKit
import Carbon.HIToolbox
import os.log

/// HotKey configuration stored in UserDefaults
struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultConfig = HotKeyConfig(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))

    private static let keyCodeKey = "HotKeyKeyCode"
    private static let modifiersKey = "HotKeyModifiers"

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: Self.modifiersKey)
    }

    static func load() -> HotKeyConfig {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: keyCodeKey) != nil {
            let modifiersInt = defaults.integer(forKey: modifiersKey)
            let keyCodeInt = defaults.integer(forKey: keyCodeKey)
            // RS-3.4: a persisted modifiers=0 would re-register a bare key
            // (e.g. just "V") as the global hotkey. Negative values would trap
            // on UInt32 conversion. Fall back to defaultConfig for any invalid
            // persisted state.
            guard modifiersInt > 0,
                  keyCodeInt >= 0,
                  keyCodeInt <= 127,
                  let modifiers = UInt32(exactly: modifiersInt),
                  let keyCode = UInt32(exactly: keyCodeInt) else {
                return .defaultConfig
            }
            return HotKeyConfig(keyCode: keyCode, modifiers: modifiers)
        }
        return .defaultConfig
    }

    /// Human-readable description of the hotkey (e.g. "⌘⌃V")
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt32) -> String {
        switch code {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Return): return "⏎"
        case UInt32(kVK_Escape): return "ESC"
        case UInt32(kVK_Delete): return "⌫"
        case UInt32(kVK_Tab): return "⇥"
        default: return "Key \(code)"
        }
    }
}

class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    var hotKeyRef: EventHotKeyRef?
    private var showWindowHandler: (() -> Void)?
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "HotKeyManager")

    private(set) var config: HotKeyConfig = .load()
    /// Whether a registration attempt was made this launch (lets UI read the
    /// outcome without triggering a re-register).
    private(set) var registerAttempted = false

    init() {}

    func register() {
        // Idempotent: callers (e.g. WelcomeView's conflict check in the past)
        // may invoke register() repeatedly. Each call used to unregister +
        // reinstall the handler + re-register, and every failed attempt
        // (another app/instance holding the hotkey, -9878) logged an error —
        // that was the log spam. Re-registering is only needed after an
        // explicit unregister() or a config change via updateHotKey().
        guard hotKeyRef == nil else { return }
        registerAttempted = true

        // Install the keyboard event handler once — a retry after a failed
        // RegisterEventHotKey must not stack duplicate handlers.
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
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
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5050), id: 1)
        let hotKeyStatus = RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if hotKeyStatus != noErr {
            if hotKeyStatus == eventHotKeyExistsErr {
                logger.error("Hotkey \(self.config.displayString) is already registered by another app or ClipMemory instance — global hotkey inactive")
            } else {
                logger.error("Failed to register hotkey \(self.config.displayString): \(hotKeyStatus)")
            }
        } else {
            logger.info("Hotkey registered: \(self.config.displayString)")
        }
    }

    /// Update hotkey and re-register. Saves to UserDefaults.
/// RS-3.4: rejects modifiers=0 — registering a bare key as global hotkey
/// is a terrible UX (every "V" keypress would fire it).
    func updateHotKey(keyCode: UInt32, modifiers: UInt32) {
        guard modifiers != 0 else {
            logger.error("Hotkey update rejected: modifiers must not be 0 (would register a bare key)")
            return
        }
        config = HotKeyConfig(keyCode: keyCode, modifiers: modifiers)
        config.save()
        unregister()
        register()
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
        // Note: Do not set hotKeyManager to nil manually — unregistering during app
        // shutdown is expected and harmless. The deinit here ensures cleanup if the
        // instance is released before app termination.
        unregister()
    }
}
