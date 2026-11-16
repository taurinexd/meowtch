import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey through Carbon: unlike an NSEvent monitor it needs
/// no Accessibility grant and swallows the keystroke, so ⌥ Space does not
/// also type into Meet. One at a time (the C callback cannot carry context).
@MainActor
final class CallHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static var current: CallHotKey?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
         action: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CallHotKey.current?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        if installed != noErr { NSLog("Vedetta call: hotkey handler failed: %d", installed) }
        let id = EventHotKeyID(signature: OSType(0x4D57_4348), id: 1)  // 'MWCH'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            NSLog("Vedetta call: hotkey registration failed: %d", status)
            hotKey = nil
        }
        Self.current = self
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        if Self.current === self { Self.current = nil }
    }

    var isRegistered: Bool { hotKey != nil }
}
