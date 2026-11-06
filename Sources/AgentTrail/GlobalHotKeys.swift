import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission. Registration is exclusive: it
/// fails when another app has registered the same chord this way, and once it
/// succeeds the chord is consumed, so the app in front no longer receives it.
/// Chords taken by macOS itself, or by apps that watch keys another way, are
/// not reported.
@MainActor
final class GlobalHotKeys {
    /// A key code and Carbon modifier flags.
    struct Chord: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// "AgTr", so presses of other code's hot keys in this process are ignored.
    nonisolated private static let signature: OSType = 0x4167_5472

    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    /// False when the chord could not be registered, usually because another app holds it.
    func register(_ chord: Chord, action: @escaping () -> Void) -> Bool {
        guard installHandler() else { return false }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return false }
        references.append(reference)
        actions[nextID] = action
        nextID += 1
        return true
    }

    func unregisterAll() {
        for reference in references {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
        actions.removeAll()
    }

    /// The key that types `letter` in the user's Latin layout, so a chord shown
    /// as ⌃⌥J is the J key under Dvorak or AZERTY too. The ASCII-capable layout
    /// stays ABC or the like while a Cyrillic or other non-Latin one is
    /// selected. Falls back to `fallback`, the letter's US key.
    nonisolated static func keyCode(typing letter: Character, fallback: UInt32) -> UInt32 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let wanted = String(letter).lowercased()
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt32 in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            func types(_ code: UInt32) -> Bool {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count,
                                            &length, &characters)
                return status == noErr && String(utf16CodeUnits: characters, count: length).lowercased() == wanted
            }
            if types(fallback) { return fallback }
            return (UInt32(0)..<128).first(where: types) ?? fallback
        }
    }

    /// Hot key events arrive on the main thread through the application event target.
    private func installHandler() -> Bool {
        if handler != nil { return true }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { keys.fire(id.id) }
            return noErr
        }, 1, &pressed, context, &handler)
        return status == noErr
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }
}
