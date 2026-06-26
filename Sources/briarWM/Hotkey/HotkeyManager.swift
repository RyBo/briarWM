import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon and reports the matched `KeyCombo` back.
/// Supports wholesale re-registration (config reload, modal mode switches).
final class HotkeyManager {
    typealias Handler = (KeyCombo) -> Void

    private var handler: Handler?
    private var registered: [UInt32: EventHotKeyRef] = [:]   // hotkey id -> ref
    private var comboByID: [UInt32: KeyCombo] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature = OSType(0x42524152) // 'BRAR'

    func install(handler: @escaping Handler) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().dispatch(hkID.id)
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// Replace all currently registered hotkeys with `combos`.
    func setHotkeys(_ combos: [KeyCombo]) {
        unregisterAll()
        for combo in combos { register(combo) }
    }

    private func dispatch(_ id: UInt32) {
        if let combo = comboByID[id] { handler?(combo) }
    }

    private func register(_ combo: KeyCombo) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = ref
            comboByID[id] = combo
        } else {
            Log.logger.warning("RegisterEventHotKey failed (status \(status)) for keyCode \(combo.keyCode)")
        }
    }

    private func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        comboByID.removeAll()
    }
}
