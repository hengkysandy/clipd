import AppKit
import Carbon.HIToolbox

/// A global hotkey via Carbon RegisterEventHotKey.
///
/// Measured: this registers and fires with AXIsProcessTrusted() false, so the
/// hotkey needs no Accessibility permission at all. Only posting the paste
/// does. It also consumes the key, so the app underneath never sees it. That
/// was verified by poisoning the clipboard with a marker string and confirming
/// the target app never pasted it.
///
/// Rejected: NSEvent.addGlobalMonitorForEvents, which requires Accessibility
/// and does NOT consume the event, so Cmd+Shift+V would also reach the app
/// underneath and trigger paste-and-match-style on every activation.
///
/// Known limitation, measured: two apps CAN both register the same hotkey and
/// both receive it. If the real Paste app is running, both will open.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    // Swift 6 rejects plain static mutable state. These are only ever touched
    // on the main actor, which the isolation here makes explicit rather than
    // assumed.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_V),
          modifiers: UInt32 = UInt32(cmdKey | shiftKey),
          handler: @escaping () -> Void) {
        HotKey.installHandlerOnce()
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5044), id: id) // 'CLPD'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Diag.panel.error("RegisterEventHotKey failed, status \(status, privacy: .public)")
            HotKey.handlers[id] = nil
            return nil
        }
        Diag.panel.info("hotkey registered, id \(self.id, privacy: .public)")
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The Carbon callback is a C function pointer, so it cannot capture
        // context. It reads the hotkey id out of the event and dispatches.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let firedID = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[firedID]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
