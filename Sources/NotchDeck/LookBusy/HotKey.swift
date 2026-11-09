import Carbon

/// System-wide hotkey through Carbon's RegisterEventHotKey: needs no Accessibility permission.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, action: @escaping () -> Void) {
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKey.actions[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            guard status == noErr else { return nil }
            HotKey.handlerInstalled = true
        }
        let hkID = EventHotKeyID(signature: OSType(0x4C4B_4253), id: id) // 'LKBS'
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        HotKey.actions[id] = action
    }

    /// RegisterEventHotKey succeeds even when another process holds the same keys,
    /// so the enabled shortcuts in System Settings are the only conflicts that can be detected.
    static func isUsedBySystem(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var result: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&result) == noErr,
              let shortcuts = result?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = cmdKey | shiftKey | optionKey | controlKey
        return shortcuts.contains {
            $0["kHISymbolicHotKeyEnabled"] as? Bool == true
                && $0["kHISymbolicHotKeyCode"] as? Int == Int(keyCode)
                && ($0["kHISymbolicHotKeyModifiers"] as? Int ?? 0) & mask == Int(modifiers)
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
