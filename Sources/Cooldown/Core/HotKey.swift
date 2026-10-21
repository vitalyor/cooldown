import Carbon.HIToolbox
import Foundation

/// ⌃⌥C anywhere opens or closes Cooldown's window. Carbon's hot keys need no permission.
enum HotKey {
    private static var reference: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    static func register() {
        guard reference == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { StatusController.shared?.toggleFromHotKey() } }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x434C444E), id: 1) // "CLDN"
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }
}
