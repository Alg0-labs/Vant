import Carbon.HIToolbox
import Foundation

/// Registers a system-wide, push-to-talk ⌃+Space hotkey via the Carbon
/// Event Manager: `onPress` fires when the key goes down, `onRelease` when
/// it comes back up — recording lasts exactly as long as the key is held.
///
/// Carbon's `RegisterEventHotKey` is used deliberately instead of
/// `NSEvent.addGlobalMonitorForEvents`: it *consumes* the keystroke, so
/// ⌃+Space doesn't also type a space into whatever app has focus, it works
/// without Input Monitoring permission, and — unlike a raw key monitor —
/// it fires exactly once per physical press/release with no OS key-repeat
/// to filter out.
///
/// Note: ⌃+Space is also macOS's default "Select the previous input
/// source" shortcut (System Settings → Keyboard → Keyboard Shortcuts →
/// Input Sources). `RegisterEventHotKey` normally takes priority over that
/// system default, but if input-source switching stops firing after
/// installing LocalFlow, disable that shortcut there.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private static let signature: OSType = 0x4C464C57 // 'LFLW'
    private static let hotKeyID: UInt32 = 1

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func register() {
        var eventSpecs: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }

                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr, pressedID.id == HotkeyManager.hotKeyID else { return noErr }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                switch GetEventKind(eventRef) {
                case UInt32(kEventHotKeyPressed):
                    manager.onPress()
                case UInt32(kEventHotKeyReleased):
                    manager.onRelease()
                default:
                    break
                }
                return noErr
            },
            eventSpecs.count,
            &eventSpecs,
            selfPointer,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyManager.hotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
